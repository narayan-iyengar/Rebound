# Phase 0.5 · BallNet-R CoreML Latency Test

**Purpose:** Empirically measure BallNet-R's inference latency on iPhone 16 Pro Max
Neural Engine BEFORE committing to Phase 1's 13-17 weeks of training work.
See `docs/SKYNET_AUTOSCORE_DESIGN.md` §11a R2 for the two hard gates this test settles.

**Effort:** ~30 minutes total. Everything Python is automated. You only:
1. Run one shell command
2. Open the resulting `.mlpackage` in Xcode
3. Screenshot the Performance tab result

**No ML training. No labels. No GPU.** Random-weights model — we measure the pipe, not the water.

---

## Prereqs

- macOS with Xcode 15+ (you have this)
- Python 3.10+ (you have `/opt/homebrew/bin/python3`)
- ~2 GB disk for PyTorch install
- iPhone 16 Pro Max (or any iOS 17+ device — but numbers are only meaningful on 16 Pro Max A18 Pro since that's the deployment target)

## Step 1 · Install Python deps (one-time, ~2 min)

```bash
cd /Users/narayan/SahilStats/SahilStatsLite/SahilStatsLite/tools/ballnetr
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Step 2 · Build model + export to CoreML (~1 min)

```bash
# Uses BatchNorm variant by default (safest for ANE per R2)
python export.py

# Optional: also export GroupNorm variant to test R2's CPU-fallback risk
python export.py --norm groupnorm --output BallNetR_gn.mlpackage
```

Output: `BallNetR.mlpackage` (~11 MB) written to this directory.

Console will print:
- Param count (should be ~2.83 M per audit)
- ONNX shape check
- CoreML conversion status
- ⚠️ Any op fallback warnings from coremltools

## Step 3 · Measure in Xcode (~5 min)

1. Open Xcode.
2. `File → Open` → select `BallNetR.mlpackage`
3. Xcode opens the model viewer. Click **Performance** tab (top).
4. Click **+** in the bottom-left, add your **iPhone 16 Pro Max** as a target device.
5. Click **Run Test**. Xcode runs 100 inferences and reports:
   - **Median compute time (ms)** — this is the number we care about
   - **Layer-level breakdown** — each layer color-coded ANE (blue) / GPU (green) / CPU (orange)

## Step 4 · Report back

Screenshot the two panels:
- Median compute time
- Layer breakdown

Paste them into the next Claude conversation. We interpret:

| Gate | Pass | Fail action |
|---|---|---|
| Median ≤ 18 ms | 🟢 GO | Shrink input to 224×384 OR halve channels |
| ≥ 90% layers on ANE | 🟢 GO | If GroupNorm falls back, switch to BN; if upsample falls back, use transposed conv |
| Model exports without op errors | 🟢 GO | Fix any unsupported op reported by coremltools |

Both gates pass → Phase 1 unblocked.

## Files

- `model.py` — PyTorch BallNet-R architecture matching design doc §5.1-5.3
- `export.py` — Random-weights build → ONNX → CoreML .mlpackage
- `requirements.txt` — Pinned pip deps
- `README.md` — this file

## What this test does NOT do

- ❌ Does not train the model
- ❌ Does not measure accuracy
- ❌ Does not require any labeled data
- ❌ Does not touch the Rebound iOS app source

This is pure architectural feasibility validation. Nothing about your app changes.
