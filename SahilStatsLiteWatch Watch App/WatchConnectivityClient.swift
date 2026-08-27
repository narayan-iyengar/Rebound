//
//  WatchConnectivityClient.swift
//  SahilStatsLiteWatch
//
//  PURPOSE: Watch-side WCSession handler. Sends score/stat/clock/period
//           updates to iPhone, receives game state sync back. Manages
//           all published state (scores, clock, period, player stats).
//           Optimistic local updates for responsive UI.
//  KEY TYPES: WatchConnectivityClient (singleton), WatchMessage
//  DEPENDS ON: WatchConnectivity framework
//
//  NOTE: Keep this header updated when modifying this file.
//

import Foundation
import WatchConnectivity
import Combine
import WatchKit

// Reuse message keys from iOS app
struct WatchMessage {
    static let scoreUpdate = "scoreUpdate"
    static let clockUpdate = "clockUpdate"
    static let periodUpdate = "periodUpdate"
    static let statUpdate = "statUpdate"
    static let gameState = "gameState"
    static let endGame = "endGame"
    static let startGame = "startGame"
    static let upcomingGames = "upcomingGames"
    static let requestState = "requestState"
    static let clip = "clip"  // Clip-from-wrist → phone triggers a clip
    static let clipStop = "clipStop"      // watch → phone: cut the forward window short, save now
    static let clipStatus = "clipStatus"  // phone → watch: is the clip ring armed
    static let clipSaved = "clipSaved"    // phone → watch: a clip just saved
    static let clipSavedCount = "clipSavedCount"  // phone → watch: monotonic saved counter

    // Team fouls + timeouts tally (bidirectional; absolute values)
    static let teamTally = "teamTally"
    static let homeFouls = "homeFouls"
    static let awayFouls = "awayFouls"
    static let homeTimeouts = "homeTimeouts"
    static let awayTimeouts = "awayTimeouts"
    static let teams = "teams"            // phone → watch: Sahil's saved team names
    static let warmup = "warmup"          // phone → watch: camera warming up, clock not yet started

    // Score update keys
    static let myScore = "myScore"
    static let oppScore = "oppScore"
    static let team = "team" // "my" or "opp"
    static let points = "points"
    static let isSubtract = "isSubtract"

    // Clock keys
    static let isRunning = "isRunning"
    static let remainingSeconds = "remainingSeconds"

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

struct WatchGame: Codable, Identifiable {
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

@MainActor
class WatchConnectivityClient: NSObject, ObservableObject {
    static let shared = WatchConnectivityClient()

    // Connection state
    @Published var isPhoneReachable: Bool = false
    @Published var hasActiveGame: Bool = false {
        didSet {
            if hasActiveGame {
                startExtendedSession()
            } else {
                invalidateExtendedSession()
            }
        }
    }

    // Upcoming games from calendar (synced from phone)
    @Published var upcomingGames: [WatchGame] = []

    // Game state (received from phone)
    @Published var teamName: String = "MY TEAM"
    @Published var opponent: String = "OPP"
    @Published var myScore: Int = 0
    @Published var oppScore: Int = 0
    @Published var remainingSeconds: Int = 18 * 60
    @Published var isClockRunning: Bool = false {
        didSet {
            if isClockRunning {
                startLocalTimer()
            } else {
                stopLocalTimer()
            }
        }
    }
    @Published var period: String = "1st Half"
    @Published var periodIndex: Int = 0
    @Published var halfLength: Int = 18
    @Published var isEnding: Bool = false

    // Team fouls + timeouts tally (synced both ways with the phone scoreboard).
    @Published var homeFouls: Int = 0
    @Published var awayFouls: Int = 0
    @Published var homeTimeouts: Int = 0
    @Published var awayTimeouts: Int = 0

    // Player stats (received from phone)
    @Published var fg2Made: Int = 0
    @Published var fg2Att: Int = 0
    @Published var fg3Made: Int = 0
    @Published var fg3Att: Int = 0
    @Published var ftMade: Int = 0
    @Published var ftAtt: Int = 0
    @Published var assists: Int = 0
    @Published var rebounds: Int = 0
    @Published var steals: Int = 0
    @Published var blocks: Int = 0
    @Published var turnovers: Int = 0
    @Published var fouls: Int = 0

    // Clip-from-wrist: is the phone's clip ring armed (can we actually clip?), and a
    // tick that bumps each time the phone confirms a clip saved (drives "Clipped ✓").
    @Published var phoneClipArmed: Bool = false
    @Published var clipSavedTick: Int = 0
    // Highest saved-counter seen from the phone. Baselined (no tick) on the first snapshot
    // of a game so a stale count in the sticky context can't fire a phantom "Clipped ✓".
    private var lastClipSavedCount: Int = -1

