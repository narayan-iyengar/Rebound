//
//  PracticeView.swift
//  SahilStatsLite
//
//  PURPOSE: Practice-mode clipping. A stripped-down capture screen with no game,
//           no score, no clock — just the live camera buffering the clip ring, and
//           the shared Clip button. Saved clips are tagged "Practice" and land in
//           the same Store, grouped under a "Practice · date" header.
//  KEY TYPES: PracticeView
//  DEPENDS ON: RecordingManager (clip ring), ClipButton, CameraPreviewView
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

struct PracticeView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var recordingManager = RecordingManager.shared

    @State private var sessionId = UUID().uuidString

    // Manual zoom for practice (game mode auto-zooms via Skynet; practice has no tracking).
    @State private var zoom: CGFloat = 1.0
    @State private var pinchBaseZoom: CGFloat = 1.0
    @State private var showWheel = false          // radial dial visible only while interacting
    @State private var hideWork: DispatchWorkItem?
    @State private var dragStartNorm: CGFloat?    // captured at the start of a wheel drag
    private let maxZoom: CGFloat = 6.0

    // Optional freeform tag saved onto this session's clips (e.g. gym / drill name).
    @State private var location: String = ""
    @State private var showLocationEditor = false
    @State private var locationDraft: String = ""

    var body: some View {
        ZStack {
            camera
                // Pinch anywhere on the preview to zoom (1×–maxZoom); reveals the dial too.
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            applyZoom(pinchBaseZoom * scale)
                            revealWheel()
                        }
                        .onEnded { _ in
                            pinchBaseZoom = zoom
                        }
                )

            // Top chrome: X (right) and the "Practice" chip (center). The Clip button now
            // lives at the bottom for thumb reach in both orientations.
            VStack {
                HStack {
                    Spacer()
                    closeButton
                        .padding(.trailing, 16)
                }
                .padding(.top, 12)
                Spacer()
            }

            VStack(spacing: 8) {
                practiceLabel
                    .padding(.top, 12)
                locationChip
                Spacer()
            }

            // Bottom bar: zoom control (badge at rest → radial dial while interacting) over
            // a centered Clip button. Drag directly on this area to zoom — no tap first.
            VStack(spacing: 6) {
                Spacer()
                ZStack {
                    if showWheel {
                        RadialZoomDial(zoom: zoom, maxZoom: maxZoom, presets: zoomPresets)
                            .transition(.opacity)
                    } else {
                        zoomBadge
                    }
                }
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(zoomDrag)

                ClipButton(idleHint: "Camera warming up…", circle: true)
                    .padding(.bottom, 22)
            }
        }
        .alert("Practice tag", isPresented: $showLocationEditor) {
            TextField("e.g. Rec Center · shooting", text: $locationDraft)
            Button("Save") {
                location = locationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                recordingManager.clipLabel = location.isEmpty ? nil : location
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Tag this session's clips with a place or drill (optional).")
        }
        .statusBar(hidden: true)
        .persistentSystemOverlays(.hidden)
        .task {
            // Arm a clip-only session: camera on, buffering, no file recording, no overlay.
            recordingManager.reset()
            recordingManager.isPracticeSession = true
            recordingManager.compositeClipOverlay = false
            recordingManager.currentClipGameId = sessionId
            recordingManager.clipLabel = location.isEmpty ? nil : location
            UIApplication.shared.isIdleTimerDisabled = true
            await recordingManager.requestPermissionsAndSetup()
            if recordingManager.isSessionReady && !recordingManager.isSimulator {
                recordingManager.startClipBuffering()
            }
        }
        .onDisappear {
            recordingManager.stopClipBuffering()
            recordingManager.stopSession()
            recordingManager.isPracticeSession = false
            recordingManager.compositeClipOverlay = true
            recordingManager.clipLabel = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Camera

    @ViewBuilder
    private var camera: some View {
        if recordingManager.isSimulator {
            LinearGradient(colors: [Chalk.board, Chalk.board2], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .overlay(
                    Text("Practice — camera unavailable in Simulator")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Chalk.dust)
                )
        } else if recordingManager.isSessionReady, let session = recordingManager.captureSession {
            CameraPreviewView(session: session)
                .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
                .overlay(
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Starting camera…").foregroundColor(.white)
                    }
                )
        }
    }

    // MARK: - Chrome

    // Mirrors the game view's top-right icon slot (there it's Sahil-stats; here it's exit).
    private var closeButton: some View {
        Button { appState.goHome() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Chalk.chalk)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color(white: 0.08, opacity: 0.55)))
                .overlay(Circle().stroke(Chalk.chalk.opacity(0.3), lineWidth: 1.5))
        }
    }

    private let zoomPresets: [CGFloat] = [1, 2, 3, 5]

    // Compact resting state: a small "1.0×" badge at the bottom of the slot. Drag directly
    // on the slot (this area) to zoom — no tap-to-open first.
    private var zoomBadge: some View {
        VStack {
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .bold))
                Text(String(format: "%.1f×", zoom))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundColor(Chalk.yellow)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.06, opacity: 0.5), in: Capsule())
            .overlay(Capsule().stroke(Chalk.chalk.opacity(0.22), lineWidth: 1))
        }
    }

    // Optional session tag under the Practice chip.
    private var locationChip: some View {
        Button {
            locationDraft = location
            showLocationEditor = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: location.isEmpty ? "mappin.and.ellipse" : "mappin.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(location.isEmpty ? "Add tag" : location)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(location.isEmpty ? Chalk.chalk.opacity(0.6) : Chalk.yellow)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(white: 0.08, opacity: 0.45), in: Capsule())
            .overlay(Capsule().stroke(Chalk.chalk.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // Drag anywhere on the zoom slot to zoom (reveals the dial, then rotates it).
    private var zoomDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                revealWheel()
                let start = dragStartNorm ?? normFor(zoom)
                if dragStartNorm == nil { dragStartNorm = normFor(zoom) }
                // Drag left → rotate wheel → higher values to center (zoom in). ~260pt = full range.
                let newNorm = max(0, min(1, start - value.translation.width / 260))
                applyZoom(snap(zoomForNorm(newNorm)))
            }
            .onEnded { _ in dragStartNorm = nil }
    }

    private func normFor(_ z: CGFloat) -> CGFloat { log(z) / log(maxZoom) }
    private func zoomForNorm(_ t: CGFloat) -> CGFloat { pow(maxZoom, t) }
    private func snap(_ z: CGFloat) -> CGFloat {
        let t = normFor(z)
        for p in zoomPresets where abs(normFor(p) - t) < 0.02 { return p }
        return z
    }

    private func applyZoom(_ factor: CGFloat) {
        let clamped = max(1.0, min(factor, maxZoom))
        // setZoom clamps to the device max too, and returns what was actually applied.
        zoom = recordingManager.setZoom(factor: clamped)
    }

    // Show the dial and (re)arm the auto-hide timer. Called on every interaction.
    private func revealWheel() {
        if !showWheel { withAnimation(.easeOut(duration: 0.2)) { showWheel = true } }
        hideWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.25)) { showWheel = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private var practiceLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: "figure.basketball")
                .font(.system(size: 13, weight: .semibold))
            Text("Practice")
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundColor(Chalk.chalk)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.08, opacity: 0.5), in: Capsule())
        .overlay(Capsule().stroke(Chalk.chalk.opacity(0.22), lineWidth: 1))
    }
}

