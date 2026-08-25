//
//  PracticeView.swift
//  SahilStatsLite
//
//  PURPOSE: Practice-mode clipping. A stripped-down capture screen with no game,
//           no score, no clock — just the live camera buffering the clip ring, and
//           a Clip button. Saved clips are tagged "Practice" and land in the same
//           Store, grouped under a "Practice · date" header.
//  KEY TYPES: PracticeView
//  DEPENDS ON: RecordingManager (clip ring), ClipBuffer, CameraPreviewView
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

struct PracticeView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var recordingManager = RecordingManager.shared

    @State private var sessionId = UUID().uuidString
    @State private var clipPulse = false
    @State private var clipRecPulse = false

    var body: some View {
        ZStack {
            camera

            VStack {
                topBar
                Spacer()
                clipButton
                    .padding(.bottom, 34)
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

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { appState.goHome() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Chalk.chalk)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(white: 0.08, opacity: 0.55)))
                    .overlay(Circle().stroke(Chalk.chalk.opacity(0.3), lineWidth: 1.5))
            }
            .padding(.leading, 16)

            Spacer()

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

            Spacer()

            // Balance the X so the pill stays centered.
            Color.clear.frame(width: 40, height: 40).padding(.trailing, 16)
        }
        .padding(.top, 12)
    }

    // MARK: - Clip button (mirrors the game view's flow, minus score chrome)

    private var clipButton: some View {
        Button {
            switch recordingManager.clipState {
            case .clipping:
                recordingManager.stopClip()
            case .saving, .saved:
                break
            default:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeOut(duration: 0.10)) { clipPulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.easeIn(duration: 0.18)) { clipPulse = false }
                }
                recordingManager.triggerClip()
            }
        } label: {
            clipLabel
                .foregroundColor(Chalk.board)
                .padding(.horizontal, 26)
                .padding(.vertical, 15)
                .background(clipBackground, in: Capsule())
                .shadow(color: Chalk.coral.opacity(clipPulse ? 0.8 : 0.4), radius: clipPulse ? 14 : 8, y: 2)
                .scaleEffect(clipPulse ? 1.10 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: recordingManager.clipState)
    }

    @ViewBuilder
    private var clipLabel: some View {
        switch recordingManager.clipState {
        case .clipping(let remaining):
            HStack(spacing: 8) {
                Circle().fill(Chalk.board).frame(width: 9, height: 9)
                    .opacity(clipRecPulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: clipRecPulse)
                Text("Clipping \(remaining)s — tap to stop")
                    .font(.system(size: 16, weight: .bold)).monospacedDigit()
            }
            .onAppear { clipRecPulse = true }
            .onDisappear { clipRecPulse = false }
        case .saving:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8).tint(Chalk.board)
                Text("Saving…").font(.system(size: 16, weight: .bold))
            }
        case .saved:
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                Text("Saved").font(.system(size: 16, weight: .bold))
            }
        case .idle:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7).tint(Chalk.board)
                Text("Warming up…").font(.system(size: 16, weight: .bold))
            }
        case .buffering:
            HStack(spacing: 8) {
                Circle().fill(Chalk.board).frame(width: 9, height: 9)
                Text("Clip").font(.system(size: 16, weight: .bold))
            }
        }
    }

    private var clipBackground: Color {
        switch recordingManager.clipState {
        case .saved: return Chalk.green
        case .idle: return Chalk.coral.opacity(0.5)
        default: return Chalk.coral
        }
    }
}
