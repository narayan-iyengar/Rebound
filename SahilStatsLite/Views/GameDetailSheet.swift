//
//  GameDetailSheet.swift
//  SahilStatsLite
//
//  PURPOSE: Game detail view showing final score, YouTube upload controls,
//           video import from Photos, player stats, and edit access.
//  KEY TYPES: GameDetailSheet
//  DEPENDS ON: YouTubeService, GamePersistenceManager, EditGameView
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// File-URL-based transferable for video import. Avoids loading the entire
/// multi-GB file into RAM (which `Data.self` does). Photos hands us a temp
/// file URL we copy into Documents.
private struct ImportedVideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            // received.file is a system-managed temp URL that vanishes when this
            // closure returns. Copy it into our own temp dir so the caller can
            // move it to its final destination on the main thread.
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked_\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

// MARK: - Game Detail Sheet

struct GameDetailSheet: View {
    let gameId: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var youtubeService = YouTubeService.shared
    @ObservedObject private var persistenceManager = GamePersistenceManager.shared

    // Edit state
    @State private var showEditSheet = false

    // Video picker state
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var isImportingVideo = false

    // Fetch live game object to ensure updates reflect immediately
    var game: Game {
        persistenceManager.savedGames.first(where: { $0.id == gameId }) ?? Game(opponent: "Unknown")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Chalk header replaces the system nav bar.
                HStack {
                    Text("Game Details")
                        .font(.chalkScript(28))
                        .foregroundColor(Chalk.chalk)

                    Spacer()

                    Button("Edit") {
                        showEditSheet = true
                    }
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(Chalk.yellow)

                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Chalk.chalk)
                    }
                    .padding(.leading, 8)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ScrollView {
                    VStack(spacing: 20) {
                    // Result Header
                    VStack(spacing: 8) {
                        Text(game.isWin ? "Victory" : (game.isLoss ? "Defeat" : "Tie"))
                            .font(.chalkScript(30))
                            .foregroundColor(game.isWin ? Chalk.green : (game.isLoss ? Chalk.coral : Chalk.yellow))

                        ScoreText(value: game.scoreString, size: 48)

                        Text("vs \(game.opponent)")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Chalk.dust)

                        Text(game.date.formatted(date: .long, time: .omitted))
                            .font(.system(size: 12))
                            .foregroundColor(Chalk.dust)
                    }
                    .padding()

                    // YouTube Upload Section
                    VStack(spacing: 12) {
                        if game.youtubeStatus == .uploaded {
                            VStack(spacing: 12) {
                                Label("Uploaded to YouTube", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Chalk.green)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Chalk.green.opacity(0.12))
                                    .cornerRadius(12)

                                if let videoID = game.youtubeVideoId {
                                    Button {
                                        if let url = URL(string: "https://youtu.be/\(videoID)") {
                                            UIApplication.shared.open(url)
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: "play.rectangle.fill")
                                            Text("Watch on YouTube")
                                        }
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(Chalk.coral)
                                        .padding(.vertical, 8)
                                    }
                                }

                                // Re-upload recovery: YouTube can flip a video to
                                // "Processing abandoned" days later, even though we
                                // recorded it as uploaded. Pick a backup from Photos —
                                // importVideo() resets youtubeStatus to .local, which
                                // exposes the Upload button on the next render.
                                if isImportingVideo {
                                    ProgressView("Importing replacement…")
                                        .tint(Chalk.chalk)
                                        .foregroundColor(Chalk.dust)
                                } else {
                                    PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                                        Label("Re-upload with a different video", systemImage: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 12))
                                            .foregroundColor(Chalk.sky)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                    }
                                    .onChange(of: selectedVideoItem) { _, newItem in
                                        if let newItem { importVideo(from: newItem) }
                                    }
                                }

