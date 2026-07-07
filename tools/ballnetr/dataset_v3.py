"""
BallNet-R v3 · dataset — HIGHER RESOLUTION input (960×544 vs v0-v2's 512×288)

Hypothesis: the ~75px peak-error plateau across v0/v1/v2 is caused by the ball
being only 5-11px at 512×288. At 960×544 the ball is ~10-22px — a much easier
localization target. Latency est ~15.7ms (Phase 0.5 gate is 18ms, so OK).

Requires triplets re-extracted at 960×544 (see run command in README/commit).
Labels stay in 640×360 coordinate space (that's what the labeler displayed) and
scale to model resolution via LABEL_W/LABEL_H.

Keeps v2's wider target Gaussian (sigma 5) — scaled up proportionally to the
bigger canvas (sigma 7.5) so the blob covers a similar fraction of the frame.

Court (ch 12) + player-density (ch 13) channels remain zero — that's v4/polish.
"""

from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset

from dataset import orange_mask, gaussian_heatmap
from dataset_v1 import load_triplets, split_by_game  # reuse loaders

# v3 model resolution (÷8 for the U-Net's 3 pooling layers)
MODEL_H = 544
MODEL_W = 960
# Label coordinate space (the labeler displayed 640×360 candidates)
LABEL_W = 640
LABEL_H = 360


class TripletDatasetV3(Dataset):
    def __init__(self, records, frames_root: Path, augment: bool = False, target_sigma: float = 7.5):
        self.records = records
        self.frames_root = frames_root
        self.augment = augment
        self.target_sigma = target_sigma

    def __len__(self) -> int:
        return len(self.records)

    def _load_rgb_and_mask(self, rel_path: str):
        bgr = cv2.imread(str(self.frames_root / rel_path))
        if bgr is None:
            # Graceful fallback — a missing/corrupt frame (e.g. end-of-game frames
            # where the 4K original ended a frame or two before the YouTube version
            # the labels were made against) must NOT crash a multi-hour training run.
            # Return a black frame; it's a handful of samples out of thousands.
            bgr = np.zeros((MODEL_H, MODEL_W, 3), dtype=np.uint8)
        bgr_r = cv2.resize(bgr, (MODEL_W, MODEL_H), interpolation=cv2.INTER_AREA)
        rgb = cv2.cvtColor(bgr_r, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        rgb_chw = np.transpose(rgb, (2, 0, 1))
        om = orange_mask(bgr_r)
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
        # channels 12 (court), 13 (player-density) stay zero in v3

        y_tgt = np.zeros((1, H, W), dtype=np.float32)
        vis = lab["visibility"]
        weight = 1.0
        if vis == "visible":
            cx = float(lab["x"]) * (MODEL_W / LABEL_W)
            cy = float(lab["y"]) * (MODEL_H / LABEL_H)
            y_tgt[0] = gaussian_heatmap(cx, cy, H, W, sigma=self.target_sigma, peak=1.0)
        elif vis == "occluded":
            cx = float(lab["x"]) * (MODEL_W / LABEL_W)
            cy = float(lab["y"]) * (MODEL_H / LABEL_H)
            y_tgt[0] = gaussian_heatmap(cx, cy, H, W, sigma=self.target_sigma, peak=0.6)
            weight = 0.5

        if self.augment and np.random.rand() < 0.5:
            x = x[:, :, ::-1].copy()
            y_tgt = y_tgt[:, :, ::-1].copy()

        return (
            torch.from_numpy(x),
            torch.from_numpy(y_tgt),
            torch.tensor(weight, dtype=torch.float32),
        )
