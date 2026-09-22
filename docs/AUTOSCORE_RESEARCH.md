# Auto-Score Research & Plan of Record

> **Status:** Research + architecture plan (2026-09-18). Not yet built.
> **Companion doc:** [`SKYNET_AUTOSCORE_DESIGN.md`](./SKYNET_AUTOSCORE_DESIGN.md) — the canonical Auto-Score/ball-tracking design. This file is the *research appendix + build plan* that feeds Phase 1 (BallNet-R).
> **Author's hat:** written as vision-ML + basketball + iOS notes for a solo build.

---

## 0. TL;DR

- **Goal:** post-game stat extraction from a single fixed-camera recording, running **locally on the user's MacBook Pro (16 GB M2 Pro)** — not the cloud. Zero per-game cost, full privacy (footage contains other people's minor children).
- **The category is real but the "95%" is marketing.** HoopIQ.ai (the reference product) is a very new single-phone → cloud → 24 h SaaS. Its 95% figure is self-reported, unverified, and dominated by easy events (team points, made shots). Per-player attribution is where accuracy actually leaks (~90% at best on good footage, lower on youth).
- **Identity = team color + jersey number**, both read from pixels. A preloaded roster only (a) renames "orange #1" → "Sahil" and (b) constrains the number-reader to the ~12 numbers on the floor, which sharply boosts accuracy. Roster-seeded and un-seeded are the *same pipeline*.
- **Our structural edge over HoopIQ:** we already have **AR court calibration** (free, near-perfect homography) and can **fine-tune on Sahil's own gym/jerseys** — the two things a one-size-fits-all cloud service can't match.
- **Architecture:** a **multi-pass, streaming pipeline** (one model resident per pass, intermediate results cached to disk) so peak memory = the largest single model, not the sum. Critical on a 16 GB unified-memory Mac.
- **Tracker:** **SAM2** (chosen for occlusion robustness + segmentation masks → clean foot points → accurate shot locations), run **windowed + streamed** to bound memory.
- **v1 scope:** points + shot chart (FG by zone) + FT% — the exact schema the Practice/Career views already use. Rebounds/assists are later, human-confirmed.

---

## 1. Reference product teardown — HoopIQ.ai

**What it is:** upload full-game footage (file or YouTube link) → cloud AI → box score, shot charts, advanced stats, highlights, per-player trends, an AI "assistant coach." Basketball only, public beta.

