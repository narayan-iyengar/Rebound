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
    // One-off guest team (Sahil guesting for another team) — used for THIS game only,
    // never saved to knownTeamNames.
    @State private var isGuest: Bool = false
    @State private var guestTeam: String = ""

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
                        .foregroundColor(Chalk.dust)
                }

                Spacer()

                Text(appState.isLogOnly ? "Log Game" : "New Game")
                    .font(.chalkScript(30))
                    .foregroundColor(Chalk.chalk)

                Spacer()

                // Placeholder for balance
                Image(systemName: "xmark")
                    .font(.title2)
                    .foregroundColor(.clear)
            }
            .padding()

            ScrollView {
                VStack(spacing: 22) {
                    // Opponent
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("opponent")

                        TextField("", text: $opponent, prompt: chalkPrompt("Team name"))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(Chalk.crisp)
                            .tint(Chalk.yellow)
                            .padding(12)
                            .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Chalk.chalk.opacity(0.25), lineWidth: 1.5))
                            .focused($isOpponentFocused)
                    }

                    // Your Team — known teams + a one-off "Other" (guest) chip
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("your team")

                        HStack(spacing: 8) {
                            ForEach(Array(teams.enumerated()), id: \.offset) { _, team in
                                teamChip(label: team, selected: !isGuest && selectedTeam == team) {
                                    isGuest = false
                                    selectedTeam = team
                                }
                            }
                            teamChip(label: "+ Other", selected: isGuest) {
                                isGuest = true
                                selectedTeam = guestTeam.trimmingCharacters(in: .whitespaces)
                            }
                        }

                        if isGuest {
                            TextField("", text: $guestTeam, prompt: chalkPrompt("Guest team name"))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(Chalk.crisp)
                                .tint(Chalk.yellow)
                                .padding(12)
                                .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Chalk.chalk.opacity(0.25), lineWidth: 1.5))
                                .onChange(of: guestTeam) { _, v in
                                    selectedTeam = v.trimmingCharacters(in: .whitespaces)
                                }
                            Text("Used for this game only — not saved to your teams")
                                .font(.system(size: 12))
                                .foregroundColor(Chalk.dust)
                        }
                    }

                    // Location (optional)
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("location (optional)")

                        TextField("", text: $location, prompt: chalkPrompt("Gym or venue"))
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(Chalk.crisp)
                            .tint(Chalk.yellow)
                            .padding(12)
                            .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Chalk.chalk.opacity(0.25), lineWidth: 1.5))
                    }

                    // Half Length (AAU games use halves)
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("half length")

                        ChalkSegmentedPicker(
                            options: [(label: "18 min", value: 18), (label: "20 min", value: 20)],
                            selection: $halfLength,
                            useChalkFont: false
                        )
                    }

                    // Record Video Toggle (only show when not in log-only mode)
                    if !appState.isLogOnly {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("record video")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Chalk.chalk)
                                Text(recordVideo ? "Game will be recorded" : "Stats only, no video")
                                    .font(.system(size: 12))
                                    .foregroundColor(Chalk.dust)
                            }

                            Spacer()

                            Toggle("", isOn: $recordVideo)
                                .labelsHidden()
                                .tint(Chalk.green)
                        }
                        .chalkCard()
                    }

                    // Stream Live — only shown when recording video and stream key is set
                    if recordVideo && !appState.isLogOnly && !StreamingService.shared.savedStreamKey.isEmpty {
                        VStack(spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("stream live")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(Chalk.chalk)
                                    Text(streamLive ? "YouTube • parents can watch" : "Record only, no stream")
                                        .font(.system(size: 12))
                                        .foregroundColor(Chalk.dust)
                                }
                                Spacer()
                                Toggle("", isOn: $streamLive)
                                    .labelsHidden()
                                    .tint(Chalk.green)
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

                            // Share button — prominent, appears once broadcast URL is ready
                            if streamLive {
                                Divider().overlay(Chalk.chalk.opacity(0.2))
                                if isCreatingBroadcast {
                                    HStack(spacing: 8) {
                                        ProgressView().scaleEffect(0.8).tint(Chalk.chalk)
                                        Text("Getting your link…")
                                            .font(.system(size: 15))
                                            .foregroundColor(Chalk.dust)
                                    }
                                } else if let err = broadcastError {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(Chalk.coral)
                                        Text(err)
                                            .font(.system(size: 13))
                                            .foregroundColor(Chalk.dust)
                                    }
                                } else if !broadcastURL.isEmpty {
                                    VStack(spacing: 8) {
                                        // Link preview
                                        Text(broadcastURL)
                                            .font(.system(size: 12))
                                            .foregroundColor(Chalk.dust)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        // Share button
                                        ChalkButton(title: "Share Link (copied ✓)",
                                                    icon: "square.and.arrow.up",
                                                    color: Chalk.coral) {
                                            let av = UIActivityViewController(
                                                activityItems: [URL(string: broadcastURL) ?? broadcastURL],
                                                applicationActivities: nil)
                                            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                               let root = scene.windows.first?.rootViewController {
                                                root.present(av, animated: true)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .chalkCard()
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
            ChalkButton(
                title: appState.isLogOnly ? "Enter Stats" : (recordVideo ? "Start Recording" : "Start Live Stats"),
                icon: appState.isLogOnly ? "pencil.line" : (recordVideo ? "video.fill" : "sportscourt.fill"),
                color: opponent.isEmpty ? Chalk.dust : Chalk.yellow
            ) {
                startGame()
            }
            .disabled(opponent.isEmpty)
            .opacity(opponent.isEmpty ? 0.6 : 1)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .chalkBoard()
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
                .foregroundColor(gimbalManager.isDockKitAvailable ? Chalk.green : Chalk.coral)

            VStack(alignment: .leading, spacing: 2) {
                Text(gimbalManager.isDockKitAvailable ? "gimbal connected" : "no gimbal detected")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Chalk.chalk)

                Text(gimbalManager.isDockKitAvailable ? "Auto-tracking ready" : "Recording will work, but no auto-tracking")
                    .font(.system(size: 12))
                    .foregroundColor(Chalk.dust)
            }

            Spacer()
        }
        .chalkCard()
    }

    // MARK: - Chalk helpers (presentation only)

    /// Clean system field label (accent rule: chalk stays on titles/CTAs only).
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Chalk.dust)
    }

    /// Dimmed placeholder that reads on the dark board.
    private func chalkPrompt(_ text: String) -> Text {
        Text(text).foregroundColor(Chalk.dust)
    }

    /// One team chip (matches ChalkSegmentedPicker styling).
    private func teamChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: selected ? .bold : .medium))
                .foregroundColor(selected ? Chalk.board : Chalk.chalkDim)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? Chalk.yellow : Chalk.board2,
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.clear : Chalk.chalk.opacity(0.2), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
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

// MARK: - Chalk segmented picker (presentation-only chip row)
//
// Drives the same binding a SwiftUI segmented Picker would; only the look changes.
// Selected chip = Chalk.yellow fill with board-dark text; unselected = chalkDim on
// dark. Labels use a clean SYSTEM font (accent rule: picker labels are controls, not
// headings) — `useChalkFont` is retained for call-site compatibility.

private struct ChalkSegmentedPicker<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T
    var useChalkFont: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Key on offset so duplicate labels/values can't collide as SwiftUI ids.
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let isSelected = opt.value == selection
                Button {
                    selection = opt.value
                } label: {
                    Text(opt.label)
                        .font(font(selected: isSelected))
                        .foregroundColor(isSelected ? Chalk.board : Chalk.chalkDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isSelected ? Chalk.yellow : Chalk.board2,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isSelected ? Color.clear : Chalk.chalk.opacity(0.2),
                                          lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func font(selected: Bool) -> Font {
        useChalkFont
            ? .chalkHand(16)
            : .system(size: 15, weight: selected ? .bold : .semibold)
    }
}

#Preview {
    GameSetupView()
        .environmentObject(AppState())
}
