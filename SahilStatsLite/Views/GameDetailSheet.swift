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
            ScrollView {
                VStack(spacing: 20) {
                    // Result Header
                    VStack(spacing: 8) {
                        Text(game.isWin ? "Victory" : (game.isLoss ? "Defeat" : "Tie"))
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(game.isWin ? .green : (game.isLoss ? .red : .orange))

                        Text(game.scoreString)
                            .font(.system(size: 48, weight: .bold, design: .rounded))

                        Text("vs \(game.opponent)")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Text(game.date.formatted(date: .long, time: .omitted))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()

                    // YouTube Upload Section
                    VStack(spacing: 12) {
                        if game.youtubeStatus == .uploaded {
                            VStack(spacing: 12) {
                                Label("Uploaded to YouTube", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .foregroundColor(.green)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.green.opacity(0.1))
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
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.red)
                                        .padding(.vertical, 8)
                                    }
                                }
                            }
                        } else if youtubeService.isUploading && youtubeService.currentUploadingGameID == game.id {
                            VStack(spacing: 8) {
                                ProgressView(value: youtubeService.uploadProgress)
                                    .tint(.blue)
                                HStack {
                                    Text("Uploading to YouTube...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button("Cancel") {
                                        youtubeService.cancelUpload()
                                    }
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.red)
                                }
                            }
                            .padding()
                            .background(Color(.systemBackground))
                            .cornerRadius(12)
                        } else {
                            if let url = resolveVideoURL(for: game) {
                                Button {
                                    startUpload(url: url)
                                } label: {
                                    HStack {
                                        Image(systemName: "square.and.arrow.up")
                                        Text(game.youtubeStatus == .failed ? "Retry Upload" : "Upload to YouTube")
                                    }
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                }

                                // Recovery path: swap in a different video file (e.g. when
                                // the recorded one is corrupt or already failed YouTube
                                // server-side processing). Pick from Photos, replace the
                                // game's videoURL, then the Upload button above retries.
                                if isImportingVideo {
                                    ProgressView("Importing replacement…")
                                } else {
                                    PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                                        Label("Use a different video from Photos", systemImage: "arrow.triangle.2.circlepath")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                    }
                                    .onChange(of: selectedVideoItem) { _, newItem in
                                        if let newItem { importVideo(from: newItem) }
                                    }
                                }

                                if let error = youtubeService.lastError {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            } else {
                                // Video missing - offer picker
                                VStack(spacing: 12) {
                                    Text("Video file not found")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    if isImportingVideo {
                                        ProgressView("Importing...")
                                    } else {
                                        PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                                            Label("Select Video from Photos", systemImage: "photo.on.rectangle")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                                .frame(maxWidth: .infinity)
                                                .padding()
                                                .background(Color(.systemGray5))
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
                            .font(.headline)

                        HStack(spacing: 0) {
                            statBox(value: "\(game.playerStats.points)", label: "PTS", color: .orange)
                            statBox(value: "\(game.playerStats.rebounds)", label: "REB", color: .blue)
                            statBox(value: "\(game.playerStats.assists)", label: "AST", color: .green)
                            statBox(value: "\(game.playerStats.steals)", label: "STL", color: .teal)
                            statBox(value: "\(game.playerStats.blocks)", label: "BLK", color: .purple)
                        }

                        // Shooting
                        HStack(spacing: 20) {
                            shootingStat(label: "2PT", made: game.playerStats.fg2Made, attempted: game.playerStats.fg2Attempted)
                            shootingStat(label: "3PT", made: game.playerStats.fg3Made, attempted: game.playerStats.fg3Attempted)
                            shootingStat(label: "FT", made: game.playerStats.ftMade, attempted: game.playerStats.ftAttempted)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Game Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button("Edit") {
                            showEditSheet = true
                        }
                        Button("Done") { dismiss() }
                    }
                }
            }
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

        item.loadTransferable(type: Data.self) { result in
            DispatchQueue.main.async {
                isImportingVideo = false

                switch result {
                case .success(let data):
                    guard let data = data else { return }

                    // Save to Documents
                    let filename = "imported_\(game.id).mov"
                    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let destinationURL = documentsPath.appendingPathComponent(filename)

                    do {
                        try data.write(to: destinationURL)

                        // Update game record
                        var updatedGame = game
                        updatedGame.videoURL = destinationURL
                        updatedGame.youtubeStatus = .local
                        persistenceManager.saveGame(updatedGame)

                        debugPrint("Video imported successfully: \(destinationURL.path)")
                    } catch {
                        debugPrint("Failed to save imported video: \(error)")
                    }

                case .failure(let error):
                    debugPrint("Failed to load video from picker: \(error)")
                }
            }
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
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func shootingStat(label: String, made: Int, attempted: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(made)/\(attempted)")
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
