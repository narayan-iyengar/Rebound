# Rebound (née SahilStatsLite) — Project Context

> **UPDATED (2026-06-27):** Skynet v5.2 shipped. Next initiative: **Auto-Score**.
> 1. **Current Status:** Build clean, zero warnings. YOLOv8n CoreML active. Auto court calibration live. YouTube upload safety nets in place. Persistent game-controls bar shipped (phone-as-controller mode).
> 2. **Latest Wins:** Auto court quad from IMU-compensated ankle heatmap, YOLO/Vision + court calibration % indicators, YouTube COPPA + processing-abandoned + silent-failure fixes, PhotosPicker FileRepresentation (no more multi-GB RAM buffer on video import).
> 3. **Next Step:** Field test at next game. Begin Auto-Score Phase 1 (BallNet-R).

## Canonical Design Docs

**Auto-Score / ball tracking / shot detection roadmap:**
👉 [`docs/SKYNET_AUTOSCORE_DESIGN.md`](docs/SKYNET_AUTOSCORE_DESIGN.md) — canonical, versioned, carries its own history (§13 rejected alternatives, §14 revision log, §15 LLM-as-a-judge audit history). Any Auto-Score work MUST read this first. Any change MUST append to §14, not overwrite silently. This is the Other Memory.

---

## Team Roles

**Narayan (Product Manager / Executive Decision Maker)**
- Father of Sahil, a 3rd grader on AAU basketball teams
- Owns Insta360 Flow Pro 2 gimbal and DJI Osmo Mobile 7P
- **Decision Maker**: Defines features, UX, and project direction.

**Claude (Lead Software Developer / Architect / Designer)**
- Responsible for 100% of the technical implementation.
- **Full Execution**: Writes complete, functional code. No placeholders.
- Channels Jony Ive for UX (simplicity) and top ML researchers for AI tracking.

---

## Project Vision

A hybrid of **XBotGO** (auto-tracking) + **ScoreCam** (video with score overlay) for personal use.

### Core Features (MVP)
1. **Auto-tracking** via DockKit (Insta360 Flow Pro 2)
2. **Live score overlay** burned into video
3. **Running game clock** with quarter support
4. **Floating Ubiquiti-style controls** for score input
5. **Calendar integration** for game scheduling
6. **Firebase backend** for data persistence

<h3>Future Features (Post-MVP)</h3>
- Post-game stat tagging for Sahil's individual plays
- Highlight reel generation
- Season stats and trends

<h3>Apple Watch Companion (DEBUGGING)</h3>
- Watch app for remote scoring from sidelines
- **Tap** score zones to add +1 point
- **Swipe down** on score to subtract -1 (fix mistakes)
- **Start game** from Watch when phone not accessible
- **Remote Calibration**: Use Watch D-Pad to adjust court corners on Phone AR view.
- Real-time two-way sync (phone ↔ watch)
- End game directly from Watch
- **Current Issue:** Watch fails to receive calendar context or active game state despite connectivity. Suspect OS version mismatch or `WCSession` daemon hang.

---

<h2>GitHub Repository</h2>

**Public repo**: https://github.com/narayan-iyengar/Rebound

---

<h2>Technical Decisions</h2>

<h3>Architecture</h3>
- Target: ~15 files, ~3,000 lines
- SwiftUI + SwiftData (or Firebase only)
- Single device focus (no multi-device sync)
- iOS 17+ minimum (for DockKit iOS 18+)

---

<h2>Hardware</h2>
- **Recording device**: iPhone 16 Pro Max
- **Gimbal**: Insta360 Flow Pro 2 (DockKit compatible)
- **Watch**: Apple Watch Ultra 2 (49mm) / Series 8 (45mm)

---

<h2>UX Design Philosophy (Jony Ive Style)</h2>

**Core Principle:** "You're a parent watching your kid's game, not babysitting an app."

