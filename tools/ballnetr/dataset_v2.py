"""
BallNet-R v2 · dataset — same 3-frame temporal input as v1, but:
  • target Gaussian sigma 5.0 (was 3.0 in v1, 4.0 in v0) — more positive
    mass so the ball peak actually drives gradients under MSE
  • intended to be paired with weighted-MSE loss (train_v2.py), not focal BCE

Court (ch 12) + player-density (ch 13) channels remain zero — that's v3.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import torch

from dataset_v1 import TripletDataset, load_triplets, split_by_game  # reuse loaders
from dataset import MODEL_H, MODEL_W  # noqa: F401  (re-export convenience)


class TripletDatasetV2(TripletDataset):
    """Identical to v1's TripletDataset but defaults to a wider target Gaussian."""

    def __init__(self, records, frames_root: Path, augment: bool = False, target_sigma: float = 5.0):
        super().__init__(records, frames_root, augment=augment, target_sigma=target_sigma)
