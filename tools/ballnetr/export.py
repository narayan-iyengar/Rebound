"""
Phase 0.5 · BallNet-R → CoreML export

Random-weights architectural test. We measure the pipe (Neural Engine
compatibility + latency), not the water (accuracy).

Usage:
    python export.py                          # default: BatchNorm, ./BallNetR.mlpackage
    python export.py --norm groupnorm         # test GroupNorm ANE compat (R2 risk)
    python export.py --output custom.mlpackage
    python export.py --input-shape 224 384    # smaller input variant
"""

import argparse
import sys
from pathlib import Path

import torch

from model import BallNetR, count_params


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--norm", choices=["batchnorm", "groupnorm"], default="batchnorm",
                   help="Normalization layer variant. Default batchnorm (safest for ANE per R2).")
    p.add_argument("--input-channels", type=int, default=14,
                   help="Input channels (default 14: RGB×3 + orange×3 + court + player-density).")
    p.add_argument("--input-shape", type=int, nargs=2, default=[288, 512], metavar=("H", "W"),
                   help="Input H W. Default 288 512 per design doc §5.1.")
    p.add_argument("--output", type=str, default="BallNetR.mlpackage",
                   help="Output .mlpackage path.")
    p.add_argument("--skip-onnx-check", action="store_true",
                   help="Skip the ONNX runtime validation step.")
    return p.parse_args()


def main():
    args = parse_args()
    H, W = args.input_shape
    output_path = Path(args.output).resolve()

    print("=" * 60)
    print("Phase 0.5 · BallNet-R CoreML Export")
    print("=" * 60)
    print(f"Norm:              {args.norm}")
    print(f"Input shape:       (1, {args.input_channels}, {H}, {W})")
    print(f"Output path:       {output_path}")
    print()

    # ── 1. Build model (random weights) ────────────────────────────────
    print("[1/4] Building model...")
    model = BallNetR(in_channels=args.input_channels, norm=args.norm)
    model.eval()
    n_params = count_params(model)
    print(f"      Params: {n_params:,}")
    if not (2_500_000 <= n_params <= 3_500_000):
        print(f"      ⚠️  Param count outside expected 2.5M-3.5M range. Design doc audit said ~2.83M.")

    # Forward smoke test
    dummy = torch.randn(1, args.input_channels, H, W)
    with torch.no_grad():
        y = model(dummy)
    assert y.shape == (1, 1, H, W), f"unexpected output shape {y.shape}"
    print(f"      Forward OK: {tuple(dummy.shape)} → {tuple(y.shape)}")

    # ── 2. Trace with a fixed input (avoids some ONNX warnings vs export directly) ──
    print("\n[2/4] Tracing model...")
    with torch.no_grad():
        traced = torch.jit.trace(model, dummy, check_trace=False)
    print("      Traced OK")

    # ── 3. Export to CoreML directly via unified converter ──────────────
    # coremltools 8 can consume a traced PyTorch model directly and target
    # mlprogram (which is required for ANE-optimized deployment on iOS 15+).
    print("\n[3/4] Converting to CoreML...")
    import coremltools as ct

    ml_input = ct.TensorType(
        name="frames",
        shape=(1, args.input_channels, H, W),
        dtype=float,
    )

    try:
        mlmodel = ct.convert(
            traced,
            inputs=[ml_input],
            outputs=[ct.TensorType(name="heatmap", dtype=float)],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16,       # ANE runs FP16
            compute_units=ct.ComputeUnit.CPU_AND_NE,      # target Neural Engine
            minimum_deployment_target=ct.target.iOS17,    # matches Rebound
        )
    except Exception as e:
        print(f"\n❌ coremltools conversion FAILED:\n   {type(e).__name__}: {e}")
        print("\nThis is R2's Phase 0.5 gate failing at the export step.")
        print("Common causes:")
        print("  • ReLU6 or GroupNorm unsupported for target -> try --norm batchnorm")
        print("  • coremltools version mismatch -> pip install -U coremltools")
        print("  • Interpolate mode/align_corners -> already set to bilinear/False")
        sys.exit(1)

    # ── 4. Save ─────────────────────────────────────────────────────────
    print("\n[4/4] Saving...")
    mlmodel.short_description = (
        f"BallNet-R architectural test model (random weights, {args.norm}). "
        f"See docs/SKYNET_AUTOSCORE_DESIGN.md Phase 0.5."
    )
    mlmodel.author = "Rebound / Skynet Auto-Score"
    mlmodel.save(str(output_path))
    size_mb = sum(f.stat().st_size for f in output_path.rglob("*")) / 1e6
    print(f"      Saved: {output_path}")
    print(f"      Size:  {size_mb:.1f} MB")

    print()
    print("=" * 60)
    print("✅ Export complete. Next: measure in Xcode.")
    print("=" * 60)
    print()
    print("1. Open Xcode.")
    print(f"2. File → Open → {output_path}")
    print("3. In the mlpackage viewer, click the Performance tab.")
    print("4. Click + to add your iPhone 16 Pro Max as a device.")
    print("5. Click Run Test. Screenshot the median ms + layer breakdown.")
    print()
    print("Gates:")
    print("   Median ≤ 18 ms       → GO")
    print("   ≥ 90% layers on ANE  → GO")


if __name__ == "__main__":
    main()