<h3>Four-Phase Workflow</h3>
1. **Setup**: Configure in Settings. Screen stays awake during warmup (`isIdleTimerDisabled`).
2. **Calibration**: Use "Scope" (AR) to mark court corners. Use Watch Remote if phone is high up.
3. **Game Recording**: Tap game clock to start. Video file recording begins. Skynet resets tracking momentum (keeps learned court bounds). Phone is a "dumb camera" from here.
4. **After game**: Review in Game Log. Tap "Upload to YouTube" manually when ready.
   - **Auto-Cleanup**: Once upload is confirmed success, local file is deleted to save space.
   - **Backup**: Original recording remains in Photos app (user manages that).
   - **Watch**: Direct "Watch on YouTube" link appears in Game Log.

<h3>Settings vs Stats Separation</h3>
- **Settings screen**: Skynet AI toggle, Gimbal mode, Team names
- **Stats overlay**: Only shooting stats, other stats, and game controls (period, OT, end)
- **Camera Controls**: Tucked at bottom of Stats dashboard (Emergency Override).

<h3>Key Decisions</h3>
- **Skynet defaults to ON** - AI tracking is the main feature.
- **Manual Upload** - No anxiety about "is it uploading?". Capture first, share later.
- **Visual Re-ID** - Skynet learns jersey colors to ignore parents walking by.
- **Zone Mapping** - Manual calibration creates a "Force Field" around the court.

---

<h2>Current Status</h2>
- Old app: archived to `SahilStats-archive.zip` (100 files, 40k lines - too complex)
- New app: ~40 files, ~5,000 lines - git repo at `/SahilStats/SahilStatsLite/SahilStatsLite/`
- Phase 1: Recording + auto-tracking + score overlay (IN PROGRESS)
- Phase 2: Stats tagging
- Phase 3: Highlights and sharing

