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
import Photos
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
    @ObservedObject private var highlightStore = HighlightStore.shared
    @State private var playerItem: PlayerItem?

    // Edit state
    @State private var showEditSheet = false

    // Video picker state
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var isImportingVideo = false
    @State private var importProgress: Double = 0     // 0…1 while streaming from Photos/iCloud
    @State private var importError: String?

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
                                    importingIndicator
                                } else {
                                    PhotosPicker(selection: $selectedVideoItem, matching: .videos, photoLibrary: .shared()) {
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
                                    importingIndicator
                                } else {
                                    PhotosPicker(selection: $selectedVideoItem, matching: .videos, photoLibrary: .shared()) {
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
                                        importingIndicator
                                    } else {
                                        PhotosPicker(selection: $selectedVideoItem, matching: .videos, photoLibrary: .shared()) {
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

                    if let importError {
                        Text(importError)
                            .font(.system(size: 12))
                            .foregroundColor(Chalk.coral)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Video & Clips — watch the full game (local file) + this game's clips.
                    videoAndClipsSection

                    // Player Stats
                    VStack(spacing: 16) {
                        Text("Sahil's Stats")
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
            .fullScreenCover(item: $playerItem) { item in
                VideoPlayerSheet(url: item.url, caption: item.caption)
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

    // MARK: - Video & Clips

    @ViewBuilder
    private var videoAndClipsSection: some View {
        let clips = highlightStore.clips(forGameId: game.id)
        let localVideo = resolveVideoURL(for: game)

        if localVideo != nil || game.youtubeVideoId != nil || !clips.isEmpty {
            VStack(spacing: 14) {
                Text("Video & Clips")
                    .font(.chalkScript(22))
                    .foregroundColor(Chalk.chalk)

                if let localVideo {
                    Button {
                        playerItem = PlayerItem(url: localVideo, caption: game.scoreString)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "play.circle.fill").font(.system(size: 22))
                            Text("Watch full game").font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(Chalk.chalk)
                        .padding()
                        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Chalk.chalk.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                // Watch on YouTube — shown right here (not just the uploaded banner) so it's
                // next to the local "Watch full game". Needs a saved youtubeVideoId.
                if let vid = game.youtubeVideoId {
                    Button {
                        if let url = URL(string: "https://youtu.be/\(vid)") { UIApplication.shared.open(url) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "play.rectangle.fill").font(.system(size: 22))
                            Text("Watch on YouTube").font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(Chalk.coral)
                        .padding()
                        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Chalk.coral.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                } else if localVideo == nil, game.youtubeStatus == .uploaded {
                    Text("Uploaded to YouTube — re-upload once to restore the watch link.")
                        .font(.system(size: 12))
                        .foregroundColor(Chalk.dust)
                }

                if !clips.isEmpty {
                    HStack {
                        Text("\(clips.count) clip\(clips.count == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Chalk.dust)
                        Spacer()
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(clips) { clip in
                                Button {
                                    playerItem = PlayerItem(url: clip.url,
                                                            caption: clip.isPractice ? "Practice" : clip.scoreLine)
                                } label: {
                                    ClipThumbnail(url: clip.url)
                                        .frame(width: 132, height: 74)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            Image(systemName: "play.circle.fill")
                                                .font(.system(size: 26))
                                                .foregroundColor(.white.opacity(0.9))
                                                .shadow(radius: 3)
                                        )
                                        .overlay(RoundedRectangle(cornerRadius: 10)
                                            .stroke(Chalk.chalk.opacity(0.18), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Chalk.board2.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }
    }

    @ViewBuilder private var importingIndicator: some View {
        VStack(spacing: 6) {
            if importProgress > 0 {
                ProgressView(value: importProgress) {
                    Text("Importing… \(Int(importProgress * 100))%")
                        .font(.system(size: 12)).foregroundColor(Chalk.dust)
                }
                .tint(Chalk.sky)
            } else {
                ProgressView("Importing…").tint(Chalk.chalk).foregroundColor(Chalk.dust)
                Text("Large iCloud videos download first — this can take a minute.")
                    .font(.system(size: 10)).foregroundColor(Chalk.dust)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func importVideo(from item: PhotosPickerItem) {
        isImportingVideo = true
        importProgress = 0
        importError = nil
        selectedVideoItem = nil  // reset so re-picking the same video works

        let filename = "imported_\(game.id).mov"
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsPath.appendingPathComponent(filename)

        // Preferred path: pull the ORIGINAL file straight from the Photos library via
        // PHAssetResourceManager. Unlike PhotosUI's loadTransferable — which shows no
        // progress and can appear frozen forever while an iCloud-stored video downloads —
        // this streams with a progress handler and `isNetworkAccessAllowed` so big
        // iCloud videos actually come down (and the user sees it happening).
        if let assetId = item.itemIdentifier {
            Task {
                let status = await ensurePhotosReadAccess()
                guard status else {
                    await finishImport(error: "Photos access is needed to import. Enable it in Settings › Privacy › Photos.")
                    return
                }
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
                    // Fall back if we can't resolve the asset (e.g. shared library quirk)
                    importViaTransferable(item, to: destinationURL); return
                }
                importViaPHAsset(asset, to: destinationURL)
            }
        } else {
            importViaTransferable(item, to: destinationURL)
        }
    }

    private func ensurePhotosReadAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited { return true }
        let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return granted == .authorized || granted == .limited
    }

    private func importViaPHAsset(_ asset: PHAsset, to destinationURL: URL) {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let videoResource = resources.first(where: { $0.type == .video })
                ?? resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first else {
            Task { await finishImport(error: "No video data found for that item.") }
            return
        }
        try? FileManager.default.removeItem(at: destinationURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true            // download from iCloud if needed
        options.progressHandler = { p in
            Task { @MainActor in self.importProgress = p }
        }
        PHAssetResourceManager.default().writeData(for: videoResource, toFile: destinationURL, options: options) { error in
            Task { @MainActor in
                if let error = error {
                    await self.finishImport(error: "Import failed: \(error.localizedDescription)")
                } else {
                    self.applyImportedVideo(at: destinationURL)
                    await self.finishImport(error: nil)
                }
            }
        }
    }

    // Fallback for items with no Photos identifier (rare): the original file-based
    // transfer. Still no progress, but it won't be silent about failure anymore.
    private func importViaTransferable(_ item: PhotosPickerItem, to destinationURL: URL) {
        Task {
            do {
                guard let imported = try await item.loadTransferable(type: ImportedVideoFile.self) else {
                    await finishImport(error: "Couldn't read that video. If it's stored in iCloud, open it once in Photos to download it, then retry.")
                    return
                }
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: imported.url, to: destinationURL)
                await MainActor.run { applyImportedVideo(at: destinationURL) }
                await finishImport(error: nil)
            } catch {
                await finishImport(error: "Import failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor private func applyImportedVideo(at destinationURL: URL) {
        var updatedGame = game
        updatedGame.videoURL = destinationURL
        updatedGame.youtubeStatus = .local
        // Clear stale YouTube video ID so the next upload registers a fresh one.
        updatedGame.youtubeVideoId = nil
        persistenceManager.saveGame(updatedGame)
        debugPrint("📹 Video imported: \(destinationURL.lastPathComponent)")
    }

    @MainActor private func finishImport(error: String?) {
        isImportingVideo = false
        importProgress = 0
        importError = error
        if let error { debugPrint("📹 Import error: \(error)") }
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
                // Save the YouTube video id so the 'Watch on YouTube' link appears.
                // (Without this it stayed nil and the link never showed.)
                finishedGame.youtubeVideoId = youtubeService.completedVideoID ?? game.youtubeVideoId
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