    // Phone is in warmup: video game loaded, camera calibrating, clock not started yet.
    // Drives the "Ready · tap clock to start" indicator so a paused 18:00 isn't mistaken
    // for a stopped game.
    @Published var isWarmup: Bool = false

    // Sahil's saved team names, synced from the phone (for the quick-game team picker).
    @Published var myTeams: [String] = []

    private var session: WCSession?
    private var extendedSession: WKExtendedRuntimeSession?
    private var localTimer: AnyCancellable?

    private override init() {
        super.init()
        setupSession()
    }
    
    // MARK: - Wall Clock (Zero-Drift Display Timer)

    // When the clock is running, the phone sends a wall-clock timestamp
    // (clockStartedAt) and the seconds remaining at that moment (secondsAtClockStart).
    // The Watch computes remaining time from Date() directly — no BLE delay drift,
    // no two timers diverging. The local timer here just refreshes the display.
    private var clockStartedAt: TimeInterval = 0       // 0 = paused
    private var secondsAtClockStart: Int = 0

    private var computedRemainingSeconds: Int {
        guard clockStartedAt > 0 else { return remainingSeconds }
        let elapsed = Int(Date().timeIntervalSince1970 - clockStartedAt)
        return max(0, secondsAtClockStart - elapsed)
    }

    private func startLocalTimer() {
        stopLocalTimer()
        // Refresh display once per second — not counting down, just triggering UI update.
        localTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                let computed = self.computedRemainingSeconds
                if computed != self.remainingSeconds {
                    self.remainingSeconds = computed
                }
                if computed == 0 {
                    self.isClockRunning = false
                    self.clockStartedAt = 0
                }
            }
    }

    private func stopLocalTimer() {
        localTimer?.cancel()
        localTimer = nil
    }
    
    // MARK: - Extended Runtime Session (Keep Screen On)
    
    private func startExtendedSession() {
        // Only start if not already running
        guard extendedSession == nil || extendedSession?.state != .running else { return }
        
        debugPrint("[Watch] Starting extended runtime session (Keep Screen On)")
        extendedSession = WKExtendedRuntimeSession()
        extendedSession?.delegate = self
        extendedSession?.start()
    }
    
    private func invalidateExtendedSession() {
        guard let session = extendedSession else { return }
        
        debugPrint("[Watch] Invalidating extended runtime session")
        session.invalidate()
        extendedSession = nil
    }

    /// Configure shared instance with sample data for Xcode Canvas previews
    static func configureForPreview() {
        let client = shared
        client.hasActiveGame = true
        client.teamName = "LAVA"
        client.opponent = "WARRIORS"
        client.myScore = 42
        client.oppScore = 38
        client.remainingSeconds = 7 * 60 + 34  // 7:34
        client.isClockRunning = true
        client.period = "2nd Half"
        client.periodIndex = 1
        client.fg2Made = 3
        client.fg2Att = 5
        client.fg3Made = 1
        client.fg3Att = 4
        client.ftMade = 2
        client.ftAtt = 3
        client.assists = 2
        client.rebounds = 4
        client.steals = 1
    }

