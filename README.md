# SahilStatsLite

> 📎 **Where the current thinking lives:** vision & roadmap → [`autoscore_spike/ROADMAP.md`](../../autoscore_spike/ROADMAP.md) · technical design → [`docs/SKYNET_AUTOSCORE_DESIGN.md`](docs/SKYNET_AUTOSCORE_DESIGN.md) · build status → [`claude.md`](claude.md). This README is the project intro.

Auto-tracking basketball camera + live scoreboard + YouTube streaming for AAU youth basketball. Built for one kid, one parent, one phone.

> A parent watching their kid's game shouldn't babysit an app.

## What It Does

Mount an iPhone 16 Pro Max on an Insta360 Flow Pro 2 gimbal at a basketball game. The app:

1. **Auto-tracks players** using YOLOv8n + DockKit gimbal control
2. **Records in 4K** with a broadcast-style score overlay burned into the video
3. **Streams live to YouTube** so remote family can watch
4. **Syncs with Apple Watch** for sideline scoring without touching the phone

The phone becomes a "dumb camera" on the gimbal. All scoring happens from the Watch.

## Architecture

```
                    iPhone 16 Pro Max
                    ┌──────────────────────────────┐
  AVCapture ──────> │  RecordingManager            │
  4K 30fps          │  ├─ OverlayRenderer (score)   │
                    │  ├─ AVAssetWriter (4K .mov)    │
                    │  └─ StreamingService ─────────────> YouTube RTMP
                    │       └─ SahilRTMPStreamer     │    (1080p H.264)
                    │          ├─ VTCompression      │
                    │          └─ Silent AAC         │
                    │                                │
  YOLO 640x360 ──> │  AutoZoomManager (Skynet)      │
  15 fps            │  ├─ PersonClassifier           │
                    │  │  ├─ YOLOv8n CoreML          │
                    │  │  └─ VNDetectHumanBodyPose   │
                    │  ├─ DeepTracker (SORT)          │
                    │  └─ GimbalTrackingManager ─────────> Insta360 Flow Pro 2
                    │       └─ DockKit PID control   │    (pan + tilt)
                    │                                │
  WCSession ──────> │  WatchConnectivityService      │ <──── Apple Watch
                    │  └─ transferUserInfo (scores)  │       (tap to score)
                    └──────────────────────────────┘
```

### Streaming Pipeline (Custom RTMP, no HaishinKit)

```
  Camera 4K ──> CIContext scale ──> VTCompressionSession ──> FLV framing ──> NWConnection
  3840x2160     to 1920x1080        H.264 High 6Mbps        RTMP chunks     TCP port 1935
                                                              │
                                                    ┌─────────┴──────────┐
                                                    │  AVC seq header    │
                                                    │  @setDataFrame     │
                                                    │  Silent AAC loop   │
                                                    │  Video keyframes   │
                                                    └────────────────────┘
                                                              │
                                                    YouTube (a.rtmp.youtube.com)
```

### Tracking Pipeline (Skynet v5.1)

```
  Camera frame ──> Downscale 640x360 ──> YOLOv8n ──> PersonClassifier ──> DeepTracker
                                          │              │                     │
                                     Person boxes   Court filter          SORT tracking
                                     0.15 conf      Foreground filter     Visual Re-ID
                                                    Body pose (ankles)    Kalman filter
                                                                              │
                                                                     Action Center (x,y)
                                                                              │
                                                               GimbalTrackingManager
                                                               ├─ Pan PID (Kp=0.8)
                                                               ├─ Tilt PID (Kp=0.4)
                                                               └─ Gravity drift (5s no detect)
```

## Key Files

### iOS App (34 files, ~14,000 lines)

| File | Purpose |
|------|---------|
| `SahilStatsLiteApp.swift` | App entry, screen routing, AppState |
| **Views** | |
| `UltraMinimalRecordingView.swift` | Main recording UI, tap zones, scoreboard |
| `HomeView.swift` | Home screen, game log, career stats, settings |
| `GameSetupView.swift` | Pre-game config, streaming toggle, share link |
| `GameSummaryView.swift` | Post-game summary, video save |
| **Services** | |
| `RecordingManager.swift` | AVFoundation 4K capture, frame callbacks |
| `AutoZoomManager.swift` | Skynet orchestrator, action center calculation |
| `PersonClassifier.swift` | YOLO + Vision classification, court filtering |
| `DeepTracker.swift` | SORT tracking, visual appearance matching |
| `YOLODetector.swift` | YOLOv8n CoreML inference, letterbox, NMS |
| `GimbalTrackingManager.swift` | DockKit PID control (pan + tilt) |
| `SahilRTMPStreamer.swift` | Custom RTMP client (~350 lines, zero dependencies) |
| `StreamingService.swift` | Streaming lifecycle, YouTube broadcast management |
| `OverlayRenderer.swift` | Core Graphics scoreboard renderer |
| `WatchConnectivityService.swift` | iPhone-side WCSession sync |
| `YouTubeService.swift` | OAuth, upload, live broadcast API |
| `GamePersistenceManager.swift` | Local + Firebase game storage |

### Watch App (9 files, ~2,600 lines)

| File | Purpose |
|------|---------|
| `WatchScoringView.swift` | Tap to score, clock, period control |
| `WatchConnectivityClient.swift` | Watch-side WCSession, wall clock sync |
| `WatchCalendarManager.swift` | Independent EventKit for game schedule |

### Tools

| File | Purpose |
|------|---------|
| `analyze.py` | Offline YOLO analysis on recorded footage, Kp tuning |
| `deploy.sh` | One-command build + deploy to iPhone + both Watches |

## Hardware

| Device | Role |
|--------|------|
| iPhone 16 Pro Max | Camera + recording + streaming |
| Insta360 Flow Pro 2 | DockKit gimbal (pan + tilt) |
| Apple Watch Ultra 2 (49mm) | Primary: daily wear + game scoring |
| Apple Watch Series 8 (45mm) | Backup: dedicated scoring remote |

## Setup

### Prerequisites
- Xcode 16+ with iOS 26 SDK
- Google Firebase project (`GoogleService-Info.plist`)
- YouTube API credentials (for upload + live streaming)
- YOLOv8n CoreML model (see `YOLODetector.swift` header for export commands)

### Build & Deploy
```bash
# From personal Mac
ssh narayan@Narayans-MacBook-Pro.local "bash ~/SahilStats/deploy.sh"
# Deploys Release build to iPhone + Watch Series 8 + Watch Ultra 2
```

### YouTube Streaming Setup
1. Create a dedicated YouTube channel (e.g., "Sahil Hoops")
2. Enable live streaming (24h wait for new channels)
3. YouTube Studio: set Latency=Ultra-low, Privacy=Unlisted, Category=Sports
4. Copy stream key into app Settings

## Game Day Workflow

```
1. Open app at gym
2. Tap + (new game) → enter opponent name
3. Toggle "Stream Live" ON → share link with parents
4. Mount phone on gimbal
5. Tap clock → game starts
6. Score from Watch (tap +1/+2/+3, swipe down to subtract)
7. Game ends → recording saves → auto-uploads on WiFi
```

## Screenshots

<!-- TODO: Add screenshots
- Home screen with game log
- Recording view with score overlay
- Watch scoring view
- YouTube Studio live preview
- Game setup with streaming toggle
-->

## License

Personal project. Not intended for App Store distribution.
