#!/usr/bin/env python3
"""
BallNet-R v1 · Extract 3-frame temporal stacks

For each already-labeled frame in labels.jsonl, extract three consecutive frames
from the source video — [f - stride, f, f + stride] — so the v1 training pipeline
can feed a real temporal signal (past / current / future) to the 14-channel input.

v0 zero-filled the past+future channels. v1 uses this script to fill them for real.

Output layout:
  training-data/frames3/sahil/<game-slug>/NNNNNNN.jpg   (raw downsampled frames,
                                                          named by source frame index)
  training-data/labels/triplets.jsonl                   (one JSON per labeled sample:
                                                          {label, prev_path, curr_path,
                                                           next_path, stride})

Naming by raw frame index (not by label) means shared frames aren't duplicated —
when two nearby labels overlap on the same past/future frame, we only save one JPG.

Usage:
  python extract_triplets.py                    # default stride=3 (~100 ms at 30fps)
  python extract_triplets.py --stride 5         # ~167 ms — more motion per stack
"""

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np


REPO_ROOT = Path(__file__).resolve().parents[2]
TRAINING_ROOT = REPO_ROOT / "training-data"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--videos-dir", type=Path, default=TRAINING_ROOT / "videos" / "sahil")
    p.add_argument("--frames3-dir", type=Path, default=TRAINING_ROOT / "frames3" / "sahil")
    p.add_argument("--labels-file", type=Path, default=TRAINING_ROOT / "labels" / "labels.jsonl")
    p.add_argument("--candidates-file", type=Path, default=TRAINING_ROOT / "labels" / "candidates.jsonl")
    p.add_argument("--triplets-out", type=Path, default=TRAINING_ROOT / "labels" / "triplets.jsonl")
    p.add_argument("--target-w", type=int, default=640)
    p.add_argument("--target-h", type=int, default=360)
    p.add_argument("--jpeg-quality", type=int, default=85)
    p.add_argument("--stride", type=int, default=3,
                   help="Frame offset between past/current and current/future. Default 3 (~100 ms at 30fps).")
    return p.parse_args()


def slug_of(source_video: str) -> str:
    """Match extract.py's slug logic."""
    import re
    stem = Path(source_video).stem.lower()
    return re.sub(r"[^a-z0-9]+", "_", stem).strip("_")


def load_labels_with_candidates(labels_file: Path, candidates_file: Path) -> list[dict]:
    """Return one dict per label with source_video and source_frame merged in."""
    cand_by_path = {}
    for line in candidates_file.read_text().splitlines():
        if line.strip():
            r = json.loads(line)
            cand_by_path[r["frame_path"]] = r

    out = []
    for line in labels_file.read_text().splitlines():
        if not line.strip():
            continue
        lab = json.loads(line)
        cand = cand_by_path.get(lab["frame_path"])
        if cand is None:
            continue
        out.append({
            "label": lab,
            "source_video": cand["source_video"],
            "source_frame": cand["source_frame"],
            "source_time_sec": cand.get("source_time_sec", 0.0),
            "resolution": cand.get("resolution", [640, 360]),
        })
    return out


def process_video(video_path: Path, indexed_labels: list[dict], args, out_root: Path) -> tuple[int, int]:
    """
    indexed_labels: labels for this specific video (subset of load_labels output).

    Walks the video sequentially, saves every frame index needed by any label
    (as curr, prev, or next) to disk exactly once. Returns (triplets_written, unique_frames_saved).
    """
    game_slug = slug_of(video_path.name)
    frames_dir = out_root / game_slug
    frames_dir.mkdir(parents=True, exist_ok=True)

    stride = args.stride
    # Union of all frame indices we need: {f-stride, f, f+stride for each label}
    needed = set()
    for lab in indexed_labels:
        f = lab["source_frame"]
        needed.add(f)
        needed.add(max(0, f - stride))
        needed.add(f + stride)  # cap-clamped at read time by termination

    if not needed:
        return 0, 0

    max_needed = max(needed)

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print(f"  ⚠️  could not open {video_path.name}", file=sys.stderr)
        return 0, 0

    src_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    print(f"── {video_path.name}")
    print(f"   src_fps={src_fps:.1f}  total={total_frames}  needed={len(needed)}  max_needed={max_needed}")

    # Track which frames actually got captured (in case max_needed > actual total)
    saved: set[int] = set()
    frame_idx = 0
    while frame_idx <= max_needed:
        ok, frame = cap.read()
        if not ok:
            break

        if frame_idx in needed:
            small = cv2.resize(frame, (args.target_w, args.target_h), interpolation=cv2.INTER_AREA)
            jpg_path = frames_dir / f"{frame_idx:07d}.jpg"
            cv2.imwrite(str(jpg_path), small, [int(cv2.IMWRITE_JPEG_QUALITY), args.jpeg_quality])
            saved.add(frame_idx)

        frame_idx += 1

        if frame_idx % (int(src_fps) * 60) == 0:
            pct = 100.0 * frame_idx / max(total_frames, 1)
            print(f"   … {frame_idx}/{total_frames} ({pct:.0f}%)  saved={len(saved)}")

    cap.release()
    print(f"   ✅ saved {len(saved)} unique frames from this video")
    return len(indexed_labels), len(saved)


