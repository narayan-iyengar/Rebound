//
//  GameDetailSheet.swift
//  SahilStatsLite
//
//  PURPOSE: One calm page per game — result, Sahil's stat line, a single "Watch"
//           card (local playback, or YouTube fallback), and this game's clips folded
//           until tapped. All housekeeping (upload, free-up-space, restore, replace,
//           delete) is tucked behind a contextual "⋯" menu so the page stays quiet.
//  KEY TYPES: GameDetailSheet
//  DEPENDS ON: YouTubeService, GamePersistenceManager, HighlightStore, EditGameView
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
    @State private var findingLink = false            // searching YouTube uploads to recover the link

    // One-page layout state
    @State private var showClips = false              // clips stay folded until tapped
    @State private var showVideoPicker = false        // ⋯ → Replace / Add video
    @State private var showDeleteConfirm = false      // ⋯ → Delete game

    // Fetch live game object to ensure updates reflect immediately
    var game: Game {
        persistenceManager.savedGames.first(where: { $0.id == gameId }) ?? Game(opponent: "Unknown")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 20) {
                        resultHeader
                        statsHero
                        watchCard
                        uploadStatusRow
                        if let importError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(Chalk.coral)
                                Text(importError)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Chalk.coral)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Chalk.coral.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Chalk.coral.opacity(0.4), lineWidth: 1))
                        }
                        clipsSection
                    }
                    .padding()
                }
            }
            .chalkBoard()
            .navigationBarHidden(true)
            .onAppear { autoRecoverIfNeeded() }
            // Single picker, driven by the ⋯ menu (Add / Replace video).
            .photosPicker(isPresented: $showVideoPicker, selection: $selectedVideoItem,
                          matching: .videos, photoLibrary: .shared())
            .onChange(of: selectedVideoItem) { _, newItem in
                if let newItem { importVideo(from: newItem) }
            }
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
            .confirmationDialog("Delete this game?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete game", role: .destructive) {
                    persistenceManager.deleteGame(game)
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Removes the stats\(resolveVideoURL(for: game) != nil ? " and the local video" : ""). This can't be undone.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Game Details")
                .font(.chalkScript(28))
                .foregroundColor(Chalk.chalk)

            Spacer()

            manageMenu

            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Chalk.chalk)
            }
            .padding(.leading, 12)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Everything managerial lives here so the page itself stays calm. Options are
    /// contextual — you only ever see actions that are valid for this game's state.
    private var manageMenu: some View {
        Menu {
            Button { showEditSheet = true } label: { Label("Edit game", systemImage: "pencil") }

            // (Upload / Retry now lives on the page itself — see uploadStatusRow.)

            if let vid = game.youtubeVideoId {
                Button {
                    if let u = URL(string: "https://youtu.be/\(vid)") { UIApplication.shared.open(u) }
                } label: { Label("Open on YouTube", systemImage: "play.rectangle") }
            }

            if let url = resolveVideoURL(for: game) {
                ShareLink(item: url) { Label("Share video", systemImage: "square.and.arrow.up.on.square") }
            }

            Divider()

            // Storage: free the local copy once it's safely on YouTube.
            if let url = resolveVideoURL(for: game), game.youtubeStatus == .uploaded,
               let size = localFileSize(at: url) {
                Button(role: .destructive) { deleteLocalFile(url: url) } label: {
                    Label("Free up \(size)", systemImage: "trash")
                }
            }
            // Bring a freed/missing local copy back from Photos.
            if resolveVideoURL(for: game) == nil, game.photoAssetId != nil {
                Button { recoverFromPhotos() } label: {
                    Label("Restore local from Photos", systemImage: "arrow.down.circle")
                }
            }
            // Recovery: swap in a different file (corrupt recording / abandoned upload).
            Button { showVideoPicker = true } label: {
                Label(resolveVideoURL(for: game) == nil ? "Add video…" : "Replace video…",
                      systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("Delete game", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Chalk.chalk)
                .frame(width: 34, height: 34)
                .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 9))
        }
    }

    // MARK: - Result header

    private var resultHeader: some View {
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
        .padding(.top, 4)
    }

    // MARK: - Stats hero

    private var statsHero: some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                statBox(value: "\(game.playerStats.points)", label: "PTS", color: Chalk.yellow)
                statBox(value: "\(game.playerStats.rebounds)", label: "REB", color: Chalk.sky)
                statBox(value: "\(game.playerStats.assists)", label: "AST", color: Chalk.green)
                statBox(value: "\(game.playerStats.steals)", label: "STL", color: Chalk.chalkDim)
                statBox(value: "\(game.playerStats.blocks)", label: "BLK", color: Chalk.coral)
            }

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

    // MARK: - Watch (one video, one verb)

    /// The single thing "the video" resolves to. Local playback wins (no data, has
    /// audio); YouTube is the fallback when the local copy has been freed.
    private enum WatchTarget { case local(URL), youtube(String), none }
    private var watchTarget: WatchTarget {
        if let local = resolveVideoURL(for: game) { return .local(local) }
        if let vid = game.youtubeVideoId { return .youtube(vid) }
        return .none
    }

    @ViewBuilder
    private var watchCard: some View {
        if isImportingVideo {
            importingCard
        } else {
            switch watchTarget {
            case .local(let url):
                watchButton(thumbnailURL: url) {
                    playerItem = PlayerItem(url: url, caption: game.scoreString)
                }
            case .youtube(let vid):
                watchButton(thumbnailURL: nil) {
                    if let u = URL(string: "https://youtu.be/\(vid)") { UIApplication.shared.open(u) }
                }
            case .none:
                noVideoCard
            }
        }
    }

    // MARK: - Upload status (surfaced on the page, not hidden in ⋯)

    /// The one place YouTube upload state is spelled out: a clear Upload button when a
    /// local file isn't up yet, live progress while uploading, and a visible failure with
    /// a Retry — so a failed upload is never silent.
    @ViewBuilder
    private var uploadStatusRow: some View {
        if youtubeService.queuedGameIDs.contains(game.id) {
            // Waiting its turn behind another upload — no second Upload button.
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundColor(Chalk.sky)
                Text("Queued for upload…").font(.system(size: 14, weight: .medium)).foregroundColor(Chalk.dust)
                Spacer()
            }
            .padding(.horizontal, 4)
        } else if youtubeService.isUploading && youtubeService.currentUploadingGameID == game.id {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill").foregroundColor(Chalk.sky)
                    Text("Uploading to YouTube…").font(.system(size: 14, weight: .medium)).foregroundColor(Chalk.chalk)
                    Spacer()
                    Text("\(Int(youtubeService.uploadProgress * 100))%")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundColor(Chalk.dust)
                    Button("Cancel") { youtubeService.cancelUpload() }
                        .font(.system(size: 13, weight: .bold)).foregroundColor(Chalk.coral)
                }
                ProgressView(value: youtubeService.uploadProgress).tint(Chalk.sky)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Chalk.chalk.opacity(0.15), lineWidth: 1))
        } else if findingLink {
            // Verifying against YouTube before offering a retry — so we never upload a
            // duplicate of a video that actually made it up.
            HStack(spacing: 8) {
                ProgressView().tint(Chalk.sky)
                Text("Checking YouTube…").font(.system(size: 14, weight: .medium)).foregroundColor(Chalk.dust)
                Spacer()
            }
            .padding(.horizontal, 4)
        } else if game.youtubeStatus == .uploaded {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.icloud.fill").foregroundColor(Chalk.green)
                Text("Saved to YouTube").font(.system(size: 14, weight: .medium)).foregroundColor(Chalk.dust)
                Spacer()
                if let vid = game.youtubeVideoId {
                    Button {
                        if let u = URL(string: "https://youtu.be/\(vid)") { UIApplication.shared.open(u) }
                    } label: {
                        Text("Watch ↗").font(.system(size: 13, weight: .semibold)).foregroundColor(Chalk.sky)
                    }
                }
            }
            .padding(.horizontal, 4)
        } else if let url = resolveVideoURL(for: game) {
            // Local file present but not on YouTube — a clear, primary action (not buried in ⋯).
            VStack(spacing: 8) {
                ChalkButton(title: game.youtubeStatus == .failed ? "Retry upload to YouTube" : "Upload to YouTube",
                            icon: "square.and.arrow.up", color: Chalk.yellow) {
                    startUpload(url: url)
                }
                if game.youtubeStatus == .failed {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundColor(Chalk.coral)
                        Text(youtubeService.lastError ?? "The last upload failed. Tap retry.")
                            .font(.system(size: 12, weight: .medium)).foregroundColor(Chalk.coral)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// The hero: a first-frame thumbnail (or gradient for a YouTube-only game) with a
    /// single play glyph. "on YouTube" is a whisper, not a competing button.
    private func watchButton(thumbnailURL: URL?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Size + crop the image FIRST, then hang overlays on the fixed 190pt box —
            // otherwise the thumbnail's intrinsic (taller) height drives layout and the
            // top labels get clipped off above the visible window.
            Group {
                if let thumbnailURL {
                    ClipThumbnail(url: thumbnailURL)
                } else {
                    LinearGradient(colors: [Chalk.board, Chalk.board2],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .clipped()
            .overlay(
                LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.30)],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay {
                Circle().fill(.white.opacity(0.92)).frame(width: 54, height: 54)
                    .overlay(Image(systemName: "play.fill").font(.system(size: 22))
                        .foregroundColor(.black.opacity(0.85)).offset(x: 2))
                    .shadow(radius: 6)
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text("Watch").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    if let d = durationText() {
                        Text("· \(d)").font(.system(size: 13)).monospacedDigit().foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                if game.youtubeVideoId != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                        Text("on YouTube").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var importingCard: some View {
        importingIndicator
            .padding()
            .frame(maxWidth: .infinity)
            .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
    }

    /// No playable video: either an uploaded game whose local copy is gone (offer to
    /// find the link / restore), or a game that never had a video (offer to add one).
    @ViewBuilder
    private var noVideoCard: some View {
        VStack(spacing: 12) {
            if game.youtubeStatus == .uploaded {
                Label("Uploaded to YouTube", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(Chalk.green)
                if findingLink {
                    ProgressView("Finding YouTube link…").tint(Chalk.chalk).foregroundColor(Chalk.dust)
                } else {
                    Button { findYouTubeLink() } label: {
                        Label("Find YouTube link", systemImage: "magnifyingglass")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(Chalk.sky)
                    }
                }
            } else if game.photoAssetId != nil {
                Text("Restoring the full game from Photos…")
                    .font(.system(size: 13)).foregroundColor(Chalk.dust)
                Button { recoverFromPhotos() } label: {
                    Label("Restore from Photos", systemImage: "arrow.down.circle")
                        .font(.system(size: 15, weight: .medium)).foregroundColor(Chalk.chalk)
                }
            } else {
                Text("No video for this game")
                    .font(.system(size: 13)).foregroundColor(Chalk.dust)
                Button { showVideoPicker = true } label: {
                    Label("Add video from Photos", systemImage: "photo.on.rectangle")
                        .font(.system(size: 15, weight: .medium)).foregroundColor(Chalk.chalk)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Chalk.board2.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Clips (folded by default)

    @ViewBuilder
    private var clipsSection: some View {
        let clips = highlightStore.clips(forGameId: game.id)
        if !clips.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showClips.toggle() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "scissors").font(.system(size: 15)).foregroundColor(Chalk.dust)
                        Text("\(clips.count) clip\(clips.count == 1 ? "" : "s")")
                            .font(.system(size: 15, weight: .medium)).foregroundColor(Chalk.chalk)
                        Spacer()
                        Image(systemName: showClips ? "chevron.up" : "chevron.down")
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(Chalk.dust)
                    }
                    .padding(.vertical, 13).padding(.horizontal, 14)
                }
                .buttonStyle(.plain)

                if showClips {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(clips) { clip in
                                Button {
                                    playerItem = PlayerItem(url: clip.url,
                                                            caption: clip.isPractice ? "Practice" : clip.scoreLine)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        ClipThumbnail(url: clip.url)
                                            .frame(width: 132, height: 74)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .overlay(Image(systemName: "play.circle.fill")
                                                .font(.system(size: 26)).foregroundColor(.white.opacity(0.9)).shadow(radius: 3))
                                            .overlay(RoundedRectangle(cornerRadius: 10)
                                                .stroke(Chalk.chalk.opacity(0.18), lineWidth: 1))
                                        Text(clip.isPractice ? "Practice" : clip.scoreLine)
                                            .font(.system(size: 11)).foregroundColor(Chalk.dust).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14).padding(.bottom, 14)
                    }
                }
            }
            .background(Chalk.board2.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func durationText() -> String? {
        guard let d = game.videoDuration, d > 0 else { return nil }
        let s = Int(d.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
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

    /// Restore the full-game file from Photos using the id we saved at record time — no
    /// manual picker. Runs when the local Documents copy is missing (e.g. purged after
    /// several big games) but the game still has a linked Photos asset.
    private func recoverFromPhotos() {
        guard let assetId = game.photoAssetId, !isImportingVideo else { return }
        isImportingVideo = true; importProgress = 0; importError = nil
        let destinationURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imported_\(game.id).mov")
        Task {
            guard await ensurePhotosReadAccess() else {
                await finishImport(error: "Photos access is needed to restore. Enable it in Settings › Privacy › Photos.")
                return
            }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
                await finishImport(error: "That recording is no longer in Photos.")
                return
            }
            importViaPHAsset(asset, to: destinationURL)
        }
    }

    /// On open, silently pull the video back from Photos if the local copy is gone but we
    /// have the linked asset — so the log links itself without a manual Photos pick.
    private func autoRecoverIfNeeded() {
        if resolveVideoURL(for: game) == nil, game.photoAssetId != nil, !isImportingVideo {
            recoverFromPhotos()
        }
        // The upload's true outcome lives on YouTube, not in our local flag. A background
        // upload can finish on YouTube's side but land back here as ".failed" (or ".uploaded"
        // with no id) if the app was backgrounded during the final handoff and we never
        // captured the returned video id. So whenever we have no id but the video *might* be
        // up (uploaded OR failed), ask YouTube: if the matching title is there, it really
        // succeeded — adopt the id and correct the status. This also prevents a "Retry" from
        // uploading a duplicate of a video that's already live.
        if (game.youtubeStatus == .uploaded || game.youtubeStatus == .failed),
           game.youtubeVideoId == nil, !findingLink {
            findYouTubeLink()
        }
    }

    /// Ask YouTube whether this game's video is already uploaded (matching title), and if so
    /// adopt its id and mark the game uploaded — recovering both a lost id AND a false failure.
    private func findYouTubeLink() {
        findingLink = true
        let title = "\(game.teamName) vs \(game.opponent) - \(game.date.formatted(date: .abbreviated, time: .omitted))"
        Task {
            let vid = await youtubeService.findUploadedVideoId(title: title)
            await MainActor.run {
                findingLink = false
                if let vid {
                    var g = game
                    g.youtubeVideoId = vid
                    g.youtubeStatus = .uploaded   // it's really on YouTube — fix a false .failed
                    persistenceManager.saveGame(g)
                    debugPrint("📺 Recovered YouTube id \(vid) — marked uploaded")
                }
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

        // Final status + youtubeVideoId are written by the single source of truth:
        // YouTubeService.onUploadCompleted → GamePersistenceManager.handleUploadCompletion,
        // which fires from the background URLSession delegate when the upload truly finishes.
        // (Previously this closure also wrote status right after uploadVideo returned — but
        // that returns EARLY for a background upload, so it saved '.uploaded' with a nil
        // videoId and clobbered the real id, hence no 'Watch on YouTube' link.)
        Task {
            await youtubeService.uploadVideo(url: url, title: title, description: description, gameID: game.id)
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
