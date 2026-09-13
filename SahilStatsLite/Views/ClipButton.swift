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
    @State private var clipStart: Date?    // when the current clip's forward window began
    @State private var clipTotal: Double?  // total forward seconds (for the countdown ring)

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
        let base = d - 20
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
        .onChange(of: recordingManager.clipState) { _, st in trackClipTiming(st) }
    }

    // Capture the forward-window start + total when a clip begins, so the tick ring can act
    // as a smooth countdown. Cleared once the clip is no longer in flight.
    private func trackClipTiming(_ st: ClipState) {
        if case .clipping(let remaining) = st {
            if clipStart == nil { clipStart = Date(); clipTotal = Double(remaining) }
        } else if st != .saving {
            clipStart = nil; clipTotal = nil
        }
    }

    // Full ring of fine ticks. Subtle/uniform at rest; while clipping the ticks act as a
    // countdown — a full ring of bright ticks that empties as the seconds run out.
    private func tickRing(d: CGFloat, animate: Bool) -> some View {
        let count = 64
        return TimelineView(.animation(paused: !animate)) { timeline in
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = size.width / 2 - 1
                let len: CGFloat = 4.5
                // Fraction of the forward window still remaining (1 → 0).
                var progress: CGFloat = 0
                if animate, let s = clipStart, let tot = clipTotal, tot > 0 {
                    let remaining = max(0, tot - timeline.date.timeIntervalSince(s))
                    progress = CGFloat(remaining / tot)
                }
                let litCount = animate ? Int((progress * CGFloat(count)).rounded()) : 0
                for i in 0..<count {
                    let a = CGFloat(i) / CGFloat(count) * 2 * .pi - .pi / 2
                    let p1 = CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a))
                    let p2 = CGPoint(x: c.x + (outer - len) * cos(a), y: c.y + (outer - len) * sin(a))
                    var path = Path(); path.move(to: p1); path.addLine(to: p2)
                    // Bright ticks = time left; they empty clockwise as the countdown runs.
                    let op: Double = animate ? (i < litCount ? 0.95 : 0.18) : 0.32
                    ctx.stroke(path, with: .color(Chalk.chalk.opacity(op)), lineWidth: 1.0)
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

// A zoom overlay with an invisible drag zone on BOTH edges, limited to the vertical middle
// band so it clears the top chrome (X / chips) and the bottom Clip button. Drag up to zoom
// in, down to zoom out (log-scaled 1×–maxZoom). Nothing shows at rest; while dragging, a
// single level readout appears top-center (no line, no edge tracking). The center is
// pass-through, so scoring taps still work. Used in Practice and stats-only clips.
struct EdgeZoomStrip: View {
    @Binding var zoom: CGFloat
    var maxZoom: CGFloat = 6.0
    /// Clamp + apply to the camera; return the value actually applied (device-clamped).
    let apply: (CGFloat) -> CGFloat

    @State private var dragStartNorm: CGFloat?
    @State private var dragging = false
    private let trackHeight: CGFloat = 200
    private let zoneWidth: CGFloat = 46

    private func normFor(_ z: CGFloat) -> CGFloat { max(0, min(1, log(z) / log(maxZoom))) }
    private func zoomForNorm(_ t: CGFloat) -> CGFloat { pow(maxZoom, max(0, min(1, t))) }

    private var dragGesture: some Gesture {
        // minimumDistance > 0 so a quick tap on the edge still falls through to scoring.
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStartNorm == nil { dragStartNorm = normFor(zoom); dragging = true }
                let start = dragStartNorm ?? normFor(zoom)
                let delta = -value.translation.height / trackHeight   // up = zoom in
                zoom = apply(zoomForNorm(start + delta))
            }
            .onEnded { _ in dragStartNorm = nil; dragging = false }
    }

    var body: some View {
        GeometryReader { geo in
            // Zones cover only the middle half vertically — top quarter (X / chips) and bottom
            // quarter (Clip button) stay tappable.
            let zoneH = geo.size.height * 0.5
            ZStack {
                HStack(spacing: 0) {
                    Color.clear.frame(width: zoneWidth, height: zoneH)
                        .contentShape(Rectangle()).gesture(dragGesture)
                    Spacer(minLength: 0)
                    Color.clear.frame(width: zoneWidth, height: zoneH)
                        .contentShape(Rectangle()).gesture(dragGesture)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if dragging {
                    Text(String(format: "%.1f×", zoom))
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Chalk.yellow)
                        .shadow(color: .black.opacity(0.55), radius: 4)
                        .padding(.top, max(130, geo.size.height * 0.15))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: dragging)
    }
}
