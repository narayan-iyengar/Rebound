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
    /// Overall size multiplier. Practice / stats-only pass a larger value for an easier tap.
    var scale: CGFloat = 1.0
    /// Big circular "record" style (iOS camera look) with the countdown inside the ring.
    var circle: Bool = false

    @ObservedObject private var recordingManager = RecordingManager.shared
    @State private var pulse = false       // brief bump on a successful tap
    @State private var recPulse = false    // steady dot pulse while clipping
    @State private var flash = false       // idle-tap "not ready" hint
    @State private var spin = false        // rotating progress arc while clipping (circle style)

    var body: some View {
        Button(action: handleTap) {
            if circle { circleBody } else { capsuleBody }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: recordingManager.clipState)
    }

    private var capsuleBody: some View {
        label
            .foregroundColor(Chalk.board)
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .background(background, in: Capsule())
            .shadow(color: Chalk.coral.opacity(pulse ? 0.8 : 0.4), radius: pulse ? 12 : 6, y: 2)
            .scaleEffect((pulse ? 1.12 : 1) * scale)
            .opacity(recordingManager.clipState == .idle ? 0.45 : 1)
    }

    // Big circular record-style button. A faint track ring is always drawn; while clipping a
    // coral arc spins around it and the center shows the seconds remaining (tap to stop early).
    private var circleBody: some View {
        let d = 78 * scale
        let clipping = isClipping
        return ZStack {
            // Track ring (always).
            Circle().stroke(Chalk.chalk.opacity(0.22), lineWidth: 5)
                .frame(width: d, height: d)

            // Spinning progress arc while clipping.
            if clipping {
                Circle().trim(from: 0, to: 0.3)
                    .stroke(Chalk.coral, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: d, height: d)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
                    .animation(.linear(duration: 1.05).repeatForever(autoreverses: false), value: spin)
            } else {
                // Clean full ring at rest (record look).
                Circle().stroke(ringColor, lineWidth: 5)
                    .frame(width: d, height: d)
            }

            circleCenter(d: d)
        }
        .frame(width: d + 10, height: d + 10)
        .shadow(color: Chalk.coral.opacity(pulse ? 0.7 : 0.25), radius: pulse ? 14 : 6, y: 2)
        .scaleEffect(pulse ? 1.06 : 1)
        .opacity(recordingManager.clipState == .idle ? 0.55 : 1)
    }

    private var isClipping: Bool {
        if case .clipping = recordingManager.clipState { return true }
        if recordingManager.clipState == .saving { return true }
        return false
    }

    private var ringColor: Color {
        recordingManager.clipState == .saved ? Chalk.green : Chalk.chalk.opacity(0.9)
    }

    @ViewBuilder
    private func circleCenter(d: CGFloat) -> some View {
        switch recordingManager.clipState {
        case .clipping(let remaining):
            Text("\(remaining)")
                .font(.system(size: d * 0.34, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Chalk.chalk)
        case .saving:
            ProgressView().tint(Chalk.coral)
        case .saved:
            Image(systemName: "checkmark")
                .font(.system(size: d * 0.32, weight: .heavy)).foregroundColor(Chalk.green)
        case .idle, .buffering:
            // The classic red "record" dot.
            Circle().fill(Chalk.coral).frame(width: d - 20, height: d - 20)
        }
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
