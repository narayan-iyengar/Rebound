#!/usr/bin/env python3
"""
BallNet-R Phase 1a · Frame extractor

Reads .mp4 files from --videos-dir, samples frames at --sample-fps,
downsamples each to 640×360 (matching Rebound's AI pipeline), runs an
HSV orange-blob heuristic (inspired by BallDetector.swift), buckets by
confidence, and writes:

  training-data/frames/sahil/<game-slug>/NNNNNNN.jpg
  training-data/labels/candidates.jsonl                (one JSON line per candidate)

Buckets:
  auto  · confidence ≥ 0.6  · quick yes/no review in labeling tool
  queue · min-conf ≤ c < 0.6 · full manual labeling
  skipped · below min-conf   · not saved

Usage:
  python extract.py                                       # sensible defaults
  python extract.py --sample-fps 0.5                      # coarser sampling
  python extract.py --videos-dir ../../training-data/videos/others \\
                    --frames-dir ../../training-data/frames/others
"""

import argparse
import json
import re
import sys
from pathlib import Path

import cv2
import numpy as np


REPO_ROOT = Path(__file__).resolve().parents[2]
TRAINING_ROOT = REPO_ROOT / "training-data"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--videos-dir", type=Path, default=TRAINING_ROOT / "videos" / "sahil")
    p.add_argument("--frames-dir", type=Path, default=TRAINING_ROOT / "frames" / "sahil")
    p.add_argument("--labels-file", type=Path, default=TRAINING_ROOT / "labels" / "candidates.jsonl")
    p.add_argument("--sample-fps", type=float, default=1.0,
                   help="Samples per second of source video. Default 1.0.")
    p.add_argument("--target-w", type=int, default=640)
    p.add_argument("--target-h", type=int, default=360)
    p.add_argument("--jpeg-quality", type=int, default=85)
    p.add_argument("--min-conf", type=float, default=0.15,
                   help="Skip frames scored below this. Default 0.15.")
    p.add_argument("--auto-conf", type=float, default=0.5,
                   help="Frames at/above this confidence go in the auto bucket. Default 0.5.")
    p.add_argument("--max-per-game", type=int, default=300,
                   help="Cap per-game candidates via uniform temporal sampling. Default 300.")
    return p.parse_args()


def slug(name: str) -> str:
    """Turn a video filename into a short lowercase slug."""
    stem = Path(name).stem.lower()
    stem = re.sub(r"[^a-z0-9]+", "_", stem).strip("_")
    return stem


def hsv_ball_detect(bgr: np.ndarray) -> tuple[float, float, float] | None:
    """
    HSV orange-blob heuristic. Returns (x, y, confidence) in the frame's
    pixel coords, or None if nothing plausible is found.

    Not a real ball detector — a fast triage heuristic to decide whether
    a frame is worth saving as a labeling candidate.
    """
    H, W = bgr.shape[:2]
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)

    # Tightened orange range — red-orange only, cuts pure-orange jerseys and dull court markings
    mask = cv2.inRange(hsv, (8, 130, 60), (20, 255, 255))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None

    frame_area = float(H * W)
    best = None  # (score, x, y)

    for c in contours:
        area = cv2.contourArea(c)
        # Basketball at gym distance in 640x360 is 15-30px diameter → 175-700 px² of bounding box
        # but the ball itself (contour area) is smaller. Range 30-300 covers most real basketballs.
        if area < 30 or area > 300:
            continue

        perim = cv2.arcLength(c, True)
        if perim < 1:
            continue

        # Circularity: 4π·area / perim² == 1 for a perfect circle
        # Tightened from 0.4 → 0.55; ball is round, jerseys and floor markings often are not
        circ = 4.0 * np.pi * area / (perim * perim)
        if circ < 0.55:
            continue

        x, y, w, h = cv2.boundingRect(c)
        if h > 0.15 * H:
            continue  # too tall — likely a person's jersey; ball can't be > 15% frame height

        aspect = w / max(h, 1)
        if aspect < 0.6 or aspect > 1.7:
            continue  # tighter roughly-square requirement

        # Mean saturation inside the contour — the ball is vividly orange
        m2 = np.zeros(mask.shape, np.uint8)
        cv2.drawContours(m2, [c], -1, 255, -1)
        sat_mean = float(cv2.mean(hsv[..., 1], mask=m2)[0]) / 255.0

        # Peaked area-fit centered around ~400 px² (typical gym-distance ball at 640×360)
        area_fit = 1.0 - abs(np.log10(area / 400.0)) / 3.0
        area_fit = max(0.0, min(1.0, area_fit))

        score = circ * sat_mean * (0.5 + 0.5 * area_fit)
        cx = x + w / 2.0
        cy = y + h / 2.0

        if best is None or score > best[0]:
            best = (score, cx, cy)

    if best is None:
        return None

    score, cx, cy = best
    return (cx, cy, max(0.0, min(1.0, score)))


def bucket(conf: float, auto_threshold: float) -> str:
    return "auto" if conf >= auto_threshold else "queue"


def process_video(video_path: Path, frames_root: Path, jsonl_out, args) -> tuple[int, int]:
    """
    Returns (candidates_written, auto_labels_written).

    Two-pass:
      Pass 1 — scan the whole video at sample_fps, collect all frames that pass
               the HSV heuristic in memory (just the metadata + the raw frame).
      Pass 2 — uniformly-in-time subsample down to max_per_game, write the
               winners to disk + append to JSONL.
    """
    game_slug = slug(video_path.name)
    frames_dir = frames_root / game_slug
    frames_dir.mkdir(parents=True, exist_ok=True)

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print(f"  ⚠️  could not open {video_path.name}", file=sys.stderr)
        return 0, 0

    src_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    stride = max(1, int(round(src_fps / args.sample_fps)))

    print(f"── {video_path.name}")
    print(f"   src_fps={src_fps:.1f}  frames={total_frames}  stride={stride}  slug={game_slug}")

    # Pass 1: collect passing frames in memory (small: max ~3000 * (640x360x3) = ~2 GB peak, fine)
    passing = []  # list of (frame_idx, cx, cy, conf, small_bgr)
    frame_idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break

        if frame_idx % stride == 0:
            small = cv2.resize(frame, (args.target_w, args.target_h), interpolation=cv2.INTER_AREA)
            det = hsv_ball_detect(small)
            if det is not None and det[2] >= args.min_conf:
                passing.append((frame_idx, det[0], det[1], det[2], small.copy()))

        frame_idx += 1
        if frame_idx % (int(src_fps) * 60) == 0:
            pct = 100.0 * frame_idx / max(total_frames, 1)
            print(f"   scan… {frame_idx}/{total_frames} ({pct:.0f}%)  passing={len(passing)}")

    cap.release()

    # Pass 2: uniform temporal subsample to max_per_game
    if len(passing) > args.max_per_game:
        idxs = np.linspace(0, len(passing) - 1, args.max_per_game).astype(int)
        chosen = [passing[i] for i in idxs]
    else:
        chosen = passing

    auto = queue = 0
    for (fidx, cx, cy, conf, small) in chosen:
        b = bucket(conf, args.auto_conf)
        jpg_name = f"{fidx:07d}.jpg"
        jpg_path = frames_dir / jpg_name
        cv2.imwrite(str(jpg_path), small, [int(cv2.IMWRITE_JPEG_QUALITY), args.jpeg_quality])
        record = {
            "frame_path": str(jpg_path.relative_to(TRAINING_ROOT)),
            "source_video": video_path.name,
            "source_frame": fidx,
            "source_time_sec": round(fidx / src_fps, 2),
            "resolution": [args.target_w, args.target_h],
            "detection": {
                "x": round(cx, 2),
                "y": round(cy, 2),
                "confidence": round(conf, 4),
                "bucket": b,
            },
        }
        jsonl_out.write(json.dumps(record) + "\n")
        if b == "auto":
            auto += 1
        else:
            queue += 1
    jsonl_out.flush()

    print(f"   ✅ HSV-passed={len(passing)}  kept={len(chosen)}  auto={auto}  queue={queue}")
    return len(chosen), auto


def main():
    args = parse_args()
    videos_dir = args.videos_dir.resolve()
    frames_dir = args.frames_dir.resolve()
    labels_file = args.labels_file.resolve()

    if not videos_dir.exists():
        print(f"❌ videos dir not found: {videos_dir}", file=sys.stderr)
        sys.exit(1)

    videos = sorted(videos_dir.glob("*.mp4"))
    if not videos:
        print(f"❌ no .mp4 files in {videos_dir}", file=sys.stderr)
        sys.exit(1)

    frames_dir.mkdir(parents=True, exist_ok=True)
    labels_file.parent.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("BallNet-R Phase 1a · Frame extractor")
    print("=" * 60)
    print(f"videos:        {videos_dir}")
    print(f"frames:        {frames_dir}")
    print(f"labels:        {labels_file}")
    print(f"sample fps:    {args.sample_fps}")
    print(f"target size:   {args.target_w}×{args.target_h}")
    print(f"HSV bounds:    hue 8-20, sat ≥130, val ≥60")
    print(f"circularity:   ≥0.55")
    print(f"area:          30-300 px²")
    print(f"max per game:  {args.max_per_game}")
    print(f"auto bucket:   confidence ≥ {args.auto_conf}")
    print(f"videos found:  {len(videos)}")
    print()

    total_candidates = total_auto = 0
    with open(labels_file, "w") as jsonl_out:
        for v in videos:
            n, n_auto = process_video(v, frames_dir, jsonl_out, args)
            total_candidates += n
            total_auto += n_auto
            print()

    print("=" * 60)
    print("Done.")
    print(f"  Candidates written: {total_candidates:,}")
    print(f"  Auto-label bucket:  {total_auto:,}  (≥{args.auto_conf} confidence)")
    print(f"  Manual queue:       {total_candidates - total_auto:,}  ({args.min_conf}-{args.auto_conf} confidence)")
    print(f"  Labels output:      {labels_file}")
    print("=" * 60)


if __name__ == "__main__":
    main()
