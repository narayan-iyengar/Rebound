#!/usr/bin/env python3
"""
BallNet-R Phase 1a · Labeling tool

Loads candidates.jsonl, presents each frame in a Tk window, lets you
either accept the HSV suggestion (Space) or click the actual ball position.
Appends one JSON line per label to labels.jsonl. Fully resumable — restart
anytime, tool skips frames already labeled.

Keyboard:
  click     mark ball position at click
  space     accept HSV suggestion (green marker)
  v         no ball visible in this frame
  o         ball occluded / obscured, best guess
  →/n       save current + next
  ←/p       save current + prev (rewind)
  ⌘Z / u    undo last committed label
  s         save + quit
  q         quit without saving current

Ordering:
  auto bucket first (quick verifies), then queue in shuffled order to
  avoid clumping on one game.
"""

import argparse
import getpass
import json
import random
import tkinter as tk
from datetime import datetime, timezone
from pathlib import Path
from tkinter import messagebox

from PIL import Image, ImageTk, ImageDraw


REPO_ROOT = Path(__file__).resolve().parents[2]
TRAINING_ROOT = REPO_ROOT / "training-data"
DISPLAY_SCALE = 2  # 640×360 candidates → 1280×720 on screen for click accuracy


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--candidates", type=Path, default=TRAINING_ROOT / "labels" / "candidates.jsonl")
    p.add_argument("--labels-out", type=Path, default=TRAINING_ROOT / "labels" / "labels.jsonl")
    p.add_argument("--frames-root", type=Path, default=TRAINING_ROOT,
                   help="Path prefix for frame_path fields in candidates.jsonl. Default: training-data/")
    p.add_argument("--labeler", type=str, default=getpass.getuser())
    p.add_argument("--seed", type=int, default=42,
                   help="Shuffle seed for the queue bucket. Change to re-shuffle a fresh session.")
    return p.parse_args()


