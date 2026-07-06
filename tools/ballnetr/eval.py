#!/usr/bin/env python3
"""
BallNet-R Phase 1b · Eval visualization

Loads the best checkpoint from training, runs it on the held-out val split,
and produces:

  1. A summary text report:
       • overall val loss
       • peak-error distribution (< 10 / < 30 / < 50 / > 50 px buckets)
       • per-visibility breakdown (visible, occluded, not_visible)
       • model-confidence histogram
  2. Per-sample side-by-side visualizations saved to eval/samples/:
       • left:  input frame (from current-frame RGB channel)
       • right: predicted heatmap over the frame + ground-truth marker

You need this because "val loss = 0.0001" is meaningless — a model that
predicts zeros everywhere gets low loss too. Only eyeballing predictions
tells you if the model actually learned to find the ball.

Usage:
  python eval.py                     # sensible defaults
  python eval.py --n-samples 60      # more visualizations
  python eval.py --checkpoint <path> # different checkpoint
"""

import argparse
import json
import math
import shutil
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont

from model import BallNetR
from dataset import BallDataset, load_labels, split_by_game, MODEL_H, MODEL_W


REPO_ROOT = Path(__file__).resolve().parents[2]
TRAINING_ROOT = REPO_ROOT / "training-data"
BALLNETR_DIR = Path(__file__).resolve().parent


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--checkpoint", type=Path, default=BALLNETR_DIR / "checkpoints" / "ballnetr_v0_best.pt")
    p.add_argument("--out-dir", type=Path, default=BALLNETR_DIR / "eval")
    p.add_argument("--n-samples", type=int, default=40,
                   help="How many val samples to render side-by-side (approx even split by visibility).")
    p.add_argument("--val-fraction", type=float, default=0.15)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--device", type=str, default="cpu",
                   help="cpu is fine and won't fight the training loop for MPS.")
    return p.parse_args()


def load_checkpoint(path: Path, device: torch.device) -> tuple[BallNetR, dict]:
    state = torch.load(path, map_location=device)
    model = BallNetR(in_channels=14, norm="batchnorm").to(device)
    model.load_state_dict(state["model"])
    model.eval()
    return model, state


def render_sample(rgb_np: np.ndarray, pred_hm: np.ndarray, target_hm: np.ndarray,
                  gt_xy: tuple[float, float] | None,
                  pred_xy: tuple[float, float],
                  peak_err: float, conf: float, meta: str) -> Image.Image:
    """
    Compose a side-by-side visualization:
      left  = raw input frame (288 × 512)
      right = same frame with predicted heatmap overlay (red channel) +
              green X on ground truth + blue O on predicted argmax
    """
    H, W = MODEL_H, MODEL_W
    frame = (rgb_np * 255).astype(np.uint8)                  # H×W×3
    left = Image.fromarray(frame, mode="RGB")

    # Right panel: overlay predicted heatmap in red
    overlay = frame.copy()
    hm = np.clip(pred_hm, 0, 1)                                # H×W
    hm_u8 = (hm * 255).astype(np.uint8)
    overlay[..., 0] = np.maximum(overlay[..., 0], hm_u8)       # boost R by heatmap
    right = Image.fromarray(overlay, mode="RGB")

    draw = ImageDraw.Draw(right)
    if gt_xy is not None:
        gx, gy = gt_xy
        R = 12
        draw.line([(gx - R, gy - R), (gx + R, gy + R)], fill=(80, 220, 80), width=3)
        draw.line([(gx - R, gy + R), (gx + R, gy - R)], fill=(80, 220, 80), width=3)
    px, py = pred_xy
    R = 12
    draw.ellipse([px - R, py - R, px + R, py + R], outline=(90, 160, 255), width=3)

    # Concat side-by-side with a divider
    W2 = W * 2 + 4
    composite = Image.new("RGB", (W2, H + 40), color=(20, 20, 20))
    composite.paste(left, (0, 0))
    composite.paste(right, (W + 4, 0))

    # Metadata band at the bottom
    band = ImageDraw.Draw(composite)
    txt = f"{meta}   err={peak_err:.1f}px   conf={conf:.3f}"
    band.text((6, H + 8), txt, fill=(220, 220, 220))
    return composite


