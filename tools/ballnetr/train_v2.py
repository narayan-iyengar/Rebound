#!/usr/bin/env python3
"""
BallNet-R Phase 1b · Training script (v0)

Reads training-data/labels/labels.jsonl + candidates.jsonl, trains the
BallNet-R U-Net (§5.1-5.3 of design doc) end-to-end, saves the best
checkpoint by validation loss, and exports the final model to a
CoreML .mlpackage so we can wire it into Rebound.

Runs on Apple Silicon MPS by default. Falls back to CPU if MPS is unavailable.

Simplifications for v0 (documented in design doc §14 v1.0 entry when we
land this):
  • Single-frame input (past/future channels zero-filled)
  • No court-quad or player-density priors yet (zero channels 12-13)
  • No TrackNetV3 warm-init (weights not conveniently downloadable; from
    scratch is fine for a first pass with ~2200 samples)
  • Focal weighted BCE loss with no auxiliary court penalty (that's v1)

Usage:
  python train.py                         # sensible defaults
  python train.py --epochs 40 --lr 1e-3
"""

import argparse
import json
import math
from pathlib import Path
from datetime import datetime

import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader

from model import BallNetR, count_params
from dataset_v2 import TripletDatasetV2, load_triplets, split_by_game
from dataset import MODEL_H, MODEL_W


REPO_ROOT = Path(__file__).resolve().parents[2]
TRAINING_ROOT = REPO_ROOT / "training-data"
CKPT_DIR = Path(__file__).resolve().parent / "checkpoints"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--epochs", type=int, default=60)
    p.add_argument("--batch-size", type=int, default=8)
    p.add_argument("--lr", type=float, default=1e-3)
    p.add_argument("--weight-decay", type=float, default=1e-4)
    p.add_argument("--val-fraction", type=float, default=0.15)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--num-workers", type=int, default=2)
    p.add_argument("--device", type=str, default="auto",
                   help="'auto' picks MPS if available, else CPU.")
    p.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "BallNetR_v2.mlpackage")
    return p.parse_args()


def pick_device(pref: str) -> torch.device:
    if pref == "auto":
        if torch.backends.mps.is_available():
            return torch.device("mps")
        return torch.device("cpu")
    return torch.device(pref)


def focal_weighted_bce(pred: torch.Tensor, target: torch.Tensor, weight: torch.Tensor,
                       pos_weight: float = 300.0) -> torch.Tensor:
    """
    v2 · WEIGHTED MSE (name kept for drop-in compatibility with the loop).

    This replaces v0/v1's focal BCE, which the model gamed — it collapsed to
    predicting a weak blob everywhere because the target is 99.9% zeros and BCE
    let it minimize loss by hedging. Confidence stuck at ~0.24 for visible AND
    not_visible frames; localization capped at 55% <10px.

    TrackNetV3 (the paper we're copying) uses weighted MSE on the heatmap, not
    BCE. MSE can't be gamed the same way — the model must actually put mass on
    the ball peak to drive the positive-region error down.

    pos_weight heavily up-weights error where target > 0 so the tiny ball region
    (a sigma-5 blob is a few hundred px out of 147k) actually dominates gradients.

    pred:   (B, 1, H, W)  in [0,1] (sigmoid output)
    target: (B, 1, H, W)  in [0,1]
    weight: (B,)          per-sample scalar (occluded gets 0.5)
    """
    se = (pred - target) ** 2                                 # (B,1,H,W)
    # Per-pixel weight: pos_weight where the target has signal, 1 elsewhere.
    pix_w = 1.0 + (pos_weight - 1.0) * target                 # target in [0,1]
    per_sample = (se * pix_w).mean(dim=(1, 2, 3))             # (B,)
    return (per_sample * weight).mean()


def evaluate(model, loader, device) -> tuple[float, float]:
    """Returns (mean loss, mean peak-error in pixels @ 512×288 for VISIBLE samples)."""
    model.eval()
    losses = []
    peak_errors = []
    with torch.no_grad():
        for x, y, w in loader:
            x = x.to(device)
            y = y.to(device)
            w = w.to(device)
            p = model(x)
            loss = focal_weighted_bce(p, y, w)
            losses.append(loss.item())

            # Peak-error metric: for samples where target has a peak > 0.5, how far off is the argmax?
            for i in range(p.shape[0]):
                tgt = y[i, 0]
                if tgt.max() < 0.5:
                    continue
                t_flat = tgt.argmax().item()
                p_flat = p[i, 0].argmax().item()
                ty, tx = divmod(t_flat, MODEL_W)
                py, px = divmod(p_flat, MODEL_W)
                peak_errors.append(math.hypot(tx - px, ty - py))
    return float(np.mean(losses)), (float(np.mean(peak_errors)) if peak_errors else float("nan"))


