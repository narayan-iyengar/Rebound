//
//  WatchConnectivityService.swift
//  SahilStatsLite
//
//  PURPOSE: iPhone-side WatchConnectivity handler. Sends game state, scores,
//           clock, and period updates to Watch. Receives scoring, clock toggle,
//           period advance, stat updates, and end game commands from Watch.
//           Must be initialized at app launch (AppDelegate) or WCSession fails.
//  KEY TYPES: WatchConnectivityService (singleton), WatchMessage, WatchGame
//  DEPENDS ON: WatchConnectivity
//
//  NOTE: Keep this header updated when modifying this file.
//

import Foundation
import Combine
import WatchConnectivity

// MARK: - Message Keys

struct WatchMessage {
    static let scoreUpdate = "scoreUpdate"
    static let clockUpdate = "clockUpdate"
    static let periodUpdate = "periodUpdate"
    static let statUpdate = "statUpdate"
    static let gameState = "gameState"
    static let endGame = "endGame"
    static let startGame = "startGame"  // Start game from watch
    static let upcomingGames = "upcomingGames"  // Calendar games sync
    static let requestState = "requestState" // Watch asks for current state
    static let clip = "clip"  // Clip-from-wrist → phone triggers a clip
    static let clipStop = "clipStop"      // watch → phone: cut the forward window short, save now
    static let clipStatus = "clipStatus"  // phone → watch: is the clip ring armed (can we clip?)
    static let clipSaved = "clipSaved"    // phone → watch: a clip just finished saving
    static let clipSavedCount = "clipSavedCount"  // phone → watch: monotonic saved counter (reliable delivery)
    static let teams = "teams"            // phone → watch: Sahil's saved team names (for the picker)

    // Team fouls + timeouts tally (bidirectional; absolute values, not deltas)
    static let teamTally = "teamTally"    // marker key
    static let homeFouls = "homeFouls"
    static let awayFouls = "awayFouls"
    static let homeTimeouts = "homeTimeouts"
    static let awayTimeouts = "awayTimeouts"

    // Score update keys
    static let myScore = "myScore"
    static let oppScore = "oppScore"
    static let team = "team" // "my" or "opp"
    static let points = "points"
    static let isSubtract = "isSubtract"  // For subtracting scores

    // Clock keys
    static let isRunning = "isRunning"
    static let remainingSeconds = "remainingSeconds"
    static let warmup = "warmup"  // phone → watch: video game loaded, camera warming up, clock not yet started

    // Period keys
    static let period = "period"
    static let periodIndex = "periodIndex"

    // Stat keys
    static let statType = "statType"
    static let statValue = "statValue"

    // Game state keys
    static let teamName = "teamName"
    static let opponent = "opponent"
    static let halfLength = "halfLength"
    static let location = "location"
    static let startTime = "startTime"
    static let gameId = "gameId"
    static let games = "games"
}

// MARK: - Watch Game (lightweight game for Watch sync)

struct WatchGame: Codable, Identifiable, Equatable {
    let id: String
    let opponent: String
    let teamName: String
    let location: String
    let startTime: Date
    let halfLength: Int

    var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: startTime)
    }

    var isToday: Bool {
        Calendar.current.isDateInToday(startTime)
    }

    var dayString: String {
        if Calendar.current.isDateInToday(startTime) {
            return "Today"
        } else if Calendar.current.isDateInTomorrow(startTime) {
            return "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE"
            return formatter.string(from: startTime)
        }
    }
}

// MARK: - iOS App Service

@MainActor
class WatchConnectivityService: NSObject, ObservableObject {
    static let shared = WatchConnectivityService()

    @Published var isWatchReachable: Bool = false
    @Published var isWatchAppInstalled: Bool = false

    // Publisher for when Watch requests to start a game (for remote triggering recording)
    @Published var pendingGameFromWatch: WatchGame?

    // Callbacks for when watch sends updates
    var onScoreUpdate: ((_ team: String, _ points: Int, _ isSubtract: Bool) -> Void)?
    var onClockToggle: (() -> Void)?
    var onClockSync: ((_ remainingSeconds: Int, _ isRunning: Bool) -> Void)?
    var onPeriodAdvance: (() -> Void)?
    var onPeriodSync: ((_ period: String, _ remainingSeconds: Int) -> Void)?
    var onStatUpdate: ((_ statType: String, _ value: Int) -> Void)?
    var onEndGame: (() -> Void)?
    var onStartGame: ((_ game: WatchGame) -> Void)?
    var onRequestState: (() -> Void)?
    // Team fouls/timeouts changed from the watch (absolute values for all four).
    var onTeamTallyUpdate: ((_ homeFouls: Int, _ awayFouls: Int, _ homeTimeouts: Int, _ awayTimeouts: Int) -> Void)?

