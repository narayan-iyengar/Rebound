"""
BallNet-R architecture — PyTorch implementation matching
docs/SKYNET_AUTOSCORE_DESIGN.md §5.1-5.3.

Structural mirror of TrackNetV3 (github.com/qaz812345/TrackNetV3/blob/main/model.py)
with channels halved for on-device inference budget:
  Encoder:  (14, 32) → (32, 64) → (64, 128) → bottleneck (128, 256)
  Decoder:  symmetric with skip-concat, bilinear upsample × 2
  Predictor: 1×1 conv → sigmoid → single-channel heatmap
  Params:   ~2.83 M

Block sizes match TrackNetV3:
  Stages 1-2, up_2, up_3: double conv
  Stage 3, bottleneck, up_1: triple conv

Two normalization variants supported:
  --norm batchnorm (default, safest for ANE per R2)
  --norm groupnorm (design doc §5.3 preference; R2 flagged CPU-fallback risk)
"""

import torch
import torch.nn as nn


def _norm(kind: str, channels: int) -> nn.Module:
    if kind == "batchnorm":
        return nn.BatchNorm2d(channels)
    if kind == "groupnorm":
        # 8 groups is a decent default for our channel counts (32/64/128/256)
        groups = min(8, channels)
        return nn.GroupNorm(num_groups=groups, num_channels=channels)
    raise ValueError(f"unknown norm kind: {kind}")


class ConvBlock(nn.Module):
    """Conv2D 3×3 + norm + ReLU6 (design doc §5.3: ReLU6 for future quant)."""

    def __init__(self, in_ch: int, out_ch: int, norm: str = "batchnorm"):
        super().__init__()
        self.conv = nn.Conv2d(in_ch, out_ch, kernel_size=3, padding=1, bias=False)
        self.norm = _norm(norm, out_ch)
        self.act = nn.ReLU6(inplace=True)

    def forward(self, x):
        return self.act(self.norm(self.conv(x)))


class DoubleConv(nn.Module):
    def __init__(self, in_ch: int, out_ch: int, norm: str = "batchnorm"):
        super().__init__()
        self.c1 = ConvBlock(in_ch, out_ch, norm)
        self.c2 = ConvBlock(out_ch, out_ch, norm)

    def forward(self, x):
        return self.c2(self.c1(x))


class TripleConv(nn.Module):
    def __init__(self, in_ch: int, out_ch: int, norm: str = "batchnorm"):
        super().__init__()
        self.c1 = ConvBlock(in_ch, out_ch, norm)
        self.c2 = ConvBlock(out_ch, out_ch, norm)
        self.c3 = ConvBlock(out_ch, out_ch, norm)

    def forward(self, x):
        return self.c3(self.c2(self.c1(x)))


class BallNetR(nn.Module):
    """
    Input:  (N, 14, 288, 512)
              14 channels = RGB×3 frames (9) + orange-prior×3 (3) + court mask (1) + player density (1)
    Output: (N, 1, 288, 512)  sigmoid heatmap of current-frame ball location
    """

    def __init__(self, in_channels: int = 14, norm: str = "batchnorm"):
        super().__init__()
        # Encoder — mirrors TrackNetV3 block cadence
        self.down_1 = DoubleConv(in_channels, 32, norm)   # stage 1: double
        self.down_2 = DoubleConv(32, 64, norm)             # stage 2: double
        self.down_3 = TripleConv(64, 128, norm)            # stage 3: triple
        self.bottleneck = TripleConv(128, 256, norm)       # bottleneck: triple
        self.pool = nn.MaxPool2d(kernel_size=2, stride=2)

        # Decoder — skip-concat + bilinear upsample (design doc §5.3)
        self.up_1 = TripleConv(256 + 128, 128, norm)       # up_1: triple
        self.up_2 = DoubleConv(128 + 64, 64, norm)         # up_2: double
        self.up_3 = DoubleConv(64 + 32, 32, norm)          # up_3: double

        # Predictor + sigmoid (kept in-graph so CoreML export includes it;
        # on-device we could optionally slice sigmoid off for numerical range)
        self.predictor = nn.Conv2d(32, 1, kernel_size=1)
        self.sigmoid = nn.Sigmoid()

    @staticmethod
    def _up(x):
        # Fixed bilinear upsample × 2 — no learned transpose conv (§5.3).
        # align_corners=False is coremltools-friendly.
        return nn.functional.interpolate(x, scale_factor=2, mode="bilinear", align_corners=False)

    def forward(self, x):
        # Encoder
        x1 = self.down_1(x)                    # (N, 32,  288, 512)
        x = self.pool(x1)                       # (N, 32,  144, 256)
        x2 = self.down_2(x)                    # (N, 64,  144, 256)
        x = self.pool(x2)                       # (N, 64,   72, 128)
        x3 = self.down_3(x)                    # (N,128,   72, 128)
        x = self.pool(x3)                       # (N,128,   36,  64)
        x = self.bottleneck(x)                 # (N,256,   36,  64)

        # Decoder
        x = torch.cat([self._up(x), x3], dim=1)      # (N,384,   72, 128)
        x = self.up_1(x)                              # (N,128,   72, 128)
        x = torch.cat([self._up(x), x2], dim=1)      # (N,192,  144, 256)
        x = self.up_2(x)                              # (N, 64,  144, 256)
        x = torch.cat([self._up(x), x1], dim=1)      # (N, 96,  288, 512)
        x = self.up_3(x)                              # (N, 32,  288, 512)

        x = self.predictor(x)                         # (N,  1,  288, 512)
        return self.sigmoid(x)


def count_params(module: nn.Module) -> int:
    return sum(p.numel() for p in module.parameters())


if __name__ == "__main__":
    # Quick sanity check when running `python model.py` directly.
    m = BallNetR(in_channels=14, norm="batchnorm")
    n = count_params(m)
    print(f"BallNet-R (BN): {n:,} params  (expected ~2.83M per audit)")
    x = torch.randn(1, 14, 288, 512)
    y = m(x)
    print(f"Forward: input {tuple(x.shape)} → output {tuple(y.shape)}")
    assert y.shape == (1, 1, 288, 512), y.shape
    print("✅ Shape check passed.")
