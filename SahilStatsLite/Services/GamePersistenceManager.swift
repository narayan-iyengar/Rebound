//
//  GamePersistenceManager.swift
//  SahilStatsLite
//
//  PURPOSE: Local disk persistence and Firebase sync for games. Saves games as
//           JSON to Documents directory, syncs with Firestore when signed in.
//           Provides career stats aggregation (PPG, RPG, APG, win rate).
//  KEY TYPES: GamePersistenceManager (singleton, @MainActor)
//  DEPENDS ON: FirebaseService, AuthService, Game
//
//  NOTE: Keep this header updated when modifying this file.
//

import Foundation
import SwiftUI
import Combine

@MainActor
class GamePersistenceManager: ObservableObject {
    static let shared = GamePersistenceManager()

    @Published private(set) var savedGames: [Game] = []
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncTime: Date?
    @Published var syncError: String?

    private let fileManager = FileManager.default
    private var authCancellable: AnyCancellable?
    private var firebaseCancellable: AnyCancellable?

    private var gamesFileURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("games.json")
    }

    private init() {
        loadGames()
        setupFirebaseSync()
        setupYouTubeListener()
    }
    
    private func setupYouTubeListener() {
        YouTubeService.shared.onUploadCompleted = { [weak self] gameID, success, videoID in
            self?.handleUploadCompletion(gameID: gameID, success: success, videoID: videoID)
        }
    }
    
    private func handleUploadCompletion(gameID: String, success: Bool, videoID: String?) {
        guard let index = savedGames.firstIndex(where: { $0.id == gameID }) else { return }
        var game = savedGames[index]
        
        if success {
            debugPrint("✅ [Persistence] Upload success for game \(gameID).")
            game.youtubeStatus = .uploaded

            if let vid = videoID {
                game.youtubeVideoId = vid
            }

            // KEEP the local file. YouTube can mark a video as "Processing abandoned"
            // hours or days after upload — when that happens, the local copy is the
            // fastest re-upload path (Photos backup may be in iCloud and slow to fetch).
            // Storage cleanup is handled manually from the Game Details sheet.
        } else {
            debugPrint("❌ [Persistence] Upload failed for game \(gameID).")
            game.youtubeStatus = .failed
        }
        
        saveGame(game)
    }

    // MARK: - Firebase Sync Setup

    private func setupFirebaseSync() {
        // Listen to auth changes
        authCancellable = AuthService.shared.$isSignedIn
            .removeDuplicates()
            .sink { [weak self] isSignedIn in
                Task { @MainActor in
                    if isSignedIn {
                        self?.startFirebaseSync()
                    } else {
                        self?.stopFirebaseSync()
                    }
                }
            }

        // Listen to Firebase game updates
        FirebaseService.shared.onGamesUpdated = { [weak self] firebaseGames in
            Task { @MainActor in
                self?.mergeFirebaseGames(firebaseGames)
            }
        }
    }

    private func startFirebaseSync() {
        debugPrint("[GamePersistence] Starting Firebase sync...")
        isSyncing = true
        FirebaseService.shared.startListening()
    }

    private func stopFirebaseSync() {
        debugPrint("[GamePersistence] Stopping Firebase sync...")
        FirebaseService.shared.stopListening()
        isSyncing = false
    }

    /// Merge games from Firebase into local storage
    private func mergeFirebaseGames(_ firebaseGames: [Game]) {
        debugPrint("[GamePersistence] Merging \(firebaseGames.count) Firebase games into local storage")

        // 1. Map existing local games for quick lookup and preservation of local-only data
        let localGamesMap = Dictionary(uniqueKeysWithValues: savedGames.map { ($0.id, $0) })
        
        // 2. Track which cloud games we've processed
        var processedCloudIds = Set<String>()
        var mergedGames: [Game] = []
        
        // 3. Process cloud games: update existing local records or add new ones
        for var cloudGame in firebaseGames {
            processedCloudIds.insert(cloudGame.id)
            
            if let localGame = localGamesMap[cloudGame.id] {
                // PRESERVE local-only fields that Firebase doesn't track
                
                // Video URL (Local path)
                if let localURL = localGame.videoURL {
                    cloudGame.videoURL = localURL
                }
                
                // Score Events (Timeline for overlays - not in Firebase)
                if !localGame.scoreEvents.isEmpty {
                    cloudGame.scoreEvents = localGame.scoreEvents
                }
                
                // Video Duration
                if let duration = localGame.videoDuration {
                    cloudGame.videoDuration = duration
                }
                
                // YouTube Upload Status (preserve 'uploading' state which is transient)
                if localGame.youtubeStatus == .uploading && cloudGame.youtubeStatus == .local {
                    cloudGame.youtubeStatus = .uploading
                }
                
                debugPrint("✅ [Merge] Updated local game \(cloudGame.id) (preserved local data)")
            } else {
                debugPrint("ℹ️ [Merge] New cloud game: \(cloudGame.id)")
            }
            
            mergedGames.append(cloudGame)
        }
        
        // 4. PRESERVE local games that haven't synced to Firebase yet
        // In the original code, these were being deleted because only cloud games were kept!
        for localGame in savedGames {
            if !processedCloudIds.contains(localGame.id) {
                mergedGames.append(localGame)
                debugPrint("✅ [Merge] Preserved local-only game (not in cloud yet): \(localGame.id)")
            }
        }

        // 5. Replace and save local storage
        savedGames = mergedGames.sorted { $0.date > $1.date }
        saveAllGamesToFile(savedGames)

        lastSyncTime = Date()
        isSyncing = false
        syncError = nil

        debugPrint("[GamePersistence] Merge complete - total games: \(savedGames.count)")
    }

    // MARK: - Local File Operations

    func loadGames() {
        guard fileManager.fileExists(atPath: gamesFileURL.path) else {
            savedGames = []
            return
        }

        do {
            let data = try Data(contentsOf: gamesFileURL)
            let decoder = JSONDecoder()
            savedGames = try decoder.decode([Game].self, from: data)
            savedGames.sort { $0.date > $1.date } // Most recent first
            debugPrint("[GamePersistence] Loaded \(savedGames.count) local games")
        } catch {
            debugPrint("[GamePersistence] Failed to load games: \(error)")
            savedGames = []
        }
    }

    // MARK: - Save

    func saveGame(_ game: Game) {
        var games = savedGames

        debugPrint("[GamePersistence] saving game \(game.id). URL: \(game.videoURL?.lastPathComponent ?? "nil")")

        // Update existing or add new
        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index] = game
        } else {
            games.insert(game, at: 0)
        }

        // Save locally
        saveAllGamesToFile(games)
        savedGames = games

        // Sync to Firebase if signed in
        if AuthService.shared.isSignedIn {
            Task {
                do {
                    try await FirebaseService.shared.saveGame(game)
                    debugPrint("[GamePersistence] Synced game to Firebase")
                } catch {
                    debugPrint("[GamePersistence] Failed to sync to Firebase: \(error)")
                    self.syncError = error.localizedDescription
                }
            }
        }
    }

    private func saveAllGamesToFile(_ games: [Game]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(games)
            try data.write(to: gamesFileURL)
            debugPrint("[GamePersistence] Saved \(games.count) games to file")
        } catch {
            debugPrint("[GamePersistence] Failed to save games: \(error)")
        }
    }

    // MARK: - Delete

    func deleteGame(_ game: Game) {
        // CLEANUP: Delete local video file if it exists
        if let url = game.videoURL {
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                    debugPrint("🗑️ Deleted local video for game \(game.id)")
                }
            } catch {
                debugPrint("⚠️ Failed to delete video file: \(error)")
            }
        }

        savedGames.removeAll { $0.id == game.id }
        saveAllGamesToFile(savedGames)

        // Sync deletion to Firebase if signed in
        if AuthService.shared.isSignedIn {
            Task {
                do {
                    try await FirebaseService.shared.deleteGame(game.id)
                    debugPrint("[GamePersistence] Deleted game from Firebase")
                } catch {
                    debugPrint("[GamePersistence] Failed to delete from Firebase: \(error)")
                    self.syncError = error.localizedDescription
                }
            }
        }
    }

    func deleteGame(at offsets: IndexSet) {
        let gamesToDelete = offsets.map { savedGames[$0] }
        
        // CLEANUP: Delete local video files
        for game in gamesToDelete {
            if let url = game.videoURL {
                do {
                    if fileManager.fileExists(atPath: url.path) {
                        try fileManager.removeItem(at: url)
                        debugPrint("🗑️ Deleted local video for game \(game.id)")
                    }
                } catch {
                    debugPrint("⚠️ Failed to delete video file: \(error)")
                }
            }
        }
        
        var games = savedGames
        games.remove(atOffsets: offsets)
        saveAllGamesToFile(games)
        savedGames = games

        // Sync deletions to Firebase if signed in
        if AuthService.shared.isSignedIn {
            for game in gamesToDelete {
                Task {
                    do {
                        try await FirebaseService.shared.deleteGame(game.id)
                    } catch {
                        debugPrint("[GamePersistence] Failed to delete from Firebase: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Migration / Clear

    /// Clear all local games (for migration from test data)
    func clearAllLocalGames() {
        savedGames = []
        saveAllGamesToFile([])
        debugPrint("[GamePersistence] Cleared all local games")
    }

    /// Cleanup games that have no video URL (ghost/test games)
    func cleanupGhostGames() async {
        let ghostGames = savedGames.filter { game in
            // A "ghost" game has no video URL AND has zero score (likely a test start)
            // Or just no video URL if you want to be aggressive
            return game.videoURL == nil && game.myScore == 0 && game.opponentScore == 0
        }
        
        debugPrint("[GamePersistence] Found \(ghostGames.count) ghost games to cleanup")
        
        for game in ghostGames {
            // Delete locally
            savedGames.removeAll { $0.id == game.id }
            
            // Delete from Firebase
            if AuthService.shared.isSignedIn {
                do {
                    try await FirebaseService.shared.deleteGame(game.id)
                    debugPrint("[GamePersistence] Deleted ghost game \(game.id) from Firebase")
                } catch {
                    debugPrint("[GamePersistence] Failed to delete ghost game \(game.id) from Firebase: \(error)")
                }
            }
        }
        
        saveAllGamesToFile(savedGames)
        debugPrint("[GamePersistence] Ghost game cleanup complete")
    }

    /// Force sync from Firebase (useful for migration)
    func forceSyncFromFirebase() async {
        guard AuthService.shared.isSignedIn else {
            debugPrint("[GamePersistence] Cannot sync - not signed in")
            return
        }

        isSyncing = true
        syncError = nil

        do {
            let firebaseGames = try await FirebaseService.shared.fetchAllGames()
            mergeFirebaseGames(firebaseGames)
            debugPrint("[GamePersistence] Force sync complete - \(firebaseGames.count) games")
        } catch {
            syncError = error.localizedDescription
            debugPrint("[GamePersistence] Force sync failed: \(error)")
        }

        isSyncing = false
    }

    // MARK: - Career Stats

    var careerGames: Int { savedGames.count }

    var careerWins: Int {
        savedGames.filter { $0.isWin }.count
    }

    var careerLosses: Int {
        savedGames.filter { $0.isLoss }.count
    }

    var careerTies: Int {
        savedGames.filter { $0.isTie }.count
    }

    var careerRecord: String {
        if careerTies > 0 {
            return "\(careerWins)-\(careerLosses)-\(careerTies)"
        }
        return "\(careerWins)-\(careerLosses)"
    }

    // Points
    var careerTotalPoints: Int {
        savedGames.reduce(0) { $0 + $1.playerStats.points }
    }

    var careerPPG: Double {
        careerGames > 0 ? Double(careerTotalPoints) / Double(careerGames) : 0
    }

    // Rebounds
    var careerTotalRebounds: Int {
        savedGames.reduce(0) { $0 + $1.playerStats.rebounds }
    }

    var careerRPG: Double {
        careerGames > 0 ? Double(careerTotalRebounds) / Double(careerGames) : 0
    }

    // Assists
    var careerTotalAssists: Int {
        savedGames.reduce(0) { $0 + $1.playerStats.assists }
    }

    var careerAPG: Double {
        careerGames > 0 ? Double(careerTotalAssists) / Double(careerGames) : 0
    }

    // Steals
    var careerTotalSteals: Int {
        savedGames.reduce(0) { $0 + $1.playerStats.steals }
    }

    var careerSPG: Double {
        careerGames > 0 ? Double(careerTotalSteals) / Double(careerGames) : 0
    }

    // Blocks
    var careerTotalBlocks: Int {
        savedGames.reduce(0) { $0 + $1.playerStats.blocks }
    }

    var careerBPG: Double {
        careerGames > 0 ? Double(careerTotalBlocks) / Double(careerGames) : 0
    }

    // Shooting
    var careerFGMade: Int {
        savedGames.reduce(0) { $0 + $1.playerStats.totalFGMade }
    }

    var careerFGAttempted: Int {
        savedGames.reduce(0) { $0 + $1.playerStats.totalFGAttempted }
    }

    var careerFGPercentage: Double {
        careerFGAttempted > 0 ? Double(careerFGMade) / Double(careerFGAttempted) * 100 : 0
    }

    var career3PMade: Int {
        savedGames.reduce(0) { $0 + $1.playerStats.fg3Made }
    }

    var career3PAttempted: Int {
        savedGames.reduce(0) { $0 + $1.playerStats.fg3Attempted }
    }

    var career3PPercentage: Double {
        career3PAttempted > 0 ? Double(career3PMade) / Double(career3PAttempted) * 100 : 0
    }

    var careerFTMade: Int {
        savedGames.reduce(0) { $0 + $1.playerStats.ftMade }
    }

    var careerFTAttempted: Int {
        savedGames.reduce(0) { $0 + $1.playerStats.ftAttempted }
    }

    var careerFTPercentage: Double {
        careerFTAttempted > 0 ? Double(careerFTMade) / Double(careerFTAttempted) * 100 : 0
    }
}
