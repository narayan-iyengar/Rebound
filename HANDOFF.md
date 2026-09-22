> ⚠️ **LEGACY / HISTORICAL SNAPSHOT (2026-05-03, build v314).** Kept for reference only — not current.
> Current vision → [`autoscore_spike/ROADMAP.md`](../../autoscore_spike/ROADMAP.md) · Current tech → [`docs/SKYNET_AUTOSCORE_DESIGN.md`](docs/SKYNET_AUTOSCORE_DESIGN.md) · Current build status → [`claude.md`](claude.md)

# Rebound — Handoff Notes (2026-05-03)

Current build: **v314 Release**. App rebranded from SahilStatsLite to **Rebound**.

---

## Current State

Feature-complete. All core systems working: recording, tracking, streaming, Watch scoring, auto-upload.
HaishinKit removed from SPM. UX polished (Tier 1+2 complete).

---

## Architecture

```
Watch (Source of Truth when connected)
    → scores, clock, period, stats
    → sends to Phone via transferUserInfo
    → runs independently when Phone unavailable

iPhone (Camera + Recording + Streaming)
    ← follows Watch state when connected
    → becomes source of truth if Watch disconnected
    → 4K recording with burned-in score overlay
    → 1080p YouTube live stream (custom RTMP)
    → YOLOv8n auto-tracking via DockKit gimbal
```

### Streaming Pipeline (Custom RTMP, no HaishinKit)
```
Camera 4K → CIContext scale 1080p → VTCompressionSession H.264 → FLV → NWConnection TCP:1935
                                                                  + Silent AAC loop (A/V sync)
                                                                  → YouTube (a.rtmp.youtube.com)
```

### Tracking Pipeline (Skynet v5.2)
```
Camera → Downscale 640x360 → YOLOv8n (0.15 conf) → PersonClassifier → DeepTracker
                                                         ↓
                                               CourtHeatmapAccumulator (warmup)
                                               └─ IMU yaw compensation → CourtQuad (auto-calibrated)
                                                         ↓
                                               GimbalTrackingManager
                                               ├─ Pan PID (Kp=1.6, negated) ← was 0.8
                                               ├─ maxPanVelocity 1.5 rad/s  ← was 0.8
                                               ├─ Tilt PID (Kp=0.4)
                                               └─ Gravity drift (-0.05 rad/s after 5s no detect)
```

## Key Files

| File | Purpose |
|------|---------|
| `SahilRTMPStreamer.swift` | Custom RTMP (~350 lines, zero dependencies) |
| `StreamingService.swift` | Streaming lifecycle, YouTube broadcast API |
| `YouTubeService.swift` | OAuth, upload, broadcast management → Sahil Hoops channel |
| `AutoZoomManager.swift` | Skynet orchestrator |
| `YOLODetector.swift` | YOLOv8n CoreML, letterbox, NMS |
| `GimbalTrackingManager.swift` | DockKit PID (pan + tilt + gravity) |
| `WatchConnectivityClient.swift` | Watch-side: standalone clock, period, stats |
| `WatchConnectivityService.swift` | Phone-side: receives Watch state |
| `RecordingManager.swift` | 4K capture, overlay, frame fork to streaming |
| `OverlayRenderer.swift` | Score overlay — 4 styles built (classic active, others ready) |

## Recent Changes