def main():
    args = parse_args()
    device = torch.device(args.device)
    if not args.checkpoint.exists():
        print(f"❌ checkpoint not found: {args.checkpoint}")
        print("   (this script expects the best checkpoint after train.py has run)")
        return

    print(f"Loading checkpoint: {args.checkpoint}")
    model, state = load_checkpoint(args.checkpoint, device)
    print(f"  trained {state.get('epoch', '?')} epochs, "
          f"val_loss={state.get('val_loss', float('nan')):.5f}, "
          f"val_peak_err={state.get('val_peak_err_px', float('nan')):.1f}px")

    # Rebuild the same val split as training (seed=42 in dataset.split_by_game).
    labels_path = TRAINING_ROOT / "labels" / "labels.jsonl"
    cands_path = TRAINING_ROOT / "labels" / "candidates.jsonl"
    records = load_labels(labels_path, cands_path)
    _, val_recs, val_games = split_by_game(records, args.val_fraction, args.seed)
    print(f"val samples: {len(val_recs)}  from games: {sorted(val_games)}")

    val_ds = BallDataset(val_recs, TRAINING_ROOT, augment=False)

    # Prepare output dir (nuke previous)
    if args.out_dir.exists():
        shutil.rmtree(args.out_dir)
    (args.out_dir / "samples").mkdir(parents=True)

    # Run over the entire val set, gather metrics
    per_sample = []  # (visibility, peak_err, conf, index)
    with torch.no_grad():
        for i in range(len(val_ds)):
            x, y, w = val_ds[i]
            xb = x.unsqueeze(0).to(device)
            pred = model(xb)[0, 0]                              # H×W

            tgt = y[0]
            visibility = val_recs[i]["label"]["visibility"]

            # Predicted peak
            p_flat = pred.argmax().item()
            py, px = divmod(p_flat, MODEL_W)
            pred_conf = float(pred.max().item())

            # Ground-truth peak (if any)
            if visibility != "not_visible":
                t_flat = tgt.argmax().item()
                ty, tx = divmod(t_flat, MODEL_W)
                peak_err = math.hypot(px - tx, py - ty)
            else:
                peak_err = float("nan")

            per_sample.append({
                "index": i,
                "visibility": visibility,
                "peak_err": peak_err,
                "pred_conf": pred_conf,
                "video": val_recs[i]["source_video"],
                "source_time_sec": val_recs[i].get("source_time_sec", 0.0),
            })

    # ── Metrics summary ──────────────────────────────────────────────
    visible = [s for s in per_sample if s["visibility"] == "visible"]
    occluded = [s for s in per_sample if s["visibility"] == "occluded"]
    invis = [s for s in per_sample if s["visibility"] == "not_visible"]

    def pct(l, thresh):
        if not l:
            return 0.0
        return 100.0 * sum(1 for s in l if s["peak_err"] < thresh) / len(l)

    def mean(lst, key):
        vals = [s[key] for s in lst if not (isinstance(s[key], float) and math.isnan(s[key]))]
        return float(np.mean(vals)) if vals else float("nan")

    report = []
    report.append("=" * 60)
    report.append(f"BallNet-R v0 · eval report")
    report.append("=" * 60)
    report.append(f"checkpoint:   {args.checkpoint}")
    report.append(f"epoch:        {state.get('epoch', '?')}")
    report.append(f"val loss:     {state.get('val_loss', float('nan')):.5f}")
    report.append(f"held-out gs:  {sorted(val_games)}")
    report.append("")
    report.append(f"val samples:  visible={len(visible)}  occluded={len(occluded)}  not_visible={len(invis)}")
    report.append("")
    report.append("Peak-error (VISIBLE samples, lower = better)")
    report.append(f"  < 10 px:   {pct(visible, 10):.1f}%")
    report.append(f"  < 30 px:   {pct(visible, 30):.1f}%")
    report.append(f"  < 50 px:   {pct(visible, 50):.1f}%")
    report.append(f"  < 100 px:  {pct(visible, 100):.1f}%")
    report.append(f"  mean:      {mean(visible, 'peak_err'):.1f}px")
    report.append("")
    report.append("Peak-error (OCCLUDED samples)")
    report.append(f"  mean:      {mean(occluded, 'peak_err'):.1f}px")
    report.append(f"  < 50 px:   {pct(occluded, 50):.1f}%")
    report.append("")
    report.append("Predicted-heatmap peak confidence")
    report.append(f"  visible mean:     {mean(visible, 'pred_conf'):.3f}")
    report.append(f"  occluded mean:    {mean(occluded, 'pred_conf'):.3f}")
    report.append(f"  not_visible mean: {mean(invis, 'pred_conf'):.3f}  (should be LOW)")
    report.append("")
    report_text = "\n".join(report)
    print(report_text)
    (args.out_dir / "report.txt").write_text(report_text + "\n")

    # ── Sample visualizations ────────────────────────────────────────
    # Pick a mix: roughly balanced across visibility, and within visible mix
    # good/bad predictions.
    def pick(subset, n):
        if len(subset) <= n:
            return subset
        idxs = np.linspace(0, len(subset) - 1, n).astype(int)
        return [subset[i] for i in idxs]

    n_per = max(1, args.n_samples // 3)
    picks = []
    # Sort visible by peak_err so we get some good and some bad
    picks += pick(sorted(visible, key=lambda s: s["peak_err"]), n_per)
    picks += pick(occluded, n_per)
    picks += pick(invis, n_per)

    print(f"\nRendering {len(picks)} sample visualizations…")
    with torch.no_grad():
        for j, s in enumerate(picks):
            i = s["index"]
            x, y, _w = val_ds[i]
            xb = x.unsqueeze(0).to(device)
            pred = model(xb)[0, 0].cpu().numpy()               # H×W

            # Extract the current-frame RGB from the input tensor (channels 3-5)
            rgb = x[3:6].cpu().numpy().transpose(1, 2, 0)       # H×W×3, [0..1]

            visibility = val_recs[i]["label"]["visibility"]
            tgt_hm = y[0].cpu().numpy()

            # Coords for annotation
            gt_xy = None
            if visibility != "not_visible":
                t_flat = int(tgt_hm.argmax())
                ty, tx = divmod(t_flat, MODEL_W)
                gt_xy = (float(tx), float(ty))
            p_flat = int(pred.argmax())
            py, px = divmod(p_flat, MODEL_W)
            pred_xy = (float(px), float(py))

            meta = f"{Path(s['video']).stem[:32]} @ {int(s['source_time_sec'] // 60):02d}:{int(s['source_time_sec'] % 60):02d}  vis={visibility}"
            img = render_sample(rgb, pred, tgt_hm, gt_xy, pred_xy, s["peak_err"], s["pred_conf"], meta)

            bucket = "good" if visibility == "visible" and s["peak_err"] < 20 else \
                     "bad" if visibility == "visible" and s["peak_err"] >= 50 else \
                     visibility
            out = args.out_dir / "samples" / f"{j:03d}_{bucket}.png"
            img.save(out)

    print(f"✅ Wrote {len(picks)} PNGs to {args.out_dir / 'samples'}")
    print(f"✅ Report at {args.out_dir / 'report.txt'}")


if __name__ == "__main__":
    main()