    private var session: WCSession?

    private override init() {
        super.init()
        setupSession()
    }

    private func setupSession() {
        guard WCSession.isSupported() else {
            debugPrint("[WatchConnectivity] WCSession not supported on this device")
            return
        }

        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    // MARK: - Send to Watch

    /// Single source of truth. Replaces the ENTIRE application context on every call —
    /// no merging, no conflicting flags accumulating across a game.
    ///
    /// clockStartedAt: wall-clock timestamp when clock last started (0 = paused).
    /// secondsAtClockStart: how many seconds remained when clock started.
    /// Watch computes remaining = secondsAtClockStart - elapsed(since clockStartedAt).
    /// This eliminates BLE delay drift entirely — both devices read Date() independently.
    /// Whether the phone's clip ring is armed (i.e. a Clip-from-wrist will actually
    /// capture). Rides along in every snapshot; also pushed immediately on change.
    nonisolated(unsafe) var clipArmed: Bool = false

    /// Monotonic count of clips saved this session — rides in the sticky context so the
    /// wrist "Clipped ✓" confirmation survives a dropped live message.
    nonisolated(unsafe) private var clipSavedCounter: Int = 0

    /// Update the clip-armed state and tell the watch right away (idempotent).
    /// Delivered two ways: an immediate message AND a merge into the sticky context, so
    /// the wrist's Clip button lights up reliably right when recording starts (a bare
    /// sendMessage is often dropped in that busy moment).
    func setClipArmed(_ armed: Bool) {
        guard armed != clipArmed else { return }
        clipArmed = armed
        sendMessage([WatchMessage.clipStatus: armed])
        mergeIntoContext([WatchMessage.clipStatus: armed])
    }

    /// Tell the watch a clip just saved (for the wrist "Clipped ✓" confirmation).
    /// Uses a monotonic counter delivered on both channels; the watch bumps its tick when
    /// the count increases, so neither a dropped message nor a duplicate double-fires.
    func sendClipSaved() {
        clipSavedCounter += 1
        let payload: [String: Any] = [WatchMessage.clipSaved: true,
                                       WatchMessage.clipSavedCount: clipSavedCounter]
        sendMessage(payload)
        mergeIntoContext([WatchMessage.clipSavedCount: clipSavedCounter])
    }

    /// Push the team fouls/timeouts tally to the watch (absolute values). Delivered on both
    /// channels + merged into the sticky context so a freshly-opened watch reads the current
    /// tally without waiting for a change.
    func sendTeamTally(homeFouls: Int, awayFouls: Int, homeTimeouts: Int, awayTimeouts: Int) {
        let payload: [String: Any] = [
            WatchMessage.teamTally:     true,
            WatchMessage.homeFouls:     homeFouls,
            WatchMessage.awayFouls:     awayFouls,
            WatchMessage.homeTimeouts:  homeTimeouts,
            WatchMessage.awayTimeouts:  awayTimeouts
        ]
        sendMessage(payload)
        mergeIntoContext(payload)
    }

    /// Merge a few keys into the sticky application context without wiping game state.
    private func mergeIntoContext(_ keys: [String: Any]) {
        guard let session = session else { return }
        var ctx = session.applicationContext
        for (k, v) in keys { ctx[k] = v }
        try? session.updateApplicationContext(ctx)
    }

    /// Push Sahil's saved team names so the watch quick-game screen can offer a picker.
    func sendTeams(_ teams: [String]) {
        guard !teams.isEmpty else { return }
        sendMessage([WatchMessage.teams: teams])
    }

    func sendFullSnapshot(
        hasActiveGame: Bool,
        teamName: String,
        opponent: String,
        myScore: Int,
        oppScore: Int,
        clockStartedAt: TimeInterval,   // 0 when paused
        secondsAtClockStart: Int,       // remaining seconds at moment clock started
        remainingSeconds: Int,          // paused value (used when clockStartedAt == 0)
        isClockRunning: Bool,
        period: String,
        periodIndex: Int,
        warmup: Bool = false
    ) {
        let snapshot: [String: Any] = [
            "hasActiveGame":      hasActiveGame,
            WatchMessage.teamName:       teamName,
            WatchMessage.opponent:       opponent,
            WatchMessage.myScore:        myScore,
            WatchMessage.oppScore:       oppScore,
            "clockStartedAt":     clockStartedAt,
            "secondsAtClockStart": secondsAtClockStart,
            WatchMessage.remainingSeconds: remainingSeconds,
            WatchMessage.isRunning:      isClockRunning,
            WatchMessage.period:         period,
            WatchMessage.periodIndex:    periodIndex,
            WatchMessage.clipStatus:     clipArmed,
            WatchMessage.clipSavedCount: clipSavedCounter,
            WatchMessage.warmup:         warmup
        ]

        // sendMessage: immediate delivery when Watch is in foreground
        sendMessage(snapshot)

        // updateApplicationContext: overwrites entire context (no merge) — delivered
        // reliably when Watch app next activates, even if currently backgrounded.
        guard let session = session else { return }
        do {
            try session.updateApplicationContext(snapshot)
        } catch {
            debugPrint("[WatchConnectivity] Snapshot context error: \(error)")
        }
    }

    // Convenience wrappers so existing call sites don't need full refactor at once.
    // These all call sendFullSnapshot — keeping the single-context guarantee.

    func sendGameState(teamName: String, opponent: String, myScore: Int, oppScore: Int,
                       remainingSeconds: Int, isClockRunning: Bool, period: String, periodIndex: Int,
                       clockStartedAt: TimeInterval = 0, secondsAtClockStart: Int = 0,
                       warmup: Bool = false) {
        sendFullSnapshot(hasActiveGame: true, teamName: teamName, opponent: opponent,
                         myScore: myScore, oppScore: oppScore,
                         clockStartedAt: clockStartedAt, secondsAtClockStart: secondsAtClockStart,
                         remainingSeconds: remainingSeconds, isClockRunning: isClockRunning,
                         period: period, periodIndex: periodIndex, warmup: warmup)
    }

    func sendScoreUpdate(myScore: Int, oppScore: Int,
                         teamName: String = "", opponent: String = "",
                         remainingSeconds: Int = 0, isClockRunning: Bool = false,
                         period: String = "", periodIndex: Int = 0,
                         clockStartedAt: TimeInterval = 0, secondsAtClockStart: Int = 0) {
        sendFullSnapshot(hasActiveGame: true, teamName: teamName, opponent: opponent,
                         myScore: myScore, oppScore: oppScore,
                         clockStartedAt: clockStartedAt, secondsAtClockStart: secondsAtClockStart,
                         remainingSeconds: remainingSeconds, isClockRunning: isClockRunning,
                         period: period, periodIndex: periodIndex)
    }

    func sendClockUpdate(remainingSeconds: Int, isRunning: Bool,
                         clockStartedAt: TimeInterval = 0, secondsAtClockStart: Int = 0) {
        // Clock-only updates still push a full snapshot to keep context consistent.
        // Callers that have full state should use sendFullSnapshot directly.
        let snapshot: [String: Any] = [
            "hasActiveGame":       true,
            WatchMessage.remainingSeconds: remainingSeconds,
            WatchMessage.isRunning:       isRunning,
            "clockStartedAt":      clockStartedAt,
            "secondsAtClockStart": secondsAtClockStart,
            WatchMessage.warmup:          false   // any clock update means play has begun
        ]
        sendMessage(snapshot)
        guard let session = session else { return }
        // Merge only the clock keys into the existing snapshot so we don't wipe game info.
        // This is the only place a merge is acceptable — clock is a subset, not a conflicting flag.
        var ctx = session.applicationContext
        for (k, v) in snapshot { ctx[k] = v }
        try? session.updateApplicationContext(ctx)
    }

    func sendPeriodUpdate(period: String, periodIndex: Int, remainingSeconds: Int, isRunning: Bool,
                          clockStartedAt: TimeInterval = 0, secondsAtClockStart: Int = 0) {
        let snapshot: [String: Any] = [
            "hasActiveGame":       true,
            WatchMessage.period:          period,
            WatchMessage.periodIndex:     periodIndex,
            WatchMessage.remainingSeconds: remainingSeconds,
            WatchMessage.isRunning:       isRunning,
            "clockStartedAt":      clockStartedAt,
            "secondsAtClockStart": secondsAtClockStart,
            WatchMessage.warmup:          false
        ]
        sendMessage(snapshot)
        guard let session = session else { return }
        var ctx = session.applicationContext
        for (k, v) in snapshot { ctx[k] = v }
        try? session.updateApplicationContext(ctx)
    }

    /// Send end game to watch (resets watch to waiting state)
    func sendEndGame() {
        let message: [String: Any] = [
            WatchMessage.endGame: true
        ]
        sendMessage(message)
        
        // When ending a game, we want to CLEAR the game-specific keys from context
        // Instead of merging, we replace with just the endGame signal
        guard let session = session else { return }
        do {
            try session.updateApplicationContext(message)
            debugPrint("[WatchConnectivity] Game ended - context cleared of active game state")
        } catch {
            debugPrint("[WatchConnectivity] Error clearing context: \(error)")
        }
    }

    /// Send upcoming games from calendar to watch
    func sendUpcomingGames(_ games: [WatchGame]) {
        // Encode games as JSON data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let gamesData = try encoder.encode(games)
            let gamesString = String(data: gamesData, encoding: .utf8) ?? "[]"

            let message: [String: Any] = [
                WatchMessage.upcomingGames: true,
                WatchMessage.games: gamesString
            ]
            
            if let session = session, session.isReachable {
                sendMessage(message)
            }
            // Merge only the games keys — calendar list doesn't conflict with game state flags
            if let session = session {
                var ctx = session.applicationContext
                ctx[WatchMessage.upcomingGames] = true
                ctx[WatchMessage.games] = gamesString
                try? session.updateApplicationContext(ctx)
            }
            debugPrint("[WatchConnectivity] Sent/Updated \(games.count) games in context")
        } catch {
            debugPrint("[WatchConnectivity] Error encoding games: \(error)")
        }
    }

