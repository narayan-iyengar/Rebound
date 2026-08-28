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
    @State private var slideStartNorm: CGFloat?      // captured at the start of a slide
    @State private var showZoomHUD = false           // transient "2.4×" readout while zooming
    @State private var hudWork: DispatchWorkItem?
    private let maxZoom: CGFloat = 6.0

    // Optional freeform tag saved onto this session's clips (e.g. gym / drill name).
    @State private var location: String = ""
    @State private var showLocationEditor = false
    @State private var locationDraft: String = ""

    var body: some View {
        ZStack {
            camera
                // Slide a thumb anywhere on the preview to zoom — up/right zooms in,
                // down/left zooms out (whichever axis you move more).
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            let start = slideStartNorm ?? normFor(zoom)
                            if slideStartNorm == nil { slideStartNorm = normFor(zoom) }
                            let t = value.translation
                            let delta = abs(t.height) >= abs(t.width) ? -t.height : t.width
                            let newNorm = max(0, min(1, start + delta / 300))
                            applyZoom(zoomForNorm(newNorm))
                            flashZoomHUD()
                        }
                        .onEnded { _ in slideStartNorm = nil; pinchBaseZoom = zoom }
                )
                // Pinch still works for those who reach for it.
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale in applyZoom(pinchBaseZoom * scale); flashZoomHUD() }
                        .onEnded { _ in pinchBaseZoom = zoom }
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

            // Transient zoom readout, shown only while sliding/pinching.
            if showZoomHUD {
                Text(String(format: "%.1f×", zoom))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundColor(Chalk.chalk)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Color(white: 0.05, opacity: 0.55), in: Capsule())
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            // Bottom bar: iOS-timelapse-style lens pills + the circular Clip button.
            // (Slide/pinch on the preview also zoom, for fine control.)
            VStack(spacing: 18) {
                Spacer()
                zoomPills
                ClipButton(idleHint: "Camera warming up…", scale: 1.4, circle: true)
                    .padding(.bottom, 26)
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

    // Zoom is a thumb-slide on the preview — log-scaled 1×–maxZoom.
    private func normFor(_ z: CGFloat) -> CGFloat { log(z) / log(maxZoom) }
    private func zoomForNorm(_ t: CGFloat) -> CGFloat { pow(maxZoom, t) }

    private let zoomPresets: [CGFloat] = [1, 2, 3, 5]
    private func isActiveZoom(_ p: CGFloat) -> Bool { abs(zoom - p) < 0.15 }

    // iOS-timelapse-style lens pills: tap to jump, active one shows the exact level.
    private var zoomPills: some View {
        HStack(spacing: 14) {
            ForEach(zoomPresets, id: \.self) { p in
                Button {
                    applyZoom(p); pinchBaseZoom = p
                } label: {
                    Text(isActiveZoom(p) ? String(format: "%.1f×", zoom) : "\(Int(p))")
                        .font(.system(size: isActiveZoom(p) ? 15 : 13, weight: .bold, design: .rounded))
                        .foregroundColor(isActiveZoom(p) ? Chalk.yellow : Chalk.chalk.opacity(0.9))
                        .frame(minWidth: isActiveZoom(p) ? 46 : 26, minHeight: isActiveZoom(p) ? 46 : 26)
                        .background(Circle().fill(Color.black.opacity(isActiveZoom(p) ? 0.4 : 0)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Briefly show the zoom readout, hiding shortly after the last movement.
    private func flashZoomHUD() {
        if !showZoomHUD { withAnimation(.easeOut(duration: 0.15)) { showZoomHUD = true } }
        hudWork?.cancel()
        let work = DispatchWorkItem { withAnimation(.easeIn(duration: 0.3)) { showZoomHUD = false } }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
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
