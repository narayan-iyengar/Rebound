"""
BallNet-R v1 · PyTorch dataset (3-frame temporal input)

Reads training-data/labels/triplets.jsonl (produced by extract_triplets.py)
and fills the REAL temporal channels of the 14-channel input:

   0  1  2  — RGB of PAST frame       (real in v1)
   3  4  5  — RGB of CURRENT frame    (real)
   6  7  8  — RGB of FUTURE frame     (real in v1)
   9        — orange mask, PAST       (real in v1)
  10        — orange mask, CURRENT    (real)
  11        — orange mask, FUTURE     (real in v1)
  12        — court-quad mask         (still zeros in v1 — v2 work)
  13        — player-density heatmap  (still zeros in v1 — v2 work)

Target heatmap uses a TIGHTER Gaussian (sigma 3.0 vs v0's 4.0) so the model
learns peakier predictions — v0's confidence was weak/diffuse (~0.25).
"""

from __future__ import annotations

import json
from pathlib import Path

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset

from dataset import orange_mask, gaussian_heatmap, MODEL_H, MODEL_W, FRAME_H, FRAME_W


def load_triplets(triplets_path: Path) -> list[dict]:
    return [json.loads(l) for l in triplets_path.read_text().splitlines() if l.strip()]


def game_of(rec: dict) -> str:
    return rec["source_video"]


def split_by_game(records: list[dict], val_fraction: float = 0.15, seed: int = 42):
    """Same by-game holdout as v0 — must match so val comparison is apples-to-apples."""
    rng = np.random.default_rng(seed)
    games = sorted({game_of(r) for r in records})
    rng.shuffle(games)
    n_val = max(1, int(round(len(games) * val_fraction)))
    val_games = set(games[:n_val])
    train = [r for r in records if game_of(r) not in val_games]
    val = [r for r in records if game_of(r) in val_games]
    return train, val, val_games


class TripletDataset(Dataset):
    def __init__(self, records: list[dict], frames_root: Path, augment: bool = False,
                 target_sigma: float = 3.0):
        self.records = records
        self.frames_root = frames_root
        self.augment = augment
        self.target_sigma = target_sigma

    def __len__(self) -> int:
        return len(self.records)

    def _load_rgb_and_mask(self, rel_path: str):
        bgr = cv2.imread(str(self.frames_root / rel_path))
        if bgr is None:
            raise RuntimeError(f"Failed to read {rel_path}")
        bgr_r = cv2.resize(bgr, (MODEL_W, MODEL_H), interpolation=cv2.INTER_AREA)
        rgb = cv2.cvtColor(bgr_r, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        rgb_chw = np.transpose(rgb, (2, 0, 1))          # 3×H×W
        om = orange_mask(bgr_r)                          # H×W
        return rgb_chw, om

    def __getitem__(self, idx: int):
        rec = self.records[idx]
        lab = rec["label"]

        prev_rgb, prev_om = self._load_rgb_and_mask(rec["prev_path"])
        curr_rgb, curr_om = self._load_rgb_and_mask(rec["curr_path"])
        next_rgb, next_om = self._load_rgb_and_mask(rec["next_path"])

        C, H, W = 14, MODEL_H, MODEL_W
        x = np.zeros((C, H, W), dtype=np.float32)
        x[0:3] = prev_rgb
        x[3:6] = curr_rgb
        x[6:9] = next_rgb
        x[9] = prev_om
        x[10] = curr_om
        x[11] = next_om
        # channels 12 (court), 13 (player-density) stay zero in v1

        # Target heatmap
        y_tgt = np.zeros((1, H, W), dtype=np.float32)
        vis = lab["visibility"]
        weight = 1.0
        if vis == "visible":
            cx = float(lab["x"]) * (MODEL_W / FRAME_W)
            cy = float(lab["y"]) * (MODEL_H / FRAME_H)
            y_tgt[0] = gaussian_heatmap(cx, cy, H, W, sigma=self.target_sigma, peak=1.0)
        elif vis == "occluded":
            cx = float(lab["x"]) * (MODEL_W / FRAME_W)
            cy = float(lab["y"]) * (MODEL_H / FRAME_H)
            y_tgt[0] = gaussian_heatmap(cx, cy, H, W, sigma=self.target_sigma, peak=0.6)
            weight = 0.5
        # not_visible: zeros, weight 1.0

        if self.augment and np.random.rand() < 0.5:
            x = x[:, :, ::-1].copy()
            y_tgt = y_tgt[:, :, ::-1].copy()

        return (
            torch.from_numpy(x),
            torch.from_numpy(y_tgt),
            torch.tensor(weight, dtype=torch.float32),
        )