**Real-world workflow (from an AAU dad's free trial):** preload team roster + jersey numbers → record with a SportCam (fixed wide auto-track cam) → upload to YouTube → HoopIQ pulls it → stats back **~24 h later**.

**The tells:**
- The required **roster/jersey preload** proves the "no manual input" marketing is false — and confirms the known-roster seed is the key accuracy lever.
- **24 h turnaround** = batched cloud GPU on a cost-optimized queue, *not* a compute limit. A single game is only ~1–4 GPU-hours; the SLA is generous to keep costs (and price, $19.99/mo) low. May also hide a human QA pass.
- **"95%" is unverified marketing** — no App Store/Play ratings, no third-party review found. Realistically a blended number dominated by team points + clean made shots; per-player/assist/rebound accuracy is lower, especially on low-res youth footage.

**Name collision warning:** the correct product is **hoopiq.ai** ("HoopIQ: Basketball Insights", `com.hoopiq.hoopiq`). NOT hoopiq.io (betting), NOT `com.hoopiq.app` (a shot-form coach), NOT Hooper.gg (a separate competitor).

**How HoopIQ works "on any random video" without a seed:** it emits **team (jersey-color cluster) + jersey number (OCR + voting)** as the identity, so it can hand you "orange #1 had 12 pts" with no roster. The seed just renames + constrains. The jersey **number is the identity anchor** (not the track) — it re-links a player across the constant track breaks. On sharp NBA broadcast, numbers read easily → it "just works." On youth wide-cam, numbers are tiny/blurred → this is exactly the stat that degrades, and exactly why the preload + voting matters more for us.

---

## 2. Competitive context (one paragraph)

Only a tiny recent cluster does *fully-automated single-phone* stats: **HoopIQ, SportsVisio, Hooper.** Everyone else leans on a crutch — multi-camera arena rigs (Second Spectrum/Genius, Sportradar, PlaySight, Pixellot Prime), dedicated hardware (Veo, Trace, Hudl Focus), wearables/chipped ball (ShotTracker), or humans-in-the-loop (Hudl Assist, Synergy). The only systems with *verified* accuracy are the pro multi-cam rigs (leagues use them as official data). Every consumer "95%/92%" number is self-reported. SportsVisio has publicly described its ~8-stage pipeline (normalization → court calibration → player/ball detection → ID tracking → possession → event classification → attribution → highlights) — the closest thing to a public blueprint, and it admits ~92% player attribution vs ~95% event detection.

---

## 3. The CV pipeline and where accuracy actually goes

Pipeline: `detect players → track → identify (team+number) → track ball → map to court → made/miss → events → possession`.

| Stage | Status | Notes for youth / fixed-cam |
|---|---|---|
| Player detection | ✅ solved | RF-DETR / YOLO11; needs ≥1280px for far-side kids |
| **Game-long identity** | ❌ **master bottleneck** | identical jerseys kill appearance re-ID; no one holds one ID for 30+ min from one camera |
| **Jersey OCR** | ⚠️ ~90% broadcast, worse on youth | **known roster → closed-set classifier** is the fix (Roboflow: ResNet-32 hit 93% vs VLM 86%) |
| Ball tracking | ✅ per-frame (TrackNetV3 ~97%) | invisible during scrums/shots — gaps land on the events you care about |
| Court homography | ✅ **trivial for us** | we already have AR 4-corner calibration |
| Made/miss + 2v3 | ⚠️ clean solved, contested hard | rim tap + downward ball trajectory; 2-vs-3 uses shooter's feet + homography |
| Rebounds | ⚠️ ~75–85% heuristic | miss + first possession near rim |
| Assists/steals/TO | ❌ least reliable | need possession + intent; human-confirmed |

**Accuracy compounds multiplicatively.** A fully-automated per-player shot-chart entry chains ~6 stages → realistically **0.3–0.45 for contested play, ~0.57 optimistic**. That is why the honest number is "team points + clean made shots," not "everything, every player." **The single most valuable design decision: decouple tracking from identity** — produce short reliable tracklets, re-anchor them to the known roster via jersey-number voting, and put a human-confirm pass at scoring events.

---

## 4. Architecture: multi-pass, streaming pipeline

The key decision for a memory-constrained Mac: **don't run all models at once.** Run the game through in **separate passes, one model resident at a time, caching intermediates to disk.** Peak memory = the largest single model, not the sum. Runtime is free (overnight), so multi-pass costs nothing — and every stage becomes independently re-runnable (tweak stitching without re-running SAM2 for hours).

```
PASS 1  DETECT   RF-DETR over sampled frames (5–10 fps)
                 → detections.parquet (players, ball, rim)      [detector resident only]

PASS 2  TRACK    SAM2, streaming + windowed, prompted by Pass-1 boxes
                 → tracklets.parquet (local IDs, masks→foot pts) [SAM2 resident only]

PASS 3  TEAM     SigLIP embeddings on crops → UMAP → KMeans
                 → team labels                                   [SigLIP resident only]

PASS 4  NUMBER   roster-constrained classifier on crops + voting
                 → number votes per tracklet                     [tiny model]

PASS 5  RESOLVE  stitch tracklets across window seams → global entities
                 vote team+number → map to roster                [CPU only]

PASS 6  EVENTS   homography (AR corners) + rim/ball geometry →
                 shots (made/miss, location), possession, box score
                 → stats.json → Firebase → Rebound               [CPU only]
```

Passes 5–6 use **no GPU** — pure geometry/logic on cached tracklets, run in seconds, and are where you iterate. Expensive passes (1–2) run once overnight.

**Data flow across devices:** Rebound (phone) records + holds the roster → video lands on the Mac (or a Synology NAS as storage/orchestration hub) → Mac runs passes 1–6 → `stats.json` written to **Firebase** (reusing existing sync) → Rebound displays it like any other game. A "review & correct" screen turns ~85% into effectively 100% on the stats that matter.

### 4.1 Tracker decision: SAM2 (windowed)

Chosen over ByteTrack/OC-SORT because runtime is not a constraint and SAM2 gives two things that directly help youth footage:
1. **Segmentation masks → clean foot contact points** (mask bottom, not box bottom) → accurate shot *location* via homography. ByteTrack can't give this.
2. **Persistence through occlusion compensates for weak youth OCR** — if a track survives 30+ s, one good number read anchors the whole stretch. Better tracker ⇒ less reliance on OCR.

Trade-off accepted: SAM2 is heavy and its memory bank grows with video length → **must be windowed + streamed** (below).

### 4.2 SAM2 memory-windowing (streamed)

```
GAME (40 min) → overlapping windows (~2 s overlap)
  per window:
    t=start → RF-DETR boxes → prompt SAM2
    every N frames → RF-DETR again → add new entrants, drop leavers
    SAM2 propagates masks; keep only a ROLLING frame buffer (not the whole window)
    t=end → reset_state          ← bounds memory
  seam → stitch local IDs across the overlap by: jersey number (hard) >
         mask/position overlap > SigLIP appearance
  global identity graph: connected components = one game-long entity;
         vote team+number across ALL member tracklets
```

**Do NOT use the reference `propagate_in_video`** (it caches the whole clip). Stream frames and keep a rolling buffer. The seam is also the natural **human-review point**: if number-votes disagree across a stitch, flag "same player? [y/n]" — one tap fixes a downstream chunk of stats. **Window length is the one real tuning knob** (longer = fewer seams but more memory/drift).

---

## 5. Memory analysis — tuned for 16 GB M2 Pro

**Apple-Silicon gotcha:** memory is **unified** — CPU and GPU share one pool. SAM2's `offload_to_cpu` flags (which save VRAM on NVIDIA) **do nothing here**; you bound memory only via short windows + streaming + multi-pass.

Component footprint (fp16):

| Model | Params | Weights | Working peak |
|---|---|---|---|
| RF-DETR-S | small | <0.5 GB | ~1.5–2 GB |
| SAM2 base+ | 81M | ~0.16 GB | ~4–6 GB (streamed, ~12 players) |
| SAM2 large | 224M | ~0.45 GB | ~7–10 GB |
| SigLIP (B/L) | — | 0.4–1.6 GB | ~2–3 GB |
| Jersey classifier | tiny | <0.1 GB | <0.5 GB |

Because it's multi-pass, **peak = the biggest single pass = SAM2.**

**16 GB M2 Pro plan (the real target):**
- macOS + apps eat ~4–8 GB → budget ~8–10 GB for the pipeline.
- Use **SAM2 base+** (not large), **short windows (~15–20 s)**, **stream** (rolling buffer), **fp16**, and **close other apps** during the run.
- Sample at **~5–6 fps** for tracking (dense only near shot events) to cut frames and memory.
- Expected wall-clock on M2 Pro (16-core GPU, MPS ≈ 0.5–1× a T4 for this workload): SAM2 pass roughly **6–15 h** for a 75-min game at 5 fps → comfortably an **overnight** job. 16 GB is tight but workable with this config; it is the constraint that rules out SAM2-large locally.
- If it thrashes: drop to SAM2-small, shorter windows, or lower fps. If you want SAM2-large or comfort, that argues for the GCP path (§6) or a 32 GB+ Mac.

---

## 6. Cost if run on GCP instead (comparison)

A game is ~1–4 GPU-hours of real work. Times below are the **full pipeline** (detect + SAM2 + team + OCR) for a ~75-min game sampled ~8 fps; SAM2 tracking dominates (Roboflow's SAM2 pipeline ran ~1–2 fps on a T4).

| GPU (GCP) | On-demand $/hr (GPU+small VM, us-central1, approx) | Spot $/hr | Time/game | **$/game on-demand** | **$/game spot** |
|---|---|---|---|---|---|
| **T4** | ~$0.55 | ~$0.15–0.25 | ~7–9 h | ~$4–5 | ~$1.5–2 |
| **L4** (g2-standard-8) | ~$0.80 | ~$0.30–0.35 | ~3–4 h | **~$2.5–3.5** | **~$1–1.5** |
| **A100 40GB** (a2-highgpu-1g) | ~$3.67 | ~$1.1–1.5 | ~1.5–2 h | ~$5.5–7.5 | ~$2 | (overkill) |

Add-ons: Cloud Storage ~$0.02/GB/mo (a 4K game ≈ 20 GB → ~$0.40/mo; delete after → negligible); ingress free; results JSON egress ~free. **Cloud Run now supports L4 GPUs with scale-to-zero, per-second billing** (~$0.70/hr class) — the closest GCP equivalent to Modal's serverless model and the least ops overhead.

**Verdict:**
- **Cheapest sensible GCP path: L4 on Cloud Run or spot ≈ $1–3/game** (~$50–150/yr at 1 game/week).
- **On-demand L4 ≈ $3/game.** A100 is not cost-effective for this.
- vs **local Mac = $0/game** (just electricity + a tied-up Mac overnight).
- **Recommendation:** local M2 Pro for cost + privacy (video of minors). Reach for **GCP L4 (spot / Cloud Run)** only if you want SAM2-large quality, faster turnaround, or to not tie up the Mac. Modal serverless (~$0.50/game from earlier research) is even simpler/cheaper than GCP if cloud is ever chosen — but cloud means uploading footage of other kids, so keep it delete-after-processing.

---

## 7. Phased roadmap (80/20)

| Phase | Delivers | Components | Accuracy target | Effort |
|---|---|---|---|---|
| **P0** | Rim tap + reuse AR corners → homography JSON | Rebound UI | — | S |
| **P1 ⭐** | **Shot chart + points** | RF-DETR → SAM2(windowed) → TrackNet ball → rim geometry → homography → roster seed | ~90% pts, ~85% made/miss + location | M |
| **P2** | Per-player attribution | jersey classifier seed + one-time roster confirm + tracklet voting | ~90% Sahil, ~80% others | M |
| **P3** | Rebounds | possession change near rim after miss | ~75–85% | M–H |
| **P4** | Assists | pass → made-FG within window | ~70–80%, noisy | H |
| **P5** | On-device port (optional) | CoreML conversion of P1 models | match | H |

Ship **P1** and use it a full season before touching assists. Auto-Score fills the **same stat buckets** the Practice/Career shot-map views already define (points, FG-by-zone incl. layups-by-hand, foul-line jumper, FT%).

---

## 8. Open-source stack (permissive; avoid AGPL for anything shipped)

| Component | Repo | License | Note |
|---|---|---|---|
| Detection | Roboflow **RF-DETR** | Apache-2.0 ✅ | ship-safe; fine-tune on Sahil's games |
| Detection (proto only) | Ultralytics YOLO11 | **AGPL-3.0** ⚠️ | fine for private local tool; must swap before shipping |
| Glue / tracking / zones | Roboflow **supervision** | MIT ✅ | ByteTrack, PolygonZone (rim zone!), annotators, Detections API; model-agnostic |
| Sports helpers | Roboflow **sports** | MIT ✅ | basketball court keypoints + jersey helpers |
| Tracking (chosen) | **SAM2** (Meta) | Apache-2.0 ✅ | masks + occlusion memory; windowed |
| Ball tracking | TrackNet family | MIT (verify per fork) | small-fast-object heatmap tracker |
| Team split | SigLIP + UMAP + KMeans | permissive ✅ | no training needed |
| Jersey OCR | ResNet classifier (roster-constrained) / SoccerNet jersey pipeline | verify | small classifier beats VLM; constrain to roster |
| Pose (P3+) | Apple Vision `VNDetectHumanBodyPose` / MMPose | Apple SDK / Apache ✅ | shot/action cues |
| Homography | **already have** (AR CourtCalibrationView) | — | don't re-implement |

Reference to cannibalize (not production): Roboflow's basketball player-ID Colab (RF-DETR-S + SAM2 + SigLIP/UMAP/KMeans + ResNet jersey + IoS matching + 3-frame voting). It stops at "who is this player" — **no homography, no shot location, no possession** (their "future work" = exactly the pieces we add and already half-own).

---

## 9. Training data

**Layered — not either/or:**
- **Pretrain on generic** (Roboflow 10-class basketball set, SportsMOT) so the model knows player/ball/rim in general.
- **Fine-tune the last mile on Sahil's own footage** — narrow, consistent domain (same-ish gyms, fixed camera, fixed jerseys) = ideal fine-tune. Generic-only underperforms in our gyms/lighting.
- **Jersey model must be team-specific** — constrain to the actual roster numbers.
- **Bootstrapping loop:** pretrained pipeline auto-labels our footage → correct in the review screen → corrections become training data → retrain. Each game improves the next; we own the ground truth (we were there). This is the moat HoopIQ's one-size-fits-all cloud can't match.

---

## 10. Privacy / licensing

- Processing **our own kid's video on our own devices is not a COPPA event** (parent, not an operator collecting third-party data). Keep it local to stay clear of the regime.
- Other kids appear incidentally — fine for private use; **do not publish clips of other kids** without their parents' OK. If this ever becomes a multi-user product, it needs consent/policy/deletion + data minimization → strong argument for on-device or delete-after-processing cloud.
- **Ultralytics YOLO / boxmot are AGPL-3.0** — fine for a private, non-distributed local tool; if ever folded into the shipped app, migrate to RF-DETR (Apache) + supervision (MIT) or buy an enterprise license. Verify TrackNet-fork and any court-calib research-repo licenses before distribution.

---

## 11. Basketball reality check (keep v1 honest to youth ball)

- Youth ball is **half-court and layup-heavy** → the shots that matter happen near the rim where the camera sees best; fewer full-court transition scrums.
- **Possession is simpler** than the NBA → nearest-player-to-ball + short dwell filter works most of the time.
- **The rim region is the highest-signal thing in the frame** → tap the rim once + ball trajectory through it = near-deterministic made/miss for the clean youth shots that dominate.
- v1 = **points + shot chart + FG-by-zone + FT%** — already the Practice/Career schema.

---

## 11a. Recommended hardware (local compute box)

Goal: one machine that runs Auto-Score locally (kills GCP cost + privacy exposure) **and** doubles as a local open-weight-LLM rig. Target LLM: **70B, possibly higher.**

**Decision drivers:**
- **Auto-Score CV** runs on anything ≥ the current 16 GB M2 Pro; more GPU cores just speed SAM2, and runtime is free (overnight). Not the deciding factor.
- **Local LLMs** are the real driver: **memory capacity → model size**, **memory bandwidth → tokens/sec** (generation is bandwidth-bound).

**RAM target for 70B+:** **128 GB.** (70B @ 4-bit ~45–50 GB; 70B @ 6/8-bit ~55–75 GB; 100–120B @ 4-bit ~60–80 GB.) 64 GB only does 70B @ 4-bit with no headroom. Apple Silicon RAM is **soldered — buy it up front.**

**Recommendation (in priority order):**
1. **Used/refurb M2 Ultra, 128 GB (~800 GB/s), ~$2.5–3.3k** — best value for a 70B-focused box. 800 GB/s beats a new M5 Max (460–614 GB/s) on the metric that matters for 70B; 128 GB covers "maybe higher." M1 Ultra 128 GB (also 800 GB/s) if notably cheaper.
2. **Apple Certified Refurbished M3 Ultra, 96–256 GB (819 GB/s)** — newer silicon + warranty; 256 GB config pushes past 120B.
3. **New Mac Studio M5 Max, 128 GB (~$2,499 + RAM upgrade)** — pick only if latest GPU/Neural Engine + full warranty outweigh 70B speed (slower token-gen than an 800 GB/s Ultra).
4. **Skip M5 Ultra ($5,499)** unless running 100–200B+ models *fast* is a real need — nothing in Auto-Score requires it.

**Buying notes:** prefer Apple Certified Refurbished (warranty + AppleCare eligibility; no user-serviceable parts). Get ≥1 TB SSD (4K game files are large even if deleted after processing). Verify RAM/SSD config and that it's not activation-locked.

**Current-lineup reference (from Apple spec sheets, 2026):**
- Mac Studio **M5 Max** from $2,499 (36 GB base → 128 GB; 460–614 GB/s; 32–40-core GPU); **M5 Ultra** from $5,499 (96 → 512 GB; 1.2 TB/s; 64–80-core GPU).
- Mac mini **M6** $899–1,299 (153–170 GB/s, ~16–32 GB); **M5 Pro** $1,699 (307 GB/s, 16-core GPU, ~up to 64 GB) — the value pick *if* 64 GB / 70B-at-4-bit is enough, but 128 GB Ultra is the better 70B+ box.

## 12. Open decisions / next steps

1. **Confirm SAM2 base+ fits comfortably on 16 GB M2 Pro** at ~15–20 s windows, 5 fps, streamed — a spike test before committing.
2. **Window length** tuning (memory vs stitch count).
3. **Stitching failure case:** SAM2 keeps a confident-but-wrong ID through a seam; voting must overrule it — design the override + review flow.
4. Where video lands (iCloud/Photos vs NAS share vs direct transfer) — the "how does the file get to the Mac" arrow.
5. Whether to fine-tune RF-DETR before P1 or bootstrap-label first.

---

## 13. P1 spike plan (run overnight on the 16 GB M2 Pro)

**Goal of the spike:** prove end-to-end that we can turn one recorded game into a **team box score + a rough shot chart**, locally, for $0 — before spending a dollar on hardware or building any real UI. Accuracy is *not* the bar here; a working skeleton that produces plausible numbers on a real game is.

**Scope (deliberately minimal):**
- Detect players + **ball** + **rim** per frame.
- Fast tracking (ByteTrack) — NOT SAM2 yet (identity/per-player is P2).
- Manual one-time inputs: tap the **4 court corners** + **rim box** on a single frame (stand-in for the AR calibration we already have).
- **Made/miss** = ball trajectory crossing the rim region downward.
- **Shot location** = shooter's feet (box bottom) → homography → court zone (2 vs 3).
- Output: `stats.json` (team points, FGA/FGM by zone, made/miss list) + an annotated preview MP4.
- **Out of scope for the spike:** per-player attribution, jersey OCR, assists, rebounds, SAM2, fine-tuning.

**Stack (all pip, permissive except YOLO):**
- `ultralytics` YOLO (AGPL — fine for a private spike; swap to RF-DETR before shipping) OR `rfdetr`.
- `supervision` (MIT) — ByteTrack, PolygonZone (rim zone), annotators.
- `opencv-python` (bundles ffmpeg — no system ffmpeg needed), `torch` (MPS backend), `numpy`.
- Homebrew Python (`/opt/homebrew/bin/python3`) to avoid the Xcode-license gate on `/usr/bin/python3`.

**16 GB tactics:** multi-pass (one model resident), sample ~5 fps, process in a streaming loop (don't hold all frames), fp16, close other apps.

**Steps:**
1. **Env + inputs:** confirm Homebrew Python + pip; get one game as a local `.mp4` (a local recording, or `yt-dlp` a YouTube upload we own).
2. **Smoke test:** run detection on the first ~30 s → annotated clip, eyeball that players/ball/rim are found.
3. **Calibrate:** click 4 court corners + rim box on one frame → save `calib.json` (homography + rim polygon).
4. **Pass 1 (detect):** YOLO over sampled frames → `detections.parquet`.
5. **Pass 2 (track):** supervision ByteTrack → `tracks.parquet`.
6. **Pass 3 (events, CPU):** rim-zone crossing → shot attempts; ball apex + downward-through-rim → made/miss; nearest player at release → shooter; feet→homography→zone (2/3).
7. **Emit:** `stats.json` + annotated preview. Hand-score the same game to measure error.

**Overnight execution:** launch Pass 1–2 before bed (the multi-hour part); Pass 3 + emit are seconds and can be re-run/tuned the next day without re-running the GPU passes. Expected wall-clock for a 75-min game @ 5 fps on M2 Pro: a few hours (detect + ByteTrack; no SAM2).

**Success criteria:** `stats.json` team points within a few baskets of truth, and a shot chart that visibly lands shots in roughly the right zones. That's enough to justify P2 (identity) and/or the hardware.

**Note on GCP free tier:** the Always-Free tier has **no GPU** — it won't help run this. A *new-account* $300 credit could cover some GPU hours (an L4 for a handful of games), but it expires and means uploading footage of minors. Local remains the right call; GCP only makes sense as a one-off if the Mac path stalls.

**Training data (the YouTube + local games):** yes — use them two ways. (1) **Eval:** hand-score 2–3 of them to create a ground-truth scoreboard (we were there; we know the truth). (2) **Bootstrap labels:** run the spike to auto-label, correct the mistakes, and that becomes fine-tuning data for RF-DETR + a roster-specific jersey classifier later. Pretrain generic → fine-tune the last mile on our own gyms/jerseys (see §9). The spike itself needs **no training** — it runs on pretrained weights; training is a P2+ accuracy step.

## Sources

HoopIQ: hoopiq.ai/tech, hoopiq.ai (FAQ), hoopiq.ai/pricing · SportsVisio pipeline: sportsvisio.com/stories/how-ai-basketball-analysis-works · Roboflow basketball player-ID: blog.roboflow.com/identify-basketball-players · supervision: github.com/roboflow/supervision · sports: github.com/roboflow/sports · SAM2: github.com/facebookresearch/sam2 · SportsMOT: arxiv.org/html/2304.05170v2 · SoccerNet jersey: arxiv.org/pdf/2309.06006 · TrackNetV3: dl.acm.org/doi/fullHtml/10.1145/3595916.3626370 · KaliCalib: arxiv.org/pdf/2209.07795 · TrackID3x3: arxiv.org/pdf/2503.18282 · Ultralytics license: ultralytics.com/license · GCP GPU pricing: cloud.google.com/compute/gpus-pricing, cloud.google.com/run (GPU) · COPPA: ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions
