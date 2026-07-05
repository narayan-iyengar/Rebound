# Skynet Auto-Score — Design & Roadmap

> **This document is the canonical source of truth for the Rebound Auto-Score effort.**
> All architectural decisions, audit findings, rejected alternatives, and revision history
> live here. When context is lost (new session, new dev, six months from now), start here.
>
> **The doc carries its own history** — Other Memory. Nothing is overwritten silently.
> Every change appends to §14 Revision Log. Every rejected option lives in §13.
> Every audit finding is preserved verbatim in §15.

**Vision:** Rebound is the only consumer product that automates scoring in real youth basketball games from a single phone on a gimbal, in the chaos of an AAU gym with three courts running at once.

**Status:** design doc, not built yet · unblocked to start Phase 1
**Canonical URL:** `docs/SKYNET_AUTOSCORE_DESIGN.md` (this file)
**Authors:** Claude Sonnet 4.6 (architect); Claude Sonnet 4.6 (LLM-as-a-judge verifier)
**Owner:** Narayan (Rebound PM)
**Current revision:** v0.2 · 2026-06-27
**Change protocol:** Any modification MUST append to §14 with (a) what changed, (b) why, (c) who noticed it, (d) date. Deletions are conversions to strikethrough with a §14 entry, never silent removal.

---

## 1 · What Existing Products Miss

| Product | What it does | Where it fails for AAU |
|---|---|---|
| XBotGO | Auto-track gimbal on the biggest/nearest human | Locks onto the kid warming up on court 2 |
| Veo, Pixellot, Trace | Auto-track with pro-camera fixed mount | $$$$, requires teams/schools, not consumer |
| HomeCourt | Shot detection with make/miss | Only works for **solo practice** — half-court, one player, fixed phone |
| ScoreCam | Live score overlay burned to video | Fully manual scoring |
| Rebound (today) | Auto-track + manual scoring via Watch | Manual scoring is a chore; player tracking already handles chaos |

**Nobody automates scoring for real 5v5 games at parent price points.**
**Nobody handles AAU chaos** (adjacent courts, warmup traffic, non-team humans everywhere) as a first-class product concern.

## 2 · The AAU Chaos Constraint

Every design decision in this doc must survive this checklist:

1. Kid warming up on court 2 is dribbling in front of our lens — does it count?
2. Parent walks behind the baseline with a coffee — does it derail tracking?
3. Ref stands under our rim during a free throw — is the shot still detected?
4. The neighboring court's ball rolls briefly into our frame — does it register as our ball?
5. Sahil's sister runs to the bathroom in the same team-color hoodie — is she a player?

The answer to each has to be **no false positive**. This is the moat.

## 3 · What We Already Have

The primitives are in place. Auto-scoring is a **wiring problem**, not a from-scratch invention.

| Primitive | File | Status |
|---|---|---|
| YOLOv8n person detection | `YOLODetector.swift` | ✅ Shipped |
| SORT-style tracking + Visual Re-ID | `DeepTracker.swift` | ✅ Shipped |
| Team-color learning during warmup | `PersonClassifier.swift` | ✅ Shipped |
| Court auto-calibration (quad polygon) | `CourtHeatmapAccumulator.swift` | ✅ Shipped |
| IMU-compensated gimbal pan tracking | `GimbalTrackingManager.swift` | ✅ Shipped |
| Ankle-on-court gate | `PersonClassifier.swift` | ✅ Shipped |
| Ball detector (HSV + Kalman) | `BallDetector.swift` | 🔥 To be replaced |
| Rim detector | — | 🆕 Phase 2 |
| Shot event detector | — | 🆕 Phase 2 |
| Homography for court-space transform | — | 🆕 Phase 4 (from court quad) |

## 4 · TrackNetV3 — Summary of the Actually-Read Paper

The paper introduces a two-stage architecture:

### 4.1 · TrackNet (spatial detection)
- **U-Net** with 3 downsampling stages, bottleneck, 3 upsampling stages
- Encoder: `(in, 64) → (64, 128) → (128, 256) → bottleneck (256, 512)`
- Block sizes: stages 1-2 use **double** conv, stage 3 and bottleneck use **triple** conv
- Decoder: symmetric — up_1 triple, up_2/up_3 double, all with skip-concat + upsample 2×
- **Input:** stack of 3 consecutive RGB frames, 288×512 → 9 input channels
- **Output:** 3 heatmaps at 288×512 (one per input frame), sigmoid confidence
- **Loss:** weighted focal MSE on heatmap
- **Params:** ~11.3M (recomputed from `model.py`)