    private func setupSession() {
        guard WCSession.isSupported() else {
            debugPrint("[Watch] WCSession not supported")
            return
        }

        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    // MARK: - Send to Phone

    /// Add score (team: "my" or "opp", points: 1, 2, or 3)
    func addScore(team: String, points: Int) {
        if team == "my" { myScore += points } else { oppScore += points }
        // transferUserInfo: guaranteed delivery even if phone screen is off mid-game
        sendUserInfo([
            WatchMessage.scoreUpdate: true,
            WatchMessage.team: team,
            WatchMessage.points: points
        ])
    }

    /// Subtract score (for fixing mistakes)
    func subtractScore(team: String, points: Int) {
        if team == "my" { myScore = max(0, myScore - points) }
        else { oppScore = max(0, oppScore - points) }
        sendUserInfo([
            WatchMessage.scoreUpdate: true,
            WatchMessage.team: team,
            WatchMessage.points: points,
            WatchMessage.isSubtract: true
        ])
    }

    /// Start a new game from watch with full game details
    func startGame(_ game: WatchGame) {
        hasActiveGame = true
        myScore = 0
        oppScore = 0
        halfLength = game.halfLength
        remainingSeconds = game.halfLength * 60
        isClockRunning = false
        clockStartedAt = 0
        secondsAtClockStart = 0
        period = "1st Half"
        periodIndex = 0
        self.opponent = game.opponent
        self.teamName = game.teamName
        // Reset ALL player stats
        fg2Made = 0; fg2Att = 0; fg3Made = 0; fg3Att = 0
        ftMade = 0; ftAtt = 0; assists = 0; rebounds = 0
        steals = 0; blocks = 0; turnovers = 0; fouls = 0
        homeFouls = 0; awayFouls = 0; homeTimeouts = 0; awayTimeouts = 0

        let message: [String: Any] = [
            WatchMessage.startGame: true,
            WatchMessage.gameId: game.id,
            WatchMessage.opponent: game.opponent,
            WatchMessage.teamName: game.teamName,
            WatchMessage.location: game.location,
            WatchMessage.halfLength: game.halfLength,
            WatchMessage.startTime: game.startTime.timeIntervalSince1970
        ]
        sendMessage(message)
        // Guaranteed backup: if the phone app is closed, the immediate message is dropped,
        // which would orphan the queued stat updates (they use transferUserInfo too). Queue
        // the game-start so the phone can attach those stats when it next launches.
        sendUserInfo(message)
    }

    /// Start a quick game with just opponent name (fallback)
    func startQuickGame(opponent: String = "Opponent") {
        let game = WatchGame(
            id: UUID().uuidString,
            opponent: opponent,
            teamName: "Home",
            location: "",
            startTime: Date(),
            halfLength: 18
        )
        startGame(game)
    }

    /// Toggle clock (pause/play)
    func toggleClock() {
        isClockRunning.toggle()

        // Run clock locally (Watch is source of truth when scoring from wrist)
        if isClockRunning {
            clockStartedAt = Date().timeIntervalSince1970
            secondsAtClockStart = remainingSeconds
        } else {
            // Paused — snapshot remaining time and clear wall clock
            remainingSeconds = computedRemainingSeconds
            clockStartedAt = 0
            secondsAtClockStart = 0
        }

        // Sync to phone (delivered even if phone backgrounded)
        sendUserInfo([
            WatchMessage.clockUpdate: true,
            "clockStartedAt": clockStartedAt,
            "secondsAtClockStart": secondsAtClockStart,
            WatchMessage.remainingSeconds: remainingSeconds,
            "isClockRunning": isClockRunning
        ])
    }

    private let periodLabels = ["1st Half", "2nd Half", "OT1", "OT2", "OT3"]

    /// Advance period — works standalone, syncs to phone when available
    func advancePeriod() {
        if periodIndex < periodLabels.count - 1 {
            periodIndex += 1
            period = periodLabels[periodIndex]
            // Reset clock for new period
            remainingSeconds = periodIndex >= 2 ? 4 * 60 : halfLength * 60  // OT = 4 min
            isClockRunning = false
            clockStartedAt = 0
        }
        sendUserInfo([
            WatchMessage.periodUpdate: true,
            WatchMessage.period: period,
            WatchMessage.periodIndex: periodIndex,
            WatchMessage.remainingSeconds: remainingSeconds
        ])
    }

    /// Update a stat (sent to phone)
    func updateStat(_ statType: String, value: Int) {
        switch statType {
        case "fg2Made": fg2Made += value
        case "fg2Att": fg2Att += value
        case "fg3Made": fg3Made += value
        case "fg3Att": fg3Att += value
        case "ftMade": ftMade += value
        case "ftAtt": ftAtt += value
        case "assists": assists += value
        case "rebounds": rebounds += value
        case "steals": steals += value
        case "blocks": blocks += value
        case "turnovers": turnovers += value
        case "fouls": fouls += value
        default: break
        }
        sendUserInfo([
            WatchMessage.statUpdate: true,
            WatchMessage.statType: statType,
            WatchMessage.statValue: value
        ])
    }

    /// Clip from the wrist — tell the phone to save a highlight now.
    func sendClip() {
        sendMessage([WatchMessage.clip: true])
        WKInterfaceDevice.current().play(.click)
    }

    /// Stop-and-save from the wrist — cut the forward window short and finalize the clip.
    /// transferUserInfo backs up the immediate message so the stop isn't lost mid-game.
    func sendClipStop() {
        sendMessage([WatchMessage.clipStop: true])
        sendUserInfo([WatchMessage.clipStop: true])
        WKInterfaceDevice.current().play(.click)
    }

    /// Adjust a team fouls/timeouts tally from the wrist and push absolute values to the
    /// phone. `key` is one of homeFouls/awayFouls/homeTimeouts/awayTimeouts.
    func updateTeamTally(_ key: String, delta: Int) {
        switch key {
        case WatchMessage.homeFouls:    homeFouls    = max(0, homeFouls + delta)
        case WatchMessage.awayFouls:    awayFouls    = max(0, awayFouls + delta)
        case WatchMessage.homeTimeouts: homeTimeouts = max(0, homeTimeouts + delta)
        case WatchMessage.awayTimeouts: awayTimeouts = max(0, awayTimeouts + delta)
        default: return
        }
        WKInterfaceDevice.current().play(delta > 0 ? .click : .directionDown)
        let payload: [String: Any] = [
            WatchMessage.teamTally:    true,
            WatchMessage.homeFouls:    homeFouls,
            WatchMessage.awayFouls:    awayFouls,
            WatchMessage.homeTimeouts: homeTimeouts,
            WatchMessage.awayTimeouts: awayTimeouts
        ]
        sendMessage(payload)
        sendUserInfo(payload)   // guaranteed backup so a tap isn't lost mid-game
    }

    /// End game — use sendMessage (immediate) so spinner shows quickly,
    /// but also sendUserInfo as a backup in case sendMessage fails.
    func endGame() {
        isEnding = true
        let msg: [String: Any] = [WatchMessage.endGame: true]
        sendMessage(msg)
        sendUserInfo(msg)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            if self.isEnding {
                self.hasActiveGame = false
                self.isEnding = false
            }
        }
    }
    
