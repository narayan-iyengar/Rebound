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
    private let maxZoom: CGFloat = 6.0

    var body: some View {
        ZStack {
            camera
                // Pinch anywhere on the preview to zoom (1×–maxZoom).
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            applyZoom(pinchBaseZoom * scale)
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

            VStack {
                practiceLabel
                    .padding(.top, 12)
                Spacer()
            }

            // Bottom bar: iOS-style zoom ruler over a centered Clip button. Thumb-reachable
            // in both orientations.
            VStack(spacing: 12) {
                Spacer()
                zoomRuler
                    .frame(height: 44)
                    .padding(.horizontal, 24)
                ClipButton(idleHint: "Camera warming up…")
                    .padding(.bottom, 18)
            }
        }
        .statusBar(hidden: true)
        .persistentSystemOverlays(.hidden)
        .task {
            // Arm a clip-only session: camera on, buffering, no file recording, no overlay.
            recordingManager.reset()
            recordingManager.isPracticeSession = true
            recordingManager.compositeClipOverlay = false
            recordingManager.currentClipGameId = sessionId
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

    // iOS-style zoom ruler: a tick track with lens labels; drag to zoom, snaps softly to
    // presets. Pinch on the preview still works for fine control.
    private let zoomPresets: [CGFloat] = [1, 2, 3, 5]

    private func normFor(_ z: CGFloat) -> CGFloat { log(z) / log(maxZoom) }   // [1,max] → [0,1]
    private func zoomForNorm(_ t: CGFloat) -> CGFloat { pow(maxZoom, t) }

    private var zoomRuler: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let midY = geo.size.height / 2
            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color(white: 0.06, opacity: 0.5))
                    .overlay(Capsule().stroke(Chalk.chalk.opacity(0.18), lineWidth: 1))

                // Ticks
                Canvas { ctx, size in
                    let minorColor = GraphicsContext.Shading.color(Chalk.chalk.opacity(0.35))
                    var t: CGFloat = 0
                    while t <= 1.0001 {
                        let x = t * size.width
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: midY - 4))
                        p.addLine(to: CGPoint(x: x, y: midY + 4))
                        ctx.stroke(p, with: minorColor, lineWidth: 1)
                        t += 0.05
                    }
                    // Major ticks at presets
                    for preset in zoomPresets {
                        let x = normFor(preset) * size.width
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: midY - 9))
                        p.addLine(to: CGPoint(x: x, y: midY + 9))
                        ctx.stroke(p, with: .color(Chalk.chalk.opacity(0.6)), lineWidth: 1.5)
                    }
                }

                // Preset labels
                ForEach(zoomPresets, id: \.self) { preset in
                    Text("\(Int(preset))×")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Chalk.chalk.opacity(0.55))
                        .position(x: normFor(preset) * w, y: midY + 16)
                }

                // Current-zoom needle + readout
                let x = normFor(zoom) * w
                Capsule()
                    .fill(Chalk.yellow)
                    .frame(width: 3, height: 26)
                    .position(x: x, y: midY)
                Text(String(format: "%.1f×", zoom))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(Chalk.yellow)
                    .fixedSize()
                    .position(x: min(max(x, 20), w - 20), y: midY - 16)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = max(0, min(1, value.location.x / w))
                        applyZoom(snap(zoomForNorm(t)))
                        pinchBaseZoom = zoom
                    }
            )
        }
    }

    // Soft-snap to a preset when within a small distance (in normalized ruler space).
    private func snap(_ z: CGFloat) -> CGFloat {
        let t = normFor(z)
        for preset in zoomPresets where abs(normFor(preset) - t) < 0.028 {
            return preset
        }
        return z
    }

    private func applyZoom(_ factor: CGFloat) {
        let clamped = max(1.0, min(factor, maxZoom))
        // setZoom clamps to the device max too, and returns what was actually applied.
        zoom = recordingManager.setZoom(factor: clamped)
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
