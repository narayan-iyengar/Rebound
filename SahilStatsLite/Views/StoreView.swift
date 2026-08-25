//
//  StoreView.swift
//  SahilStatsLite
//
//  PURPOSE: The "Store" — saved Clips (highlights), grouped by game session
//           (Sahil's team vs opponent · date/time). Tap to play, long-press to
//           share or delete. No win/loss — clips are self-describing from the
//           metadata captured at clip time, independent of any saved Game.
//  KEY TYPES: StoreView, ClipCard, ClipThumbnail, ClipPlayerSheet
//  DEPENDS ON: HighlightStore, AVKit
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import AVKit
import AVFoundation

struct StoreView: View {
    @ObservedObject private var store = HighlightStore.shared
    @State private var playing: Highlight?
    @State private var pendingDelete: Highlight?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if store.highlights.isEmpty {
                    emptyState
                } else {
                    ForEach(store.grouped) { group in
                        gameSection(group)
                    }
                }

                Spacer(minLength: 30)
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .chalkBoard()
        .fullScreenCover(item: $playing) { clip in
            ClipPlayerSheet(clip: clip)
        }
        .confirmationDialog("Delete this clip?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete clip", role: .destructive) {
                if let clip = pendingDelete { store.delete(clip) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes it from the app. The copy in Photos stays.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Store")
                .font(.chalkScript(40))
                .foregroundColor(Chalk.chalk)
            Text(store.highlights.isEmpty
                 ? "Your saved clips live here"
                 : "\(store.highlights.count) clip\(store.highlights.count == 1 ? "" : "s") · \(store.grouped.count) game\(store.grouped.count == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Chalk.dust)
        }
        .padding(.top, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundColor(Chalk.coral.opacity(0.8))
            Text("No clips yet")
                .font(.chalkScript(28))
                .foregroundColor(Chalk.chalk)
            Text("Tap Clip during a game to save the last ~30s as a highlight. Saved clips appear here, grouped by game.")
                .font(.system(size: 15))
                .foregroundColor(Chalk.dust)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .chalkCard()
    }

    // MARK: - Game section

    private func gameSection(_ group: HighlightGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.matchup)
                    .font(.chalkScript(26))
                    .foregroundColor(Chalk.chalk)
                    .lineLimit(1)
                Spacer()
                Text(Self.sessionDate(group.date))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Chalk.dust)
            }

            ForEach(group.clips) { clip in
                ClipCard(clip: clip)
                    .onTapGesture { playing = clip }
                    .contextMenu {
                        ShareLink(item: clip.url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) { pendingDelete = clip } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    static func sessionDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "'Today' · h:mm a"
            : (Calendar.current.isDateInYesterday(date) ? "'Yesterday' · h:mm a" : "MMM d · h:mm a")
        return f.string(from: date)
    }
}

// MARK: - Clip card (one saved highlight)

private struct ClipCard: View {
    let clip: Highlight

    var body: some View {
        HStack(spacing: 14) {
            ClipThumbnail(url: clip.url)
                .frame(width: 108, height: 61)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(radius: 3)
                )
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Chalk.chalk.opacity(0.18), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                if clip.isPractice {
                    Text("Practice clip")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Chalk.chalk)
                    Text(clip.createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Chalk.dust)
                } else {
                    Text(clip.scoreLine)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(Chalk.chalk)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(clip.period)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Chalk.yellow)
                        Text(clip.clockTime)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(Chalk.dust)
                    }
                }
            }
            Spacer()
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Chalk.dust)
                .rotationEffect(.degrees(90))
        }
        .padding(10)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Chalk.chalk.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Thumbnail (first frame)

private struct ClipThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Chalk.board, Chalk.board2], startPoint: .top, endPoint: .bottom)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 320)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        // Grab a frame ~1s in (past the opening keyframe) when possible.
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        if let cg = try? await gen.image(at: time).image {
            let img = UIImage(cgImage: cg)
            await MainActor.run { self.image = img }
        }
    }
}

// MARK: - Player

private struct ClipPlayerSheet: View {
    let clip: Highlight
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.85))
                            .shadow(radius: 4)
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                }
                Spacer()
                HStack {
                    Text(clip.isPractice ? "Practice" : clip.scoreLine)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                    Spacer()
                    ShareLink(item: clip.url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .onAppear { player = AVPlayer(url: clip.url) }
        .onDisappear { player?.pause() }
    }
}
