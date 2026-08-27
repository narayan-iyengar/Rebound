//
//  UltraMinimalRecordingView.swift
//  SahilStatsLite
//
//  PURPOSE: Main recording interface. Full-screen tap zones for scoring (left=home,
//           right=away), pinch-to-zoom, swipe to subtract. Camera preview starts
//           on landscape entry (warmup calibration); video recording starts on
//           first clock tap. Contains scoreboard, stats overlay, Watch callbacks,
//           end game flow with Photos save and YouTube upload.
//  KEY TYPES: UltraMinimalRecordingView, BlinkingColon, CameraPreviewView
//  DEPENDS ON: RecordingManager, AutoZoomManager, GimbalTrackingManager,
//              WatchConnectivityService, YouTubeService, GamePersistenceManager
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import AVFoundation
import Combine
import Photos

struct UltraMinimalRecordingView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var recordingManager = RecordingManager.shared
    @ObservedObject private var gimbalManager = GimbalTrackingManager.shared
    @ObservedObject private var autoZoomManager = AutoZoomManager.shared
    @ObservedObject private var persistenceManager = GamePersistenceManager.shared
    @ObservedObject private var watchService = WatchConnectivityService.shared
    @ObservedObject private var youtubeService = YouTubeService.shared
    @ObservedObject private var streamingService = StreamingService.shared

    // Game state
    @State private var myScore: Int = 0
    @State private var opponentScore: Int = 0
    // Team fouls + timeouts as tally marks (ephemeral per game — bonus/timeout rules
    // vary by tournament, so these just count up; the scorekeeper reads them).
    @State private var homeFouls: Int = 0
    @State private var awayFouls: Int = 0
    @State private var homeTimeouts: Int = 0
    @State private var awayTimeouts: Int = 0
    @State private var remainingSeconds: Int = 0
    @State private var remainingTenths: Int = 0  // 0-9, for sub-minute display
    @State private var period: String = "1st Half"
    @State private var isClockRunning: Bool = false

    // Wall clock sync: recorded when clock starts/resumes so Watch can compute
    // remaining time from Date() without drift. Reset to 0 when paused.
    @State private var clockStartedAt: TimeInterval = 0
    @State private var secondsAtClockStart: Int = 0

    // Player stats (Sahil)
    @State private var playerStats = PlayerStats()

    // Shooting stats for UI (mirrors playerStats)
    @State private var fg2Made: Int = 0
    @State private var fg2Att: Int = 0
    @State private var fg3Made: Int = 0
    @State private var fg3Att: Int = 0
    @State private var ftMade: Int = 0
    @State private var ftAtt: Int = 0

    // Timer
    @State private var timer: AnyCancellable?

    // Tap-to-score
    @State private var myTapCount: Int = 0
    @State private var oppTapCount: Int = 0
    @State private var myTapTimer: AnyCancellable?
    @State private var oppTapTimer: AnyCancellable?

    // Subtract feedback
    @State private var showMySubtract: Bool = false
    @State private var showOppSubtract: Bool = false

    // UI state
    @State private var showSahilStats: Bool = false      // stat pad expanded vs minimized pill
    @State private var statUndo: [StatEvent] = []        // undo stack for live stat taps

    private enum StatEvent: Equatable {
        case make2, miss2, make3, miss3, makeFT, missFT, reb, ast, stl, blk, turnover, foul
    }
    @State private var showEndConfirmation: Bool = false
    // Collapsing clock chip (top-center). Collapsed = one-tap pause/resume;
    // expand chevron reveals Period / +1:00 / End. Auto-collapses when idle.
    @State private var controlsExpanded: Bool = false
    @State private var autoCollapseWork: DispatchWorkItem?
    // True once the clock has been started at least once (any mode) — drives the chip's
    // "Start" vs "Pause"/"Resume" label. hasGameStarted only covers recording mode.
    @State private var clockEverStarted: Bool = false
    @State private var isFinishingRecording: Bool = false
    @State private var isPortrait: Bool = true
    @State private var hasCameraStarted: Bool = false
    @State private var hasGameStarted: Bool = false
    @State private var isPulsing: Bool = false
    @State private var showLinkCopied: Bool = false
    @State private var currentZoom: CGFloat = 1.0
    // Debug-only tracking overlay (gimbal/detection/court %). Off by default — normal
    // games stay clean; toggle in Settings.
    @AppStorage("showTrackingOverlay") private var showTrackingOverlay = false

    // Computed
    private var halfLength: Int {
        appState.currentGame?.halfLength ?? 18
    }

    private var clockTime: String {
        if remainingSeconds < 60 {
            // Under 1 minute: show "SS.t" format
            return String(format: "%d.%d", remainingSeconds, remainingTenths)
        } else {
            let mins = remainingSeconds / 60
            let secs = remainingSeconds % 60
            return String(format: "%d:%02d", mins, secs)
        }
    }

    private var isUnderOneMinute: Bool {
        remainingSeconds < 60
    }

    private var clockColor: Color {
        isUnderOneMinute ? .red : (isClockRunning ? .white : .orange)
    }

    private var clockMinutes: String {
        if isUnderOneMinute {
            // Show seconds as the "big" number when under 1 minute
            return String(remainingSeconds)
        }
        return String(remainingSeconds / 60)
    }

    private var clockSeconds: String {
        if isUnderOneMinute {
            // Show tenths after decimal point
            return String(remainingTenths)
        }
        return String(format: "%02d", remainingSeconds % 60)
    }

    private var clockSeparator: String {
        isUnderOneMinute ? "." : ":"
    }

    private var sahilPoints: Int {
        (fg2Made * 2) + (fg3Made * 3) + ftMade
    }

    private var timerInterval: TimeInterval {
        // Under 1 minute: update every 0.1 seconds for dramatic countdown
        isUnderOneMinute ? 0.1 : 1.0
    }

    // Shooting percentages
    private var fgPct: Double {
        let att = fg2Att + fg3Att
        let made = fg2Made + fg3Made
        return att > 0 ? Double(made) / Double(att) * 100 : 0
    }

    private var fg3Pct: Double {
        fg3Att > 0 ? Double(fg3Made) / Double(fg3Att) * 100 : 0
    }

    private var ftPct: Double {
        ftAtt > 0 ? Double(ftMade) / Double(ftAtt) * 100 : 0
    }

    private var efgPct: Double {
        let att = fg2Att + fg3Att
        let made = fg2Made + fg3Made
        return att > 0 ? (Double(made) + 0.5 * Double(fg3Made)) / Double(att) * 100 : 0
    }

    private var tsPct: Double {
        let fga = fg2Att + fg3Att
        let denominator = 2 * (Double(fga) + 0.44 * Double(ftAtt))
        return denominator > 0 ? Double(sahilPoints) / denominator * 100 : 0
    }

    var body: some View {
        ZStack {
            // Full screen camera
            cameraPreview

            // Top bar: Clip (left) · [clock chip is a separate centered overlay] · Sahil-stats (right)
            VStack {
                HStack {
                    ClipButton(idleHint: appState.isStatsOnly ? "Camera warming up…" : "Start game to clip")
                        .padding(.leading, 16)

                    // Streaming indicator (only while live to YouTube)
                    if recordingManager.isStreamingActive || streamingService.health.isActive {
                        HStack(spacing: 3) {
                            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 9))
                            Text("YT").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(streamingService.health.isActive ? Chalk.coral : Chalk.yellow)
                    }

                    trackingStatus  // debug-only

                    Spacer()

                    // Sahil stats (top-right)
                    Button(action: { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showSahilStats.toggle() } }) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.fill").font(.system(size: 14, weight: .bold))
                            Text("\(sahilPoints)").font(.system(size: 15, weight: .heavy)).monospacedDigit()
                        }
                        .foregroundColor(showSahilStats ? Chalk.board : Chalk.chalk)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(showSahilStats ? Chalk.yellow : Color(white: 0.08, opacity: 0.55)))
                        .overlay(Capsule().stroke(Chalk.chalk.opacity(0.3), lineWidth: 1.5))
                    }
                    .padding(.trailing, 16)
                }
                .padding(.top, 12)
                Spacer()
            }

            // Full-screen tap zones for scoring (Jony Ive style - simple, forgiving)
            // Left half = your team, Right half = opponent
            // Tap to add points, Swipe OUTWARD to subtract (away from center), Pinch to zoom
            if !isPortrait || recordingManager.isSimulator || appState.isStatsOnly {
                HStack(spacing: 0) {
                    // LEFT HALF - My team (swipe LEFT to subtract)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { handleMyTeamTap() }
                        .gesture(
                            DragGesture(minimumDistance: 40)
                                .onEnded { value in
                                    // Swipe LEFT (away from center) to subtract
                                    // Must be predominantly horizontal (width > height)
                                    if value.translation.width < -60 &&
                                       abs(value.translation.width) > abs(value.translation.height) {
                                        subtractScore(isMyTeam: true)
                                    }
                                }
                        )

                    // RIGHT HALF - Opponent (swipe RIGHT to subtract)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { handleOpponentTap() }
                        .gesture(
                            DragGesture(minimumDistance: 40)
                                .onEnded { value in
                                    // Swipe RIGHT (away from center) to subtract
                                    // Must be predominantly horizontal (width > height)
                                    if value.translation.width > 60 &&
                                       abs(value.translation.width) > abs(value.translation.height) {
                                        subtractScore(isMyTeam: false)
                                    }
                                }
                        )
                }
                .padding(.top, 60)      // Leave room for top bar
                .padding(.bottom, 100)  // Leave room for scoreboard
                // Pinch to zoom (works across both halves, 0.5x to 3.0x)
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            let baseZoom = autoZoomManager.mode == .auto ? autoZoomManager.currentZoom : currentZoom
                            let newZoom = baseZoom * scale
                            let clampedZoom = min(max(newZoom, 0.5), 3.0)
                            _ = recordingManager.setZoom(factor: clampedZoom)
                            autoZoomManager.manualZoomOverride(clampedZoom)
                        }
                        .onEnded { _ in
                            currentZoom = recordingManager.getCurrentZoom()
                        }
                )
            }

            // Scoreboard: full-screen big layout in stats-only mode (no video); the small
            // corner board when recording. Both keep the fouls/timeout tally.
            if !isPortrait || recordingManager.isSimulator || appState.isStatsOnly {
                if appState.isStatsOnly && !isStatsOnlyClipping {
                    fullScreenStatsLayout
                        // Shrink toward the bottom-right corner as the clip starts, so the
                        // big stats board visibly collapses into the small recording-view board.
                        .transition(.scale(scale: 0.32, anchor: .bottomTrailing).combined(with: .opacity))
                } else {
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom, spacing: 8) {
                            // Subtle zoom indicator (bottom-left).
                            if displayZoom > 1.05 || displayZoom < 0.95 {
                                zoomIndicator
                                    .padding(.leading, 12)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 6) {
                                foulsTimeoutStrip
                                scoreboardDisplay
                            }
                            .padding(.trailing, 8)
                            // While a clip is capturing, the corner board "ducks" — a small
                            // shrink toward its corner (recording mode; stats-only shrinks the
                            // big board instead) plus a coral glow shown in BOTH modes, so the
                            // "we're clipping" signal is consistent. Same spring as the shrink.
                            .scaleEffect(isClipCapturing ? 0.86 : 1, anchor: .bottomTrailing)
                            .shadow(color: isCapturingClip ? Chalk.coral.opacity(0.6) : .clear,
                                    radius: isCapturingClip ? 14 : 0)
                            .animation(Self.clipCaptureSpring, value: isClipCapturing)
                            .animation(Self.clipCaptureSpring, value: isCapturingClip)
                        }
                        .padding(.bottom, 16)
                    }
                }
            }


            // Tap feedback overlays (centered in each half) - doesn't block touches
            HStack {
                // Left half feedback (my team)
                ZStack {
                    if myTapCount > 0 {
                        FloatingScore(text: "+\(myTapCount)", color: Chalk.yellow, dots: myTapCount)
                            .id(myTapCount)
                            .transition(.opacity)
                    }
                    if showMySubtract {
                        FloatingScore(text: "−1", color: Chalk.coral, dots: 0)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right half feedback (opponent)
                ZStack {
                    if oppTapCount > 0 {
                        FloatingScore(text: "+\(oppTapCount)", color: Chalk.sky, dots: oppTapCount)
                            .id(oppTapCount)
                            .transition(.opacity)
                    }
                    if showOppSubtract {
                        FloatingScore(text: "−1", color: Chalk.coral, dots: 0)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)

            // Streamlined stat entry — a docked, non-dimming pad. Minimized state is just
            // the top-right person+points pill; tapping it (or the pad's minimize bar) collapses.
            if showSahilStats {
                ZStack(alignment: .bottom) {
                    // Transparent (non-dimming) catcher: absorbs taps OUTSIDE the pad so they
                    // never fall through to the scoring zones; tapping outside collapses the pad.
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showSahilStats = false }
                        }
                    statPad
                        .contentShape(Rectangle())  // absorb taps on the pad itself (never score)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Clock control chip — its OWN top-center overlay, fully independent of the
            // REC/person row so its expansion never shifts other elements.
            // Placed AFTER the full-screen scoring tap-zones so the chip (and its
            // expanded Period/+1:00/End buttons that spring down into the tap-zone
            // region) win hit-testing — otherwise taps fell through and just scored.
            // Gate matches the old control bar: show whenever the scoring UI is active.
            if !isPortrait || recordingManager.isSimulator || appState.isStatsOnly {
                VStack {
                    clockControlChip
                        .padding(.top, 12)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            // End game confirmation
            if showEndConfirmation {
                endGameConfirmation
            }

            // Rotate to landscape prompt (not needed for stats-only mode)
            if isPortrait && !recordingManager.isSimulator && !appState.isStatsOnly {
                rotatePromptOverlay
            }
        }
        .statusBar(hidden: true)
        .persistentSystemOverlays(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientationState()
        }
        .task {
            initializeGameState()
            updateOrientationState()

            // Keep the screen awake for the whole session — recording AND stats-only.
            // (Stats-only used to sleep mid-game because this lived inside the camera
            // branch below; a dark screen also means you can't tap score or Clip.)
            UIApplication.shared.isIdleTimerDisabled = true

            // Only setup camera if recording video
            if !appState.isStatsOnly {
                recordingManager.reset()
                updateOverlayState()
                await recordingManager.requestPermissionsAndSetup()

                // If already in landscape, start camera preview + Skynet learning (NOT recording)
                // Recording starts when game clock starts (warmup = free calibration)
                if !isPortrait && !hasCameraStarted && recordingManager.isSessionReady && !recordingManager.isSimulator {
                    debugPrint("📹 Camera + Skynet started (warmup calibration)")
                    hasCameraStarted = true
                    updateOverlayState()
                    gimbalManager.startTracking()
                    startAutoZoom()
                }
            } else {
                // Stats-only: bring up the camera HIDDEN, purely to buffer Clips. No
                // file recording — the green board stays until a Clip reveals the camera.
                recordingManager.reset()
                updateOverlayState()
                await recordingManager.requestPermissionsAndSetup()
                if recordingManager.isSessionReady && !recordingManager.isSimulator {
                    recordingManager.startClipBuffering()
                }
            }
        }
        .onDisappear {
            // Let the screen sleep normally again once we leave the game view.
            UIApplication.shared.isIdleTimerDisabled = false
            // Stop responding to watch resync requests — the game is over.
            teardownWatchCallbacks()
            if !appState.isStatsOnly {
                stopRecording()
                stopAutoZoom()
                recordingManager.stopSession()
            } else {
                recordingManager.stopClipBuffering()
                recordingManager.stopSession()
            }
        }
        // Sync zoom when Camera Control button is used (iPhone 16+)
        .onChange(of: recordingManager.currentZoomLevel) { _, newZoom in
            currentZoom = newZoom
            // Override auto-zoom if user is manually controlling via Camera Control
            if autoZoomManager.mode == .auto {
                autoZoomManager.manualZoomOverride(newZoom)
            }
        }
        .animation(.spring(response: 0.3), value: showSahilStats)
        .animation(Self.clipCaptureSpring, value: isStatsOnlyClipping)
        // Mirror team fouls/timeouts to the watch whenever they change (either device).
        // The absolute-value push is idempotent, so a watch-origin change echoing back is
        // harmless (the watch already holds the value and won't re-send).
        .onChange(of: homeFouls) { _, _ in pushTeamTally() }
        .onChange(of: awayFouls) { _, _ in pushTeamTally() }
        .onChange(of: homeTimeouts) { _, _ in pushTeamTally() }
        .onChange(of: awayTimeouts) { _, _ in pushTeamTally() }
    }

    // MARK: - Initialize Game State

    private func initializeGameState() {
        remainingSeconds = halfLength * 60
        remainingTenths = 0
        // Stamp the current game id so saved clips group together in the Store.
        recordingManager.currentClipGameId = appState.currentGame?.id
        setupWatchCallbacks()
        sendGameStateToWatch()
        pushTeamTally()   // baseline the watch's tally page (starts at 0)
    }

    // MARK: - Watch Connectivity

    private func setupWatchCallbacks() {
        // Handle score updates from watch (add or subtract)
        watchService.onScoreUpdate = { [self] team, points, isSubtract in
            if isSubtract {
                if team == "my" {
                    myScore = max(0, myScore - points)
                } else {
                    opponentScore = max(0, opponentScore - points)
                }
            } else {
                if team == "my" {
                    myScore += points
                } else {
                    opponentScore += points
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            updateOverlayState()
            sendScoreToWatch()
        }

        // Handle clock toggle from watch
        watchService.onClockToggle = { [self] in
            toggleClock()
        }

        // Handle period advance from watch
        watchService.onPeriodAdvance = { [self] in
            advancePeriod()
        }

        // Handle stat updates from watch
        // NOTE: Stats are tracked separately from game score
        // Use score buttons for game score changes
        watchService.onStatUpdate = { [self] statType, value in
            switch statType {
            case "fg2Made": fg2Made += value
            case "fg2Att": fg2Att += value
            case "fg3Made": fg3Made += value
            case "fg3Att": fg3Att += value
            case "ftMade": ftMade += value
            case "ftAtt": ftAtt += value
            case "assists": playerStats.assists += value
            case "rebounds": playerStats.rebounds += value
            case "steals": playerStats.steals += value
            case "blocks": playerStats.blocks += value
            case "turnovers": playerStats.turnovers += value
            default: break
            }
            // Stats don't affect game score - no sendScoreToWatch() needed
        }

        // Handle end game from watch - end and save directly
        watchService.onEndGame = { [self] in
            endGame()
        }

        // Handle start game from watch (if already recording, just resync)
        watchService.onStartGame = { [self] _ in
            debugPrint("📱 Received start request from Watch while already recording. Resyncing.")
            sendGameStateToWatch()
        }
        
        // Handle state request from watch (e.g. app just launched)
        watchService.onRequestState = { [self] in
            debugPrint("📱 Received state request from Watch. Sending active game state.")
            sendGameStateToWatch()
            pushTeamTally()   // include the current fouls/timeouts tally in the resync
        }

        // Team fouls/timeouts changed on the watch → mirror onto the phone scoreboard.
        watchService.onTeamTallyUpdate = { [self] hf, af, ht, at in
            homeFouls = hf; awayFouls = af; homeTimeouts = ht; awayTimeouts = at
        }
    }

    /// Push the current team fouls/timeouts tally to the watch.
    private func pushTeamTally() {
        watchService.sendTeamTally(homeFouls: homeFouls, awayFouls: awayFouls,
                                   homeTimeouts: homeTimeouts, awayTimeouts: awayTimeouts)
    }

    /// Clear the watch callbacks when leaving the game. Otherwise onRequestState /
    /// onStartGame linger and, on the next watch reactivation, re-push hasActiveGame:true —
    /// yanking the watch back into a game we just ended/discarded.
    private func teardownWatchCallbacks() {
        watchService.onScoreUpdate = nil
        watchService.onClockToggle = nil
        watchService.onPeriodAdvance = nil
        watchService.onStatUpdate = nil
        watchService.onEndGame = nil
        watchService.onStartGame = nil
        watchService.onRequestState = nil
        watchService.onTeamTallyUpdate = nil
    }

    private func sendGameStateToWatch() {
        // Don't re-assert an active game while we're tearing one down — otherwise a
        // stale watch resync request would flip the watch back into the ended game.
        guard !isFinishingRecording else { return }
        let periodNames = ["1st Half", "2nd Half", "OT", "OT2", "OT3"]
        let periodIdx = periodNames.firstIndex(of: period) ?? 0
        watchService.sendGameState(
            teamName: appState.currentGame?.teamName ?? "Home",
            opponent: appState.currentGame?.opponent ?? "Away",
            myScore: myScore, oppScore: opponentScore,
            remainingSeconds: remainingSeconds, isClockRunning: isClockRunning,
            period: period, periodIndex: periodIdx,
            clockStartedAt: clockStartedAt, secondsAtClockStart: secondsAtClockStart,
            // Warmup = video game loaded, clock never started. (Not gated on camera
            // startup, which races the view appearing — "clock hasn't started" is the
            // signal the watch needs.) Tells the watch "Ready · tap clock to start".
            warmup: !hasGameStarted && !appState.isStatsOnly
        )
    }

    private func sendScoreToWatch() {
        // Score updates push a full snapshot so Watch always has consistent state
        sendGameStateToWatch()
    }

    private func sendClockToWatch() {
        watchService.sendClockUpdate(
            remainingSeconds: remainingSeconds, isRunning: isClockRunning,
            clockStartedAt: clockStartedAt, secondsAtClockStart: secondsAtClockStart
        )
    }

    private func sendPeriodToWatch() {
        let periodNames = ["1st Half", "2nd Half", "OT", "OT2", "OT3"]
        let periodIdx = periodNames.firstIndex(of: period) ?? 0
        watchService.sendPeriodUpdate(
            period: period, periodIndex: periodIdx,
            remainingSeconds: remainingSeconds, isRunning: isClockRunning,
            clockStartedAt: clockStartedAt, secondsAtClockStart: secondsAtClockStart
        )
    }

    // MARK: - Camera Preview

    @ViewBuilder
    private var cameraPreview: some View {
        if appState.isStatsOnly {
            // Stats-only mode: green chalk board is the ground and the full-screen
            // scoreboard fills it — UNTIL a Clip is taken, when the (already-buffering)
            // camera is revealed behind the shrunk corner board.
            ZStack {
                LinearGradient(colors: [Chalk.board, Chalk.board2], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                if isStatsOnlyClipping, recordingManager.isSessionReady,
                   let session = recordingManager.captureSession {
                    CameraPreviewView(session: session)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.45), value: isStatsOnlyClipping)
        } else if recordingManager.isSimulator {
            LinearGradient(
                colors: [Color(white: 0.92), Color(white: 0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .overlay(
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    Text("Simulator Mode")
                        .font(.title2)
                        .fontWeight(.bold)
                }
                .foregroundColor(.primary)
            )
        } else if recordingManager.isSessionReady, let session = recordingManager.captureSession {
            CameraPreviewView(session: session)
                .ignoresSafeArea()
        } else {
            Color.black
                .ignoresSafeArea()
                .overlay(
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("Starting camera...")
                            .foregroundColor(.white)
                    }
                )
        }
    }


    // MARK: - REC Indicator

    // Recording video is active (drives the clock-chip coral glow, replacing a REC pill).
    private var isRecordingLive: Bool {
        hasGameStarted && !appState.isStatsOnly
    }

    /// One shared spring for every clip-capture board motion, so the shrink/duck and
    /// the grow-back use the exact same timing in both modes (in == out).
    static let clipCaptureSpring: Animation = .spring(response: 0.5, dampingFraction: 0.78)

    /// A clip is actively capturing (either mode). Base for the two derived flags.
    private var isCapturingClip: Bool {
        switch recordingManager.clipState {
        case .clipping, .saving: return true
        default: return false
        }
    }

    /// Stats-only, capturing → reveal the camera and shrink the big board into the corner.
    private var isStatsOnlyClipping: Bool { appState.isStatsOnly && isCapturingClip }

    /// Recording mode, capturing → the (already-corner) board ducks (small shrink).
    private var isClipCapturing: Bool { !appState.isStatsOnly && isCapturingClip }

    private var recIndicator: some View {
        Group {
            if appState.isStatsOnly {
                // Stats-only mode indicator
                HStack(spacing: 5) {
                    Circle()
                        .fill(isClockRunning ? Chalk.green : Chalk.yellow)
                        .frame(width: 8, height: 8)
                    Text("LIVE")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(isClockRunning ? Chalk.green : Chalk.yellow)
                    // Simple YT LIVE indicator — no tap needed, phone is on gimbal
                    if streamingService.health.isActive {
                        HStack(spacing: 3) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 8))
                                .foregroundColor(Chalk.coral)
                            Text("YT")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Chalk.coral)
                        }
                    }
                }
            } else if isClockRunning {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Chalk.coral)
                        .frame(width: 12, height: 12)
                        .scaleEffect(isPulsing ? 1.3 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                            value: isPulsing
                        )
                        .onAppear { isPulsing = true }

                    // Stream health — always visible so you know what's happening
                    if recordingManager.isStreamingActive {
                        Text(streamingService.health.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(streamingService.health.isActive ? Chalk.coral : Chalk.yellow)
                    }
                }
            } else {
                Image(systemName: "pause.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Chalk.yellow)
            }
        }
    }

    // MARK: - Tracking Status (visible during warmup so you know before mounting)

    private var trackingStatus: some View {
        Group {
            if hasCameraStarted && showTrackingOverlay {
                // Minimal icon-only status (debug-glance). No model name, no text labels.
                HStack(spacing: 11) {
                    // Gimbal connected (green) / not (coral)
                    Image(systemName: gimbalManager.isDockKitAvailable ? "camera.aperture" : "camera.metering.none")
                        .font(.system(size: 13))
                        .foregroundColor(gimbalManager.isDockKitAvailable ? Chalk.green : Chalk.coral)

                    // Players tracked
                    HStack(spacing: 3) {
                        Image(systemName: "figure.basketball")
                            .font(.system(size: 13))
                        Text("\(autoZoomManager.detectedPlayerCount)")
                            .font(.system(size: 12, weight: .bold)).monospacedDigit()
                    }
                    .foregroundColor(autoZoomManager.detectedPlayerCount > 0 ? Chalk.sky : Chalk.dust)

                    // Court calibration — icon fills in as it calibrates; % only while pending
                    HStack(spacing: 3) {
                        Image(systemName: autoZoomManager.courtIsCalibrated ? "square.dashed.inset.filled" : "square.dashed")
                            .font(.system(size: 13))
                        if !autoZoomManager.courtIsCalibrated {
                            Text("\(Int(autoZoomManager.courtCalibrationProgress * 100))%")
                                .font(.system(size: 12, weight: .bold)).monospacedDigit()
                        }
                    }
                    .foregroundColor(autoZoomManager.courtIsCalibrated ? Chalk.green : Chalk.yellow)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color(white: 0.08, opacity: 0.55))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Chalk.chalk.opacity(0.15), lineWidth: 1)
                )
            }
        }
    }

    // Current zoom level (from AI or manual)
    private var displayZoom: CGFloat {
        autoZoomManager.mode == .auto ? autoZoomManager.currentZoom : currentZoom
    }

    // MARK: - Zoom Indicator (minimal, bottom-left)

    private var zoomIndicator: some View {
        HStack(spacing: 4) {
            if autoZoomManager.mode == .auto {
                // AI zoom active indicator
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 6, height: 6)
            }
            Text(String(format: "%.1fx", displayZoom))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(autoZoomManager.mode == .auto ? .cyan : .white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
    }

    private func startAutoZoom() {
        guard autoZoomManager.mode == .auto else { return }

        // Hook up frame callback for Vision processing
        recordingManager.onFrameForAI = { pixelBuffer in
            autoZoomManager.processFrame(pixelBuffer)
        }
        autoZoomManager.start()
        debugPrint("🔍 [AutoZoom] Activated in \(autoZoomManager.mode.rawValue) mode")
    }

    private func stopAutoZoom() {
        autoZoomManager.stop()
        recordingManager.onFrameForAI = nil
    }

    // MARK: - Clock Control Chip (top-center, collapsing)
    // Default state is a single glanceable clock that is ALSO the one-tap pause/resume
    // button — the 95% action. A distinct chevron reveals Period / +1:00 / End inline
    // (no modal, no navigation — stays on the recording canvas). Auto-collapses when idle.
    // Lives top-center because the bottom corners are the thumb-grip zone in landscape,
    // where the old always-visible bar caused accidental taps (including "End").
    private var clockControlChip: some View {
        VStack(spacing: 6) {
            // Collapsed chip: [ ⏸ Pause | ⌄ ] — no clock number here; the clock lives
            // only at the scoreboard (bottom-right), which is what's burned into the
            // video. This chip is purely the control, so there's no double clock.
            HStack(spacing: 0) {
                // Primary: one-tap pause/resume — big, forgiving target
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    toggleClock()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isClockRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(isClockRunning ? Chalk.coral : Chalk.green)
                        Text(clockEverStarted ? (isClockRunning ? "Pause" : "Resume") : "Start")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Chalk.yellow)
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 12)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(Chalk.chalk.opacity(0.15))
                    .frame(width: 1, height: 26)

                // Secondary: deliberate edge target to reveal the rest
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        controlsExpanded.toggle()
                    }
                    if controlsExpanded { scheduleAutoCollapse() } else { cancelAutoCollapse() }
                } label: {
                    Image(systemName: controlsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Chalk.chalkDim)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Color(white: 0.08, opacity: 0.9))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    // Glows coral while recording video — the chip carries the recording
                    // state (no separate REC pill).
                    .stroke(isRecordingLive ? Chalk.coral.opacity(0.65) : Chalk.chalk.opacity(0.22),
                            lineWidth: isRecordingLive ? 1.5 : 1)
            )
            .shadow(color: isRecordingLive ? Chalk.coral.opacity(0.55) : .clear,
                    radius: isRecordingLive ? 12 : 0)

            // Expanded controls — spring down, inline, auto-collapse
            if controlsExpanded {
                HStack(spacing: 6) {
                    // Period advance
                    controlButton(icon: "forward.fill", label: nextPeriodLabel, color: Chalk.sky) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        advancePeriod()
                        scheduleAutoCollapse()
                    }

                    // Time: tap +1:00, long-press -1:00, Add OT when clock=0
                    controlButton(
                        icon: remainingSeconds > 0 ? "clock.arrow.circlepath" : "plus.circle.fill",
                        label: remainingSeconds > 0 ? "+1:00" : "Add OT",
                        color: Chalk.yellow
                    ) {
                        if remainingSeconds > 0 {
                            remainingSeconds += 60
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            updateOverlayState()
                            sendClockToWatch()
                        } else {
                            addOvertime()
                        }
                        scheduleAutoCollapse()
                    }
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                        if remainingSeconds >= 60 {
                            remainingSeconds -= 60
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            updateOverlayState()
                            sendClockToWatch()
                        }
                        scheduleAutoCollapse()
                    })

                    // End game — never one-tap; requires expand + confirmation
                    controlButton(icon: "stop.fill", label: "End", color: Chalk.coral) {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        cancelAutoCollapse()
                        if hasGameStarted || appState.isStatsOnly {
                            showEndConfirmation = true
                        } else {
                            discardGame()
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // Auto-collapse the expanded controls after a few idle seconds. Any control
    // interaction calls this to restart the timer so the row stays open while in use.
    private func scheduleAutoCollapse() {
        autoCollapseWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                controlsExpanded = false
            }
        }
        autoCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func cancelAutoCollapse() {
        autoCollapseWork?.cancel()
        autoCollapseWork = nil
    }

    private func controlButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(color)
            .frame(width: 62, height: 50)
            // Solid dark chip + colored border so it stays legible over any video
            // (the old translucent color fill washed out against bright footage).
            .background(Color(white: 0.10, opacity: 0.92), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.75), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Interactive Scoreboard (Jony Ive Style - scoreboard IS the control)
    // Tap team row = add points (multi-tap: 1, 2, or 3)
    // Long press team row = subtract 1 point
    // Tap clock = pause/play
    // Tap period = advance period

    // MARK: - Scoreboard Display (clean, minimal - only clock is tappable)

    // MARK: - Full-screen stats scoreboard (stats-only mode, no video)
    // Big team names (chalk) + CRISP scores fill the screen. The scores are DISPLAY ONLY
    // (allowsHitTesting=false) so the left/right scoring tap-zones underneath still work.
    // The fouls/timeout tallies + clock live in the BOTTOM band, outside the scoring
    // zones (which are padded away from the bottom), so tapping a tally never scores.
    private var fullScreenStatsLayout: some View {
        ZStack {
            // Two columns: team name + big score (display, taps pass through to scoring)
            // + a framed tally box (interactive — consumes taps so it never scores).
            HStack(spacing: 0) {
                statColumn(name: appState.currentGame?.teamName ?? "HOME",
                           score: myScore, accent: Chalk.yellow,
                           fouls: $homeFouls, timeouts: $homeTimeouts)
                Rectangle().fill(Chalk.chalk.opacity(0.15))
                    .frame(width: 1.5)
                    .padding(.vertical, 80)
                    .allowsHitTesting(false)
                statColumn(name: appState.currentGame?.opponent ?? "AWAY",
                           score: opponentScore, accent: Chalk.sky,
                           fouls: $awayFouls, timeouts: $awayTimeouts)
            }
            .padding(.top, 50)
            .padding(.bottom, 54)

            // Clock + period, bottom center (display only).
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Text(period)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Chalk.chalkDim)
                    Text("·").foregroundColor(Chalk.dust)
                    Text(clockTime)
                        .font(.system(size: 18, weight: .bold)).monospacedDigit()
                        .foregroundColor(isClockRunning ? Chalk.crisp : Chalk.yellow)
                }
                .padding(.bottom, 14)
            }
            .allowsHitTesting(false)
        }
    }

    private func statColumn(name: String, score: Int, accent: Color,
                            fouls: Binding<Int>, timeouts: Binding<Int>) -> some View {
        VStack(spacing: 8) {
            Text(name.prefix(8).uppercased())
                .font(.chalkHand(30))
                .foregroundColor(accent)
                .lineLimit(1).minimumScaleFactor(0.7)
                .allowsHitTesting(false)
            Text("\(score)")
                .font(.system(size: 82, weight: .heavy)).monospacedDigit()
                .foregroundColor(Chalk.crisp)
                .minimumScaleFactor(0.5)
                .allowsHitTesting(false)
            tallyBox(fouls: fouls, timeouts: timeouts, accent: accent)
        }
        .frame(maxWidth: .infinity)
    }

    // Framed fouls|timeouts box (like the mock). Interactive: tap a tally to +1,
    // long-press to −1. Consumes its own taps so it never triggers a score.
    private func tallyBox(fouls: Binding<Int>, timeouts: Binding<Int>, accent: Color) -> some View {
        HStack(spacing: 0) {
            ftItemBig(label: "FOULS", count: fouls, color: Chalk.coral)
            Rectangle().fill(Chalk.chalk.opacity(0.2)).frame(width: 1, height: 34)
            ftItemBig(label: "T.O.", count: timeouts, color: accent)
        }
        .background(Color(white: 0.08, opacity: 0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Chalk.chalk.opacity(0.2), lineWidth: 1))
    }

    private func ftItemBig(label: String, count: Binding<Int>, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Chalk.dust)
            TallyMarks(count: count.wrappedValue, color: color, barHeight: 22)
                .frame(minWidth: 44, minHeight: 24, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            count.wrappedValue += 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .onLongPressGesture {
            if count.wrappedValue > 0 {
                count.wrappedValue -= 1
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    // Fouls + timeouts tally strip (sits above the corner scoreboard; also reused in the
    // full-screen stats layout). Tap a tally to add one, long-press to remove one.
    private var foulsTimeoutStrip: some View {
        HStack(spacing: 10) {
            teamFT(fouls: $homeFouls, timeouts: $homeTimeouts, accent: Chalk.yellow)
            Rectangle().fill(Chalk.chalk.opacity(0.15)).frame(width: 1, height: 24)
            teamFT(fouls: $awayFouls, timeouts: $awayTimeouts, accent: Chalk.sky)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.08, opacity: 0.7))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
    }

    private func teamFT(fouls: Binding<Int>, timeouts: Binding<Int>, accent: Color) -> some View {
        HStack(spacing: 9) {
            ftItem(label: "FOULS", count: fouls, color: Chalk.coral)
            ftItem(label: "T.O.", count: timeouts, color: accent)
        }
    }

    private func ftItem(label: String, count: Binding<Int>, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Chalk.dust)
            TallyMarks(count: count.wrappedValue, color: color, barHeight: 19)
                .frame(minWidth: 34, minHeight: 22, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            count.wrappedValue += 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .onLongPressGesture {
            if count.wrappedValue > 0 {
                count.wrappedValue -= 1
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private var scoreboardDisplay: some View {
        VStack(spacing: 0) {
            // HOME ROW
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Chalk.yellow)
                    .frame(width: 6)

                Text((appState.currentGame?.teamName ?? "HOME").prefix(4).uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Chalk.chalk)
                    .frame(width: 54, alignment: .leading)
                    .padding(.leading, 8)

                Text("\(myScore)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 40, alignment: .trailing)

                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 28)
                    .padding(.horizontal, 8)

                Text(period)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Chalk.chalkDim)
                    .frame(width: 64, alignment: .center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.trailing, 6)
            }
            .frame(height: 36)

            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(height: 1)
                .padding(.leading, 6)

            // AWAY ROW
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Chalk.sky)
                    .frame(width: 6)

                Text((appState.currentGame?.opponent ?? "AWAY").prefix(4).uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Chalk.chalk)
                    .frame(width: 54, alignment: .leading)
                    .padding(.leading, 8)

                Text("\(opponentScore)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 40, alignment: .trailing)

                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 28)
                    .padding(.horizontal, 8)

                // Clock (tap to pause/play)
                HStack(spacing: 0) {
                    Text(clockMinutes)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(clockColor)
                    if isUnderOneMinute {
                        Text(".")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(clockColor)
                    } else {
                        BlinkingColon(
                            isRunning: isClockRunning,
                            font: .system(size: 18, weight: .bold, design: .monospaced),
                            runningColor: isUnderOneMinute ? .red : .white,
                            pausedColor: isUnderOneMinute ? .red : .orange
                        )
                    }
                    Text(clockSeconds)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(clockColor)
                }
                .frame(width: 64, alignment: .center)
                .padding(.trailing, 6)
            }
            .frame(height: 36)
        }
        .fixedSize()
        .background(Color(white: 0.08, opacity: 0.88))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Chalk.chalk.opacity(0.25), lineWidth: 1)  // solid over video (calmer than dashed)
        )
    }


    // MARK: - Tap Feedback


    // MARK: - Tap Handling

    private func handleMyTeamTap() {
        let newCount = min(myTapCount + 1, 3)
        myTapCount = newCount

        myTapTimer?.cancel()
        myTapTimer = Timer.publish(every: 0.6, on: .main, in: .common)
            .autoconnect()
            .first()
            .sink { _ in
                addScore(points: myTapCount, isMyTeam: true)
                myTapCount = 0
            }
    }

    private func handleOpponentTap() {
        let newCount = min(oppTapCount + 1, 3)
        oppTapCount = newCount

        oppTapTimer?.cancel()
        oppTapTimer = Timer.publish(every: 0.6, on: .main, in: .common)
            .autoconnect()
            .first()
            .sink { _ in
                addScore(points: oppTapCount, isMyTeam: false)
                oppTapCount = 0
            }
    }

    // MARK: - Score Actions

    private func addScore(points: Int, isMyTeam: Bool) {
        if isMyTeam {
            myScore += points
        } else {
            opponentScore += points
        }

        // Log score event
        let event = ScoreEvent(
            timestamp: recordingManager.recordingDuration,
            team: isMyTeam ? .my : .opponent,
            points: points,
            quarter: period == "1st" ? 1 : 2,
            myScoreAfter: myScore,
            opponentScoreAfter: opponentScore
        )
        appState.currentGame?.scoreEvents.append(event)

        updateOverlayState()
        sendScoreToWatch()

        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
    }

    private func subtractScore(isMyTeam: Bool) {
        if isMyTeam {
            myScore = max(0, myScore - 1)
            // Show feedback
            showMySubtract = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                showMySubtract = false
            }
        } else {
            opponentScore = max(0, opponentScore - 1)
            // Show feedback
            showOppSubtract = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                showOppSubtract = false
            }
        }

        updateOverlayState()
        sendScoreToWatch()

        // Different haptic for subtract
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }

    // MARK: - Clock

    private func toggleClock() {
        debugPrint("🕐 [toggleClock] called - isClockRunning: \(isClockRunning)")

        isClockRunning.toggle()

        if isClockRunning { clockEverStarted = true }

        // First clock start = game start → begin recording
        if isClockRunning && !hasGameStarted && !appState.isStatsOnly {
            hasGameStarted = true
            debugPrint("🏀 Game started! Beginning video recording + resetting Skynet tracking")
            recordingManager.startRecording()
            autoZoomManager.resetTrackingState()

            // Start live stream if enabled and key is configured
            if StreamingService.shared.streamingEnabled && !StreamingService.shared.savedStreamKey.isEmpty {
                recordingManager.isStreamingActive = true
                // Store broadcast ID on game so we can delete the stream recording after 4K upload
                appState.currentGame?.broadcastVideoId = StreamingService.shared.currentBroadcastId
                Task { await StreamingService.shared.startStream(teamName: appState.currentGame?.teamName ?? "", opponent: appState.currentGame?.opponent ?? "") }
            }
        }

        if isClockRunning {
            // Record wall clock timestamp for zero-drift Watch sync
            clockStartedAt = Date().timeIntervalSince1970
            secondsAtClockStart = remainingSeconds
            startTimerIfNeeded()
        } else {
            clockStartedAt = 0
            secondsAtClockStart = 0
            stopTimer()
        }
        updateOverlayState()
        sendClockToWatch()
    }

    private func startTimerIfNeeded() {
        guard isClockRunning, remainingSeconds > 0 else { return }
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        timer?.cancel()
        guard isClockRunning, (remainingSeconds > 0 || remainingTenths > 0) else {
            if remainingSeconds == 0 && remainingTenths == 0 {
                isClockRunning = false
                sendClockToWatch()
            }
            return
        }

        timer = Timer.publish(every: timerInterval, on: .main, in: .common)
            .autoconnect()
            .first()
            .sink { _ in
                if self.isUnderOneMinute {
                    // Under 1 minute: decrement tenths (real-time countdown)
                    if self.remainingTenths > 0 {
                        self.remainingTenths -= 1
                    } else if self.remainingSeconds > 0 {
                        self.remainingSeconds -= 1
                        self.remainingTenths = 9
                    } else {
                        // Time's up — surface the contextual next action (Next Period /
                        // Add OT) by auto-expanding the chip. It stays open (no auto-collapse)
                        // until the user acts.
                        self.remainingSeconds = 0
                        self.remainingTenths = 0
                        self.isClockRunning = false
                        self.cancelAutoCollapse()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                            self.controlsExpanded = true
                        }
                    }
                } else {
                    // Over 1 minute: decrement seconds normally
                    if self.remainingSeconds > 1 {
                        self.remainingSeconds -= 1
                    } else {
                        // Entering final minute - start tenths countdown
                        self.remainingSeconds = 59
                        self.remainingTenths = 9
                    }
                }
                self.updateOverlayState()

                // Send clock update to watch (less frequently when in tenths mode)
                if !self.isUnderOneMinute || self.remainingTenths == 0 {
                    self.sendClockToWatch()
                }

                if self.isClockRunning {
                    self.scheduleNextTick()
                }
            }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Recording

    private func stopRecording() {
        timer?.cancel()
        gimbalManager.stopTracking()
        if recordingManager.isRecording {
            recordingManager.stopRecording()
        }
        // Stop stream if active
        if recordingManager.isStreamingActive {
            recordingManager.isStreamingActive = false
            Task { await StreamingService.shared.stopStream() }
        }
    }

    private func updateOverlayState() {
        recordingManager.updateOverlay(
            homeTeam: appState.currentGame?.teamName ?? "Home",
            awayTeam: appState.currentGame?.opponent ?? "Away",
            homeScore: myScore,
            awayScore: opponentScore,
            period: period,
            clockTime: clockTime,
            isClockRunning: isClockRunning,
            eventName: ""
        )
    }

    // MARK: - Orientation

    private func updateOrientationState() {
        let orientation = UIDevice.current.orientation
        var newIsPortrait = isPortrait

        switch orientation {
        case .landscapeLeft, .landscapeRight:
            newIsPortrait = false
        case .portrait, .portraitUpsideDown:
            newIsPortrait = true
        default:
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let interfaceOrientation = windowScene.effectiveGeometry.interfaceOrientation
                newIsPortrait = interfaceOrientation.isPortrait
            }
        }

        // Start camera + Skynet when entering landscape (warmup = free calibration)
        // Recording starts later when game clock starts
        if !newIsPortrait && isPortrait && !hasCameraStarted && !appState.isStatsOnly {
            if recordingManager.isSessionReady && !recordingManager.isSimulator {
                debugPrint("📹 Camera + Skynet started on landscape entry (warmup calibration)")
                hasCameraStarted = true
                updateOverlayState()
                gimbalManager.startTracking()
                startAutoZoom()
            }
        }

        withAnimation { isPortrait = newIsPortrait }
    }

    // MARK: - Rotate Prompt

    private var rotatePromptOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "rotate.right.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.orange)
                    .rotationEffect(.degrees(-90))

                Text("Rotate to Landscape")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text("Hold your phone horizontally\nto start camera")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - End Game Confirmation

    private var endGameConfirmation: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                if isFinishingRecording {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)

                    Text(appState.isStatsOnly ? "Saving stats..." : "Finishing recording...")
                        .font(.chalkScript(26))
                        .foregroundColor(Chalk.chalk)
                } else {
                    Text("End Game?")
                        .font(.chalkScript(30))
                        .foregroundColor(Chalk.chalk)

                    Text("\(appState.currentGame?.teamName ?? "Home") \(myScore) - \(opponentScore) \(appState.currentGame?.opponent ?? "Away")")
                        .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        .foregroundColor(Chalk.crisp)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 12) {
                        ChalkButton(title: appState.isStatsOnly ? "Save Stats" : "End & Save", color: Chalk.yellow) {
                            endGame()
                        }
                        ChalkButton(title: "Cancel & Discard", color: Chalk.coral, filled: false) {
                            discardGame()
                        }
                        Button("Keep Recording") {
                            showEndConfirmation = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Chalk.dust)
                        .padding(.top, 4)
                    }
                    .padding(.top, 8)
                }
            }
            .frame(width: 300)
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Chalk.board2)
            )
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Chalk.chalk.opacity(0.25), lineWidth: 1.5))
        }
    }

    private func discardGame() {
        isFinishingRecording = true
        timer?.cancel()

        let wasStatsOnly = appState.isStatsOnly

        // Notify Watch to reset
        watchService.sendEndGame()

        // Discard means discard: never save, and remove any record that may already
        // exist (e.g. a live game pushed to Firebase at start) so it never shows in
        // the Game Log. deleteGame no-ops safely if the game was never persisted, and
        // also cleans up any local video file.
        if let game = appState.currentGame {
            persistenceManager.deleteGame(game)
        }

        // Delete stream recording from YouTube so nothing stays on the channel
        if let broadcastId = appState.currentGame?.broadcastVideoId {
            Task {
                await YouTubeService.shared.deleteVideo(videoId: broadcastId)
            }
        }

        if !wasStatsOnly {
            gimbalManager.stopTracking()
            stopAutoZoom()

            Task {
                // Just stop, don't use the URL
                _ = await recordingManager.stopRecordingAndWait()

                await MainActor.run {
                    isFinishingRecording = false
                    appState.goHome()
                }
            }
        } else {
            recordingManager.stopClipBuffering()
            isFinishingRecording = false
            appState.isStatsOnly = false
            appState.goHome()
        }
    }

    private func endGame() {
        isFinishingRecording = true
        timer?.cancel()

        // Notify Watch that game has ended
        watchService.sendEndGame()

        // Sync player stats
        syncPlayerStats()

        // Update game
        appState.currentGame?.myScore = myScore
        appState.currentGame?.opponentScore = opponentScore
        appState.currentGame?.playerStats = playerStats
        appState.currentGame?.completedAt = Date()

        if appState.isStatsOnly {
            // Stats-only mode: just save the game, no video to process
            recordingManager.stopClipBuffering()
            if let game = appState.currentGame {
                persistenceManager.saveGame(game)
            }
            isFinishingRecording = false
            appState.isStatsOnly = false  // Reset for next game
            appState.goHome()
        } else {
            // Recording mode: stop recording and save
            gimbalManager.stopTracking()
            stopAutoZoom()

            Task {
                let videoURL = await recordingManager.stopRecordingAndWait()

                // Log video details
                if let url = videoURL {
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    debugPrint("📹 Video file: \(url.lastPathComponent)")
                    debugPrint("📹 Video exists: \(exists), size: \(size / 1_000_000) MB")
                } else {
                    debugPrint("📹 WARNING: No video URL returned from recording!")
                }

                // Save to persistence
                if var game = appState.currentGame {
                    game.videoURL = videoURL
                    game.completedAt = Date()
                    debugPrint("📹 Saving game with URL: \(videoURL?.lastPathComponent ?? "nil")")
                    persistenceManager.saveGame(game)
                }

                // Process video: Save to Photos, upload to YouTube, then cleanup
                if let url = videoURL {
                    var photosSaved = false

                    // 1. Save to Photos (WAIT for completion)
                    debugPrint("📹 Starting save to Photos...")
                    photosSaved = await saveVideoToPhotosAsync(url: url)
                    debugPrint("📹 Photos save: \(photosSaved ? "SUCCESS" : "FAILED")")
                    if !photosSaved {
                        await MainActor.run {
                            appState.photosSaveFailureMessage = "Video saved to the app but NOT to Photos. Check Photos permissions in Settings. Local copy is preserved — upload it from Game Log."
                        }
                    }

                    // 2. Upload to YouTube - REMOVED (Manual only now)
                    /*
                    if youtubeService.isEnabled && youtubeService.isAuthorized {
                        // ... code removed for manual workflow ...
                        debugPrint("📺 YouTube upload skipped (switched to manual workflow)")
                    }
                    */

                    // 3. Auto-cleanup - DISABLED for manual upload workflow
                    /*
                    if photosSaved {
                        do {
                            try FileManager.default.removeItem(at: url)
                            debugPrint("🗑️ Video cleaned up from Documents folder")
                        } catch {
                            debugPrint("🗑️ Cleanup failed: \(error.localizedDescription)")
                        }
                    } else {
                        debugPrint("⚠️ Keeping video in Documents (Photos save failed)")
                    }
                    */
                    debugPrint("✅ Video kept in Documents for manual upload")
                }

                await MainActor.run {
                    isFinishingRecording = false
                    appState.goHome()
                }
            }
        }
    }

    private func saveVideoToPhotosAsync(url: URL) async -> Bool {
        // First check if file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            debugPrint("📹 Video file doesn't exist at: \(url.path)")
            return false
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    debugPrint("📹 Photo library access denied: \(status.rawValue)")
                    continuation.resume(returning: false)
                    return
                }

                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } completionHandler: { success, error in
                    if success {
                        debugPrint("📹 Video saved to Photos successfully")
                    } else if let error = error {
                        debugPrint("📹 Failed to save video: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private func syncPlayerStats() {
        playerStats.fg2Made = fg2Made
        playerStats.fg2Attempted = fg2Att
        playerStats.fg3Made = fg3Made
        playerStats.fg3Attempted = fg3Att
        playerStats.ftMade = ftMade
        playerStats.ftAttempted = ftAtt
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: Date())
    }

    // MARK: - Stats Overlay

    // MARK: - Streamlined stat entry (docked pad + minimized pill)

    private var liveStatLine: String {
        let fgM = fg2Made + fg3Made, fgA = fg2Att + fg3Att
        return "\(sahilPoints) pts · \(fgM)/\(fgA) FG · \(playerStats.rebounds) reb · \(playerStats.assists) ast"
    }

    /// Expanded: the docked, non-dimming stat pad.
    private var statPad: some View {
        VStack(spacing: 10) {
            Capsule().fill(Chalk.chalk.opacity(0.3)).frame(width: 40, height: 4)
                .padding(.top, 3)
                .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showSahilStats = false } }

            // Live line + undo + collapse
            HStack(spacing: 8) {
                Text("Sahil").font(.chalkScript(18)).foregroundColor(Chalk.yellow)
                Text(liveStatLine).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                    .foregroundColor(Chalk.chalkDim).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Button { undoStat() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .bold))
                        Text("Undo").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(statUndo.isEmpty ? Chalk.dust.opacity(0.5) : Chalk.sky)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(Capsule().stroke((statUndo.isEmpty ? Chalk.dust : Chalk.sky).opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain).disabled(statUndo.isEmpty)
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showSahilStats = false } } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundColor(Chalk.dust).padding(4)
                }.buttonStyle(.plain)
            }

            // Shooting — one tap Make (make+attempt+points) or a small Miss (attempt only)
            HStack(spacing: 8) {
                makeMissTile("2PT", made: fg2Made, att: fg2Att, make: .make2, miss: .miss2, color: Chalk.sky)
                makeMissTile("3PT", made: fg3Made, att: fg3Att, make: .make3, miss: .miss3, color: Chalk.yellow)
                makeMissTile("FT", made: ftMade, att: ftAtt, make: .makeFT, miss: .missFT, color: Chalk.green)
            }

            // Counters — one tap +1, long-press −1
            HStack(spacing: 8) {
                counterTile("REB", playerStats.rebounds, .reb, Chalk.yellow)
                counterTile("AST", playerStats.assists, .ast, Chalk.green)
                counterTile("STL", playerStats.steals, .stl, Chalk.sky)
            }
            HStack(spacing: 8) {
                counterTile("BLK", playerStats.blocks, .blk, Chalk.coral)
                counterTile("TO", playerStats.turnovers, .turnover, Chalk.coral)
                counterTile("PF", playerStats.fouls, .foul, Chalk.dust)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 16).padding(.top, 4)
        .background(
            LinearGradient(colors: [Color(white: 0.08, opacity: 0.88), Color(white: 0.05, opacity: 0.97)],
                           startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Chalk.chalk.opacity(0.16), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .shadow(color: .black.opacity(0.45), radius: 16, y: -2)
    }

    private func makeMissTile(_ label: String, made: Int, att: Int, make: StatEvent, miss: StatEvent, color: Color) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 11, weight: .bold)).foregroundColor(Chalk.dust)
                Spacer()
                Text("\(made)/\(att)").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundColor(color)
            }
            HStack(spacing: 5) {
                Button { logStat(make) } label: {
                    Text("✓ Make").font(.system(size: 13, weight: .heavy)).foregroundColor(Color(white: 0.1))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(color, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
                Button { logStat(miss) } label: {
                    Text("Miss").font(.system(size: 12, weight: .bold)).foregroundColor(Chalk.coral)
                        .frame(width: 50).padding(.vertical, 9)
                        .background(Chalk.coral.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Chalk.coral.opacity(0.4), lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Chalk.chalk.opacity(0.12), lineWidth: 1))
    }

    private func counterTile(_ label: String, _ value: Int, _ event: StatEvent, _ color: Color) -> some View {
        Button { logStat(event) } label: {
            VStack(spacing: 2) {
                Text("\(value)").font(.system(size: 22, weight: .heavy)).monospacedDigit().foregroundColor(color)
                Text("\(label) +").font(.system(size: 11, weight: .semibold)).foregroundColor(Chalk.dust)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Chalk.chalk.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in decStat(event) })
    }

    private func logStat(_ e: StatEvent) {
        apply(e, +1)
        statUndo.append(e)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func undoStat() {
        guard let e = statUndo.popLast() else { return }
        apply(e, -1)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    private func decStat(_ e: StatEvent) {
        apply(e, -1)
        if let idx = statUndo.lastIndex(of: e) { statUndo.remove(at: idx) }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    private func apply(_ e: StatEvent, _ s: Int) {
        func adj(_ v: inout Int) { v = max(0, v + s) }
        switch e {
        case .make2: adj(&fg2Made); adj(&fg2Att)
        case .miss2: adj(&fg2Att)
        case .make3: adj(&fg3Made); adj(&fg3Att)
        case .miss3: adj(&fg3Att)
        case .makeFT: adj(&ftMade); adj(&ftAtt)
        case .missFT: adj(&ftAtt)
        case .reb: adj(&playerStats.rebounds)
        case .ast: adj(&playerStats.assists)
        case .stl: adj(&playerStats.steals)
        case .blk: adj(&playerStats.blocks)
        case .turnover: adj(&playerStats.turnovers)
        case .foul: adj(&playerStats.fouls)
        }
    }

    private var nextPeriodLabel: String {
        switch period {
        case "1st Half": return "2nd Half"
        case "2nd Half": return "Overtime"
        default:
            // In OT - tapping adds more time
            if period.hasPrefix("OT") {
                return "+1:00 OT"
            }
            return "Next"
        }
    }

    private func advancePeriod() {
        switch period {
        case "1st Half":
            period = "2nd Half"
            remainingSeconds = halfLength * 60
            remainingTenths = 0
            isClockRunning = false
            stopTimer()
        case "2nd Half":
            // Go to OT
            period = "OT"
            remainingSeconds = 60  // 1 minute OT
            remainingTenths = 0
            isClockRunning = false
            stopTimer()
        default:
            // Already in OT - add another minute
            if period.hasPrefix("OT") {
                remainingSeconds += 60
                remainingTenths = 0
                // Don't change period name, just add time
            }
        }
        updateOverlayState()
        sendPeriodToWatch()
    }

    private func addOvertime() {
        period = "OT"
        remainingSeconds += 60
        remainingTenths = 0
        if !isClockRunning {
            isClockRunning = true
            startTimerIfNeeded()
        }
        showSahilStats = false
        updateOverlayState()
        sendPeriodToWatch()
    }

    private func shootingTile(_ label: String, made: Binding<Int>, att: Binding<Int>, pts: Int, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(color)

            Text("\(made.wrappedValue)/\(att.wrappedValue)")
                .font(.system(size: 20, weight: .bold)).monospacedDigit()
                .foregroundColor(Chalk.crisp)

            HStack(spacing: 6) {
                // Made shot - only tracks stats, does NOT add to game score
                // Use tap scoring for game score changes
                Button(action: {
                    made.wrappedValue += 1
                    att.wrappedValue += 1
                    // NOTE: No longer adds to myScore - use score screen for that
                }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Chalk.board)
                        .frame(width: 32, height: 26)
                        .background(Chalk.green)
                        .cornerRadius(6)
                }

                // Missed shot
                Button(action: { att.wrappedValue += 1 }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Chalk.board)
                        .frame(width: 32, height: 26)
                        .background(Chalk.coral)
                        .cornerRadius(6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Chalk.board.opacity(0.55))
        .cornerRadius(10)
    }

    private func statTile(_ label: String, _ value: Binding<Int>, _ color: Color) -> some View {
        Button(action: { value.wrappedValue += 1 }) {
            VStack(spacing: 2) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color.opacity(0.85))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: { if value.wrappedValue > 0 { value.wrappedValue -= 1 } }) {
                Label("Subtract 1", systemImage: "minus")
            }
            Button(action: { value.wrappedValue = 0 }) {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
        }
    }

}

// Effervescent score feedback: a big chalk "+N" (or "−1") that rises up and fades on
// its own (self-animating), so it never sits static over the name/score.
private struct FloatingScore: View {
    let text: String
    let color: Color
    let dots: Int   // multi-tap indicator (0 = subtract, no dots)
    @State private var animate = false
    var body: some View {
        VStack(spacing: 6) {
            Text(text)
                .font(.chalkScript(74))
                .foregroundColor(color)
                .shadow(color: .black.opacity(0.5), radius: 7, y: 1)
            if dots > 0 {
                HStack(spacing: 6) {
                    ForEach(1...3, id: \.self) { i in
                        Circle()
                            .fill(i <= dots ? color : color.opacity(0.22))
                            .frame(width: 7, height: 7)
                    }
                }
            }
        }
        .offset(y: animate ? -128 : 24)   // rise from near the score up into empty space
        .scaleEffect(animate ? 1.15 : 0.8)
        .opacity(animate ? 0 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: 0.85)) { animate = true }
        }
    }
}

#Preview("Portrait") {
    UltraMinimalRecordingView()
        .environmentObject(AppState())
}

#Preview("Landscape", traits: .landscapeRight) {
    UltraMinimalRecordingView()
        .environmentObject(AppState())
}
