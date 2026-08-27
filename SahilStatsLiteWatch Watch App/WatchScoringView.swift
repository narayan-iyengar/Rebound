//
//  WatchScoringView.swift
//  SahilStatsLiteWatch
//
//  PURPOSE: Primary scoring screen during games. Tap score zones to add +1,
//           swipe away to subtract -1. Shows live/paused indicator, period,
//           clock with blinking colon. Long-press clock to end game.
//           Auto-adapts layout for Series 8 (45mm) and Ultra 2 (49mm).
//  KEY TYPES: WatchScoringView
//  DEPENDS ON: WatchConnectivityClient, WatchLayout
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import Combine
import WatchKit

struct WatchScoringView: View {
    @EnvironmentObject var connectivity: WatchConnectivityClient
    @State private var showEndGame: Bool = false
    @State private var myFeedback: Int? = nil
    @State private var oppFeedback: Int? = nil
    @State private var colonVisible: Bool = true
    @State private var clipSent: Bool = false
    @State private var clipInFlight: Bool = false

    private let layout: WatchLayout

    init(layout: WatchLayout = .current) {
        self.layout = layout
    }

    private var clockMinutes: String {
        String(connectivity.remainingSeconds / 60)
    }

    private var clockSeconds: String {
        String(format: "%02d", connectivity.remainingSeconds % 60)
    }

    // Warmup-aware status shown in the header pill and clock helper. Warmup means the
    // phone camera is calibrating and the clock hasn't started — so a paused 18:00 reads
    // as "get ready", not "stopped game".
    private var statusText: String {
        if connectivity.isWarmup { return "WARM-UP" }
        return connectivity.isClockRunning ? "LIVE" : "PAUSED"
    }
    private var statusColor: Color {
        if connectivity.isWarmup { return WChalk.sky }
        return connectivity.isClockRunning ? WChalk.green : WChalk.yellow
    }
    private var clockHelperText: String {
        if connectivity.isWarmup { return "tap clock to start" }
        return connectivity.isClockRunning ? "running" : "hold to end"
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [WChalk.board2, WChalk.board], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header: combined on smaller screens, separate on Ultra
                if layout.combinedHeader {
                    compactHeader
                        .padding(.top, 4)
                } else {
                    liveIndicator
                        .padding(.top, 4)
                    periodButton
                        .padding(.top, 2)
                }

                // Score area - takes all remaining space
                HStack(spacing: 0) {
                    // My team
                    scoreZone(
                        score: connectivity.myScore,
                        name: connectivity.teamName,
                        isMyTeam: true,
                        feedback: myFeedback,
                        onTap: { handleMyTeamTap() },
                        onSwipeDown: { handleMyTeamSwipeDown() }
                    )

                    // Center divider
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, WChalk.chalk.opacity(0.15), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 1)
                        .padding(.vertical, 10)

                    // Opponent
                    scoreZone(
                        score: connectivity.oppScore,
                        name: connectivity.opponent,
                        isMyTeam: false,
                        feedback: oppFeedback,
                        onTap: { handleOppTeamTap() },
                        onSwipeDown: { handleOppTeamSwipeDown() }
                    )
                }
                .frame(maxHeight: .infinity)

                // Clock
                clockArea

                // Clip from the wrist → phone saves a highlight
                watchClipButton
                    .padding(.horizontal, 18)
                    .padding(.bottom, layout.showSwipeHint ? 2 : 5)