def emit_triplets(indexed_labels: list[dict], out_root: Path, args, jsonl_out) -> tuple[int, int]:
    """For each label, resolve prev/curr/next paths and write one JSONL line."""
    stride = args.stride
    written = clamped = 0

    for lab in indexed_labels:
        game_slug = slug_of(lab["source_video"])
        f = lab["source_frame"]
        fp = max(0, f - stride)
        fn = f + stride

        # Resolve paths (relative to training-data/)
        base_dir = out_root / game_slug
        prev_path = base_dir / f"{fp:07d}.jpg"
        curr_path = base_dir / f"{f:07d}.jpg"
        next_path = base_dir / f"{fn:07d}.jpg"

        # If next is past end of video, we won't have that JPG — fall back to curr
        if not next_path.exists():
            next_path = curr_path
            clamped += 1
        # If prev is missing (near-start clip), fall back to curr
        if not prev_path.exists():
            prev_path = curr_path
            clamped += 1

        record = {
            "label": lab["label"],
            "source_video": lab["source_video"],
            "source_frame": f,
            "source_time_sec": lab["source_time_sec"],
            "stride": stride,
            "prev_path": str(prev_path.relative_to(TRAINING_ROOT)),
            "curr_path": str(curr_path.relative_to(TRAINING_ROOT)),
            "next_path": str(next_path.relative_to(TRAINING_ROOT)),
            "resolution": [args.target_w, args.target_h],
        }
        jsonl_out.write(json.dumps(record) + "\n")
        written += 1

    return written, clamped


def main():
    args = parse_args()
    videos_dir = args.videos_dir.resolve()
    frames3_dir = args.frames3_dir.resolve()
    labels_file = args.labels_file.resolve()
    triplets_out = args.triplets_out.resolve()

    if not labels_file.exists():
        print(f"❌ labels file not found: {labels_file}", file=sys.stderr)
        sys.exit(1)
    if not videos_dir.exists():
        print(f"❌ videos dir not found: {videos_dir}", file=sys.stderr)
        sys.exit(1)

    frames3_dir.mkdir(parents=True, exist_ok=True)
    triplets_out.parent.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("BallNet-R v1 · 3-frame stack extractor")
    print("=" * 60)
    print(f"videos:      {videos_dir}")
    print(f"frames3:     {frames3_dir}")
    print(f"labels in:   {labels_file}")
    print(f"triplets:    {triplets_out}")
    print(f"stride:      {args.stride}  ({1000 * args.stride / 30:.0f} ms at 30fps)")
    print(f"target:      {args.target_w}×{args.target_h}")
    print()

    # Load labels + merge with candidates for source_video/frame lookup
    indexed = load_labels_with_candidates(labels_file, args.candidates_file)
    print(f"total labeled: {len(indexed)}")

    # Group by source video
    by_video: dict[str, list[dict]] = defaultdict(list)
    for lab in indexed:
        by_video[lab["source_video"]].append(lab)

    # Extract frames per video
    total_labels = total_frames_saved = 0
    for video_name, labels in sorted(by_video.items()):
        video_path = videos_dir / video_name
        if not video_path.exists():
            print(f"  ⚠️  video missing on disk: {video_name}")
            continue
        n_lab, n_saved = process_video(video_path, labels, args, frames3_dir)
        total_labels += n_lab
        total_frames_saved += n_saved
        print()

    # Now write the triplets JSONL, resolving prev/curr/next paths
    with open(triplets_out, "w") as jsonl_out:
        written, clamped = emit_triplets(indexed, frames3_dir, args, jsonl_out)

    print("=" * 60)
    print("Done.")
    print(f"  labels processed:  {total_labels:,}")
    print(f"  unique frames saved:  {total_frames_saved:,}")
    print(f"  triplets written:  {written:,}")
    print(f"  edge-clamped ends: {clamped}  (fell back to curr when prev/next unavailable)")
    print(f"  output:            {triplets_out}")
    print("=" * 60)


if __name__ == "__main__":
    main()
