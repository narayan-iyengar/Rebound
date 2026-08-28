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

            // Bottom bar: zoom pill + Clip button, thumb-reachable, portrait & landscape.
            VStack {
                Spacer()
                HStack(alignment: .center) {
                    zoomPill
                    Spacer()
                    ClipButton(idleHint: "Camera warming up…")
                    Spacer()
                    // Invisible spacer matching the zoom pill keeps the Clip button centered.
                    zoomPill.opacity(0).disabled(true)
                }
                .padding(.horizontal, 18)
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

    // Thumb-friendly zoom control: shows the current level, tap to cycle 1× → 2× → 3×.
    // (Pinch on the preview handles fine-grained zoom.)
    private var zoomPill: some View {
        Button(action: cycleZoomPreset) {
            Text(String(format: "%.1f×", zoom))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(Chalk.chalk)
                .frame(minWidth: 52)
                .padding(.vertical, 10)
                .background(Color(white: 0.08, opacity: 0.55), in: Capsule())
                .overlay(Capsule().stroke(Chalk.chalk.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func cycleZoomPreset() {
        // 1× → 2× → 3× → back to 1×
        let next: CGFloat = zoom < 1.75 ? 2.0 : (zoom < 2.75 ? 3.0 : 1.0)
        applyZoom(next)
        pinchBaseZoom = zoom
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