    /// Request current game state from phone (called on connect)
    func requestState() {
        debugPrint("[Watch] Requesting game state from phone...")
        let message: [String: Any] = [
            WatchMessage.requestState: true
        ]
        sendMessage(message)
    }

    /// Guaranteed delivery — queued and delivered even when phone is backgrounded.
    /// Use for all scoring and stat updates so nothing is lost mid-game.
    private func sendUserInfo(_ message: [String: Any]) {
        guard let session = session else { return }
        session.transferUserInfo(message)
    }

    /// Immediate delivery — for time-sensitive requests only (e.g. requestState).
    /// Silently dropped if phone not reachable.
    private func sendMessage(_ message: [String: Any]) {
        guard let session = session, session.isReachable else { return }
        session.sendMessage(message, replyHandler: nil) { error in
            debugPrint("[Watch] sendMessage error: \(error)")
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityClient: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            debugPrint("[Watch] Activation complete: \(activationState.rawValue)")
            self.isPhoneReachable = session.isReachable
            
            // 1. Check cached context first (Sticky State)
            // This ensures we show the active game even if Phone is backgrounded/unreachable
            let cachedContext = session.receivedApplicationContext
            if !cachedContext.isEmpty {
                debugPrint("[Watch] Loading cached application context")
                self.handleMessage(cachedContext)
            }
            
            // 2. Request fresh state if reachable
            if session.isReachable {
                self.requestState()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isPhoneReachable = session.isReachable
            debugPrint("[Watch] Reachability changed: \(session.isReachable)")
            
            // Request state when phone becomes reachable
            if session.isReachable {
                self.requestState()
            }
        }
    }

    // Receive messages from phone
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            handleMessage(message)
        }
    }

