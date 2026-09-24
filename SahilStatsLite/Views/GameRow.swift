//
//  GameRow.swift
//  SahilStatsLite
//
//  PURPOSE: Game log row — a VISUAL row: a tap-to-play court thumbnail on the left
//           (plays the local file, or opens YouTube when the local copy is freed), then
//           result + matchup + team · date and a compact score · pts · clips meta line.
//           Tapping the thumbnail plays; tapping the text opens the game detail.
//  KEY TYPES: GameRow
//  DEPENDS ON: Game, HighlightStore, ClipThumbnail, VideoPlayerSheet
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

// MARK: - Shared grouping helpers (used by the game log AND the clip store, so they stay
// visually identical)

/// Team → color. Lava is pinned to the app's yellow; every other team (Elements, one-off
/// guest teams) gets a stable color from a small palette that deliberately avoids the W/L
/// green + coral. Deterministic hash so a given team is always the same color, no picking.
enum TeamPalette {
    static let colors: [Color] = [
        Chalk.sky,
        Color(red: 0.78, green: 0.72, blue: 0.88),   // lavender
        Color(red: 0.88, green: 0.66, blue: 0.77),   // rose
        Color(red: 0.66, green: 0.71, blue: 0.88),   // periwinkle
        Color(red: 0.85, green: 0.77, blue: 0.55)    // sand
    ]

    static func color(for name: String) -> Color {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if key == "lava" { return Chalk.yellow }
        if key.isEmpty { return Chalk.chalkDim }
        var hash: UInt64 = 5381
        for scalar in key.unicodeScalars { hash = (hash &* 33) &+ UInt64(scalar.value) }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

/// Adaptive time bucket for a date: This Week / This Month / month (this year) / year (older,
/// collapsed by default). Fine detail for recent, coarse for old.
enum AdaptiveTimeSection {
    static func info(for date: Date) -> (title: String, collapsed: Bool) {
        let cal = Calendar.current
        let now = Date()
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date),
                                         to: cal.startOfDay(for: now)).day, days >= 0, days < 7 {
            return ("This Week", false)
        }
        if cal.isDate(date, equalTo: now, toGranularity: .month) {
            return ("This Month", false)
        }
        let df = DateFormatter()
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            df.dateFormat = "MMMM"
            return (df.string(from: date), false)
        }
        df.dateFormat = "yyyy"
        return (df.string(from: date), true)
    }
}

// MARK: - Game Row

struct GameRow: View {
    let game: Game
    /// Play the local file in an in-app player (owner presents the sheet).
    var onPlayLocal: ((URL) -> Void)? = nil
    /// Open the game detail page (stats, clips, management).
    var onOpen: (() -> Void)? = nil

    // Observe the upload service so a game waiting in the queue shows a clock (and the one
    // actively uploading shows the bouncing arrow).
    @ObservedObject private var youtubeService = YouTubeService.shared

    private var localVideo: URL? { Self.resolveLocal(game) }
    private var playable: Bool { localVideo != nil || game.youtubeVideoId != nil }
    private var clipCount: Int { HighlightStore.shared.clips(forGameId: game.id).count }
    private var badgeColor: Color { game.isWin ? Chalk.green : Chalk.coral }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            Button { onOpen?() } label: {
                HStack(spacing: 6) {
                    info
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Chalk.dust)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .chalkCard()
    }

    // MARK: Thumbnail (tap to play)

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            if let localVideo {
                ClipThumbnail(url: localVideo)
            } else if playable || game.youtubeStatus == .uploaded {
                LinearGradient(colors: [Chalk.board, Chalk.board2],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Chalk.board2
            }

            if playable {
                Color.black.opacity(0.18)
                Circle().fill(.white.opacity(0.92)).frame(width: 38, height: 38)
                    .overlay(Image(systemName: "play.fill").font(.system(size: 15))
                        .foregroundColor(.black.opacity(0.85)).offset(x: 1))
                if let d = durationText {
                    VStack { Spacer(); HStack { Spacer()
                        Text(d).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    } }.padding(5)
                }
                // Corner hint when the only source is YouTube (local copy freed).
                if localVideo == nil, game.youtubeVideoId != nil {
                    VStack { HStack { Spacer()
                        Image(systemName: "play.rectangle.fill").font(.system(size: 12)).foregroundColor(.white.opacity(0.9))
                    } ; Spacer() }.padding(5)
                }
            } else {
                Image(systemName: "film").font(.system(size: 20)).foregroundColor(Chalk.dust.opacity(0.5))
            }
        }
        .frame(width: 124, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Chalk.chalk.opacity(0.12), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { play() }
    }

    // MARK: Info

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(game.resultString)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(badgeColor)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(badgeColor.opacity(0.6), lineWidth: 1.5))
                Text("vs \(game.opponent)")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Chalk.chalk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(subLine)
                .font(.system(size: 14))
                .foregroundColor(Chalk.dust)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(game.scoreString)
                    .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    .foregroundColor(Chalk.crisp)
                dot
                Text("\(game.playerStats.points) pts")
                    .font(.system(size: 15, weight: .medium)).monospacedDigit()
                    .foregroundColor(Chalk.yellow)
                if clipCount > 0 {
                    dot
                    HStack(spacing: 3) {
                        Image(systemName: "scissors").font(.system(size: 12))
                        Text("\(clipCount)").font(.system(size: 15, weight: .medium)).monospacedDigit()
                    }
                    .foregroundColor(Chalk.dust)
                }
                if youtubeService.queuedGameIDs.contains(game.id) {
                    // Waiting its turn in the sequential upload queue.
                    Image(systemName: "clock").font(.system(size: 14, weight: .medium)).foregroundColor(Chalk.sky)
                } else if game.youtubeStatus == .uploading {
                    UploadingArrow()
                } else if game.youtubeStatus == .uploaded {
                    // On YouTube — a play glyph reads more like "video's up" than a cloud check.
                    Image(systemName: "play.rectangle.fill").font(.system(size: 15)).foregroundColor(Chalk.green)
                } else if game.youtubeStatus == .failed {
                    Image(systemName: "exclamationmark.icloud.fill").font(.system(size: 14)).foregroundColor(Chalk.coral)
                }
            }
            .padding(.top, 2)
        }
    }

    private var dot: some View {
        Text("·").font(.system(size: 14)).foregroundColor(Chalk.dust.opacity(0.7))
    }

    /// A quiet bouncing up-arrow that reads as "uploading" without the wrapping text.
    private struct UploadingArrow: View {
        @State private var up = false
        var body: some View {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Chalk.sky)
                .offset(y: up ? -3 : 2)
                .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: up)
                .onAppear { up = true }
        }
    }

    private var subLine: String {
        let d = game.date.formatted(.dateTime.month(.abbreviated).day())
        return game.teamName.isEmpty ? d : "\(game.teamName) · \(d)"
    }

    private var durationText: String? {
        guard let dur = game.videoDuration, dur > 0 else { return nil }
        let s = Int(dur.rounded()); let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func play() {
        if let localVideo {
            onPlayLocal?(localVideo)
        } else if let vid = game.youtubeVideoId, let u = URL(string: "https://youtu.be/\(vid)") {
            UIApplication.shared.open(u)
        } else {
            onOpen?()
        }
    }

    /// Resolve the on-disk video, tolerating a moved Documents container (same as the detail sheet).
    static func resolveLocal(_ game: Game) -> URL? {
        guard let url = game.videoURL else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let alt = docs.appendingPathComponent(url.lastPathComponent)
        return FileManager.default.fileExists(atPath: alt.path) ? alt : nil
    }
}
