//
//  GameSetupView.swift
//  SahilStatsLite
//
//  PURPOSE: Pre-game setup screen. Select opponent, team, location, half length
//           (18 or 20 min AAU). Auto-populates from calendar event if available.
//           Offers video recording or stats-only mode.
//  KEY TYPES: GameSetupView
//  DEPENDS ON: GimbalTrackingManager, AppState
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

struct GameSetupView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var gimbalManager = GimbalTrackingManager.shared

    // Teams loaded from UserDefaults
    @State private var teams: [String] = []
    @State private var selectedTeam: String = ""

    @State private var opponent: String = ""
    @State private var location: String = ""
    @State private var halfLength: Int = 18  // AAU: 18 or 20 minute halves
    @State private var recordVideo: Bool = true
    @State private var streamLive: Bool = false  // default OFF — enable per-game when signal is good
    @State private var isCreatingBroadcast: Bool = false
    @State private var broadcastURL: String = ""   // local state so SwiftUI re-renders on change
    @State private var broadcastError: String? = nil

    @FocusState private var isOpponentFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack {
                Button {
                    appState.currentScreen = .home
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(appState.isLogOnly ? "Log Game" : "New Game")
                    .font(.headline)

                Spacer()

                // Placeholder for balance
                Image(systemName: "xmark")
                    .font(.title2)
                    .foregroundColor(.clear)
            }
            .padding()

            ScrollView {
                VStack(spacing: 20) {
                    // Opponent
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Opponent")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("Team name", text: $opponent)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .focused($isOpponentFocused)
                    }

                    // Your Team
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Team")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if teams.count > 1 {
                            Picker("Team", selection: $selectedTeam) {
                                ForEach(Array(teams.enumerated()), id: \.offset) { _, team in
                                    Text(team).tag(team)
                                }
                            }
                            .pickerStyle(.segmented)
                        } else {
                            // Single team - just show it
                            Text(selectedTeam.isEmpty ? "No team configured" : selectedTeam)
                                .font(.title3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                        }
                    }

                    // Location (optional)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Location (optional)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("Gym or venue", text: $location)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Half Length (AAU games use halves)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Half Length")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Picker("Half Length", selection: $halfLength) {
                            Text("18 min").tag(18)
                            Text("20 min").tag(20)
                        }
                        .pickerStyle(.segmented)
                    }

                    // Record Video Toggle (only show when not in log-only mode)
                    if !appState.isLogOnly {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Record Video")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(recordVideo ? "Game will be recorded" : "Stats only, no video")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            Toggle("", isOn: $recordVideo)
                                .tint(.orange)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                    }

                    // Stream Live — only shown when recording video and stream key is set
                    if recordVideo && !appState.isLogOnly && !StreamingService.shared.savedStreamKey.isEmpty {
                        VStack(spacing: 0) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Stream Live")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Text(streamLive ? "YouTube • parents can watch" : "Record only, no stream")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Toggle("", isOn: $streamLive)
                                    .tint(.red)
                                    .onChange(of: streamLive) { _, on in
                                        if on {
                                            if YouTubeService.shared.isAuthorized {
                                                createBroadcast()
                                            } else {
                                                broadcastError = "Sign in to YouTube in Settings first"
                                                streamLive = false
                                            }
                                        } else {
                                            broadcastURL = ""
                                            broadcastError = nil
                                        }
                                    }
                            }
                            .padding()

                            // Share button — prominent, appears once broadcast URL is ready
                            if streamLive {
                                Divider().padding(.horizontal)
                                if isCreatingBroadcast {
                                    HStack(spacing: 8) {
                                        ProgressView().scaleEffect(0.8)
                                        Text("Getting your link…")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding()
                                } else if let err = broadcastError {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                        Text(err)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding()
                                } else if !broadcastURL.isEmpty {
                                    VStack(spacing: 8) {
                                        // Link preview
                                        Text(broadcastURL)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .padding(.horizontal)
                                        // Share button
                                        Button {
                                            let av = UIActivityViewController(
                                                activityItems: [URL(string: broadcastURL) ?? broadcastURL],
                                                applicationActivities: nil)
                                            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                               let root = scene.windows.first?.rootViewController {
                                                root.present(av, animated: true)
                                            }
                                        } label: {
                                            Label("Share Link (copied ✓)", systemImage: "square.and.arrow.up")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundColor(.white)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 12)
                                                .background(Color.red)
                                                .cornerRadius(10)
                                        }
                                        .padding(.horizontal)
                                        .padding(.bottom, 8)
                                    }
                                }
                            }
                        }
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                    }

                    // Gimbal Status (only show if recording video)
                    if recordVideo && !appState.isLogOnly {
                        gimbalStatusCard
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal)
            }

            // Start Button
            Button {
                startGame()
            } label: {
                HStack {
                    Image(systemName: appState.isLogOnly ? "pencil.line" : (recordVideo ? "video.fill" : "sportscourt.fill"))
                    Text(appState.isLogOnly ? "Enter Stats" : (recordVideo ? "Start Recording" : "Start Live Stats"))
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(opponent.isEmpty ? Color.gray : Color.orange)
                .cornerRadius(16)
            }
            .disabled(opponent.isEmpty)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            // Load teams from UserDefaults
            loadTeams()

            // Load default half length
            let savedHalfLength = UserDefaults.standard.integer(forKey: "defaultHalfLength")
            if savedHalfLength > 0 {
                halfLength = savedHalfLength
            }

            // Clear stale broadcast from previous game — each game gets a fresh URL
            StreamingService.shared.liveStreamURL = ""
            StreamingService.shared.currentBroadcastId = nil

            // Pre-fill from calendar if available
            if let pending = appState.pendingCalendarGame {
                opponent = pending.opponent
                location = pending.location

                // Auto-select team if detected from calendar
                if let detectedTeam = pending.team {
                    // Find matching team (case-insensitive)
                    if let matchingTeam = teams.first(where: { $0.lowercased() == detectedTeam.lowercased() }) {
                        selectedTeam = matchingTeam
                    } else if let matchingTeam = teams.first(where: { $0.lowercased().contains(detectedTeam.lowercased()) || detectedTeam.lowercased().contains($0.lowercased()) }) {
                        selectedTeam = matchingTeam
                    }
                }

                // Clear after use
                appState.pendingCalendarGame = nil
            }
            // Focus opponent field if empty
            if opponent.isEmpty {
                isOpponentFocused = true
            }

            // If streaming was already enabled from last game, create broadcast now.
            // onChange(of: streamLive) doesn't fire when the initial value is already true.
            if streamLive && !StreamingService.shared.savedStreamKey.isEmpty && YouTubeService.shared.isAuthorized {
                createBroadcast()
            }
        }
    }

    // MARK: - Gimbal Status

    private var gimbalStatusCard: some View {
        HStack {
            Image(systemName: gimbalManager.isDockKitAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(gimbalManager.isDockKitAvailable ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(gimbalManager.isDockKitAvailable ? "Gimbal Connected" : "No Gimbal Detected")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(gimbalManager.isDockKitAvailable ? "Auto-tracking ready" : "Recording will work, but no auto-tracking")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }

    // MARK: - Actions

    private func createBroadcast() {
        isCreatingBroadcast = true
        broadcastURL = ""
        broadcastError = nil
        StreamingService.shared.liveStreamURL = ""
        StreamingService.shared.currentBroadcastId = nil
        let team = selectedTeam.isEmpty ? "Home" : selectedTeam
        let opp = opponent.isEmpty ? "Away" : opponent
        let title = "\(team) vs \(opp)"
        debugPrint("[GameSetup] Creating broadcast: \(title)")
        Task {
            do {
                let (id, url) = try await YouTubeService.shared.createBroadcast(title: title)
                debugPrint("[GameSetup] Broadcast created: \(id) -> \(url)")
                await MainActor.run {
                    StreamingService.shared.currentBroadcastId = id
                    StreamingService.shared.liveStreamURL = url
                    broadcastURL = url          // drives the UI re-render
                    isCreatingBroadcast = false
                    UIPasteboard.general.string = url  // auto-copy to clipboard
                }
            } catch {
                debugPrint("[GameSetup] Broadcast creation FAILED: \(error)")
                await MainActor.run {
                    isCreatingBroadcast = false
                    broadcastError = "Couldn't create broadcast: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadTeams() {
        // Single source of truth: the same list Settings ("My Teams") edits via
        // GameCalendarManager.knownTeamNames. Previously this read an orphaned
        // "myTeams" key that nothing ever wrote — so teams added in Settings
        // (a 4th team, etc.) never showed up here.
        let known = GameCalendarManager.shared.knownTeamNames
        if !known.isEmpty {
            teams = known
        } else if let oldTeam = UserDefaults.standard.string(forKey: "myTeamName"), !oldTeam.isEmpty {
            teams = [oldTeam]
        } else {
            teams = ["Wildcats"]
        }
        // Select first team by default
        if selectedTeam.isEmpty, let first = teams.first {
            selectedTeam = first
        }
    }

    private func startGame() {
        // Save preferences
        UserDefaults.standard.set(halfLength, forKey: "defaultHalfLength")
        
        var game = Game(
            opponent: opponent,
            teamName: selectedTeam,
            location: location.isEmpty ? nil : location
        )
        game.halfLength = halfLength
        appState.currentGame = game

        // Navigate based on mode
        if appState.isLogOnly {
            appState.currentScreen = .statsEntry
        } else {
            appState.isStatsOnly = !recordVideo
            // Apply per-game streaming decision
            StreamingService.shared.streamingEnabled = streamLive && recordVideo
            appState.currentScreen = .recording
        }
    }
}

#Preview {
    GameSetupView()
        .environmentObject(AppState())
}