### May 3 — Skynet v5.2 + Infra
- **Auto court calibration (zero manual input)**: CourtHeatmapAccumulator accumulates ankle positions during warmup with IMU yaw compensation (CMMotionManager reads gimbal pan directly). Convex hull → quadrilateral fit → locks after 10 stable re-computes. Works from bleachers, corners, any angle. Status bar shows "Court 0%→✓".
- **CourtQuad replaces CGRect**: Perspective-correct polygon containment check. `courtBounds` kept as legacy shim.
- **Faster gimbal**: Kp 0.8→1.6 (analyze.py recommended), maxPanVelocity 0.8→1.5 rad/s (46→86°/s). Fast breaks no longer lag 1.5s.
- **Tighter default court filter**: x: 0.05→0.15, width: 0.90→0.70. Feet-only fallback (was feet||center).
- **YOLO active**: yolov8n.mlmodelc committed to repo (recovered from device cache). Tracking status bar shows YOLO/Vision + Court calibration %.
- **Stream link fixed**: Share button now actually appears (was @Published bug). Auto-copies to clipboard on generation. Shows error if YouTube not authorized.
- **Build number**: Run Script phase re-added — Xcode GUI builds now get correct build number from git.
- **Zero warnings**: All Swift concurrency warnings cleared (Sendable, nonisolated, actor isolation).
- **Paid Apple Developer account**: Signed up, devices registered. Free cert expiry no longer an issue.
- **Deploy infra**: deploy.sh in git, SSH over port 443 (port 22 blocked on some networks), remote fixed to SSH.

### Apr 25 — UX Polish (Tier 1+2)
- HaishinKit removed from SPM (was unused, slowed builds)
- Game log film icon for games with local video
- Haptic feedback on phone score taps
- Stat tiles capsule-shaped with white-on-color (AST, REB, STL, BLK, TO, PF)
- Tracking indicator visible during recording (player count + gimbal status)
- Smart clock +1:00 undo via long-press (warning haptic)
- 4 scoreboard overlay styles built in OverlayRenderer (Classic, Full Bar, Broadcast, Pill)
  - Picker removed (style switching had a binding bug, classic works, not worth debugging)
  - Code preserved for future use

### Apr 25 — Watch Standalone Mode
- Watch clock counts down independently (was frozen without phone)
- Watch advances periods locally with clock reset
- Personal fouls wired (was placeholder)
- New game fully resets all stats

### Apr 18-19 — Tracking + Rebrand
- YOLO coordinates fixed (pixel→normalized, was causing 0 detections)
- Gimbal pan direction negated (was opposite)
- Tilt PID added (Kp=0.4) + gravity drift
- App rebranded to "Rebound"
- Repo renamed to github.com/narayan-iyengar/rebound

### Apr 7-8 — Streaming
- Custom RTMP implementation (replaced HaishinKit entirely)
- Silent AAC for A/V sync
- Auto-broadcast via YouTube API (unlisted, Sports, ultra-low latency)
- Per-game streaming toggle in GameSetupView

## YouTube
- Channel: Sahil Hoops (@RealDeadlSahil, UCUMg4lDQC7cxgpHc5xrOH4w)
- All uploads + broadcasts target this channel
- Titles: "Team vs Opponent", descriptions: "Recorded with Rebound"

## Known Issues
- **Watch app won't open at games** — Watch 8 recurring. `deploy.sh --watch-only` times out even on same WiFi. Workaround: deploy via Xcode directly (Run button, watch destination).
- Ultra 2 often times out on wireless deploy
- YOLO foreground filter blocks home testing (works at game distance 10+ feet)
- Tilt direction confirmed at home, untested at game (may need sign flip)
- Court auto-calibration not yet field-tested
## Completed Optimizations (Apr 25, Opus session)
- CVPixelBuffer pool reuse for streaming (was allocating per frame, now pooled)
- Removed 3 unused scoreboard styles (Full Bar, Broadcast, Pill) — 309 lines deleted
- Removed dead film icon from GameRow (videoURL always nil after upload)
- Silent audio fallback already fixed (iOS 26 PCM rewrite in earlier session)

## Remaining
- **Watch deploy via deploy.sh broken** — investigate why devicectl times out on WiFi even though devices show as "available (paired)". May be a CoreDevice pairing/provisioning issue with the new paid account.
- Consider removing BallDetector (~730 lines, minimal tracking impact)
- RTMP auto-reconnect, YouTube API retry — evaluated, not worth the complexity
- Field-test court auto-calibration at next game

## Deploy
```bash
ssh narayan@Narayans-MacBook-Pro.local "bash ~/SahilStats/deploy.sh"
```
