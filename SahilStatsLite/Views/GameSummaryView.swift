//
//  GameSummaryView.swift
//  SahilStatsLite
//
//  PURPOSE: Post-game summary screen. Shows final score, Sahil's stats,
//           shooting percentages (FG%, 3P%, FT%, eFG%, TS%). Auto-saves
//           video to Photos library.
//  KEY TYPES: GameSummaryView
//  DEPENDS ON: RecordingManager, AppState
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import Photos

struct GameSummaryView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var recordingManager = RecordingManager.shared

    // Save state
    @State private var saveStatus: SaveStatus = .idle

    enum SaveStatus {
        case idle
        case saving
        case saved
        case failed(String)
    }

    @State private var showHighlights = false

    var game: Game? {
        appState.currentGame
    }

    var videoURL: URL? {
        recordingManager.getRecordingURL()
    }

    var gameClipCount: Int {
        guard let game else { return 0 }
        return HighlightStore.shared.clips(forGameId: game.id).count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Result Header
                resultHeader

                // Score Card
                scoreCard

                // Player Stats (Sahil's performance)
                if let game = game {
                    playerStatsSection(stats: game.playerStats)
                }

                // Review this game's saved clips
                if gameClipCount > 0 {
                    ChalkButton(title: "Review Highlights", icon: "film.stack", color: Chalk.sky) {
                        showHighlights = true
                    }
                }

                // Save status (minimal)
                saveStatusView

                // Done button
                doneButton

                Spacer(minLength: 40)
            }
            .padding()
        }
        .chalkBoard()
        .navigationBarHidden(true)
        .sheet(isPresented: $showHighlights) {
            GameHighlightsSheet(gameId: game?.id ?? "")
        }
        .task {
            // Auto-save video to Photos when view appears
            await autoSaveVideo()
        }
    }

    // MARK: - Auto Save

    private func autoSaveVideo() async {
        guard let url = videoURL else {
            saveStatus = .saved // No video, nothing to save - that's fine
            return
        }

        saveStatus = .saving

        let success = await saveVideoToLibrary(url: url)
        await MainActor.run {
            if success {
                saveStatus = .saved
            } else {
                saveStatus = .failed("Couldn't save to Photos")
            }
        }
    }

    private func saveVideoToLibrary(url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            debugPrint("❌ Video file doesn't exist at: \(url.path)")
            return false
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    debugPrint("❌ Photo library access denied: \(status)")
                    continuation.resume(returning: false)
                    return
                }

                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } completionHandler: { success, error in
                    if let error = error {
                        debugPrint("❌ Failed to save to photos: \(error)")
                    } else {
                        debugPrint("✅ Video saved to Photos successfully")
                    }
                    continuation.resume(returning: success)
                }
            }
        }
    }

    // MARK: - Result Header

    private var resultHeader: some View {
        VStack(spacing: 10) {
            // Rotated chalk stamp — the emotional headline, hand font as accent.
            Text(resultText)
                .font(.chalkScript(44))
                .foregroundColor(resultColor)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(resultColor.opacity(0.7),
                                      style: StrokeStyle(lineWidth: 3, dash: [7, 5]))
                )
                .rotationEffect(.degrees(-4))

            if let game = game {
                Text(game.date, style: .date)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Chalk.dust)
            }
        }
        .padding(.top, 24)
    }

    private var resultColor: Color {
        guard let game = game else { return Chalk.chalk }
        if game.isWin { return Chalk.green }
        if game.isLoss { return Chalk.coral }
        return Chalk.yellow
    }

    private var resultText: String {
        guard let game = game else { return "" }
        if game.isWin { return "WIN" }
        if game.isLoss { return "TOUGH LOSS" }
        return "TIE GAME"
    }

    // MARK: - Score Card

    private var scoreCard: some View {
        HStack(spacing: 0) {
            // My Team
            VStack(spacing: 8) {
                Text(game?.teamName ?? "Home")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Chalk.sky)
                    .lineLimit(1)

                ScoreText(value: "\(game?.myScore ?? 0)", size: 48)
            }
            .frame(maxWidth: .infinity)

            // Separator
            Text("–")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(Chalk.dust)

            // Opponent
            VStack(spacing: 8) {
                Text(game?.opponent ?? "Away")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Chalk.coral)
                    .lineLimit(1)

                ScoreText(value: "\(game?.opponentScore ?? 0)", size: 48)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
    }

    // MARK: - Player Stats Section

    private func playerStatsSection(stats: PlayerStats) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sahil's Performance")
                .font(.chalkScript(24))
                .foregroundColor(Chalk.chalk)

            VStack(spacing: 16) {
                // Main Stats Row
                HStack(spacing: 0) {
                    statBox(value: "\(stats.points)", label: "PTS", color: Chalk.yellow)
                    statBox(value: "\(stats.rebounds)", label: "REB", color: Chalk.sky)
                    statBox(value: "\(stats.assists)", label: "AST", color: Chalk.green)
                    statBox(value: "\(stats.steals)", label: "STL", color: Chalk.chalkDim)
                    statBox(value: "\(stats.blocks)", label: "BLK", color: Chalk.coral)
                    if gameClipCount > 0 {
                        statBox(value: "\(gameClipCount)", label: "CLIPS", color: Chalk.coral)
                    }
                }

                Divider().overlay(Chalk.chalk.opacity(0.15))

                // Shooting Stats
                VStack(spacing: 12) {
                    Text("Shooting")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Chalk.dust)

                    HStack(spacing: 16) {
                        shootingStat(
                            label: "2PT",
                            made: stats.fg2Made,
                            attempted: stats.fg2Attempted,
                            percentage: stats.fg2Percentage
                        )
                        shootingStat(
                            label: "3PT",
                            made: stats.fg3Made,
                            attempted: stats.fg3Attempted,
                            percentage: stats.fg3Percentage
                        )
                        shootingStat(
                            label: "FT",
                            made: stats.ftMade,
                            attempted: stats.ftAttempted,
                            percentage: stats.ftPercentage
                        )
                    }

                    // Advanced stats row
                    HStack(spacing: 24) {
                        advancedStat(value: String(format: "%.1f%%", stats.fgPercentage), label: "FG%")
                        advancedStat(value: String(format: "%.1f%%", stats.efgPercentage), label: "eFG%")
                        advancedStat(value: String(format: "%.1f%%", stats.tsPercentage), label: "TS%")
                    }
                    .padding(.top, 4)
                }

                // Other Stats
                if stats.turnovers > 0 || stats.fouls > 0 {
                    Divider().overlay(Chalk.chalk.opacity(0.15))
                    HStack(spacing: 24) {
                        if stats.turnovers > 0 {
                            HStack(spacing: 4) {
                                Text("\(stats.turnovers)")
                                    .font(.system(size: 15, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(Chalk.crisp)
                                Text("TO")
                                    .font(.system(size: 15))
                                    .foregroundColor(Chalk.dust)
                            }
                        }
                        if stats.fouls > 0 {
                            HStack(spacing: 4) {
                                Text("\(stats.fouls)")
                                    .font(.system(size: 15, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(Chalk.crisp)
                                Text("PF")
                                    .font(.system(size: 15))
                                    .foregroundColor(Chalk.dust)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
        }
    }

    private func statBox(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Chalk.dust)
        }
        .frame(maxWidth: .infinity)
    }

    private func advancedStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(Chalk.crisp)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Chalk.dust)
        }
    }

    private func shootingStat(label: String, made: Int, attempted: Int, percentage: Double) -> some View {
        VStack(spacing: 4) {
            Text("\(made)/\(attempted)")
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(Chalk.crisp)
            Text(String(format: "%.0f%%", percentage))
                .font(.system(size: 12))
                .foregroundColor(percentage >= 50 ? Chalk.green : percentage >= 33 ? Chalk.yellow : Chalk.dust)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Chalk.dust)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Save Status

    private var saveStatusView: some View {
        Group {
            switch saveStatus {
            case .idle:
                EmptyView()
            case .saving:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(Chalk.chalk)
                    Text("Saving video...")
                        .font(.system(size: 15))
                        .foregroundColor(Chalk.dust)
                }
            case .saved:
                Label("Video saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(Chalk.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(Chalk.coral)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Done Button

    private var doneButton: some View {
        ChalkButton(title: "Done", icon: "checkmark", color: Chalk.yellow) {
            appState.goHome()
        }
    }
}

#Preview {
    let appState = AppState()
    appState.currentGame = Game(opponent: "Thunder", teamName: "Wildcats")
    appState.currentGame?.myScore = 24
    appState.currentGame?.opponentScore = 18

    // Add sample player stats
    appState.currentGame?.playerStats = PlayerStats(
        fg2Made: 4,
        fg2Attempted: 8,
        fg3Made: 2,
        fg3Attempted: 5,
        ftMade: 3,
        ftAttempted: 4,
        assists: 3,
        rebounds: 5,
        steals: 2,
        blocks: 1,
        turnovers: 2,
        fouls: 1
    )

    return GameSummaryView()
        .environmentObject(appState)
}