<h3>Phase 1 Progress (Updated 2026-02-21)</h3>
- [x] Basic project structure
- [x] Camera preview working
- [x] Floating Ubiquiti-style controls with score buttons (+1, +2, +3)
- [x] Running game clock with play/pause
- [x] Save to Photos functionality
- [x] ScoreTimelineTracker - records score snapshots with timestamps
- [x] OverlayCompositor - burns score overlay into video post-recording
- [x] Integration complete: RecordingView -> ScoreTimelineTracker -> OverlayCompositor -> GameSummaryView
- [x] **4K video recording support** (now default)
- [x] Broadcast-style overlay design (blue home, red/orange away, dark score boxes)
- [x] Landscape rotation handling for video composition
- [x] iOS 26 UIScreen.main deprecation fix
- [x] **Skynet v4.1**: Momentum Attention + Timeout Detection + Golden Smoothing.
- [x] **Skynet v5.0 (Earth Shattering)**: Visual Re-ID (Color Histogram) + AR Court Calibration (Zone Mapping).
- [x] **Watch Remote Calibration**: Adjust phone view from wrist.
- [x] **Manual YouTube Upload**: Background URLSession for reliable "put in pocket" uploads.
- [x] **Watch Sync Fix**: Handshake ensures Watch picks up active game instantly.
- [x] **Edit Game**: Fix stats/scores post-game via "Jony Ive" interactive tiles.
- [x] **Video Recovery**: Import video from Photos if local file is missing.
- [x] **Auto-Cleanup**: Delete local file after successful YouTube upload.
- [x] **Firebase Sync**: YouTube status syncs correctly across devices.
- [x] **Fixed**: Critical bug where `saveGame` was called before `videoURL` was assigned.
- [x] **Cleanup**: Deleting a game removes the local video file.
- [x] **UI**: Overlay scaled 1.5x for 4K.
- [x] **Robust Sync**: Fixed `mergeFirebaseGames` to preserve local-only fields (`videoURL`, `scoreEvents`) during cloud sync.
- [x] **Watch Resiliency**: Upgraded `WatchConnectivityService` to use `updateApplicationContext` (sticky state) for reliable score/clock sync.
- [x] **Ghost Cleanup**: Added "Cleanup Ghost Games" maintenance tool in Settings to remove orphaned test records (no video, no score).
- [x] **Discard Workflow**: Added "Cancel & Discard" option to End Game dialog to stop recording without saving a record.
- [x] **Watch Always On**: Implemented `WKExtendedRuntimeSession` to keep Watch app active and screen on during games.
- [x] **Build System**: Cleaned ModuleCache and resolved package dependencies.
- [x] **Court Priority Audio**: Configured `AVAudioSession` category to `.playAndRecord` with `.videoRecording` mode to ensure iOS prioritizes the high-quality Back Microphone.
- [x] **Skynet Foreground Filter**: Rejects bounding boxes >50% screen height.
- [x] **Tracking Smoothness Upgrades**: Pan-only gimbal (tall narrow ROI strip), 2.5% X deadband, 1.3x zoom cap, 3% action center deadband.
- [x] **Skynet God Mode (Ball Tracking Fusion)**: BallDetector wired into AutoZoomManager. 60/40 ball/player blend with 0.2s Gretzky lead.
- [x] **Vision Off Main Thread**: AutoZoomManager dispatches Vision+Kalman to `skynetQueue`. Only `@Published` writes happen on `@MainActor`. Eliminates UI freezes.
- [x] **CIContext Pooled**: PersonClassifier reuses a single CIContext (was allocating one per frame at 15fps).
- [x] **Age Classifier Removed**: Replaced with court geometry + body pose standing detection.
- [x] **Body Pose Detection**: `VNDetectHumanBodyPoseRequest` runs alongside main detector. Ankle positions for court contact, knee/ankle ratio for sitting detection.
- [x] **Team Jersey Color Learning**: Accumulates histograms during warmup, clusters to 2 team profiles at game start. Weights action center by jersey color match.
- [x] **ObservationMomentum Dt Fixed**: DeepTracker uses actual frame dt instead of hardcoded 1/30 for velocity calculation.
- [x] **YOLOv8n CoreML**: Replaced `VNDetectHumanRectanglesRequest` with sports-optimized YOLO detection. Letterbox 640x360→640x640, decode [1,84,8400], NMS, reverse letterbox. Falls back to Vision if model absent.
- [x] **processInterval Fixed**: Was 0.25 (4fps). Now 0.067 (15fps) — Vision actually runs at the intended rate.
- [x] **Direct GitHub Push**: Confirmed HTTPS push works from PAN work Mac. SCP workflow no longer needed.
- [x] **Autonomous Watch Calendar**: Watch app now uses its own local `EventKit` to find upcoming games (`WatchCalendarManager`), making it fully independent of the iPhone connection for pre-game setup.
- [x] **Watch Calendar Sync**: Phone still pushes calendar updates on request as a fallback.
- [x] **Hide Watch Games**: Replaced deprecated context menu with a reliable long-press alert to locally hide/ignore specific calendar games.
- [x] **Editable Team Names**: Added the ability to edit both Home and Away team names directly on the Watch before starting a game (Jony Ive style).
- [x] **Independent Watch Clock**: Watch now runs its own local timer. It stays perfectly in sync with the iPhone, but won't freeze if the iPhone app is killed/suspended, making it a reliable standalone scoring device.
- [x] **Better Swipe-to-Subtract**: Made the swipe-down gesture on the Watch score boxes much more sensitive (reduced minimum drag distance) so correcting scores is effortless.

---

<h2>Technical Details</h2>

<h3>Video Recording (RecordingManager.swift)</h3>
- Uses AVCaptureSession with AVCaptureVideoDataOutput + AVAssetWriter
- **New Default: 4K (3840x2160)** for maximum quality
- Real-time burned-in scoreboard overlay
- Async `stopRecordingAndWait()` ensures file is fully written before processing
- Checks `isWriterConfigured` to prevent saving "phantom" videos (0 frames).

<h3>Video Orientation Handling (ScoreCam Pattern)</h3>
**RecordingManager.swift** uses `UIWindowScene.interfaceOrientation` to set `videoRotationAngle` on the connection BEFORE recording.

<h3>Score Overlay Approach</h3>
**Real-time rendering**:
1. `OverlayRenderer.swift` uses Core Graphics to draw the scoreboard.
2. `RecordingManager` renders this overlay onto every pixel buffer before it reaches the `AVAssetWriter`.
3. Ensures what you see on screen is exactly what is saved to the file (WYSIWYG).