                                // Manual storage cleanup. Local copy is kept after upload
                                // (in case YouTube fails server-side), but the user can
                                // free space once they're confident the upload is good.
                                if let url = resolveVideoURL(for: game),
                                   let size = localFileSize(at: url) {
                                    Button(role: .destructive) {
                                        deleteLocalFile(url: url)
                                    } label: {
                                        Label("Delete local file (\(size))", systemImage: "trash")
                                            .font(.system(size: 12))
                                            .foregroundColor(Chalk.coral)
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        } else if youtubeService.isUploading && youtubeService.currentUploadingGameID == game.id {
                            VStack(spacing: 8) {
                                ProgressView(value: youtubeService.uploadProgress)
                                    .tint(Chalk.sky)
                                HStack {
                                    Text("Uploading to YouTube...")
                                        .font(.system(size: 12))
                                        .foregroundColor(Chalk.dust)
                                    Spacer()
                                    Button("Cancel") {
                                        youtubeService.cancelUpload()
                                    }
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Chalk.coral)
                                }
                            }
                            .padding()
                            .background(Chalk.board2)
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
                        } else {
                            if let url = resolveVideoURL(for: game) {
                                ChalkButton(title: game.youtubeStatus == .failed ? "Retry Upload" : "Upload to YouTube",
                                            icon: "square.and.arrow.up", color: Chalk.yellow) {
                                    startUpload(url: url)
                                }

                                // Recovery path: swap in a different video file (e.g. when
                                // the recorded one is corrupt or already failed YouTube
                                // server-side processing). Pick from Photos, replace the
                                // game's videoURL, then the Upload button above retries.
                                if isImportingVideo {
                                    ProgressView("Importing replacement…")
                                        .tint(Chalk.chalk)
                                        .foregroundColor(Chalk.dust)
                                } else {
                                    PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                                        Label("Use a different video from Photos", systemImage: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 12))
                                            .foregroundColor(Chalk.sky)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                    }
                                    .onChange(of: selectedVideoItem) { _, newItem in
                                        if let newItem { importVideo(from: newItem) }
                                    }
                                }