def main():
    args = parse_args()
    device = pick_device(args.device)
    print(f"device: {device}")
    print(f"torch:  {torch.__version__}")

    # ── Data ─────────────────────────────────────────────────────────
    trip_path = TRAINING_ROOT / "labels" / "triplets.jsonl"
    
    records = load_triplets(trip_path)
    print(f"total labeled records: {len(records)}")

    train_recs, val_recs, val_games = split_by_game(records, args.val_fraction, args.seed)
    print(f"train: {len(train_recs)}  val: {len(val_recs)}  val games: {sorted(val_games)}")

    train_ds = TripletDatasetV2(train_recs, TRAINING_ROOT, augment=True)
    val_ds = TripletDatasetV2(val_recs, TRAINING_ROOT, augment=False)

    train_loader = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True,
                              num_workers=args.num_workers, drop_last=True)
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False,
                            num_workers=args.num_workers)

    # ── Model ────────────────────────────────────────────────────────
    model = BallNetR(in_channels=14, norm="batchnorm").to(device)
    n_params = count_params(model)
    print(f"model params: {n_params:,}")

    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs, eta_min=args.lr / 20)

    CKPT_DIR.mkdir(parents=True, exist_ok=True)
    best_val = float("inf")
    best_ckpt = CKPT_DIR / "ballnetr_v2_best.pt"
    history: list[dict] = []

    # ── Loop ─────────────────────────────────────────────────────────
    for epoch in range(1, args.epochs + 1):
        model.train()
        t0 = datetime.now()
        train_losses = []
        for step, (x, y, w) in enumerate(train_loader):
            x = x.to(device); y = y.to(device); w = w.to(device)
            p = model(x)
            loss = focal_weighted_bce(p, y, w)

            opt.zero_grad()
            loss.backward()
            opt.step()
            train_losses.append(loss.item())

        sched.step()
        train_mean = float(np.mean(train_losses))
        val_loss, val_peak = evaluate(model, val_loader, device)

        dt = (datetime.now() - t0).total_seconds()
        row = {
            "epoch": epoch, "lr": opt.param_groups[0]["lr"],
            "train_loss": train_mean, "val_loss": val_loss,
            "val_peak_err_px": val_peak, "seconds": dt,
        }
        history.append(row)
        print(f"[{epoch:03d}/{args.epochs}] "
              f"train={train_mean:.5f}  val={val_loss:.5f}  peak_err={val_peak:.1f}px  "
              f"lr={row['lr']:.2e}  ({dt:.1f}s)")

        if val_loss < best_val:
            best_val = val_loss
            torch.save({"model": model.state_dict(), "epoch": epoch,
                        "val_loss": val_loss, "val_peak_err_px": val_peak},
                       best_ckpt)

    # ── Save history ─────────────────────────────────────────────────
    (CKPT_DIR / "history.json").write_text(json.dumps(history, indent=2))
    print(f"\nBest val loss: {best_val:.5f} → {best_ckpt}")

    # ── Reload best weights and export to CoreML ─────────────────────
    print("\nLoading best checkpoint and exporting to CoreML…")
    state = torch.load(best_ckpt, map_location="cpu")
    model_cpu = BallNetR(in_channels=14, norm="batchnorm")
    model_cpu.load_state_dict(state["model"])
    model_cpu.eval()

    dummy = torch.randn(1, 14, MODEL_H, MODEL_W)
    with torch.no_grad():
        traced = torch.jit.trace(model_cpu, dummy, check_trace=False)

    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="frames", shape=(1, 14, MODEL_H, MODEL_W), dtype=float)],
        outputs=[ct.TensorType(name="heatmap", dtype=float)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.short_description = (
        f"BallNet-R v0 · trained {state['epoch']} epochs · val_loss={state['val_loss']:.4f} "
        f"· peak_err={state['val_peak_err_px']:.1f}px · {n_params:,} params"
    )
    mlmodel.author = "Rebound / Skynet Auto-Score"
    mlmodel.save(str(args.output))
    print(f"✅ CoreML export: {args.output}")


if __name__ == "__main__":
    main()