def load_candidates(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def load_completed(path: Path) -> set[str]:
    if not path.exists():
        return set()
    done = set()
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            done.add(json.loads(line)["frame_path"])
        except Exception:
            pass
    return done


def order_candidates(cands: list[dict], seed: int) -> list[dict]:
    autos = [c for c in cands if c["detection"]["bucket"] == "auto"]
    queue = [c for c in cands if c["detection"]["bucket"] != "auto"]
    rng = random.Random(seed)
    rng.shuffle(queue)
    return autos + queue


class LabelingApp:
    def __init__(self, root: tk.Tk, args, ordered: list[dict], completed: set[str]):
        self.root = root
        self.args = args
        self.ordered = ordered
        self.completed = completed
        self.total = len(ordered)
        self.total_auto = sum(1 for c in ordered if c["detection"]["bucket"] == "auto")

        # Filter out already-completed frames for the working list, keep original indices
        self.pending = [c for c in ordered if c["frame_path"] not in completed]
        if not self.pending:
            messagebox.showinfo("All done", f"All {self.total} candidates already labeled.")
            root.quit()
            return

        self.i = 0
        self.click_xy: tuple[int, int] | None = None  # in image coords (640×360)
        self.undo_stack: list[dict] = []  # last-N committed labels for undo
        self.session_count = 0
        self.done_count = len(completed)

        # UI
        root.title("BallNet-R labeling")
        root.geometry("1300x820")
        root.configure(bg="#111")

        self.status = tk.Label(root, text="", bg="#111", fg="#eee", font=("SF Mono", 12), anchor="w", justify="left")
        self.status.pack(fill="x", padx=8, pady=(6, 0))

        self.canvas = tk.Canvas(root, width=640 * DISPLAY_SCALE, height=360 * DISPLAY_SCALE,
                                bg="#000", highlightthickness=0)
        self.canvas.pack(padx=8, pady=8)

        self.hint = tk.Label(
            root,
            text="click=mark  space=accept HSV  v=no ball  o=occluded   →/n=next  ←/p=prev  ⌘Z/u=undo  s=save+quit",
            bg="#111", fg="#888", font=("SF Mono", 11), anchor="w", justify="left"
        )
        self.hint.pack(fill="x", padx=8, pady=(0, 6))

        # Bindings
        self.canvas.bind("<Button-1>", self._on_click)
        root.bind("<space>", lambda e: self._commit_and_advance("accept_hsv", 1))
        root.bind("<Right>", lambda e: self._commit_and_advance("auto_choice", 1))
        root.bind("n", lambda e: self._commit_and_advance("auto_choice", 1))
        root.bind("<Left>", lambda e: self._commit_and_advance("auto_choice", -1))
        root.bind("p", lambda e: self._commit_and_advance("auto_choice", -1))
        root.bind("v", lambda e: self._commit_and_advance("no_ball", 1))
        root.bind("o", lambda e: self._commit_and_advance("occluded", 1))
        root.bind("<Command-z>", lambda e: self._undo())
        root.bind("u", lambda e: self._undo())
        root.bind("s", lambda e: self._save_and_quit())
        root.bind("q", lambda e: root.quit())

        self.image_id = None
        self.hsv_marker_id = None
        self.click_marker_id = None
        self._render()

    # ── I/O ─────────────────────────────────────────────────────────

    def _current(self) -> dict:
        return self.pending[self.i]

    def _resolve_frame_path(self, rec) -> Path:
        return (self.args.frames_root / rec["frame_path"]).resolve()

    def _load_image(self, rec) -> ImageTk.PhotoImage:
        p = self._resolve_frame_path(rec)
        img = Image.open(p).convert("RGB")
        img = img.resize((640 * DISPLAY_SCALE, 360 * DISPLAY_SCALE), Image.NEAREST)
        return ImageTk.PhotoImage(img)

    # ── Rendering ───────────────────────────────────────────────────

    def _render(self):
        rec = self._current()
        self.click_xy = None

        # Image
        self.photo = self._load_image(rec)
        self.canvas.delete("all")
        self.image_id = self.canvas.create_image(0, 0, anchor="nw", image=self.photo)

        # HSV suggestion marker (green X)
        dx = rec["detection"]["x"] * DISPLAY_SCALE
        dy = rec["detection"]["y"] * DISPLAY_SCALE
        R = 14
        for (x1, y1, x2, y2) in [(dx - R, dy - R, dx + R, dy + R), (dx - R, dy + R, dx + R, dy - R)]:
            self.canvas.create_line(x1, y1, x2, y2, fill="#7fce65", width=3)
        self.canvas.create_oval(dx - R - 4, dy - R - 4, dx + R + 4, dy + R + 4,
                                outline="#7fce65", width=2)

        # Status bar
        bucket = rec["detection"]["bucket"]
        conf = rec["detection"]["confidence"]
        pending_left = len(self.pending) - self.i
        game_name = Path(rec["source_video"]).stem[:60]
        t = rec.get("source_time_sec", 0)
        mm, ss = divmod(int(t), 60)
        self.status.config(text=(
            f"{game_name}  @ {mm:02d}:{ss:02d}   bucket={bucket}  hsv-conf={conf:.2f}\n"
            f"pending {pending_left}   total done {self.done_count}/{self.total}   this session +{self.session_count}"
        ))

    # ── Interactions ────────────────────────────────────────────────

    def _on_click(self, event):
        # Convert screen coords → image coords (640×360)
        ix = event.x / DISPLAY_SCALE
        iy = event.y / DISPLAY_SCALE
        if 0 <= ix < 640 and 0 <= iy < 360:
            self.click_xy = (round(ix, 2), round(iy, 2))
            # Draw blue circle
            if self.click_marker_id is not None:
                self.canvas.delete(self.click_marker_id)
            self.click_marker_id = self.canvas.create_oval(
                event.x - 12, event.y - 12, event.x + 12, event.y + 12,
                outline="#4a9eff", width=3
            )

    def _commit_and_advance(self, mode: str, direction: int):
        """
        mode:
          'accept_hsv'  → use HSV suggestion coords, visibility=visible
          'auto_choice' → if user clicked, use click; else fall back to HSV (visible)
          'no_ball'     → visibility=not_visible, no x/y
          'occluded'    → visibility=occluded, use last-clicked coords if any
        direction: +1 next, -1 previous
        """
        rec = self._current()
        det = rec["detection"]

        if mode == "no_ball":
            label = {"visibility": "not_visible"}
        elif mode == "occluded":
            xy = self.click_xy or (det["x"], det["y"])
            label = {"visibility": "occluded", "x": xy[0], "y": xy[1]}
        elif mode == "accept_hsv":
            label = {"visibility": "visible", "x": det["x"], "y": det["y"]}
        else:  # auto_choice
            xy = self.click_xy or (det["x"], det["y"])
            label = {"visibility": "visible", "x": xy[0], "y": xy[1]}

        out = {
            "frame_path": rec["frame_path"],
            **label,
            "labeler": self.args.labeler,
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        with self.args.labels_out.open("a") as f:
            f.write(json.dumps(out) + "\n")

        self.undo_stack.append(out)
        self.session_count += 1
        self.done_count += 1

        self.i = max(0, min(len(self.pending) - 1, self.i + direction))
        if self.i >= len(self.pending):
            messagebox.showinfo("Done", f"Session complete. Labeled {self.session_count} in this run.")
            self.root.quit()
            return
        self._render()

    def _undo(self):
        if not self.undo_stack:
            return
        # Remove last line from labels.jsonl
        last = self.undo_stack.pop()
        lines = self.args.labels_out.read_text().splitlines()
        # Drop the last matching frame_path (safest — always the tail)
        for j in range(len(lines) - 1, -1, -1):
            try:
                if json.loads(lines[j])["frame_path"] == last["frame_path"]:
                    del lines[j]
                    break
            except Exception:
                continue
        self.args.labels_out.write_text("\n".join(lines) + ("\n" if lines else ""))
        self.session_count -= 1
        self.done_count -= 1
        self.i = max(0, self.i - 1)
        self._render()

    def _save_and_quit(self):
        # Autosave every commit — nothing else to do
        self.root.quit()


def main():
    args = parse_args()
    if not args.candidates.exists():
        print(f"❌ candidates file missing: {args.candidates}")
        return
    args.labels_out.parent.mkdir(parents=True, exist_ok=True)
    args.labels_out.touch(exist_ok=True)

    candidates = load_candidates(args.candidates)
    completed = load_completed(args.labels_out)
    ordered = order_candidates(candidates, args.seed)

    print(f"Loaded {len(candidates):,} candidates.")
    print(f"Already labeled: {len(completed):,}")
    print(f"Remaining: {len(candidates) - len(completed):,}")

    root = tk.Tk()
    app = LabelingApp(root, args, ordered, completed)
    root.mainloop()


if __name__ == "__main__":
    main()