                // Swipe hint (Ultra only - extra room)
                if layout.showSwipeHint {
                    swipeHint
                        .padding(.bottom, 4)
                }
            }

            // End game confirmation
            if showEndGame {
                endGameOverlay
            }
            
            // Ending spinner
            if connectivity.isEnding {
                endingSpinner
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            if connectivity.isClockRunning {
                colonVisible.toggle()
            } else {
                colonVisible = true
            }
        }
    }

    // MARK: - Clip from the wrist

    // Can we actually clip? Only when the phone is reachable AND its clip ring is armed
    // (i.e. it's recording / stats-only buffering). Prevents phantom "Clipped" on a
    // watch-only test when the phone isn't recording.
    private var canClip: Bool { connectivity.isPhoneReachable && connectivity.phoneClipArmed }

    private var watchClipButton: some View {
        Button {
            if clipInFlight {
                // Second press while capturing → cut the forward window short and save now.
                connectivity.sendClipStop()
            } else if canClip {
                connectivity.sendClip()
                clipInFlight = true
                // Failsafe: never let the button hang if a save confirmation is lost.
                // (Forward window defaults to 20s; 35s leaves comfortable margin.)
                DispatchQueue.main.asyncAfter(deadline: .now() + 35) {
                    if clipInFlight && !clipSent { clipInFlight = false }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: clipSent ? "checkmark" : (clipInFlight ? "stop.fill" : "scissors"))
                    .font(.system(size: 11, weight: .bold))
                Text(clipSent ? "Clipped" : (clipInFlight ? "Stop & Save" : (canClip ? "Clip" : "Not recording")))
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor((canClip || clipInFlight || clipSent) ? WChalk.board : WChalk.chalk.opacity(0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Capsule().fill(
                clipSent ? WChalk.green : ((canClip || clipInFlight) ? WChalk.coral : WChalk.chalk.opacity(0.14))
            ))
        }
        .buttonStyle(.plain)
        .disabled(!canClip && !clipInFlight)
        .onChange(of: connectivity.clipSavedTick) { _, _ in
            clipInFlight = false
            clipSent = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { clipSent = false }
        }
    }

    // MARK: - Compact Header (Series 8 / smaller - live + period on one line)

    private var compactHeader: some View {
        HStack {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                Text(statusText)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(statusColor)

                // Mode: recording with the phone (video) vs watch-only stats.
                Image(systemName: connectivity.phoneClipArmed ? "video.fill" : "pencil")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(connectivity.phoneClipArmed ? WChalk.sky : WChalk.dust)
            }

            Spacer()

            Button {
                connectivity.advancePeriod()
            } label: {
                Text(connectivity.period)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WChalk.chalk.opacity(0.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(WChalk.chalk.opacity(0.08))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Live Indicator (Ultra - separate line)

    private var liveIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(statusText)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(statusColor)
        }
    }

    // MARK: - Period Button (Ultra - separate line)

    private var periodButton: some View {
        Button {
            connectivity.advancePeriod()
        } label: {
            Text(connectivity.period)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(WChalk.chalk.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(WChalk.chalk.opacity(0.08))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Score Zone (adaptive)

    private func scoreZone(
        score: Int,
        name: String,
        isMyTeam: Bool,
        feedback: Int?,
        onTap: @escaping () -> Void,
        onSwipeDown: @escaping () -> Void
    ) -> some View {
        VStack(spacing: layout.scoreZoneSpacing) {
            ZStack {
                Text("\(score)")
                    .font(.system(size: layout.scoreFontSize, weight: .bold, design: .rounded))
                    .foregroundColor(WChalk.chalk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WChalk.chalk.opacity(0.05))
                    .cornerRadius(12)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 15)
                            .onEnded { value in
                                let isVertical = abs(value.translation.height) > abs(value.translation.width) * 1.2
                                let isDownward = value.translation.height > 20
                                if isDownward && isVertical {
                                    WKInterfaceDevice.current().play(.click)
                                    onSwipeDown()
                                }
                            }
                    )
                    .onTapGesture {
                        WKInterfaceDevice.current().play(.click)
                        onTap()
                    }

                if let points = feedback {
                    Text(points > 0 ? "+\(points)" : "\(points)")
                        .font(.system(size: layout.feedbackFontSize, weight: .bold))
                        .foregroundColor(points > 0 ? WChalk.yellow : .red)
                        .offset(y: -30)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            Text(String(name.prefix(4)).uppercased())
                .font(.system(size: layout.teamNameFontSize, weight: .semibold))
                .foregroundColor(isMyTeam ? WChalk.yellow : WChalk.chalk.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Clock Area (adaptive)

    private var clockArea: some View {
        VStack(spacing: (layout.showClockHelper || connectivity.isWarmup) ? 4 : 2) {
            clockButton

            // Always surface the helper during warmup — that's the moment it matters most,
            // even on the compact (Series 8) layout that normally hides it.
            if layout.showClockHelper || connectivity.isWarmup {
                Text(clockHelperText)
                    .font(.system(size: 9, weight: connectivity.isWarmup ? .bold : .medium))
                    .foregroundColor(connectivity.isWarmup ? WChalk.sky : WChalk.chalk.opacity(0.3))
                    .allowsHitTesting(false)
            }
        }
        .padding(.vertical, layout.clockVerticalPadding)
    }

    private var clockButton: some View {
        HStack(spacing: 0) {
            Text(clockMinutes)
                .font(.system(size: layout.clockFontSize, weight: .semibold, design: .monospaced))
            Text(":")
                .font(.system(size: layout.clockFontSize, weight: .semibold, design: .monospaced))
                .opacity(connectivity.isClockRunning ? (colonVisible ? 1.0 : 0.0) : 1.0)
            Text(clockSeconds)
                .font(.system(size: layout.clockFontSize, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(connectivity.isClockRunning ? WChalk.chalk : WChalk.yellow)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(WChalk.chalk.opacity(0.1))
        .cornerRadius(8)
        .onTapGesture {
            connectivity.toggleClock()
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            showEndGame = true
        }
    }

    // MARK: - Swipe Hint

    private var swipeHint: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2)
                .fill(WChalk.chalk.opacity(0.3))
                .frame(width: 30, height: 3)

            Text("Stats")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(WChalk.chalk.opacity(0.3))
        }
    }

    // MARK: - End Game Overlay

    private var endGameOverlay: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()

            VStack(spacing: 12) {
                Text("End Game?")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(WChalk.chalk)

                Text("\(connectivity.myScore) - \(connectivity.oppScore)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(connectivity.myScore > connectivity.oppScore ? WChalk.green : (connectivity.myScore < connectivity.oppScore ? WChalk.coral : WChalk.chalk))

                HStack(spacing: 12) {
                    Button {
                        showEndGame = false
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(WChalk.chalk)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(WChalk.chalk.opacity(0.2))
                            .cornerRadius(16)
                    }
                    .buttonStyle(.plain)

                    Button {
                        connectivity.endGame()
                        showEndGame = false
                    } label: {
                        Text("End")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(WChalk.yellow)
                            .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Ending Spinner
    
    private var endingSpinner: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()
            
            VStack(spacing: 12) {
                ProgressView()
                    .tint(WChalk.yellow)
                    .scaleEffect(1.5)
                
                Text("Ending Game...")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(WChalk.chalk)
                
                Text("Saving video on phone")
                    .font(.system(size: 11))
                    .foregroundColor(WChalk.chalk.opacity(0.7))
            }
        }
    }

    // MARK: - Actions

    private func handleMyTeamTap() {
        connectivity.addScore(team: "my", points: 1)
        withAnimation(.spring(response: 0.3)) {
            myFeedback = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation {
                myFeedback = nil
            }
        }
    }

    private func handleOppTeamTap() {
        connectivity.addScore(team: "opp", points: 1)
        withAnimation(.spring(response: 0.3)) {
            oppFeedback = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation {
                oppFeedback = nil
            }
        }
    }

    private func handleMyTeamSwipeDown() {
        connectivity.subtractScore(team: "my", points: 1)
        withAnimation(.spring(response: 0.3)) {
            myFeedback = -1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation {
                myFeedback = nil
            }
        }
    }

    private func handleOppTeamSwipeDown() {
        connectivity.subtractScore(team: "opp", points: 1)
        withAnimation(.spring(response: 0.3)) {
            oppFeedback = -1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation {
                oppFeedback = nil
            }
        }
    }
}

// MARK: - Previews (compare both sizes in Xcode Canvas)

#Preview("Series 8 — 45mm (TinyPod)") {
    WatchConnectivityClient.configureForPreview()
    return WatchScoringView(layout: .preview45mm)
        .environmentObject(WatchConnectivityClient.shared)
}

#Preview("Ultra 2 — 49mm (PodX)") {
    WatchConnectivityClient.configureForPreview()
    return WatchScoringView(layout: .preview49mm)
        .environmentObject(WatchConnectivityClient.shared)
}

#Preview("Compact — 41mm") {
    WatchConnectivityClient.configureForPreview()
    return WatchScoringView(layout: .preview41mm)
        .environmentObject(WatchConnectivityClient.shared)
}