    /// Convert calendar games to watch games and send
    func syncCalendarGames() {
        let calendarManager = GameCalendarManager.shared

        // Check calendar access
        guard calendarManager.hasCalendarAccess else {
            debugPrint("[WatchConnectivity] Cannot sync games - no calendar access")
            return
        }

        // Ensure games are loaded first
        calendarManager.loadUpcomingGames()

        let calendarGames = calendarManager.upcomingGames.prefix(10) // Limit to 10 games

        debugPrint("[WatchConnectivity] Syncing \(calendarGames.count) calendar games to Watch context")
        
        let defaultHalfLength = UserDefaults.standard.integer(forKey: "defaultHalfLength")
        let halfLength = defaultHalfLength > 0 ? defaultHalfLength : 18

        let watchGames = calendarGames.map { game in
            return WatchGame(
                id: game.id,
                opponent: game.opponent,
                teamName: game.detectedTeam ?? "Home",
                location: game.location,
                startTime: game.startTime,
                halfLength: halfLength
            )
        }

        sendUpcomingGames(Array(watchGames))
    }

    private func sendMessage(_ message: [String: Any]) {
        guard let session = session, session.isReachable else { return }
        session.sendMessage(message, replyHandler: nil) { error in
            debugPrint("[WatchConnectivity] sendMessage error: \(error)")
        }
    }
}