                                if let error = youtubeService.lastError {
                                    Text(error)
                                        .font(.system(size: 12))
                                        .foregroundColor(Chalk.coral)
                                }
                            } else {
                                // Video missing - offer picker
                                VStack(spacing: 12) {
                                    Text("Video file not found")
                                        .font(.system(size: 12))
                                        .foregroundColor(Chalk.dust)

                                    if isImportingVideo {
                                        ProgressView("Importing...")
                                            .tint(Chalk.chalk)
                                            .foregroundColor(Chalk.dust)
                                    } else {
                                        PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                                            Label("Select Video from Photos", systemImage: "photo.on.rectangle")
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundColor(Chalk.chalk)
                                                .frame(maxWidth: .infinity)
                                                .padding()
                                                .background(Chalk.board.opacity(0.6))
                                                .cornerRadius(12)
                                        }
                                        .onChange(of: selectedVideoItem) { _, newItem in
                                            if let newItem {
                                                importVideo(from: newItem)
                                            }
                                        }
                                    }
                                }
                                .padding()
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Player Stats
                    VStack(spacing: 16) {
                        Text("Player Stats")
                            .font(.chalkScript(22))
                            .foregroundColor(Chalk.chalk)

                        HStack(spacing: 0) {
                            statBox(value: "\(game.playerStats.points)", label: "PTS", color: Chalk.yellow)
                            statBox(value: "\(game.playerStats.rebounds)", label: "REB", color: Chalk.sky)
                            statBox(value: "\(game.playerStats.assists)", label: "AST", color: Chalk.green)
                            statBox(value: "\(game.playerStats.steals)", label: "STL", color: Chalk.chalkDim)
                            statBox(value: "\(game.playerStats.blocks)", label: "BLK", color: Chalk.coral)
                        }

                        // Shooting
                        HStack(spacing: 20) {
                            shootingStat(label: "2PT", made: game.playerStats.fg2Made, attempted: game.playerStats.fg2Attempted)
                            shootingStat(label: "3PT", made: game.playerStats.fg3Made, attempted: game.playerStats.fg3Attempted)
                            shootingStat(label: "FT", made: game.playerStats.ftMade, attempted: game.playerStats.ftAttempted)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
                    }
                    .padding()
                }
            }
            .chalkBoard()
            .navigationBarHidden(true)
            .sheet(isPresented: $showEditSheet) {
                // Pass binding that saves via persistence manager
                if let index = persistenceManager.savedGames.firstIndex(where: { $0.id == gameId }) {
                    EditGameView(game: Binding(
                        get: { persistenceManager.savedGames[index] },
                        set: { persistenceManager.saveGame($0) }
                    ))
                }
            }
        }
    }

    private func importVideo(from item: PhotosPickerItem) {
        isImportingVideo = true
        selectedVideoItem = nil  // reset so re-picking the same video works

        Task {
            defer { Task { @MainActor in isImportingVideo = false } }
            do {
                // File-based transfer: no in-memory buffer. For a 4K 41-min game
                // this used to allocate 3–5 GB of RAM via Data.self and either
                // hang or get killed by the OS.
                guard let imported = try await item.loadTransferable(type: ImportedVideoFile.self) else {
                    debugPrint("Picker returned nil video file")
                    return
                }

                // Move into Documents under the game's stable filename
                let filename = "imported_\(game.id).mov"
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destinationURL = documentsPath.appendingPathComponent(filename)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: imported.url, to: destinationURL)

                await MainActor.run {
                    var updatedGame = game
                    updatedGame.videoURL = destinationURL
                    updatedGame.youtubeStatus = .local
                    // Clear stale YouTube video ID so the next upload registers
                    // a fresh one (otherwise UI keeps linking to the broken video)
                    updatedGame.youtubeVideoId = nil
                    persistenceManager.saveGame(updatedGame)
                    debugPrint("Video imported successfully: \(destinationURL.path)")
                }
            } catch {
                debugPrint("Failed to import video: \(error)")
            }
        }
    }

    private func localFileSize(at url: URL) -> String? {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else { return nil }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1000 {
            return String(format: "%.1f GB", mb / 1000)
        }
        return String(format: "%.0f MB", mb)
    }

    private func deleteLocalFile(url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            var updatedGame = game
            updatedGame.videoURL = nil
            persistenceManager.saveGame(updatedGame)
            debugPrint("[Cleanup] Deleted local video: \(url.path)")
        } catch {
            debugPrint("[Cleanup] Failed to delete: \(error)")
        }
    }

    private func resolveVideoURL(for game: Game) -> URL? {
        guard let url = game.videoURL else { return nil }

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let filename = url.lastPathComponent
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let newURL = documentsPath.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: newURL.path) {
            return newURL
        }

        return nil
    }

    private func startUpload(url: URL) {
        let title = "\(game.teamName) vs \(game.opponent) - \(game.date.formatted(date: .abbreviated, time: .omitted))"
        let description = """
        \(game.teamName) \(game.myScore) - \(game.opponentScore) \(game.opponent)

        Recorded with Rebound
        """

        var updatedGame = game
        updatedGame.youtubeStatus = .uploading
        persistenceManager.saveGame(updatedGame)

        Task {
            await youtubeService.uploadVideo(url: url, title: title, description: description, gameID: game.id)

            if youtubeService.lastError == nil {
                var finishedGame = game
                finishedGame.youtubeStatus = .uploaded
                persistenceManager.saveGame(finishedGame)
            } else {
                var failedGame = game
                failedGame.youtubeStatus = .failed
                persistenceManager.saveGame(failedGame)
            }
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

    private func shootingStat(label: String, made: Int, attempted: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(made)/\(attempted)")
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(Chalk.crisp)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Chalk.dust)
        }
        .frame(maxWidth: .infinity)
    }
}
