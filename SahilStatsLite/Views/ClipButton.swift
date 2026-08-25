//
//  ClipButton.swift
//  SahilStatsLite
//
//  PURPOSE: The one Clip button, shared by every capture screen (game recording,
//           stats-only, practice) so they look and behave identically. Drives the
//           whole flow off RecordingManager.clipState: tap to clip, live countdown,
//           tap to stop early, Saving/Saved. Dims + hints when not yet armed.
//  KEY TYPES: ClipButton
//  DEPENDS ON: RecordingManager (clipState / triggerClip / stopClip)
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

struct ClipButton: View {
    /// Text shown briefly if tapped before the ring is armed (differs by context).
    var idleHint: String = "Start game to clip"

    @ObservedObject private var recordingManager = RecordingManager.shared
    @State private var pulse = false       // brief bump on a successful tap
    @State private var recPulse = false    // steady dot pulse while clipping
    @State private var flash = false       // idle-tap "not ready" hint

    var body: some View {
        Button(action: handleTap) {
            label
                .foregroundColor(Chalk.board)
                .padding(.horizontal, 15)
                .padding(.vertical, 7)
                .background(background, in: Capsule())
                .shadow(color: Chalk.coral.opacity(pulse ? 0.8 : 0.4), radius: pulse ? 12 : 6, y: 2)
                .scaleEffect(pulse ? 1.12 : 1)
                .opacity(recordingManager.clipState == .idle ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: recordingManager.clipState)
    }

    private func handleTap() {
        switch recordingManager.clipState {
        case .clipping:
            recordingManager.stopClip()
        case .saving, .saved:
            break  // in-flight; ignore
        case .idle:
            // Not armed yet — say why instead of doing nothing.
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            withAnimation(.easeOut(duration: 0.12)) { flash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeIn(duration: 0.25)) { flash = false }
            }
        case .buffering:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeOut(duration: 0.10)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeIn(duration: 0.18)) { pulse = false }
            }
            recordingManager.triggerClip()
        }
    }

    @ViewBuilder
    private var label: some View {
        switch recordingManager.clipState {
        case .clipping(let remaining):
            HStack(spacing: 6) {
                Circle().fill(Chalk.board).frame(width: 8, height: 8)
                    .opacity(recPulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: recPulse)
                Text("Clipping \(remaining)s")
                    .font(.system(size: 14, weight: .bold)).monospacedDigit()
            }
            .onAppear { recPulse = true }
            .onDisappear { recPulse = false }
        case .saving:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7).tint(Chalk.board)
                Text("Saving…").font(.system(size: 14, weight: .bold))
            }
        case .saved:
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                Text("Saved").font(.system(size: 14, weight: .bold))
            }
        case .idle:
            HStack(spacing: 6) {
                Circle().fill(Chalk.board).frame(width: 8, height: 8)
                Text(flash ? idleHint : "Clip").font(.system(size: 14, weight: .bold))
            }
        case .buffering:
            HStack(spacing: 6) {
                Circle().fill(Chalk.board).frame(width: 8, height: 8)
                Text("Clip").font(.system(size: 14, weight: .bold))
            }
        }
    }

    private var background: Color {
        recordingManager.clipState == .saved ? Chalk.green : Chalk.coral
    }
}