// MARK: - WCSessionDelegate

extension WatchConnectivityService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            debugPrint("[WatchConnectivity] Activation complete: \(activationState.rawValue)")
            debugPrint("[WatchConnectivity] Watch reachable: \(session.isReachable), installed: \(session.isWatchAppInstalled)")
            self.isWatchReachable = session.isReachable
            self.isWatchAppInstalled = session.isWatchAppInstalled

            // Sync calendar games on activation if Watch is reachable
            if session.isReachable {
                // Small delay to ensure Watch app is ready
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
                self.syncCalendarGames()
                
                // Also request state resync in case we are mid-game
                self.onRequestState?()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        debugPrint("[WatchConnectivity] Session became inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        debugPrint("[WatchConnectivity] Session deactivated")
        // Reactivate for switching watches
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isWatchReachable = session.isReachable
            debugPrint("[WatchConnectivity] Reachability changed: \(session.isReachable)")

            // Sync calendar games when Watch becomes reachable
            if session.isReachable {
                self.syncCalendarGames()
                
                // Also request state resync in case we are mid-game
                self.onRequestState?()
            }
        }
    }

    // Receive real-time messages from Watch (requires Watch in foreground)
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in handleMessage(message) }
    }

    // Receive queued messages from Watch (transferUserInfo — guaranteed delivery,
    // works even when phone is backgrounded/screen off during a game).
    // Watch uses this for all score and stat updates.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in handleMessage(userInfo) }
    }

    @MainActor
    private func handleMessage(_ message: [String: Any]) {
        // Score update from watch (add or subtract)
        if message[WatchMessage.scoreUpdate] != nil,
           let team = message[WatchMessage.team] as? String,
           let points = message[WatchMessage.points] as? Int {
            let isSubtract = message[WatchMessage.isSubtract] as? Bool ?? false
            onScoreUpdate?(team, points, isSubtract)
        }

        // Clock update from watch (Watch is source of truth when scoring from wrist)
        if message[WatchMessage.clockUpdate] != nil {
            if let remaining = message[WatchMessage.remainingSeconds] as? Int {
                onClockSync?(remaining, message["isClockRunning"] as? Bool ?? false)
            }
            onClockToggle?()
        }

        // Period advance from watch (Watch runs periods independently)
        if message[WatchMessage.periodUpdate] != nil {
            if let per = message[WatchMessage.period] as? String,
               let remaining = message[WatchMessage.remainingSeconds] as? Int {
                onPeriodSync?(per, remaining)
            }
            onPeriodAdvance?()
        }

        // Stat update from watch
        if message[WatchMessage.statUpdate] != nil,
           let statType = message[WatchMessage.statType] as? String,
           let value = message[WatchMessage.statValue] as? Int {
            onStatUpdate?(statType, value)
        }

        // Clip from the wrist → trigger a clip on the phone (works in recording +
        // stats-only whenever the clip ring is armed).
        if message[WatchMessage.clip] != nil {
            Task { @MainActor in RecordingManager.shared.triggerClip() }
        }

        // Stop-and-save from the wrist → cut the forward window short and finalize now.
        if message[WatchMessage.clipStop] != nil {
            Task { @MainActor in RecordingManager.shared.stopClip() }
        }

        // Team fouls/timeouts tally changed on the watch → apply to the phone scoreboard.
        if message[WatchMessage.teamTally] != nil {
            let hf = message[WatchMessage.homeFouls] as? Int ?? 0
            let af = message[WatchMessage.awayFouls] as? Int ?? 0
            let ht = message[WatchMessage.homeTimeouts] as? Int ?? 0
            let at = message[WatchMessage.awayTimeouts] as? Int ?? 0
            onTeamTallyUpdate?(hf, af, ht, at)
        }

        // End game from watch
        if message[WatchMessage.endGame] != nil {
            onEndGame?()
        }
        
        // Request state from watch
        if message[WatchMessage.requestState] != nil {
            debugPrint("[WatchConnectivity] ⌚️ Watch requested game state sync")
            
            // 1. Sync Calendar Games (so the Watch gets the list if it missed it)
            syncCalendarGames()
            sendTeams(GameCalendarManager.shared.knownTeamNames)
            
            // 2. Sync Active Game State (if there is one)
            onRequestState?()
        }

        // Start game from watch (triggers recording on phone)
        if message[WatchMessage.startGame] != nil {
            let gameId = message[WatchMessage.gameId] as? String ?? UUID().uuidString
            let opponent = message[WatchMessage.opponent] as? String ?? "Away"
            let teamName = message[WatchMessage.teamName] as? String ?? "Home"
            let location = message[WatchMessage.location] as? String ?? ""
            let halfLength = message[WatchMessage.halfLength] as? Int ?? 18
            let startTimeInterval = message[WatchMessage.startTime] as? TimeInterval ?? Date().timeIntervalSince1970

            let game = WatchGame(
                id: gameId,
                opponent: opponent,
                teamName: teamName,
                location: location,
                startTime: Date(timeIntervalSince1970: startTimeInterval),
                halfLength: halfLength
            )

            debugPrint("[WatchConnectivity] 📱 Received START GAME from Watch: \(teamName) vs \(opponent)")

            // Set pending game - ContentView will react to this
            pendingGameFromWatch = game

            // Also call callback if set
            onStartGame?(game)
        }
    }
}
