//
//  SahilStatsLiteApp.swift
//  SahilStatsLite
//
//  PURPOSE: App entry point, root navigation, and global state management.
//           AppDelegate initializes Firebase and WatchConnectivity at launch.
//           ContentView manages NavigationStack for screen transitions.
//  KEY TYPES: SahilStatsLiteApp, AppDelegate, ContentView, AppState
//  DEPENDS ON: FirebaseService, WatchConnectivityService, GamePersistenceManager
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import FirebaseCore
import GoogleSignIn
import Combine
import CoreText

@main
struct SahilStatsLiteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // Build stamp — compare with Watch console output to confirm both are in sync.
        debugPrint("📱 [iOS] Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?") | \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?")")

        // Register the bundled hand-chalk fonts (Caveat + Gochi Hand) at runtime.
        // Belt-and-suspenders alongside Info.plist's UIAppFonts, so ChalkTheme's
        // Font.chalkScript/.chalkHand always resolve regardless of plist path quirks.
        ChalkFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()

        // Start WatchConnectivity session
        _ = WatchConnectivityService.shared
        debugPrint("[AppDelegate] WatchConnectivity service initialized")

        // Start WiFi auto-upload monitor
        Task { @MainActor in
            WiFiUploadManager.shared.startMonitoring()
        }

        return true
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var appState = AppState()
    @ObservedObject private var watchService = WatchConnectivityService.shared

    var body: some View {
        NavigationStack {
            switch appState.currentScreen {
            case .home:
                HomeView()
                    .environmentObject(appState)

            case .setup:
                GameSetupView()
                    .environmentObject(appState)

            case .recording:
                UltraMinimalRecordingView()
                    .environmentObject(appState)

            case .statsEntry:
                ManualGameEntryView()
                    .environmentObject(appState)

            case .summary:
                GameSummaryView()
                    .environmentObject(appState)

            case .practice:
                PracticeView()
                    .environmentObject(appState)
            }
        }
        .onChange(of: watchService.pendingGameFromWatch) { _, newGame in
            // Watch triggered a game start - navigate to recording
            if let game = newGame {
                debugPrint("[ContentView] 📱 Starting game from Watch: \(game.teamName) vs \(game.opponent)")
                appState.startGameFromWatch(game)
                // Clear the pending game so it doesn't re-trigger
                watchService.pendingGameFromWatch = nil
            }
        }
    }
}

// MARK: - App State

class AppState: ObservableObject {
    @MainActor @Published var currentScreen: Screen = .home
    @MainActor @Published var currentGame: Game?

    // Log-only mode (no video recording, enter stats after game)
    @MainActor @Published var isLogOnly: Bool = false

    // Stats-only mode (live stats without video recording)
    @MainActor @Published var isStatsOnly: Bool = false

    // Pre-fill data from calendar (cleared after use)
    @MainActor @Published var pendingCalendarGame: (opponent: String, location: String, team: String?)?

    /// Set when the post-recording Photos save fails. Surfaced as an alert on
    /// Home so the user knows the only backup is the local Documents file.
    @MainActor @Published var photosSaveFailureMessage: String?

    // Recent games now come from persistence
    var recentGames: [Game] {
        GamePersistenceManager.shared.savedGames
    }

    enum Screen {
        case home
        case setup
        case recording
        case statsEntry  // Manual stats entry (no video)
        case summary
        case practice    // Clip-only practice session (no game/score)
    }

    @MainActor
    func startPractice() {
        currentGame = nil
        currentScreen = .practice
    }

    @MainActor
    func startNewGame(opponent: String, teamName: String, location: String?) {
        currentGame = Game(opponent: opponent, teamName: teamName, location: location)
        currentScreen = .recording
    }

    @MainActor
    func startGameFromWatch(_ watchGame: WatchGame) {
        // Prevent overwriting an active game
        if currentScreen == .recording && currentGame != nil {
            debugPrint("[AppState] ⚠️ Watch requested start game, but recording already in progress. Resyncing Watch.")
            // Send current state to resync the Watch that thinks it's starting a new one
            // UltraMinimalRecordingView handles the actual live state, but we can nudge it here
            // by triggering a resync if we have a way to call into the view.
            // Actually, the WatchService singleton is global, so we can use that.
            return
        }
        
        // Create game from Watch data
        var game = Game(
            opponent: watchGame.opponent,
            teamName: watchGame.teamName,
            location: watchGame.location.isEmpty ? nil : watchGame.location
        )
        game.halfLength = watchGame.halfLength

        currentGame = game
        currentScreen = .recording

        // Confirm acceptance to the wrist immediately — don't wait for the record view to
        // spin up the camera. The watch entered the game optimistically; this snapshot makes
        // the phone the source of truth right away (team/clock/warmup) so there's no "did it
        // take?" gap, and it seeds the sticky context in case the watch relaunches.
        WatchConnectivityService.shared.sendGameState(
            teamName: game.teamName, opponent: game.opponent,
            myScore: 0, oppScore: 0,
            remainingSeconds: game.halfLength * 60, isClockRunning: false,
            period: "1st Half", periodIndex: 0,
            clockStartedAt: 0, secondsAtClockStart: 0,
            warmup: true
        )

        debugPrint("[AppState] 📱 Started game from Watch: \(game.teamName) vs \(game.opponent), \(game.halfLength) min halves")
    }

    @MainActor
    func endGame() {
        if var game = currentGame {
            game.completedAt = Date()
            game.videoURL = RecordingManager.shared.getRecordingURL()
            // Game is saved by UltraMinimalRecordingView before calling this
            currentScreen = .summary
        }
    }

    @MainActor
    func goHome() {
        currentGame = nil
        currentScreen = .home
    }
}
