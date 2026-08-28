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

    // iOS-timelapse-style record button: a full ring of fine ticks with a red center that
    // morphs circle → rounded square while clipping; the ticks fill/unfill (sweep) meanwhile.
    private var circleBody: some View {
        let d = 78 * scale
        let recording = isClipping
        let base = d - 16
        let side = recording ? base * 0.5 : base
        let corner = recording ? side * 0.30 : side / 2
        return ZStack {
            tickRing(d: d, animate: recording)

            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(centerColor)
                .frame(width: side, height: side)

            if recordingManager.clipState == .saved {
                Image(systemName: "checkmark")
                    .font(.system(size: base * 0.34, weight: .heavy))
                    .foregroundColor(Chalk.board)
            }
        }
        .frame(width: d + 12, height: d + 12)
        .shadow(color: Chalk.coral.opacity(pulse ? 0.6 : 0.2), radius: pulse ? 14 : 6, y: 2)
        .scaleEffect(pulse ? 1.06 : 1)
        .opacity(recordingManager.clipState == .idle ? 0.6 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: recording)
    }

    // Full ring of fine ticks. Static (uniform) at rest; while recording a bright wedge
    // grows and shrinks (fills/unfills) around the ring.
    private func tickRing(d: CGFloat, animate: Bool) -> some View {
        let count = 60
        return TimelineView(.animation(paused: !animate)) { timeline in
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = size.width / 2 - 1
                let len: CGFloat = 6
                let t = timeline.date.timeIntervalSinceReferenceDate
                let period = 2.4
                let frac = CGFloat((t / period).truncatingRemainder(dividingBy: 1))
                let tri = 1 - abs(2 * frac - 1)                 // 0→1→0 triangle
                let bright = animate ? Int(tri * CGFloat(count)) : 0
                for i in 0..<count {
                    let a = CGFloat(i) / CGFloat(count) * 2 * .pi - .pi / 2
                    let p1 = CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a))
                    let p2 = CGPoint(x: c.x + (outer - len) * cos(a), y: c.y + (outer - len) * sin(a))
                    var path = Path(); path.move(to: p1); path.addLine(to: p2)
                    let op: Double = animate ? (i < bright ? 1.0 : 0.25) : 0.5
                    ctx.stroke(path, with: .color(Chalk.chalk.opacity(op)), lineWidth: 1.6)
                }
            }
        }
        .frame(width: d, height: d)
    }

    private var isClipping: Bool {
        if case .clipping = recordingManager.clipState { return true }
        if recordingManager.clipState == .saving { return true }
        return false
    }

    private var centerColor: Color {
        recordingManager.clipState == .saved ? Chalk.green : Chalk.coral
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