---

<h2>Project Structure (SahilStatsLite)</h2>

**Git repo root**: `/Users/narayan/SahilStats/SahilStatsLite/SahilStatsLite/`

All files have documentation headers (PURPOSE, KEY TYPES, DEPENDS ON) for quick context.

```
SahilStatsLite/SahilStatsLite/              ← Git repo root
├── claude.md                                # Project context for Claude
├── Gemini.md                                # Project context for Gemini
├── SahilStatsLite/                          ← iOS app source
│   ├── SahilStatsLiteApp.swift              # App entry point, AppState, AppDelegate, screen routing
│   ├── Components/
│   │   └── MissingComponents.swift          # Stub components for compilation
│   ├── Models/
│   │   ├── Game.swift                       # Game, PlayerStats, ScoreEvent, GameResult models
│   │   └── FirebaseGame.swift               # Codable Firebase data model for cloud sync
│   ├── Views/
│   │   ├── HomeView.swift                   # Home screen: hero card, game log, career stats, settings
│   │   ├── GameSetupView.swift              # Pre-game setup: opponent, team, half length, video toggle
│   │   ├── UltraMinimalRecordingView.swift  # Main recording UI: full-screen tap zones, scoreboard, warmup
│   │   ├── GameSummaryView.swift            # Post-game summary: scores, shooting %, video save
│   │   ├── ManualGameEntryView.swift        # Manual stats-only entry (no video)
│   │   ├── AuthView.swift                   # Firebase sign-in + sync controls
│   │   ├── AILabView.swift                  # AI lab: test Skynet pipeline on recorded videos
│   │   ├── SkynetTestView.swift             # Standalone Skynet test UI (pick video, run pipeline)
│   │   ├── CourtCalibrationView.swift       # AR interface for manual court mapping
│   │   └── EditGameView.swift               # Interactive stat editor
│   ├── Services/
│   │   ├── RecordingManager.swift           # AVFoundation 4K capture, frame callbacks for AI
│   │   ├── AutoZoomManager.swift            # Skynet orchestrator (zoom, pan, timeout detection)
│   │   ├── PersonClassifier.swift           # Classification + Re-ID + Court Geometry
│   │   ├── DeepTracker.swift                # SORT-style tracking with Visual Appearance Matching
│   │   ├── GimbalTrackingManager.swift      # DockKit gimbal pan/tilt/zoom integration
│   │   ├── GameCalendarManager.swift        # Calendar event parsing, team/opponent detection
│   │   ├── GamePersistenceManager.swift     # Local game storage (UserDefaults JSON)
│   │   ├── OverlayRenderer.swift            # Core Graphics scoreboard renderer (broadcast-style)
│   │   ├── WatchConnectivityService.swift   # iPhone-side WCSession (Watch ↔ Phone sync)
│   │   ├── YouTubeService.swift             # YouTube OAuth + Background Upload
│   │   ├── AuthService.swift                # Firebase/Google Sign-In auth wrapper
│   │   ├── FirebaseService.swift            # Firestore CRUD for games
│   │   ├── BallDetector.swift               # Orange basketball detection via color thresholding
│   │   ├── CourtDetector.swift              # Court line detection (R&D, limited success)
│   │   ├── ActionProbabilityField.swift     # Predictive action field for camera focus
│   │   ├── GameStateDetector.swift          # Play/dead-ball/timeout state detection
│   │   ├── ExperimentalFilters.swift        # R&D tracking filters (sandbox)
│   │   ├── TestVideoProcessor.swift         # Offline video processing for SkynetTestView
│   │   ├── VideoAnalysisPipeline.swift      # Full video analysis: detection → tracking → output
│   │   └── HomographyUtils.swift            # Math for court geometry mapping
│   └── Resources/
│       └── Info.plist                       # Privacy descriptions (camera, mic, photos, calendar)
├── SahilStatsLite.xcodeproj/                # Xcode project
├── SahilStatsLiteWatch Watch App/           ← Apple Watch companion
│   ├── SahilStatsLiteWatchApp.swift         # Watch app entry point
│   ├── WatchContentView.swift               # Root nav: waiting screen or scoring TabView
│   ├── WatchScoringView.swift               # Tap-to-score, clock, period, end game
│   ├── WatchShootingStatsView.swift         # Shooting stats (MAKE/MISS)
│   ├── WatchOtherStatsView.swift            # Detail stats (AST, REB, STL...)
│   ├── WatchGameConfirmationView.swift      # Pre-game confirmation from Watch
│   ├── WatchCalibrationView.swift           # Remote control for calibration
│   ├── WatchLayout.swift                    # Adaptive layout (compact/regular/ultra)
│   ├── WatchConnectivityClient.swift        # Watch-side WCSession handler
│   └── Assets.xcassets/                     # Watch app icons
└── SkynetTest/                              ← AI R&D tools (standalone)
    ├── SkynetVideoTest.swift                # CLI: broadcast-quality Skynet test on video files
    └── ailab.swift                           # CLI: person detection, heat map, zoom-in-post
```

