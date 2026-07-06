"""
BallNet-R Phase 1b · PyTorch dataset

Reads training-data/labels/labels.jsonl (produced by label.py) and matches
each entry against its candidate frame at training-data/frames/... . Turns
the (x, y, visibility) label into a Gaussian-blob target heatmap.

For v0 we don't yet have neighboring-frame extraction — the model's 14-channel
input has zeros for the past/future frame slots and for the court/player
prior channels. Only 4 channels carry signal: RGB (3) + orange-hue mask (1).

Layout of the 14-channel input tensor (channel index):
   0  1  2  — RGB of PAST frame       (zeros in v0)
   3  4  5  — RGB of CURRENT frame    (real data)
   6  7  8  — RGB of FUTURE frame     (zeros in v0)
   9        — orange mask, PAST       (zeros)
  10        — orange mask, CURRENT    (real)
  11        — orange mask, FUTURE     (zeros)
  12        — court-quad mask         (zeros in v0; all-ones would also work)
  13        — player-density heatmap  (zeros in v0)
"""

from __future__ import annotations

import json
from pathlib import Path

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset


MODEL_H = 288
MODEL_W = 512
FRAME_H = 360   # extract.py output height
FRAME_W = 640   # extract.py output width


def load_labels(labels_path: Path, candidates_path: Path) -> list[dict]:
    """Merge each labels.jsonl entry with its candidates.jsonl entry (metadata)."""
    cand_by_path: dict[str, dict] = {}
    for line in candidates_path.read_text().splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        cand_by_path[r["frame_path"]] = r

    out: list[dict] = []
    for line in labels_path.read_text().splitlines():
        if not line.strip():
            continue
        lab = json.loads(line)
        cand = cand_by_path.get(lab["frame_path"])
        if cand is None:
            continue
        out.append({**cand, "label": lab})
    return out


def game_of(rec: dict) -> str:
    return rec["source_video"]


def split_by_game(records: list[dict], val_fraction: float = 0.15, seed: int = 42) -> tuple[list[dict], list[dict]]:
    """
    Held-out validation split BY GAME. Never split within a game — neighboring
    frames leak between train/val otherwise and validation loss lies to us.
    """
    rng = np.random.default_rng(seed)
    games = sorted({game_of(r) for r in records})
    rng.shuffle(games)
    n_val = max(1, int(round(len(games) * val_fraction)))
    val_games = set(games[:n_val])
    train = [r for r in records if game_of(r) not in val_games]
    val = [r for r in records if game_of(r) in val_games]
    return train, val, val_games  # type: ignore[return-value]


def orange_mask(bgr: np.ndarray) -> np.ndarray:
    """Cheap HSV orange prior. Returns a 0..1 float32 array shaped like the input's h,w."""
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    m = cv2.inRange(hsv, (8, 130, 60), (20, 255, 255))
    return (m.astype(np.float32) / 255.0)


def gaussian_heatmap(cx: float, cy: float, H: int, W: int, sigma: float = 4.0, peak: float = 1.0) -> np.ndarray:
    """Radial Gaussian centred at (cx, cy) in a heatmap of size (H, W)."""
    y = np.arange(H, dtype=np.float32).reshape(-1, 1)
    x = np.arange(W, dtype=np.float32).reshape(1, -1)
    g = np.exp(-((x - cx) ** 2 + (y - cy) ** 2) / (2.0 * sigma * sigma))
    return (peak * g).astype(np.float32)


class BallDataset(Dataset):
    """
    Returns (input_tensor, target_tensor, sample_weight) triples.

    input_tensor: (14, MODEL_H, MODEL_W), float32 in [0, 1]
    target_tensor: (1, MODEL_H, MODEL_W), float32 in [0, 1]
    sample_weight: scalar float32 in [0, 1] — occluded samples get 0.5,
                   visible get 1.0, not_visible get 1.0 (they teach the
                   model where balls do NOT appear).
    """

    def __init__(self, records: list[dict], frames_root: Path, augment: bool = False):
        self.records = records
        self.frames_root = frames_root
        self.augment = augment

    def __len__(self) -> int:
        return len(self.records)

    def _load_frame(self, rel_path: str) -> np.ndarray:
        p = self.frames_root / rel_path
        bgr = cv2.imread(str(p))
        if bgr is None:
            raise RuntimeError(f"Failed to read {p}")
        return bgr  # H, W, 3

    def _resize(self, arr: np.ndarray, is_mask: bool = False) -> np.ndarray:
        interp = cv2.INTER_NEAREST if is_mask else cv2.INTER_AREA
        return cv2.resize(arr, (MODEL_W, MODEL_H), interpolation=interp)

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        rec = self.records[idx]
        lab = rec["label"]

        # ── Load and resize the current frame ────────────────────────
        bgr = self._load_frame(rec["frame_path"])            # 360×640×3 (H,W,C)
        bgr_r = self._resize(bgr)                              # 288×512×3
        rgb = cv2.cvtColor(bgr_r, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        rgb_chw = np.transpose(rgb, (2, 0, 1))                 # 3×H×W

        # Orange mask on the model-resolution frame
        om = orange_mask(bgr_r)                                 # H×W float32

        # ── Assemble the 14-channel input ────────────────────────────
        C, H, W = 14, MODEL_H, MODEL_W
        x = np.zeros((C, H, W), dtype=np.float32)
        # RGB current
        x[3:6] = rgb_chw
        # Orange current
        x[10] = om
        # Channels 0-2 (past RGB), 6-8 (future RGB), 9 (past orange), 11 (future orange),
        # 12 (court), 13 (player density) stay zero for v0.

        # ── Target heatmap ───────────────────────────────────────────
        # Scale label pixel coords (640×360) → model pixel coords (512×288)
        y_tgt = np.zeros((1, H, W), dtype=np.float32)
        vis = lab["visibility"]
        weight = 1.0
        if vis == "visible":
            cx = float(lab["x"]) * (MODEL_W / FRAME_W)
            cy = float(lab["y"]) * (MODEL_H / FRAME_H)
            y_tgt[0] = gaussian_heatmap(cx, cy, H, W, sigma=4.0, peak=1.0)
        elif vis == "occluded":
            cx = float(lab["x"]) * (MODEL_W / FRAME_W)
            cy = float(lab["y"]) * (MODEL_H / FRAME_H)
            y_tgt[0] = gaussian_heatmap(cx, cy, H, W, sigma=4.0, peak=0.6)
            weight = 0.5
        # not_visible: all zeros; weight 1.0 — teaches the model to suppress background

        # ── Optional light augmentation (train only) ─────────────────
        if self.augment:
            # Horizontal flip 50%
            if np.random.rand() < 0.5:
                x = x[:, :, ::-1].copy()
                y_tgt = y_tgt[:, :, ::-1].copy()

        return (
            torch.from_numpy(x),
            torch.from_numpy(y_tgt),
            torch.tensor(weight, dtype=torch.float32),
        )
