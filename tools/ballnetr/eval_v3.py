#!/usr/bin/env python3
"""
BallNet-R v3 · eval — distribution report at 960×544.

Reports peak-error normalized to % of frame width so it's directly
comparable to v0-v2 (which ran at 512×288). The training-time mean
peak_err is a liar (bimodal distribution) — this gives the real story.

v0 reference (512 canvas): 55.2% <10px = <1.95% width, 67% <30px = <5.9% width.
Comparable v3 buckets below use the same % thresholds.
"""

import argparse
import math
from pathlib import Path

import numpy as np
import torch

from model import BallNetR
from dataset_v3 import TripletDatasetV3, MODEL_H, MODEL_W
from dataset_v1 import load_triplets, split_by_game

REPO_ROOT = Path(__file__).resolve().parents[2]
TRAINING_ROOT = REPO_ROOT / "training-data"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--checkpoint", type=Path, default=Path(__file__).resolve().parent / "checkpoints" / "ballnetr_v3_best.pt")
    p.add_argument("--triplets", type=Path, default=TRAINING_ROOT / "labels" / "triplets_hires.jsonl")
    p.add_argument("--val-fraction", type=float, default=0.15)
    p.add_argument("--seed", type=int, default=42)
    return p.parse_args()


def main():
    args = parse_args()
    dev = torch.device("cpu")
    state = torch.load(args.checkpoint, map_location=dev)
    model = BallNetR(in_channels=14, norm="batchnorm").to(dev)
    model.load_state_dict(state["model"])
    model.eval()
    print(f"checkpoint: {args.checkpoint}  epoch {state.get('epoch','?')}  val_loss {state.get('val_loss',float('nan')):.5f}")

    records = load_triplets(args.triplets)
    _, val_recs, val_games = split_by_game(records, args.val_fraction, args.seed)
    val_ds = TripletDatasetV3(val_recs, TRAINING_ROOT, augment=False)
    print(f"val: {len(val_recs)} samples from {sorted(val_games)}\n")

    # width-normalized error thresholds (% of frame width) — comparable across resolutions
    pct_thresholds = [1.95, 3.9, 5.9, 9.8, 19.5]  # 2%, 4%, 6%, 10%, 20% (approx v0's px buckets)

    vis_errs_pct = []
    occ_errs_pct = []
    confs = {"visible": [], "occluded": [], "not_visible": []}

    with torch.no_grad():
        for i in range(len(val_ds)):
            x, y, w = val_ds[i]
            pred = model(x.unsqueeze(0))[0, 0]
            vis = val_recs[i]["label"]["visibility"]
            confs[vis].append(float(pred.max()))
            if vis == "not_visible":
                continue
            t_flat = int(y[0].argmax()); ty, tx = divmod(t_flat, MODEL_W)
            p_flat = int(pred.argmax()); py, px = divmod(p_flat, MODEL_W)
            err_px = math.hypot(px - tx, py - ty)
            err_pct = 100.0 * err_px / MODEL_W
            (vis_errs_pct if vis == "visible" else occ_errs_pct).append(err_pct)

    def dist(errs, label):
        if not errs:
            print(f"{label}: no samples"); return
        errs = np.array(errs)
        print(f"{label} (n={len(errs)}):")
        for t in pct_thresholds:
            print(f"  < {t:4.1f}% width: {100*np.mean(errs < t):5.1f}%")
        print(f"  mean: {errs.mean():.1f}% width\n")

    print("=" * 55)
    print("v3 peak-error distribution (% of frame width)")
    print("=" * 55)
    print("v0 reference: 55.2% <1.95%, 67% <5.9%, 72% <9.8%\n")
    dist(vis_errs_pct, "VISIBLE")
    dist(occ_errs_pct, "OCCLUDED")
    print("Confidence (should be higher for visible than not_visible):")
    for k in ("visible", "occluded", "not_visible"):
        c = confs[k]
        print(f"  {k:12s}: {np.mean(c):.3f}" if c else f"  {k}: none")


if __name__ == "__main__":
    main()