    // Receive application context from phone (reliable/sticky)
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            debugPrint("[Watch] Received application context update")
            handleMessage(applicationContext)
        }
    }

    @MainActor
    private func handleMessage(_ message: [String: Any]) {
        // Full game state snapshot from phone.
        // Also handles the new "hasActiveGame" key that replaces the old gameState flag.
        let isFullSnapshot = message["hasActiveGame"] != nil
        let isLegacyGameState = message[WatchMessage.gameState] != nil

        if isFullSnapshot || isLegacyGameState {
            if let active = message["hasActiveGame"] as? Bool {
                hasActiveGame = active
            } else if isLegacyGameState {
                hasActiveGame = true
            }
            if let name = message[WatchMessage.teamName] as? String, !name.isEmpty { teamName = name }
            if let opp  = message[WatchMessage.opponent] as? String,  !opp.isEmpty  { opponent = opp }
            if let my   = message[WatchMessage.myScore] as? Int  { myScore = my }
            if let opp  = message[WatchMessage.oppScore] as? Int { oppScore = opp }
            if let per  = message[WatchMessage.period] as? String    { period = per }
            if let idx  = message[WatchMessage.periodIndex] as? Int  { periodIndex = idx }
            applyClockState(from: message)
            debugPrint("[Watch] Snapshot applied: \(teamName) vs \(opponent) | \(myScore)-\(oppScore)")
        }

        // Clip-from-wrist sync: armed state (rides in the snapshot + pushed on change)
        // and the save confirmation.
        if let armed = message[WatchMessage.clipStatus] as? Bool { phoneClipArmed = armed }
        if let teams = message[WatchMessage.teams] as? [String], !teams.isEmpty { myTeams = teams }

        // Team fouls/timeouts tally from the phone (absolute values).
        if message[WatchMessage.teamTally] != nil {
            if let v = message[WatchMessage.homeFouls] as? Int    { homeFouls = v }
            if let v = message[WatchMessage.awayFouls] as? Int    { awayFouls = v }
            if let v = message[WatchMessage.homeTimeouts] as? Int { homeTimeouts = v }
            if let v = message[WatchMessage.awayTimeouts] as? Int { awayTimeouts = v }
        }

        // Clip-saved confirmation via monotonic counter (reliable across both channels).
        // First value of a game baselines silently; only a genuine increase drives "Clipped ✓".
        if let count = message[WatchMessage.clipSavedCount] as? Int {
            if lastClipSavedCount < 0 {
                lastClipSavedCount = count
            } else if count > lastClipSavedCount {
                lastClipSavedCount = count
                clipSavedTick += 1
            }
        }

        // Warmup indicator: honor the phone's flag, but a running clock always wins
        // (belt-and-suspenders in case a stale warmup:true arrives out of order).
        if let warm = message[WatchMessage.warmup] as? Bool { isWarmup = warm && !isClockRunning }
        if isClockRunning { isWarmup = false }

        // Score update from phone
        if message[WatchMessage.scoreUpdate] != nil {
            if let my = message[WatchMessage.myScore] as? Int {
                myScore = my
            }
            if let opp = message[WatchMessage.oppScore] as? Int {
                oppScore = opp
            }
        }

        // Clock update from phone — apply wall clock timestamps if present
        if message[WatchMessage.clockUpdate] != nil {
            applyClockState(from: message)
        }

        // End game from phone
        if message[WatchMessage.endGame] != nil {
            hasActiveGame = false
            isClockRunning = false   // stops the watch's independent local timer
            clockStartedAt = 0
            phoneClipArmed = false
            isWarmup = false
            isEnding = false
            lastClipSavedCount = -1  // re-baseline for the next game
            homeFouls = 0; awayFouls = 0; homeTimeouts = 0; awayTimeouts = 0
        }

        // Period update from phone
        if message[WatchMessage.periodUpdate] != nil {
            if let per = message[WatchMessage.period] as? String   { period = per }
            if let idx = message[WatchMessage.periodIndex] as? Int { periodIndex = idx }
            applyClockState(from: message)
        }

        // Upcoming games from phone (calendar sync)
        if message[WatchMessage.upcomingGames] != nil,
           let gamesString = message[WatchMessage.games] as? String,
           let gamesData = gamesString.data(using: .utf8) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                let games = try decoder.decode([WatchGame].self, from: gamesData)
                upcomingGames = games
                debugPrint("[Watch] Received \(games.count) upcoming games")
            } catch {
                debugPrint("[Watch] Error decoding games: \(error)")
            }
        }
    }

    /// Apply clock state from a message or snapshot.
    /// Uses wall clock timestamps when available (zero drift).
    /// Falls back to remainingSeconds directly when clock is paused.
    @MainActor
    private func applyClockState(from message: [String: Any]) {
        let startedAt = message["clockStartedAt"] as? TimeInterval ?? 0
        let secsAtStart = message["secondsAtClockStart"] as? Int ?? 0
        let running = message[WatchMessage.isRunning] as? Bool ?? false

        if running && startedAt > 0 {
            // Clock is running — compute remaining from wall clock, zero drift
            clockStartedAt = startedAt
            secondsAtClockStart = secsAtStart
            let elapsed = Int(Date().timeIntervalSince1970 - startedAt)
            remainingSeconds = max(0, secsAtStart - elapsed)
            isClockRunning = true
        } else {
            // Clock is paused — use the explicit remaining seconds value
            clockStartedAt = 0
            secondsAtClockStart = 0
            if let secs = message[WatchMessage.remainingSeconds] as? Int {
                remainingSeconds = secs
            }
            isClockRunning = false
        }
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension WatchConnectivityClient: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        Task { @MainActor in
            debugPrint("[Watch] Extended runtime session invalidated: \(reason.rawValue), error: \(String(describing: error))")
            self.extendedSession = nil
        }
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            debugPrint("[Watch] Extended runtime session started")
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            debugPrint("[Watch] Extended runtime session expiring soon")
            // Could notify user or try to restart? Usually it lasts 1 hour.
        }
    }
}