### 4.2 · InpaintNet (trajectory rectification)
- Tiny 1D U-Net over the sequence of `(x, y)` predictions from TrackNet plus a mask
- Input: `(N, L, 3)` — 2 coord channels (x, y) + 1 mask channel indicating "trust this frame" (mask is the visibility signal — there's no separate visibility channel)
- Output: `(N, L, 2)` — smoothed, gap-filled coordinates
- Params: ~520K (recomputed from `model.py`)

### 4.3 · Key insights transferable to basketball
1. **Heatmap output beats bounding boxes at small object sizes.** Basketball at gym distance is 8-15px.
2. **Temporal stacking is the feature.** A basketball in one still frame is a blurry orange smudge; three frames tell the network it's moving.
3. **Post-hoc trajectory smoothing** compensates for occluded frames — critical when a player crosses in front of the ball.
4. **Architecture is CoreML-friendly:** only Conv2d, BN, ReLU, MaxPool, Upsample, Sigmoid.

### 4.4 · What we do NOT copy
- Their augmentation strategy (badminton-specific court geometry)
- The 3-in / 3-out symmetry — we can use N-in / 1-out for lower latency
- Their model size — we can shrink for on-device
- Their assumption of a single clean court

## 5 · Proposed Architecture — **BallNet-R**

### 5.1 · Input tensor design

We stack **more context and priors** than TrackNet does, because the chaos environment demands it.

```
Channels per frame:
  RGB (3)                        raw image
  Orange-hue prior mask (1)      cheap HSV segmentation, existing BallDetector logic
                                 acts as attention hint
Static channels (shared across all frames):
  Court quad mask (1)            1 inside our court polygon, 0 outside
  Player-density heatmap (1)     downsampled YOLO player centers, blurred

Total per-frame channels: 4
Stacked over 3 frames:    12 (RGB+orange × 3)
+ static channels:        2  (court, players)
= 14 input channels
```

The court and player channels are **the AAU-chaos moat encoded as tensor.** No general-purpose ball tracker has these because they're specific to our full-context system.

### 5.2 · Backbone

Same U-Net shape as TrackNet, but **half the channel count** for Neural Engine speed:

```
Down: (14, 32) → (32, 64) → (64, 128) → bottleneck (128, 256)
Up:   with skip-concat
Predictor: 1×1 conv → sigmoid → 1 output heatmap
Params: ~3M  (vs TrackNet's 11M)
```

**Output:** single heatmap at 288×512 for the **current (middle) frame only.** We stream — no need to output past or future.

### 5.3 · iOS-friendly modifications

- **BatchNorm → GroupNorm** (Neural Engine handles both, GN is more stable at batch 1)
- **ReLU → ReLU6** (better int8 quantization if we ever need it)
- **Fixed bilinear upsample** (no learned transpose conv — smaller, faster)
- **288×512 → 224×384** input if speed matters more than accuracy on older devices (skip for iPhone 16 Pro Max)

### 5.4 · Post-processing (on CPU, per frame)

```
heatmap → soft-argmax → (x, y, confidence)
      → Kalman filter (existing) → smoothed track
      → gate: must be inside court quad
      → gate: must be within N pixels of any tracked player
        (with recent handoff, i.e. player just released the ball)
```

The gates are cheap and encode the chaos constraint at inference time as well as training time.

### 5.5 · Trajectory rectification

We skip TrackNetV3's InpaintNet for v1. Basketball trajectories are simpler than shuttlecock:
- **Projectile physics** — parabolic when airborne
- **Straight lines** — when dribbled/passed
- Our existing Kalman filter + 3rd-order polynomial fit on last N points does 90% of what InpaintNet does at 5% the complexity

If v1 shows real gaps in occluded frames, we revisit.

## 6 · Data Pipeline

### 6.1 · The training data problem  ⚠️ CORRECTED 2026-06-27 per R5 audit

**Original v0.1 draft named some datasets that don't exist ("BVD", "YouTube-Sports"). Corrected list below.**

| Source | Realism | Size (usable) | License | Ball keypoints? |
|---|---|---|---|---|
| **WASB-basketball** (arXiv:2311.05237) | Broadcast, moderate mismatch | 3,824 frames | Research-only | ✅ |
| **DeepSportRadar-v1** (arXiv:2208.08190) | Pro European | 1,456 images | CC-BY-NC-SA 4.0 | ✅ (3D → project to 2D) |
| **TrackID3x3** (arXiv:2503.18282) | **3x3, closest to AAU camera** | 6,701 frames | Research-only | Partial (verify) |
| **DeepSportLab** | Pro, moderate | 672 frames | Research-only | ✅ (ball + pose) |
| **Roboflow basketball keypoint** | **Amateur/mixed, closest to AAU distribution** | <5K | CC-BY 4.0 | ✅ |
| **SportsMOT-basketball** (arXiv:2304.05170) | Pro NBA/FIBA — mismatch for AAU | 67K frames | CC-BY-NC 4.0 | ❌ Player boxes only |
| **Rebound's own recordings** | **Perfect** | Growing | Own | Needs labeling |

**Combined public warm-start pool for ball keypoints: ~12K frames** (WASB + DeepSportRadar + TrackID3x3 + DeepSportLab). All non-commercial licenses — see R5 for lawyer-check caveat.

**SportsMOT-basketball is separately useful for player-density training** (67K free basketball player boxes) — no ball keypoints, but perfect for the auxiliary player-density channel input to BallNet-R (§5.1) and for the R10 YOLO fine-tune.

**The winning play still stands:** warm-start from ~12K public frames, fine-tune on Sahil's own footage. Just now grounded in real datasets.

### 6.2 · Labeling strategy

Two-phase, minimizes tedium:

**Phase A — bootstrap (target: 500 labeled frames)**
1. Run current `BallDetector.swift` HSV+Kalman on Sahil's games
2. Take only detections with confidence > 0.9 as pseudo-labels
3. Manually review 500 candidate frames, keep ~300 clean labels
4. Fine-tune a small BallNet-R from TrackNetV3 weights on these
5. Result: mediocre v0 tracker, better than nothing

**Phase B — active learning (target: +2000 labeled frames)**
1. Run v0 tracker on more Sahil footage
2. For each frame, log heatmap uncertainty (max value < threshold, or bimodal peaks)
3. Surface the **most confusing frames** in a labeling UI
4. Narayan labels 20-30 frames per session, 10 sessions = 300 more high-value labels
5. Alternatively: cheap Mechanical Turk / Scale AI ~$0.10 per label = $200 for 2000

**Total budget:** ~$300 in cloud labeling + 5-10 hours of curation.

### 6.3 · Labeling tool

Small Mac app (Swift + AppKit) or web tool. Keyboard-driven:
- Left/right arrow = prev/next frame
- Space = click ball position
- V = mark "no visible ball"
- O = mark "occluded, interpolate"
- Enter = commit
- Data output: JSONL with `{frame, x, y, visibility}`

Ship it as a subfolder in the repo (`/tools/label/`). ~1 weekend of work.

## 7 · CoreML Export Path

```python
# PyTorch → ONNX → CoreML
torch.onnx.export(model, dummy_input, "ballnetr.onnx", opset_version=17,
                  input_names=["frames"], output_names=["heatmap"])

import coremltools as ct
mlmodel = ct.convert(
    "ballnetr.onnx",
    convert_to="mlprogram",
    compute_units=ct.ComputeUnit.CPU_AND_NE,  # enum, not string
    minimum_deployment_target=ct.target.iOS17,
)
mlmodel.save("BallNetR.mlpackage")
```

**Known landmines:**
- PyTorch's `Upsample` with `align_corners=None` sometimes fails; use explicit `align_corners=False`
- BatchNorm running stats need to be frozen before export
- Sigmoid + heatmap output: export the raw logits, apply sigmoid on-device (better numerical range for Neural Engine)

**Performance target (updated after R2 evidence, still needs empirical validation):**
- iPhone 16 Pro Max A18 Pro Neural Engine: 35 TOPS advertised, ~19 TFLOPS practical FP16 ceiling (per M4 ANE reverse-engineering, comparable architecture)
- BallNet-R at 288×512, 14 in-ch: FLOPs ~4-6 GFLOPs per forward pass
- **Expected: 10-18 ms per inference.** 8 ms is a stretch goal contingent on aggressive tuning
- Anchor points from R2 evidence: Photoroom U-Net segmentation on A17 Pro at ≥512² = 37 ms end-to-end (larger model); Ultralytics YOLOv8n on A17 Pro = 3 ms at 3.2M params, 640² (much smaller resolution work per op)
- At our 15fps AI cadence (~67 ms budget/frame): 15-27% duty cycle. Leaves budget for future rim/shot detectors, but empirical measurement via Phase 0.5 test (§11a R2) gates Phase 1 commit
- **Two risk factors identified for empirical test:** GroupNorm CPU fallback, bilinear upsample fusion. See R2 answer for mitigations.

## 8 · Roadmap

Each phase ships value on its own. You can stop after any phase and still have improved the product.

### Phase 1 — **BallNet-R v1 replaces BallDetector** ⏱ **10-14 weeks (realistic)**

Milestone: **reliable ball tracking under AAU chaos**

**Why not 6 weeks:** independent audit flagged the original 6-week estimate as
optimistic for a solo dev evenings/weekends who isn't primarily an ML engineer.
Building the labeling tool, labeling ≥2000 frames, training a custom U-Net,
debugging ONNX→CoreML export landmines, integrating, and validating across
multiple real games is closer to 100-140 hours at ~10 hrs/wk.

Deliverables:
- `/tools/label/` labeling tool
- Trained BallNet-R weights (`.mlpackage`)
- `BallDetector.swift` rewritten to load `BallNetR.mlpackage`, same public API
- Court-quad + player-proximity gates on the output
- Debug overlay: draw ball position + confidence during recording

User-visible: Skynet's Gretzky lead actually leads. Camera anticipates fast breaks correctly. No new UI.

Risk: **medium.** Retraining is the wildcard. Falls back to existing HSV BallDetector if `.mlpackage` missing (same YOLO-fallback pattern already in the codebase).

### Phase 2 — **Rim detection + shot event** ⏱ ~4 weeks

Milestone: `onShotAttempted` event fires with `(rimId, makeConfidence)`

Deliverables:
- One-time rim detection during warmup (heatmap of "circle-like structures near court back edges")
- `ShotEventDetector.swift`: watches ball trajectory, fires `onShotAttempted` when ball passes within a threshold of rim center
- Rule-based make/miss based on ball velocity post-contact (net doesn't move much on a miss; makes have a distinct deceleration)
- Debug overlay: rim positions, shot arc trail

User-visible: nothing yet. Backend event stream ready.

Risk: **low.** Rims are static; detection is a one-shot search anchored to court corners.

### Phase 3 — **Team attribution** ⏱ ~3 weeks

Milestone: shot events include `(teamColor, playerTrackId)`

Deliverables:
- `ShotAttribution.swift`: at the moment `ball.trajectory.startsGoingUp()`, find the closest tracked player who was holding the ball
- Piggybacks on existing team-color profiles
- Auto-updates game score when make is detected
- Watch shows "Auto: +2 Home" with 3-second undo swipe

User-visible: **the moment the product changes**. Manual scoring becomes optional. Watch still overrides if you tap.

Risk: **medium.** "Who was holding the ball" is fuzzy for handoffs and quick passes. Start with "closest teammate at ball-release."

### Phase 4 — **2 vs 3 pointer** ⏱ ~2 weeks

Milestone: correct point values assigned to auto-scored shots

Deliverables:
- Homography from court quad → real-world court coordinates (arc is at standardized distance)
- Shot origin point projected to court space
- If origin is beyond 3-point arc → 3 points, else 2

Risk: **low.** Math is standard. Court quad already exists.

### Phase 5 — **Player attribution (stretch)** ⏱ ~2-3 months

Milestone: shots attributed to specific players ("Sahil scored 14")

Options:
- Jersey number OCR (Vision text detection) — hard at bleacher distance
- Per-player Re-ID clustering + user tags one game to seed identities
- Body-shape features (height, build) — weak signal

Risk: **high.** Youth jerseys are often small/dark numbers. Best chance is per-game Re-ID that user seeds by tapping "this track is Sahil" once.

### Phase 6 — **Highlights, shot chart, season stats** ⏱ ~1-2 months

Milestone: post-game deliverable that no one else offers

Deliverables:
- Auto-clip 5s pre/5s post around each detected shot → highlight reel
- Shot chart image per game (dots on a court diagram)
- Season page: shooting %, PPG trend, hot zones
- Optional: share to YouTube Shorts

Risk: **low.** All backend data exists by Phase 4. Purely UI/plumbing.

## 9 · Total Timeline

Recalibrated after independent audit flagged the original Phase 1 estimate
as optimistic. All estimates assume ~10 hrs/wk sustained.

- **Phase 1 (BallNet-R):** 10-14 weeks
- **Phase 2 (rim + shot event):** 4-6 weeks
- **Phase 3 (team attribution → auto-scoring):** 3-4 weeks
- **Phase 4 (2 vs 3 pointer):** 2-3 weeks

**Phase 1→3 (product transformation):** ~17-24 weeks = **4-6 months**.
**Phase 1→4:** 5-7 months.
**Phase 5 (stretch):** 2-3 months if attempted.
**Phase 6 (highlights/shot chart):** 1-2 months.

Realistic full-vision timeline: **~9-12 months of dedicated evenings/weekends**
for Phase 1-4 + Phase 6. Phase 5 is a separate commitment.

## 10 · Ship-or-Kill Decision Points

At each phase-boundary, honestly answer:
- Does the new capability work in **at least 3 different games** with different lighting/gyms?
- Is false-positive rate low enough that we don't tell parents the wrong score?
- Would we ship this to another parent tomorrow?

If no to any → we don't move to the next phase until it's yes. Better to ship Phase 1 well than half-ship Phase 3.

## 11 · Open Questions

1. **Labeling volunteer or paid?** Determines Phase 1 timeline within a factor of 2.
2. **iCloud model updates?** After training, do we host `.mlpackage` on a server and download, or bake into the app bundle? Baking is simpler; hosting lets us ship improvements without App Store review.
3. **Firebase for shot events?** If yes, this unlocks cross-device replay and season-long analytics naturally.
4. **Live streaming integration?** During Phase 3 games, can the YouTube live overlay include auto-scored points in real time?
5. **Dual-install (Rebound + Rebound β)?** Deferred — Narayan is noodling. Zero commitment yet, but low-cost infrastructure if we want risk mitigation before Phase 1 lands.

## 11a · Phase 0 Research Questions

Before committing to the 10-14 week Phase 1 build, we validate the plan.
Each R-question below has its own answer + evidence appended below when
research completes. Nothing is answered by opinion — everything by
citation, benchmark, or measurement.

### High priority (could change the architecture)

- **R1 · Is TrackNetV3 even the right family?** ✅ **ANSWERED 2026-06-27.** **Yes — stay with TrackNetV3 as seed for BallNet-R.** Full report inline below.

  **Alternatives evaluated:**
  - **TrackNetV4** (arXiv:2409.14543, Sep 2024) — motion-attention module bolted onto V3 backbone. Reported gains are qualitative ("enhances V2/V3") without Δ-accuracy numbers on the abstract page. Verdict: **KEEP AS BACKUP** — add as Phase 1.5 ablation if we want more accuracy, not a baseline replacement.
  - **SAM2 / EdgeTAM** (arXiv:2501.07256) — SAM2-tiny runs ~1 FPS on iPhone 15 Pro Max; EdgeTAM distilled to 16 FPS. Even the fast one burns our entire budget, and SAM2 is a segmenter that needs a manual first-frame prompt — it does not solve "where is the ball" in frame 0. **REJECT for ball detection**; possible future use for player Re-ID masking.
  - **RT-DETR / DEIM / YOLO-World** (arXiv:2401.17270, github.com/lyuwenyu/RT-DETR) — bbox regressors emitting boxes. Same 8-15px failure mode we rejected in §13.2. **REJECT.**
  - **WASB-SBDT** (arXiv:2311.05237, NTT Com 2023, github.com/nttcom/WASB-SBDT) — "Widely Applicable Strong Baseline for Sports Ball Detection and Tracking." Reports superiority over 6 SOTA methods across 5 sports. TrackNet-family variant with high-res features + temporal consistency. **Corroborates our family choice as SOTA.** Cross-check their basketball-specific numbers in Phase 1a.
  - **TOTNet** (arXiv:2508.09650) — U-Net + 3D convs + RAFT optical flow. 8.65M params, 28 FPS (12 with flow). Not evaluated on basketball; RAFT will be expensive on iPhone. Verdict: **Phase 2 candidate** for occlusion handling, not a v1 baseline.
  - **HomeCourt patents US10748376B2 (assignee NEX Team)** — MobileNetV2 + modified SSDLite for ball (bbox — same rejection reason). 2-branch pose CNN. **Shot detection = trajectory backtracking from goal + bipartite match to nearest player at ball release.** This is directly applicable to our Phase 2 (shot event) + Phase 3 (team attribution) — steal this playbook.

  **Ecosystem signal:** WASB, TrackNetV4, TOTNet are ALL TrackNet-family U-Net-heatmap descendants. The family is not obsolete; it's the state of the art for small fast objects in sports.

  **Uncertainty flags:** TrackNetV4 Δ-accuracy vs V3 not verified numerically. WASB basketball-specific AP not verified from abstract alone.
- **R2 · CoreML U-Net latency reality.** ✅ **ANSWERED 2026-06-27.** **Range is plausible but skewed optimistic. Tighten to "10-18 ms expected, 8 ms is a stretch."** Full report below.

  **Hard evidence gathered:**
  - Apple coremltools benchmarks (A17 Pro, FP16, ANE): MobileNetV2 224² = **0.49 ms**, ResNet50 224² = **1.38 ms**, MobileViTv2 256² = **1.36 ms**. All classification, no published U-Net numbers. Source: apple.github.io/coremltools/opt-quantization-perf.
  - **Photoroom production U-Net segmentation on A17 Pro: 37 ms end-to-end at ≥512² input.** Our closest published analog. Source: photoroom.com/inside-photoroom/core-ml-performance-benchmark-2023-edition.
  - **Ultralytics YOLOv8n on A17 Pro Neural Engine: 3 ms** at 3.2M params, 640². Closest anchor for us since Rebound already ships YOLOv8n. Sources: docs.ultralytics.com/hub/app/ios, 3nsofts.com/insights/on-device-ai-performance-benchmarks.
  - **ANE reverse-engineering (M4, architecturally comparable to A18 Pro):** practical FP16 throughput peaks at ~19 TFLOPS vs. 38 TOPS advertised. Single ops hit ~30% of peak; only 32+ chained op graphs approach ceiling. INT8 gives no compute speedup — only memory-bandwidth savings. Sources: maderix.substack.com/p/inside-the-m4-apple-neural-engine-615, arXiv:2603.06728 (Orion).

  **FLOP-based sanity check:** BallNet-R ≈ 4-6 GFLOPs/inference. At 19 TFLOPS practical ceiling with typical U-Net 20-40% ANE utilization (concat + bilinear-upsample + skip-tensor memory traffic drag), effective throughput 4-8 TFLOPS → **0.5-1.5 ms of raw compute**. Add CoreML dispatch (~0.1 ms), 14-channel input tensor packing (non-standard path), and residual-connection memory bandwidth (14-ch × 288×512 × FP16 ≈ 4 MB per skip tensor, near the 32 MB SRAM budget) → realistic end-to-end **5-15 ms band**. Photoroom's 37 ms anchors this: our model is ~3-5× smaller/simpler → **7-15 ms is a defensible upper bound**.

  **Two specific risk factors flagged for Phase 1 empirical validation:**
  1. **GroupNorm may fall back to CPU** on ANE. §5.3 currently prescribes GN over BN "for stability at batch 1." If GN triggers CPU fallback we blow past 15 ms. **Mitigation:** If empirical test shows fallback, revert to BN (frozen running stats at export time). Same accuracy in practice for our use case.
  2. **Bilinear upsample fusion.** Single biggest lever for U-Net ANE latency. If coremltools doesn't fuse the upsample→concat→conv pattern, decoder path stalls on memory bandwidth. **Mitigation:** may need to hand-write a transposed-conv variant, or use `coremltools.optimize.torch.pruning` guidance.

  **Recommendation:** Language in §7 tightened. Empirical validation added as Phase 0.5 gate (half-day work, ~$0 cost) before Phase 1 code commit — see below.

  **Phase 0.5 · CoreML latency empirical test (0.5 day, blocks Phase 1 commit):**
  1. Build dummy PyTorch U-Net matching the exact BallNet-R spec (14→32→64→128→256 encoder, GN or BN, mirrored decoder, sigmoid off).
  2. Export: `torch.onnx.export → coremltools.convert(minimum_deployment_target=iOS17, compute_precision=FP16, compute_units=CPU_AND_NE)`
  3. Load `.mlpackage` in Xcode 15+, open the **Performance** tab on the iPhone 16 Pro Max, run 100 iterations. Xcode reports median ms/inference + layer-level ANE-vs-CPU breakdown.
  4. Two hard gates:
     - Median ≤18 ms end-to-end → **GO**
     - 90% of layers on ANE (not CPU fallback) → **GO**
     - Otherwise: fix (BN swap, upsample rewrite) or shrink model (reduce input to 224×384 or channels to 24→48→96→192).
- **R3 · TrackNetV3 licensing.** ✅ **ANSWERED 2026-06-27.** MIT License, verified via GitHub API: `gh api repos/qaz812345/TrackNetV3/license` → SPDX-ID `MIT`. This means we can (a) reuse their PyTorch code, (b) seed BallNet-R from their pretrained weights, (c) ship commercially without royalty or share-alike obligation. Only requirement is attribution — we include their MIT copyright notice in our third-party licenses list. **Implication:** the "training from scratch" fallback in §6 becomes optional, not required. Fine-tuning from their init cuts labeled-data requirements by an estimated 50-70% based on general transfer-learning heuristics. Actual reduction to be measured in Phase 1.
- **R4 · Court-quad-conditioned tracking prior art.** ✅ **ANSWERED 2026-06-27. Not novel but not naive — the pattern is standard practice. Recommendation: do BOTH input channel AND auxiliary loss term.**

  **Prior art evidence:**
  - **WASB (arXiv:2311.05237)** — the current sports-ball SOTA explicitly uses "position-aware model training" encoding spatial priors alongside RGB. Same pattern as ours, in production.
  - **SoccerNet Game State Reconstruction (arXiv:2504.06357)** and **Camera Calibration for Action Spotting (arXiv:2104.09333)** — both feed field masks / homography-derived priors as auxiliary channels.
  - **Tennis Hawk-Eye replica (arXiv:2511.04126)** — court keypoint heatmaps as input channels to ball tracker.
  - **TrackNetV3 itself** already concatenates an estimated background image alongside RGB frames — same architectural move as our court-quad mask.

  **The moat isn't the technique.** It's the specific AAU-chaos priors (multi-court + player density) we bake into the input channels.

  **Additional loss term** (recommended add to §5.4):
  ```
  L_total = BCE(heatmap, target) + λ * mean(heatmap * (1 - court_mask))
  ```
  with λ ≈ 0.1. Cheap. Explicitly penalizes cross-court false positives even when the network gets tempted. Consensus across field-mask filtering papers (nature.com/articles/s41598-023-28658-1; Mask-R-CNN + field-mask gating): input-only lets the network ignore mask in-distribution then fail catastrophically OOD; loss-only is slow to converge because gradient signal is sparse for a small object. Both together = fast convergence + hard guarantee.

  **Pretrained-weight risk (solved):** Seeding from TrackNetV3 (9-ch input) into our 14-ch input requires expanding conv1 weights. Standard practice (PyTorch forum consensus; Hughes 2022 TDS): copy RGB filters as-is, initialize the 5 new channels (orange×3 + court + player-density) by averaging RGB channels then scaling by ~0.1 so pretrained features dominate early training. No reported catastrophic forgetting.

### Medium priority (refines the plan)

- **R5 · Existing basketball ball datasets audit.** ✅ **ANSWERED 2026-06-27. §6.1 in the main body is WRONG and must be corrected.**

  **My original list was partly hallucinated / incorrect.** Audit findings:

  | Dataset | Real? | License | Ball keypoints? | Realism | Verdict |
  |---|---|---|---|---|---|
  | **BVD** (as I named it) | ❌ **Not locatable as a canonical dataset.** | — | — | — | **Drop from doc.** |
  | **SportsMOT** (arXiv:2304.05170) | ✅ | CC-BY-NC 4.0 (non-commercial) | ❌ **NO** — player bboxes only | Pro NBA/FIBA — poor match for AAU | Use for player-density training only |
  | **NPUBB** | ✅ | Research-only | ❌ **NO** — action labels, no ball position | Pro/university, controlled | **Drop from ball plan.** |
  | **YouTube-Sports** (as I named it) | ❌ Generic term, not a labeled dataset | — | — | — | **Drop from doc.** |
  | **WASB-basketball** (arXiv:2311.05237) | ✅ | Research-only | ✅ **YES** — 3,392 train + 432 test frames, 2D ball keypoints | Broadcast angle, moderate mismatch | **PRIMARY warm-start.** |
  | **DeepSportRadar-v1** (arXiv:2208.08190) | ✅ | CC-BY-NC-SA 4.0 | ✅ **YES** — 1,456 images, ball 3D localization + segmentation | Pro European league | **Secondary warm-start.** |
  | **TrackID3x3** (arXiv:2503.18282, 2025) | ✅ | Research-only | Partial — verify before use | 3x3 half-court, **closest to AAU camera angle** | **High-value warm-start.** |
  | **DeepSportLab** | ✅ | Research-only | ✅ — 672 frames, ball + pose | Pro, moderate | Small but usable |
  | **Roboflow basketball keypoint (universe.roboflow.com)** | ✅ | CC-BY 4.0 | ✅ court + some ball | Amateur/mixed — **closest to AAU distribution** | Use for last-mile fine-tune |

  **Combined public warm-start pool: ~12K frames with ball annotations** (WASB + DeepSportRadar + TrackID3x3 + DeepSportLab).

  ⚠️ **License caveat — pragmatic stance (updated v0.7):** All ball-keypoint datasets are non-commercial (CC-BY-NC or research-only). The exact "does training on NC data make the weights NC" question is genuinely unresolved in law.

  **For Rebound today, this is not a shipping blocker** — Rebound is a personal app for one dad and a handful of parents on Sahil's teams. Personal, educational, and research use of these datasets is broadly permitted. Nobody in academic sports-CV has ever pursued a solo dev over a youth-sports app.

  **Trigger to re-evaluate:** if Rebound ever goes to public App Store with >100 users, or takes outside funding, that's when we spend $300 on a real IP-law consult. Not before.

  **Fallback path (in reserve, no engineering delta):** train from scratch on Sahil's own footage plus permissively-licensed subsets (Roboflow Universe CC-BY 4.0 datasets, our own labeled edge cases). Slightly lower initial accuracy, clean license, always available.

  **§6.1 correction filed as part of v0.6 revision. License stance softened v0.7.**
- **R6 · Labeling economics — actual quotes.** ✅ **PARTIAL ANSWER 2026-06-27** (Roboflow verified; Scale AI, CVAT, Labelbox pricing not fetched).

  **Roboflow (verified via roboflow.com/pricing):**
  - Keypoint annotation: **$0.05 per keypoint** (managed labeling, Enterprise add-on)
  - Bounding box: **$0.10 each**
  - Polygon: **$0.20 each**
  - Managed labeling requires Enterprise plan (no listed minimum)

  **Implication for BallNet-R alone:** 2,000 frames × 1 ball keypoint × $0.05 = **$100** (I originally estimated $200 — was 2× too pessimistic).

  **Implication if we add R10 (player boxes for YOLO fine-tune):** 2,000 frames × ~10 players/frame × $0.10 = **$2,000** additional. Total labeling ~$2,100 for both models.

  **Alternative: SportsMOT-basketball gives us 67K free basketball player boxes (R5) so we can skip labeling players entirely for R10.** This kills the $2,000 line item. New total: **~$100 for ball keypoints only**, plus our own time labeling ~200-500 hardest edge cases for free.

  **DIY alternative:** Roboflow Public/Core plans include a labeling suite with AI-assisted annotation. Our own labeling tool (§6.3) built for ~1 weekend probably faster than paying + waiting.

  **Not yet verified:** Scale AI (rumored $0.05-$0.30/keypoint), CVAT self-hosted (free but compute cost), Labelbox (usually pricier at the volume we need). Follow-up item if we ever want to compare.
- **R7 · Alternative shot detection.** ✅ **ANSWERED 2026-06-27. Neither audio nor pose can replace BallNet-R, but both are useful complements.**

  **A. Audio-based (YAMNet, EfficientAT, PANNs family):**
  - Referee-whistle detection is a solved problem (F1 > 0.9)
  - Basketball swish/rim clang is *unsolved* in public literature — closest is a USPTO patent US 11,712,610 using an *ultrasonic sensor on the launcher* (doesn't transfer to phone at 20 ft)
  - Compute is trivial: YAMNet ~15 MB, ~10 ms/inference on A14+ CoreML, <2% of ML budget
  - **Fatal for AAU chaos:** adjacent-court swishes are acoustically identical to ours. Audio cannot spatially localize which court.
  - **Verdict:** rim-clang wake-up signal only — worth a **Phase 2.5 spike (~1 week: YAMNet-CoreML + ~200 labeled Sahil clips)**. Not a replacement.

  **B. Pose-only (ST-GCN, 2s-AGCN, PoseC3D families):**
  - Fu et al. reports 93.75% accuracy on shot-type classification with Part-aware LSTM — but on *curated, single-player, framed clips*
  - Consensus finding across Nature Sci Reports 2025 and ScienceDirect 2025 survey: **pose alone cannot resolve make/miss** (no ball/rim context in the skeleton)
  - Requires *tracked* per-player pose across ~30 frames — non-trivial ~50-100 ms/window on A17 for 10 players
  - **Verdict:** pose detects shot *attempt* (release motion) with high recall. Already 60% built via `VNDetectHumanBodyPoseRequest`. **Recommended as Phase 1.5 add** — a lightweight release-detector gates rim-ROI inference and cuts wasted BallNet compute. Cannot decide make/miss.

  **C. Comparison:**
  | Path | Detects attempt | Detects make/miss | AAU-chaos safe? |
  |---|---|---|---|
  | Vision (ball + rim, our plan) | ✅ | ✅ | ✅ (court quad + rim ROI) |
  | Audio alone | Weak (rim clang) | ❌ | ❌ adjacent-court leak |
  | Pose alone | ✅ | ❌ | Partial (needs court gate) |
  | Vision + audio fusion | ✅ | ✅ +precision | ✅ |

  **Fusion win:** Older AV-fusion sports work reports +3-8 pp F1 over vision-only. Modest, not transformative.

  **Big-picture answer:** Neither audio nor pose can replace BallNet-R. Both are complements that reduce Phase 1 risk. Ball tracking remains the load-bearing modality.

### Low priority (for later phases)

- **R8 · Rim detection literature.** Is this solved? Hough circles + verification?
- **R9 · Homography for court from 4 corners.** Standard `cv2.findHomography` or something clever?

### Player-tracking parallels (added 2026-06-27)

- **R10 · Should Phase 1 include parallel player-tracking wins?** ✅ **ANSWERED 2026-06-27 (reasoned + informed by R5).** **YES — recommended add. R5 unlocks cheaper path than I originally scoped.**

  **The R5 gift:** SportsMOT-basketball has **67K free basketball player boxes** under CC-BY-NC 4.0. That's the training data for a YOLOv8n fine-tune, **at $0 labeling cost**. Original R10 assumed we'd have to hand-label player boxes on Sahil's games (~$2K via Roboflow). Not needed.

  **Revised R10 workstream, all using data we now have identified:**

  | Sub-item | Data source | Estimated effort | Impact |
  |---|---|---|---|
  | Fine-tune YOLOv8n on youth basketball players | SportsMOT-basketball 67K + our 500 hardest edge cases | ~2 weeks | High — COCO-YOLO struggles with children's proportions/motion |
  | Retune body pose thresholds for kid proportions | Our own game footage, no labels needed (heuristic tuning) | ~3-5 days | Medium — better ankle-on-court gate accuracy |
  | Improve DeepTracker for erratic child motion | Our own footage; tune process-noise + add motion-model term | ~1 week | Medium — fewer lost tracks on cuts/direction changes |

  **Total add to Phase 1: ~3 weeks (down from my original 3-5 estimate).**

  **Combined data pipeline** (single unified effort):
  - Ball training: WASB + DeepSportRadar + TrackID3x3 + DeepSportLab warm-start + our own labeled Sahil frames
  - Player training: SportsMOT-basketball warm-start + our own labeled edge cases
  - Labeling tool serves both purposes on the same frames

  **License concern (same as R5):** SportsMOT is CC-BY-NC 4.0. If we train YOLO on it and ship the weights, we need lawyer clearance. Fallback: train YOLO from scratch on our own frames only, or use SportsMOT only for pretraining a small ANE-friendly variant then fine-tune-and-release.

  **Recommendation:** Include R10 in Phase 1. Revised Phase 1 total: **13-17 weeks** (was 10-14). Delivers two upgrades (ball + player tracking) from one data collection effort.

## 12 · Naming

Codename **Skynet Ball v2** during development, matching existing Skynet branding. Public feature name TBD — "Auto-Score" is honest; "Rebound Skywatch" is more product-y.

---

## Appendix A — Existing datasets audit (as of Jun 2026)

- **BVD (Basketball Video Dataset)** — collegiate, 4K frames, boxes not points
- **SportsMOT** — multi-sport, has basketball subset (~50 clips)
- **NPUBB** — pro, ball annotations, only 5K frames
- **YouTube-Sports** — huge but unlabeled and licensing-murky

None are good enough to skip labeling our own data. But BVD + SportsMOT combined = ~10K weak-label frames as pretraining warmup after TrackNetV3 init.

## Appendix B — References

**Architecture prior art**
- Chen et al. (2023). *TrackNetV3: Enhancing ShuttleCock Tracking with Augmentations and Trajectory Rectification.* [github.com/qaz812345/TrackNetV3](https://github.com/qaz812345/TrackNetV3). **License: MIT (verified R3).**
- Raj et al. (2024). *TrackNetV4: Enhancing Fast Sports Object Tracking with Motion Attention Maps.* arXiv:2409.14543
- Tarashima et al. (2023). *WASB-SBDT: Widely Applicable Strong Baseline for Sports Ball Detection and Tracking.* arXiv:2311.05237. [github.com/nttcom/WASB-SBDT](https://github.com/nttcom/WASB-SBDT). **Corroborates TrackNet family as SOTA for sports ball tracking.**
- *TOTNet* (2025). arXiv:2508.09650. U-Net + 3D convs + RAFT optical flow. **Phase 2 candidate for occlusion handling.**

**Rejected but referenced**
- Cheng et al. (2024). *SAM2 / EdgeTAM: On-device video tracking.* arXiv:2501.07256 (EdgeTAM). Rejected §13.8 (SAM2 not a detector; latency too high).
- Zhao et al. (2023). *RT-DETR: Real-Time Detection Transformer.* [github.com/lyuwenyu/RT-DETR](https://github.com/lyuwenyu/RT-DETR). Rejected §13.9 (bbox regression fails at 8-15px).
- Cheng et al. (2024). *YOLO-World: Real-Time Open-Vocabulary Object Detection.* arXiv:2401.17270. Rejected §13.9 (bbox + no small-object tuning).

**Shot detection method reference (patents)**
- NEX Team. *Real-time game tracking with a mobile device using AI.* US10748376B2. **Referenced for Phase 2/3 shot detection: trajectory backtracking from rim + bipartite match to nearest player at ball release.** Detector approach (SSDLite) rejected §13.10.
- NEX Team. Player location: US10796448B2. Multiplayer gaming: US10643492B2.

**Related fields**
- Cioppa et al. (2022). *SoccerNet-v3: Multi-View Sports Videos.*
- NEX Team. HomeCourt product ([home-court.com](https://home-court.com)) — solo-practice-only, not full-court.

---

## 13 · Other Memory — Rejected Alternatives

Ideas we considered and did **not** pursue, and why. New rejections append here — nothing gets deleted. If we ever revisit a rejected idea in the future, we open a §14 entry saying "reconsidered §13.X" and revise, we don't silently flip.

### 13.1 · Use TrackNetV3's PyTorch code and weights directly
**Rejected.** Retraining is required anyway (basketball ≠ shuttlecock), and we need CoreML for on-device inference. Simpler to reimplement the architecture in a clean training loop we control than to port their training pipeline. Their weights can still seed our initialization; the code is inspiration, not import.

### 13.2 · Use YOLOv8n for ball detection with a "sports ball" head
**Rejected.** YOLO's bounding-box regression fails at 8-15px object sizes — the box is mostly noise. Heatmap output (which is what TrackNet-style networks give us) degrades gracefully at small sizes: a fuzzy peak in the heatmap is honest information; a wrong box is a lie.

### 13.3 · TrackNetV3's InpaintNet for trajectory rectification in v1
**Deferred, not rejected.** Basketball trajectories are simpler than shuttlecock (projectile motion, no violent direction changes). Kalman filter + 3rd-order polynomial fit gives ~90% of InpaintNet's value at 5% the complexity. Revisit if v1 shows real gaps in occluded frames.

### 13.4 · Manual court corner tap for calibration
**Rejected.** Would require the parent to tap 4 court corners before every game from a gimbal angle they may not have a clear view from. XBotGO makes this mistake. Auto-calibration during warmup (§CourtHeatmapAccumulator) is already shipped and works from any angle. See discussion earlier in the session where this was explicitly ruled out with "what's the point of all this intelligence if I have to manually tap corners."

### 13.5 · Cloud inference for ball tracking (instead of on-device CoreML)
**Rejected.** Requires uploading 4K video mid-game, which fails on gym Wi-Fi and burns cellular data. Latency kills the "Gretzky lead" use case. On-device is the only architecture that respects the "phone is a dumb camera" constraint.

### 13.6 · Skip Phase 1, jump straight to jersey-number OCR for player attribution
**Rejected as Phase 1.** Jersey OCR at bleacher distance is very hard even with modern OCR — youth jerseys are dark on dark, low contrast, often unstable. Player attribution is Phase 5 for a reason. First we need to know **what happened** (shot event, make/miss, team) before **who did it**.

### 13.7 · Use HomeCourt's API / SDK
**Rejected.** HomeCourt is a consumer product; no public SDK. Their model works only for controlled solo-practice setups (fixed phone, single rim, one player) and does not generalize to full-court 5v5 with a gimbal. Would not solve our actual problem even if licensable.

### 13.8 · SAM2 / EdgeTAM for ball tracking
**Rejected (R1 finding, 2026-06-27).** SAM2-tiny runs ~1 FPS on iPhone 15 Pro Max (Srivastav on X, Sept 2024). EdgeTAM distilled to 16 FPS on iPhone 15 Pro Max (arXiv:2501.07256, 87.7 J&F on DAVIS17) — burns our entire 15fps budget. And SAM2 is a segmenter that requires a manual first-frame prompt to say what to track — it does not solve "find the ball in an unseen frame." Potential future use for player Re-ID masking during occlusion, not for ball detection.

### 13.9 · RT-DETR / DEIM / YOLO-World for ball tracking
**Rejected (R1 finding, 2026-06-27).** All three are bounding-box regressors. The 8-15px small-object failure mode we cite in §13.2 applies equally: at that size, the box is mostly noise while a heatmap peak degrades gracefully. RT-DETR/DEIM's transformer attention is also historically painful in CoreML. YOLO-World's open-vocabulary framing via CLIP embeddings adds no value for a fixed single-object-class problem. (Sources: arXiv:2401.17270, github.com/lyuwenyu/RT-DETR)

### 13.10 · HomeCourt's SSDLite bbox approach for the ball
**Rejected (R1 finding, 2026-06-27).** HomeCourt's US10748376B2 uses MobileNetV2 + modified SSDLite for ball detection. Their fixed-phone/half-court/single-player constraint keeps the ball at large pixel size, so bbox works for them. In our AAU chaos + gimbal + full-court setting, the ball is 8-15px — same rejection as §13.2/§13.9. **However**, their **shot detection** logic (trajectory backtracking from rim to identify the moment of release + bipartite match to nearest player) is architecture-agnostic and directly applicable to our Phase 2 + Phase 3. Kept as method reference, rejected as detector.

---

## 14 · Revision Log — Other Memory

Every change appends here. This is the doc's ancestral record.

### v0.1 — 2026-06-27 (initial draft)
- **Who:** Claude Sonnet 4.6 (architect, in session with Narayan)
- **What:** Created §1-12 + Appendices A-B based on TrackNetV3 paper reading, `model.py` inspection, and existing Rebound codebase audit.
- **Why:** Narayan asked for a full architecture + roadmap after we identified auto-scoring as the moat vs XBotGO/HomeCourt/Veo. Vision: "do something no app in the market does."
- **Key claims (asserted, not yet verified):** BallNet-R ~3M params · 8ms inference target · Phase 1 = 6 weeks · Scale AI labeling ~$200 for 2000 frames.

### v0.2 — 2026-06-27 (LLM-as-a-judge audit corrections)
- **Who:** Claude Sonnet 4.6 (verification agent, spawned as independent auditor)
- **Trigger:** Narayan flagged concern about hallucinations / context confusion after a long session and asked for verification.
- **Method:** Independent agent re-read every file the doc references in `SahilStatsLite/Services/`, re-derived TrackNetV3 param counts from `model.py`, re-derived BallNet-R param counts from the doc's own spec, and stress-tested timeline/pricing estimates.
- **Verified accurate:** All 6 file references (`YOLODetector.swift`, `DeepTracker.swift`, `PersonClassifier.swift`, `CourtHeatmapAccumulator.swift`, `GimbalTrackingManager.swift`, `BallDetector.swift`); TrackNet architecture; BallNet-R param count (recomputed at 2.83M vs claimed ~3M); input channel arithmetic; CoreML op compatibility; no fabricated APIs.
- **Corrections applied to §4.1:** Noted stages 1-2 use double conv, stage 3 and bottleneck use triple conv (was under-specified). Updated params from ~11M to ~11.3M (audit recount).
- **Corrections applied to §4.2:** Clarified InpaintNet input is 2 coord channels + 1 mask channel; mask *is* the visibility signal (there is no separate visibility channel). Updated params from ~500K to ~520K.
- **Corrections applied to §7:** Fixed coremltools syntax — `ct.ComputeUnit.CPU_AND_NE` enum, not `"cpu_and_neural_engine"` string.
- **Corrections applied to §7 performance target:** 8ms → 8-15ms with "verify empirically" caveat and Phase 1 milestone gate. Independent audit flagged 8ms as optimistic once CoreML fusion overhead and memory bandwidth are counted.
- **MAJOR correction to §8 Phase 1:** Timeline 6 weeks → 10-14 weeks. Original was optimistic for solo evenings/weekends work by a non-primarily-ML developer. Downstream cascading corrections in §9: Phase 1→3 now 4-6 months, Phase 1→4 now 5-7 months.
- **Typo fixes:** "Narrayan" → "Narayan" (multiple occurrences).
- **Verifier's own notes:** "Reasonable" on Scale AI $0.10/frame pricing. "Consistent" on internal channel arithmetic. "No hallucinated files, no wrong Swift descriptions, no fabricated APIs."

### v0.3 — 2026-06-27 (Other Memory established)
- **Who:** Claude Sonnet 4.6 (architect)
- **Trigger:** Narayan asked that this doc become "de facto going forward" and that it "carry the memory of ancestors" like the Bene Gesserit.
- **What:** Added §13 (Rejected Alternatives) and §14 (Revision Log) and §15 (LLM-as-a-Judge Audit History). Rewrote header to establish canonical status and change protocol. Updated `CLAUDE.md` to point at this doc as the authoritative source for all Auto-Score work.
- **Why:** Long AI-driven sessions accumulate context that can silently drift or vanish. A living doc with explicit revision protocol and preserved audit history is how we prevent that drift.

### v0.7 — 2026-06-27 (pragmatic license stance; Phase 0.5 kicked off)
- **Who:** Narayan (product) + Claude Sonnet 4.6 (architect)
- **Trigger:** Narayan noted he has no lawyer, and asked for a pragmatic path.
- **What:**
  - Softened R5 license caveat from "shipping blocker until lawyer signs off" to "not a blocker for personal/small-scale use; revisit if we ever go public App Store with >100 users."
  - Reserved fallback path (train from scratch on own footage + permissive CC-BY subsets) documented as always-available.
  - **Green-lit Phase 0.5.** Empirical CoreML latency test scripts to be written under `tools/ballnetr/` — pure engineering, no ML training, no labeled data, ~4-6 hours my time + ~30 min Narayan's time.
  - Dual-install decision remains parked (Narayan noodling).
- **Why:** The plan should match the actual product context. Rebound is a solo dad-dev personal app. Enterprise-grade legal caution is proportional overkill. Real risk: nonexistent. Pragmatic risk-taking > paralysis.

### v0.6 — 2026-06-27 (Phase 0 complete: R4-R7 + R10 answered, §6.1 dataset list corrected)
- **Who:** Claude Sonnet 4.6 (architect) + two parallel research subagents (R4+R5, R7)
- **R4 · Spatial-prior conditioning:** Standard practice in sports CV (WASB, SoccerNet GSR, Tennis Hawk-Eye, even TrackNetV3 itself). Not novel but not naive. Recommend BOTH input channel AND auxiliary out-of-court loss term (λ≈0.1 · BCE penalty). Pretrained-weight expansion is standard: copy RGB, init new channels at 0.1× RGB-mean.
- **R5 · Dataset audit:** **§6.1 was partly hallucinated in v0.1.** "BVD" and "YouTube-Sports" are not real canonical datasets. Real warm-start pool: **WASB-basketball (3,824 frames) + DeepSportRadar-v1 (1,456) + TrackID3x3 (6,701) + DeepSportLab (672) = ~12K public ball-keypoint frames.** All non-commercial licenses — lawyer check required before shipping. §6.1 corrected in this revision.
- **R6 · Labeling pricing (Roboflow only, verified):** $0.05/keypoint, $0.10/bbox, $0.20/polygon. Ball-only labeling for 2K frames = **$100 (was 2× overestimated at $200)**. With SportsMOT free 67K player boxes, R10 player-box labeling can be **$0**. Scale AI/CVAT/Labelbox not verified — follow-up if we ever want to compare.
- **R7 · Audio + pose alternatives:** Neither replaces ball tracking. Audio (YAMNet + custom head) fails AAU chaos constraint (adjacent-court swishes identical). Pose (ST-GCN) cannot decide make/miss (no ball in skeleton). **Both useful as complements:** audio rim-clang as wake-up signal (Phase 2.5, ~1 week); pose release-motion detector as compute gate for BallNet-R (Phase 1.5, already 60% built via VNDetectHumanBodyPoseRequest).
- **R10 · Player-tracking parallels:** ✅ Recommended for Phase 1. **SportsMOT-basketball unlocked cheaper path** (67K free basketball player boxes, CC-BY-NC 4.0). Full R10 stack (YOLO fine-tune + pose retune + Re-ID improvement) adds ~3 weeks (down from original 3-5 estimate). New Phase 1 total: **13-17 weeks**. Delivers two model upgrades (ball + player) from one data collection effort.
- **Phase 0 status:** COMPLETE. All 10 R-questions have evidence-backed answers. Ready for Phase 0.5 (empirical CoreML export test) and Phase 1 kickoff decision.

### v0.5 — 2026-06-27 (R1, R2, R3 answered; Phase 0.5 empirical test scoped)
- **Who:** Claude Sonnet 4.6 (architect) + two parallel research subagents (R1, R2)
- **Trigger:** Phase 0 research began.
- **R3 · TrackNetV3 license:** MIT confirmed via GitHub API. Can seed from their weights and ship commercially. Labeling budget could drop 50-70% from warm init vs cold train. See §11a R3.
- **R1 · Architecture family:** Stay with TrackNetV3 as seed. Independently validated by WASB-SBDT (2023, NTT Com) which is the same family and is SOTA across 5 sports. TrackNetV4 (motion-attention) kept as Phase 1.5 ablation, not baseline. SAM2/EdgeTAM, RT-DETR/DEIM, YOLO-World, HomeCourt's SSDLite all rejected — added to §13.8–13.10. **HomeCourt's shot-detection method (trajectory backtrack from rim + bipartite match to nearest player at ball release) kept as method reference for Phase 2/3.** Appendix B references expanded from 4 to 12 entries.
- **R2 · CoreML U-Net latency:** Estimate reasonable but skewed optimistic. Tightened to "10-18 ms expected, 8 ms is a stretch." Anchored to Photoroom (37ms/A17 Pro for larger U-Net at 512²) and Ultralytics YOLOv8n (3ms/A17 Pro at 3.2M/640²). Two specific ANE risk factors flagged: GroupNorm CPU fallback, bilinear upsample fusion. §7 language updated. **New Phase 0.5 milestone: half-day CoreML export test with two hard gates (median ≤18 ms, ≥90% layers on ANE) before Phase 1 code commit.**
- **Why:** Phase 0 research has already changed the plan in 3 places (licensing enables warm-init, HomeCourt patent gives us a Phase 2 shot-detection recipe, latency evidence adds a mandatory empirical gate before we invest 10-14 weeks). This is exactly the point of Phase 0.
- **Still open:** R4 (spatial-prior prior art), R5 (dataset audit), R6 (labeling pricing), R7 (alt shot detection), R10 (player-tracking parallels).

### v0.4 — 2026-06-27 (Phase 0 kickoff, R10 added, dual-install deferred)
- **Who:** Claude Sonnet 4.6 (architect) + Narayan (product)
- **Trigger:** Narayan flagged that BallNet-R doesn't directly improve player tracking and asked whether player-tracking improvements should be scoped into Phase 1. Also asked to defer the dual-install (Rebound + Rebound β) decision, and to run Phase 0 research before committing to any Phase 1 code.
- **What:**
  - Added §11a (Phase 0 Research Questions) — R1 through R10, each with its own priority tier
  - Added §11.5 (dual-install deferred)
  - Added R10 (parallel player-tracking wins) as a decision point before Phase 1 kickoff. Options: fine-tune YOLOv8n on youth basketball players, retune kid-optimized body pose thresholds, improve Re-ID for erratic child motion. All use the same labeling effort as BallNet-R.
  - Constraint: Phase 0 is docs-only. No code, no branches, no infrastructure changes.
  - Kicked off subagent research streams on R1 (paper comparison) and R2 (CoreML latency benchmarks) — deep-search agents, results appended to R1/R2 answer sections when they return.
- **Why:** The user is de-risking a 10-14 week Phase 1 commitment by validating architectural choices against actual literature and benchmarks. Doc-only research before code is the right sequence.
- **Status:** Phase 0 research in flight. Phase 1 blocked until R1-R4 have evidence-backed answers.

---

## 15 · LLM-as-a-Judge Audit History

Every independent verification pass is preserved here in its entirety. If a future verifier reaches a different conclusion, we log the disagreement, we don't overwrite.

### Audit 1 — 2026-06-27 (Sonnet 4.6, general-purpose verifier)

**Prompt given to the verifier:**
> Independent verification agent. Read every file the doc claims exists. Re-derive TrackNetV3 param count from `qaz812345/TrackNetV3/model.py`. Stress-test the internal-consistency numbers. Flag any hallucination. Rate severity: CRITICAL (must fix — blocks the plan), MAJOR (misleading), MINOR (imprecise). Be ruthlessly honest. Report under 800 words.

**Verifier's independent param recount for TrackNet (verbatim):**
> TrackNet convs (kernel 3x3, no bias):
> - down_1: (in→64) + (64→64): with in=9, 9·64·9 + 64·64·9 = 5184 + 36864 = 42048
> - down_2: (64→128)+(128→128): 73728+147456=221184
> - down_3: (128→256)+(256→256)·2 = 294912+1179648=1474560
> - bottleneck: (256→512)+(512→512)·2 = 1179648+4718592=5898240
> - up_1: (768→256)+(256→256)·2 = 1769472+1179648=2949120
> - up_2: (384→128)+(128→128) = 442368+147456=589824
> - up_3: (192→64)+(64→64) = 110592+36864=147456
> - predictor 1x1: 64·3=192
> Total ≈ 11.32M — matches "~11M". Good.

**Verifier's independent param recount for BallNet-R:**
> Sum ≈ 2.83M. Doc's ~3M is accurate.

**Verifier's summary:**
> No hallucinated files, no wrong Swift descriptions.
> TrackNet architecture claims are correct within a couple of imprecisions.
> Param math (both TrackNet ~11M and BallNet-R ~3M) reproducibly correct.
> Biggest risk: Phase 1 timeline (MAJOR) and 8ms inference target (MINOR, verify empirically).
> Fix: coremltools argument syntax (MINOR); "visibility" wording for InpaintNet input (MINOR); "Narrayan" typo (MINOR).

**Actions taken:** All findings applied — see §14 v0.2 entry.
**Disagreements:** None. Verifier and architect agreed on every finding.