// MARK: - Radial Zoom Dial (iOS-style rotating wheel)

/// The wheel rotates under a fixed top caret so the current zoom sits at the top.
/// Presentational only — the parent drives zoom via a drag on the whole slot.
/// Log-scaled 1×–maxZoom.
private struct RadialZoomDial: View {
    let zoom: CGFloat
    let maxZoom: CGFloat
    let presets: [CGFloat]

    // Radians of arc per one unit of normalized zoom [0,1]. Full range spans ±(ANG/2).
    private let angPerUnit: CGFloat = 1.15
    private let visibleHalfAngle: CGFloat = 0.72   // ticks beyond this are off the visible arc

    private func norm(_ z: CGFloat) -> CGFloat { log(z) / log(maxZoom) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let r = w * 1.3
            let cx = w / 2
            let cy = r + 8          // circle center pushed below the band; only top arc shows
            let curT = norm(zoom)

            ZStack {
                // Ticks + labels
                Canvas { ctx, _ in
                    // Minor ticks every 0.02 of normalized range.
                    var tv: CGFloat = 0
                    while tv <= 1.0001 {
                        let a = (tv - curT) * angPerUnit
                        if abs(a) <= visibleHalfAngle {
                            let isMajor = presets.contains { abs(norm($0) - tv) < 0.008 }
                            let outerR = r
                            let innerR = r - (isMajor ? 16 : 9)
                            let sinA = sin(a), cosA = cos(a)
                            let p1 = CGPoint(x: cx + outerR * sinA, y: cy - outerR * cosA)
                            let p2 = CGPoint(x: cx + innerR * sinA, y: cy - innerR * cosA)
                            var path = Path()
                            path.move(to: p1); path.addLine(to: p2)
                            let shade = GraphicsContext.Shading.color(
                                Chalk.chalk.opacity(isMajor ? 0.7 : 0.32))
                            ctx.stroke(path, with: shade, lineWidth: isMajor ? 2 : 1)
                        }
                        tv += 0.02
                    }
                }

                // Preset labels
                ForEach(presets, id: \.self) { p in
                    let a = (norm(p) - curT) * angPerUnit
                    if abs(a) <= visibleHalfAngle {
                        let lr = r - 34
                        Text("\(Int(p))×")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(Chalk.chalk.opacity(0.75))
                            .position(x: cx + lr * sin(a), y: cy - lr * cos(a))
                    }
                }

                // Fixed caret + readout at the top (the current value lives here)
                VStack(spacing: 2) {
                    Text(String(format: "%.1f×", zoom))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(Chalk.yellow)
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Chalk.yellow)
                }
                .position(x: cx, y: 14)
            }
            .frame(width: w, height: h)
        }
    }
}
