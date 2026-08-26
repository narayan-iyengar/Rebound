//
//  VideoComponents.swift
//  SahilStatsLite
//
//  PURPOSE: Shared video UI reused across the Store and the Game Log detail:
//           a first-frame thumbnail and a full-screen player sheet. Keeps clip +
//           game-video playback identical everywhere.
//  KEY TYPES: ClipThumbnail, VideoPlayerSheet, PlayerItem
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import AVKit
import AVFoundation

/// Identifiable wrapper so a URL can drive `.fullScreenCover(item:)`.
struct PlayerItem: Identifiable {
    let id = UUID()
    let url: URL
    var caption: String? = nil
}

/// First-frame thumbnail for a video file.
struct ClipThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
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
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        if let cg = try? await gen.image(at: time).image {
            let img = UIImage(cgImage: cg)
            await MainActor.run { self.image = img }
        }
    }
}

/// Full-screen player for any local video URL, with close + share.
struct VideoPlayerSheet: View {
    let url: URL
    var caption: String? = nil

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
                    if let caption {
                        Text(caption)
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(.white)
                    }
                    Spacer()
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause() }
    }
}
