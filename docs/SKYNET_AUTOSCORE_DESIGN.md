# Skynet Auto-Score — Design & Roadmap

**Vision:** Rebound is the only consumer product that automates scoring in real youth basketball games from a single phone on a gimbal, in the chaos of an AAU gym with three courts running at once.

**Status:** design doc, not built yet
**Author:** Claude (Sonnet 4.6, Rebound arch)
**Reviewed by:** Narayan (Rebound PM)
**Last updated:** 2026-06-27

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
- Decoder: skip-concat + upsample 2× + conv triplets/doublets
- **Input:** stack of 3 consecutive RGB frames, 288×512 → 9 input channels
- **Output:** 3 heatmaps at 288×512 (one per input frame), sigmoid confidence
- **Loss:** weighted focal MSE on heatmap
- **Params:** ~11M

### 4.2 · InpaintNet (trajectory rectification)
- Tiny 1D U-Net over the sequence of `(x, y, visibility)` predictions from TrackNet
- Input: `(N, L, 3)` — L frames of predicted coordinates + a mask channel indicating "trust this frame"
- Output: `(N, L, 2)` — smoothed, gap-filled coordinates
- Params: ~500K

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

### 6.1 · The training data problem

There is no good basketball-ball dataset for youth games. Options:

| Source | Realism | Size | Cost |
|---|---|---|---|
| SoccerNet-Ball | Wrong sport | 500K frames | Free |
| Basketball academic datasets (BVD, NPUBB) | Pro/collegiate only | ~5K frames | Free |
| Kaggle NBA broadcast footage | Wrong perspective (broadcast angle) | Large | Free |
| **Rebound's own recordings** | **Perfect** | Growing | Free (already have them) |
| YouTube AAU footage | Realistic | Large | Free but license concerns |

**The winning play:** we have Sahil's actual game footage. That's the exact distribution we serve at inference time.

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
4. Narrayan labels 20-30 frames per session, 10 sessions = 300 more high-value labels
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

```
PyTorch model
   ↓ torch.onnx.export
ONNX
   ↓ coremltools.convert(target="mlprogram", compute_units="cpu_and_neural_engine")
BallNetR.mlpackage
```

**Known landmines:**
- PyTorch's `Upsample` with `align_corners=None` sometimes fails; use explicit `align_corners=False`
- BatchNorm running stats need to be frozen before export
- Sigmoid + heatmap output: export the raw logits, apply sigmoid on-device (better numerical range for Neural Engine)

**Performance target:**
- iPhone 16 Pro Max A18 Pro Neural Engine: 35 TOPS
- 3M-param U-Net at 288×512: **~8ms per inference** — comfortably 60fps
- At our 15fps AI cadence, this is 12% duty cycle — leaves budget for future rim/shot detectors

## 8 · Roadmap

Each phase ships value on its own. You can stop after any phase and still have improved the product.

### Phase 1 — **BallNet-R v1 replaces BallDetector** ⏱ ~6 weeks

Milestone: **reliable ball tracking under AAU chaos**

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

- **Phase 1 → 3 (product transformation):** ~13 weeks focused evenings/weekends
- **Phase 4:** +2 weeks
- **Phase 5 (stretch, high-value):** 2-3 months if attempted
- **Phase 6:** 1-2 months

At `~10 hours/week` sustained, **Phase 1-4 lands in ~5 months.** Phase 5 optional.

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

- Chen et al. (2023). *TrackNetV3: Enhancing ShuttleCock Tracking with Augmentations and Trajectory Rectification.* [github.com/qaz812345/TrackNetV3](https://github.com/qaz812345/TrackNetV3)
- Raj et al. (2024). *TrackNetV4: Enhancing Fast Sports Object Tracking with Motion Attention Maps.* arXiv:2409.14543
- Cioppa et al. (2022). *SoccerNet-v3: Multi-View Sports Videos.*
- NEX Team. HomeCourt product ([home-court.com](https://home-court.com))