---

<h2>Apple Watch App</h2>

<h3>Overview</h3>
The Watch app allows Narayan to control scoring remotely while the iPhone records on the gimbal.

<h3>Multi-Watch Setup</h3>
- Both watches paired to iPhone, **auto-switch OFF**.
- Before game: manually switch to scoring watch in Watch app on iPhone.
- Only one watch active at a time (Apple limitation).

<h3>Hardware</h3>
| Watch | Case | Role |
|-------|------|------|
| Ultra 2 (49mm) | PodX Adventure Classic | Primary — daily wear + games |
| Series 8 (45mm) | TinyPod Standard | Backup — dedicated remote |

<h3>Adaptive Layout (WatchLayout.swift)</h3>
The Watch UI auto-detects screen size via `WKInterfaceDevice.current().screenBounds`:
- **Ultra (49mm)**: Full layout - separate live/period lines, swipe hint.
- **Regular (45mm)**: Compact layout - combined live+period header.
- **Compact (40mm)**: Max score zones, smaller fonts.

<h3>Watch Scoring Interactions</h3>
- **Tap score** → Add +1 point.
- **Swipe DOWN on score** → Subtract -1 (fix mistake).
- **Tap period** → Advance (1st Half → 2nd Half → OT).
- **Tap clock** → Pause/Play.
- **Long press clock** → End Game (wait for spinner confirmation).
- **Digital Crown** → Scroll between Scoring / Shooting Stats / Detail Stats.

---

<h2>YouTube Upload (Lean Implementation)</h2>
- **Immediate Upload**: No WiFi queue needed (user has unlimited 5G).
- **Manual Trigger**: Upload button in Game Log. No auto-upload anxiety.
- **Background Session**: Upload continues if app is backgrounded/locked.
- **Keychain Auth**: Tokens stored locally on device.

---

<h2>AI Lab (R&D Complete)</h2>

**Skynet v5.0 (Earth Shattering)**:
- **Visual Re-ID**: `DeepTracker` extracts color histograms from player bounding boxes. If a track is lost (occlusion), it only re-matches if the visual appearance score is high (>0.85). This ignores parents/refs who don't match the team jersey color.
- **Zone Mapping (Calibration)**: `CourtCalibrationView` allows the user to drag 4 corners to define the court floor. `PersonClassifier` checks every detection against this geometry. Anything outside the green box is ignored.
- **Remote Calibration**: Use the Apple Watch to move the court corners on the iPhone screen (for tall tripods).

**Warmup → Game Transition:**
```
Landscape entry → Camera session + Skynet learning (hasCameraStarted = true)
  → Screen forced AWAKE (isIdleTimerDisabled = true)
  → PersonClassifier learns: court bounds, baseline kid height, ref stripe patterns
  → DeepTracker builds: initial track IDs, confidence baselines

Clock tap → Video recording starts (hasGameStarted = true)
  → AutoZoomManager.resetTrackingState() called
  → Resets: DeepTracker tracks, zoom, action center, momentum
  → KEEPS: court bounds (manual or learned), kid height baseline
```
