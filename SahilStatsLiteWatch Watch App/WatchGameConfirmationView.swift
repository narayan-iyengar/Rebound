//
//  WatchGameConfirmationView.swift
//  SahilStatsLiteWatch
//
//  PURPOSE: Pre-game confirmation screen on Watch. Shows opponent, team,
//           and time for a selected upcoming game. Start Recording button
//           sends startGame message to iPhone via WatchConnectivity.
//  KEY TYPES: WatchGameConfirmationView
//  DEPENDS ON: WatchConnectivityClient, WatchGame
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

struct WatchGameConfirmationView: View {
    let game: WatchGame
    @EnvironmentObject var connectivity: WatchConnectivityClient
    @Environment(\.dismiss) private var dismiss

    @State private var isStarting = false
    @State private var selectedHalfLength: Int = 18
    @State private var selectedFormat: String = "halves"   // "halves" or "quarters"
    @State private var editedOpponent: String = ""
    @State private var editedTeam: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Game info card
                VStack(spacing: 8) {
                    // Your team
                    HStack(spacing: 4) {
                        Circle()
                            .fill(WChalk.yellow)
                            .frame(width: 6, height: 6)
                        TextField("My Team", text: $editedTeam)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(WChalk.yellow)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                    }

                    // Opponent (big)
                    HStack(spacing: 4) {
                        Text("vs")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(WChalk.chalk.opacity(0.7))
                        
                        TextField("Opponent", text: $editedOpponent)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(WChalk.chalk)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                    }

                    Divider()
                        .background(WChalk.chalk.opacity(0.2))
                        .padding(.vertical, 4)

                    // Time
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(WChalk.chalk.opacity(0.5))

                        if game.isToday {
                            Text(game.timeString)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(WChalk.chalk)
                        } else {
                            Text("\(game.dayString) \(game.timeString)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(WChalk.chalk)
                        }
                    }

                    // Location (if available)
                    if !game.location.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 10))
                                .foregroundColor(WChalk.chalk.opacity(0.5))
                            Text(game.location)
                                .font(.system(size: 10))
                                .foregroundColor(WChalk.chalk.opacity(0.7))
                                .lineLimit(1)
                        }
                    }

                    // Half length (Tappable to change)
                    Button(action: {
                        // Toggle between 18 and 20
                        if selectedHalfLength == 18 {
                            selectedHalfLength = 20
                        } else {
                            selectedHalfLength = 18
                        }
                        WKInterfaceDevice.current().play(.click)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                                .font(.system(size: 10))
                                .foregroundColor(WChalk.yellow)
                            Text("\(selectedHalfLength) min \(selectedFormat == "quarters" ? "quarters" : "halves")")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(WChalk.yellow)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundColor(WChalk.yellow.opacity(0.7))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(WChalk.yellow.opacity(0.15))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    // Format toggle: halves ↔ quarters
                    Button(action: {
                        selectedFormat = selectedFormat == "quarters" ? "halves" : "quarters"
                        WKInterfaceDevice.current().play(.click)
                    }) {
                        Text(selectedFormat == "quarters" ? "4 Quarters" : "2 Halves")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(WChalk.sky)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(WChalk.sky.opacity(0.15))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(12)
                .background(WChalk.chalk.opacity(0.08))
                .cornerRadius(12)

                Spacer(minLength: 8)

                // Buttons
                if isStarting {
                    // Starting state
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(WChalk.yellow)
                        Text("Starting...")
                            .font(.system(size: 11))
                            .foregroundColor(WChalk.chalk.opacity(0.6))
                    }
                    .padding(.vertical, 12)
                } else {
                    VStack(spacing: 10) {
                        // Start Recording button
                        Button(action: startGame) {
                            HStack(spacing: 6) {
                                Image(systemName: connectivity.isPhoneReachable ? "record.circle" : "pencil.line")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(connectivity.isPhoneReachable ? "Tip Off" : "Tip Off · Stats")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(WChalk.board)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(WChalk.yellow)
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)

                        // Cancel button
                        Button(action: { dismiss() }) {
                            Text("Cancel")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(WChalk.chalk.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .watchBoard()
        .navigationTitle("Confirm")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedHalfLength = game.halfLength
            editedOpponent = game.opponent
            editedTeam = game.teamName
        }
    }

    private func startGame() {
        isStarting = true

        // Haptic feedback
        WKInterfaceDevice.current().play(.click)

        // Create updated game object with selected half length and edited names
        let updatedGame = WatchGame(
            id: game.id,
            opponent: editedOpponent.isEmpty ? "Away" : editedOpponent,
            teamName: editedTeam.isEmpty ? "Home" : editedTeam,
            location: game.location,
            startTime: game.startTime,
            halfLength: selectedHalfLength,
            format: selectedFormat
        )

        // Send to phone - this will trigger recording mode
        connectivity.startGame(updatedGame)

        // Brief delay to show starting state, then dismiss
        // The main view will switch to scoring mode when hasActiveGame becomes true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            dismiss()
        }
    }
}

// Quick game confirmation (for games without calendar details)
struct WatchQuickGameConfirmationView: View {
    @EnvironmentObject var connectivity: WatchConnectivityClient
    @Environment(\.dismiss) private var dismiss

    @State private var opponent: String = ""      // free-form (no calendar → type it)
    @State private var teamName: String = ""      // picked from synced teams, or typed
    @State private var addingTeam = false
    @State private var halfLength: Int = 18
    @State private var quickFormat: String = "halves"
    @State private var isStarting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // My Team — pick from synced teams, or add a new one (like the phone)
                VStack(alignment: .leading, spacing: 6) {
                    Text("My Team")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(WChalk.chalk.opacity(0.5))

                    if !connectivity.myTeams.isEmpty && !addingTeam {
                        // Tappable team chips (like the phone) + add-new.
                        ForEach(connectivity.myTeams, id: \.self) { t in
                            Button { teamName = t } label: {
                                HStack {
                                    Text(t).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    if teamName == t {
                                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                    }
                                }
                                .foregroundColor(teamName == t ? WChalk.board : WChalk.chalk)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(teamName == t ? WChalk.yellow : WChalk.chalk.opacity(0.1))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                        Button { addingTeam = true; teamName = "" } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("New team")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(WChalk.sky)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    } else {
                        TextField("Team name", text: $teamName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(WChalk.yellow)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(WChalk.chalk.opacity(0.1))
                            .cornerRadius(8)
                    }
                }

                // Opponent — free-form (we don't know it without a calendar game)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Opponent")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(WChalk.chalk.opacity(0.5))

                    TextField("Opponent", text: $opponent)
                        .font(.system(size: 14, weight: .semibold))
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(WChalk.chalk.opacity(0.1))
                        .cornerRadius(8)
                }

                // Half length picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Half Length")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(WChalk.chalk.opacity(0.5))

                    Picker("Half", selection: $halfLength) {
                        Text("18 min").tag(18)
                        Text("20 min").tag(20)
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 50)
                }

                // Format toggle
                Button(action: {
                    quickFormat = quickFormat == "quarters" ? "halves" : "quarters"
                    WKInterfaceDevice.current().play(.click)
                }) {
                    Text(quickFormat == "quarters" ? "4 Quarters" : "2 Halves")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(WChalk.sky)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(WChalk.sky.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                // Buttons
                if isStarting {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(WChalk.yellow)
                        Text("Starting...")
                            .font(.system(size: 11))
                            .foregroundColor(WChalk.chalk.opacity(0.6))
                    }
                } else {
                    VStack(spacing: 10) {
                        Button(action: startQuickGame) {
                            HStack(spacing: 6) {
                                Image(systemName: connectivity.isPhoneReachable ? "record.circle" : "pencil.line")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(connectivity.isPhoneReachable ? "Tip Off" : "Tip Off · Stats")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(WChalk.board)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(WChalk.yellow)
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)

                        Button(action: { dismiss() }) {
                            Text("Cancel")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(WChalk.chalk.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .watchBoard()
        .navigationTitle("Quick Game")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Pre-select the first saved team so the picker isn't empty.
            if teamName.isEmpty, let first = connectivity.myTeams.first { teamName = first }
        }
    }

    private func startQuickGame() {
        isStarting = true
        WKInterfaceDevice.current().play(.click)

        let game = WatchGame(
            id: UUID().uuidString,
            opponent: opponent.trimmingCharacters(in: .whitespaces).isEmpty ? "Opponent" : opponent,
            teamName: teamName.trimmingCharacters(in: .whitespaces).isEmpty ? "My Team" : teamName,
            location: "",
            startTime: Date(),
            halfLength: halfLength,
            format: quickFormat
        )

        connectivity.startGame(game)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            dismiss()
        }
    }
}

#Preview {
    WatchGameConfirmationView(
        game: WatchGame(
            id: "1",
            opponent: "Warriors Elite",
            teamName: "Bay Area Lava",
            location: "Main Gym",
            startTime: Date(),
            halfLength: 18
        )
    )
    .environmentObject(WatchConnectivityClient.shared)
}
