//
//  SettingsView.swift
//  SahilStatsLite
//
//  PURPOSE: App settings: Skynet AI toggle, gimbal mode, YouTube connection,
//           team management, calendar selection, Firebase account, ghost game
//           cleanup, YouTube Live stream key, and app info.
//  KEY TYPES: SettingsView
//  DEPENDS ON: AuthService, GamePersistenceManager, GameCalendarManager,
//              YouTubeService, AutoZoomManager, GimbalTrackingManager, StreamingService
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import EventKit

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject private var authService = AuthService.shared
    @ObservedObject private var persistenceManager = GamePersistenceManager.shared
    @ObservedObject private var calendarManager = GameCalendarManager.shared
    @ObservedObject private var youtubeService = YouTubeService.shared
    @ObservedObject private var autoZoomManager = AutoZoomManager.shared
    @ObservedObject private var gimbalManager = GimbalTrackingManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var newTeamName: String = ""
    @State private var showAddTeam: Bool = false
    @State private var showStreamKey: Bool = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Chalk header replaces the system nav bar so the whole screen reads
                // as the green board (no white title / blue Done island).
                HStack {
                    Text("Settings")
                        .font(.chalkScript(30))
                        .foregroundColor(Chalk.chalk)

                    Spacer()

                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Chalk.chalk)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                List {
                    // Recording Section (Skynet, Gimbal)
                    Section {
                        // Skynet (AI Tracking)
                        Toggle(isOn: Binding(
                            get: { autoZoomManager.mode == .auto },
                            set: { autoZoomManager.mode = $0 ? .auto : .off }
                        )) {
                            HStack(spacing: 12) {
                                Image(systemName: "brain.head.profile")
                                    .font(.title2)
                                    .foregroundColor(Chalk.sky)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Skynet AI Tracking")
                                        .font(.system(size: 15))
                                        .foregroundColor(Chalk.chalk)
                                    Text("Auto-zoom follows players, ignores refs")
                                        .font(.system(size: 12))
                                        .foregroundColor(Chalk.dust)
                                }
                            }
                        }
                        .tint(Chalk.green)
                        .listRowBackground(Chalk.board2)

                        // Gimbal Tracking
                        HStack {
                            Image(systemName: gimbalManager.gimbalMode.icon)
                                .font(.title2)
                                .foregroundColor(gimbalManager.gimbalMode == .track ? Chalk.green : Chalk.dust)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gimbal Mode")
                                    .font(.system(size: 15))
                                    .foregroundColor(Chalk.chalk)
                                Text(gimbalManager.gimbalMode.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(Chalk.dust)
                            }

                            Spacer()

                            Picker("", selection: $gimbalManager.gimbalMode) {
                                ForEach(GimbalMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .tint(Chalk.yellow)
                        }
                        .listRowBackground(Chalk.board2)

                        // Ultra-wide capture — for the fixed elevated-tripod full-court
                        // experiment (BallerTV-style). Uses the 0.5× / ~120° lens instead
                        // of the main 1× lens. Restart recording after toggling.
                        Toggle(isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "useUltraWideCamera") },
                            set: { UserDefaults.standard.set($0, forKey: "useUltraWideCamera") }
                        )) {
                            HStack(spacing: 12) {
                                Image(systemName: "camera.aperture")
                                    .font(.title2)
                                    .foregroundColor(Chalk.sky)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ultra-Wide Lens (0.5×)")
                                        .font(.system(size: 15))
                                        .foregroundColor(Chalk.chalk)
                                    Text("Full-court capture from a fixed elevated tripod")
                                        .font(.system(size: 12))
                                        .foregroundColor(Chalk.dust)
                                }
                            }
                        }
                        .tint(Chalk.green)
                        .listRowBackground(Chalk.board2)
                    } header: {
                        sectionHeader("Recording")
                    } footer: {
                        sectionFooter("Skynet uses AI to track players and adjust zoom automatically. Ultra-Wide is experimental — for a fixed tall-tripod full-court setup, no gimbal. Restart recording after changing.")
                    }

                    // YouTube Section
                    Section {
                        if youtubeService.isAuthorized {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Chalk.green)
                                Text("YouTube Connected")
                                    .font(.system(size: 15))
                                    .foregroundColor(Chalk.chalk)
                                Spacer()
                                Button("Disconnect") {
                                    youtubeService.revokeAccess()
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Chalk.coral)
                            }
                            .listRowBackground(Chalk.board2)
                        } else {
                            ChalkButton(title: "Connect YouTube", icon: "play.rectangle.fill", color: Chalk.coral) {
                                Task {
                                    do {
                                        try await youtubeService.authorize()
                                    } catch {
                                        debugPrint("YouTube auth error: \(error)")
                                    }
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }
                    } header: {
                        sectionHeader("YouTube")
                    } footer: {
                        sectionFooter("Connect to upload game videos manually from the Game Log.")
                    }

                    // My Teams Section (for smart opponent detection)
                    Section {
                        ForEach(calendarManager.knownTeamNames, id: \.self) { team in
                            Text(team)
                                .font(.system(size: 15))
                                .foregroundColor(Chalk.chalk)
                                .listRowBackground(Chalk.board2)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let team = calendarManager.knownTeamNames[index]
                                calendarManager.removeKnownTeamName(team)
                            }
                        }

                        // Add team row
                        if showAddTeam {
                            HStack {
                                TextField("", text: $newTeamName,
                                          prompt: Text("Team name").foregroundColor(Chalk.dust))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 15))
                                    .foregroundColor(Chalk.crisp)
                                    .tint(Chalk.yellow)
                                    .autocapitalization(.words)

                                Button {
                                    let trimmed = newTeamName.trimmingCharacters(in: .whitespaces)
                                    if !trimmed.isEmpty {
                                        calendarManager.addKnownTeamName(trimmed)
                                        newTeamName = ""
                                        showAddTeam = false
                                    }
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Chalk.green)
                                }
                                .disabled(newTeamName.trimmingCharacters(in: .whitespaces).isEmpty)

                                Button {
                                    showAddTeam = false
                                    newTeamName = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(Chalk.dust)
                                }
                            }
                            .listRowBackground(Chalk.board2)
                        } else {
                            Button {
                                showAddTeam = true
                            } label: {
                                Label("Add Team", systemImage: "plus")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(Chalk.yellow)
                            }
                            .listRowBackground(Chalk.board2)
                        }
                    } header: {
                        sectionHeader("My Teams")
                    } footer: {
                        sectionFooter("Sahil's teams (Uneqld, Lava, etc). Calendar events with these names will auto-detect the opponent.")
                    }

                    // Calendar Section
                    if calendarManager.hasCalendarAccess {
                        Section {
                            let availableCalendars = calendarManager.getAvailableCalendars()
                            if availableCalendars.isEmpty {
                                Text("No calendars found")
                                    .font(.system(size: 15))
                                    .foregroundColor(Chalk.dust)
                                    .listRowBackground(Chalk.board2)
                            } else {
                                ForEach(availableCalendars, id: \.calendarIdentifier) { calendar in
                                    HStack {
                                        Circle()
                                            .fill(Color(cgColor: calendar.cgColor))
                                            .frame(width: 12, height: 12)

                                        Text(calendar.title)
                                            .font(.system(size: 15))
                                            .foregroundColor(Chalk.chalk)

                                        Spacer()

                                        if isCalendarSelected(calendar) {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(Chalk.yellow)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        toggleCalendar(calendar)
                                    }
                                    .listRowBackground(Chalk.board2)
                                }
                            }
                        } header: {
                            sectionHeader("Calendars")
                        } footer: {
                            sectionFooter("Select calendars to show games from. Leave all unchecked to show all calendars.")
                        }
                    }

                    // Account Section
                    Section {
                        if authService.isSignedIn {
                            HStack(spacing: 12) {
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(Chalk.green)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(authService.displayName ?? "Signed In")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundColor(Chalk.chalk)
                                    if let email = authService.userEmail {
                                        Text(email)
                                            .font(.system(size: 12))
                                            .foregroundColor(Chalk.dust)
                                    }
                                }

                                Spacer()

                                if persistenceManager.isSyncing {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .tint(Chalk.chalk)
                                } else if persistenceManager.syncError != nil {
                                    Image(systemName: "exclamationmark.icloud.fill")
                                        .foregroundColor(Chalk.coral)
                                } else {
                                    Image(systemName: "checkmark.icloud.fill")
                                        .foregroundColor(Chalk.green)
                                }
                            }
                            .padding(.vertical, 8)
                            .listRowBackground(Chalk.board2)

                            Button {
                                Task {
                                    await persistenceManager.forceSyncFromFirebase()
                                }
                            } label: {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(Chalk.yellow)
                            }
                            .disabled(persistenceManager.isSyncing)
                            .listRowBackground(Chalk.board2)

                            Button(role: .destructive) {
                                authService.signOut()
                            } label: {
                                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(Chalk.coral)
                            }
                            .listRowBackground(Chalk.board2)
                        } else {
                            HStack(spacing: 12) {
                                Image(systemName: "person.circle")
                                    .font(.system(size: 40))
                                    .foregroundColor(Chalk.dust)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Not Signed In")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundColor(Chalk.chalk)
                                    Text("Sign in to sync games across devices")
                                        .font(.system(size: 12))
                                        .foregroundColor(Chalk.dust)
                                }
                            }
                            .padding(.vertical, 8)
                            .listRowBackground(Chalk.board2)

                            Button {
                                Task {
                                    await authService.signInWithGoogle()
                                }
                            } label: {
                                Label("Sign in with Google", systemImage: "g.circle.fill")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(Chalk.yellow)
                            }
                            .disabled(authService.isLoading)
                            .listRowBackground(Chalk.board2)
                        }
                    } header: {
                        sectionHeader("Account")
                    } footer: {
                        if let error = authService.error {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundColor(Chalk.coral)
                        } else if let syncError = persistenceManager.syncError {
                            Text(syncError)
                                .font(.system(size: 12))
                                .foregroundColor(Chalk.coral)
                        } else if authService.isSignedIn {
                            if let lastSync = persistenceManager.lastSyncTime {
                                sectionFooter("Last synced: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                    }

                    // Troubleshooting Section
                    Section {
                        Button {
                            Task {
                                await persistenceManager.cleanupGhostGames()
                            }
                        } label: {
                            HStack {
                                Label("Cleanup Ghost Games", systemImage: "trash")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(Chalk.coral)
                                Spacer()
                                Image(systemName: "questionmark.circle")
                                    .font(.caption)
                                    .foregroundColor(Chalk.dust)
                            }
                        }
                        .disabled(persistenceManager.isSyncing)
                        .listRowBackground(Chalk.board2)
                    } header: {
                        sectionHeader("Maintenance")
                    } footer: {
                        sectionFooter("Removes test games with no scores and no video recordings from local storage and Firebase.")
                    }

                    // YouTube Live Streaming
                    Section {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundColor(Chalk.dust)
                                .font(.caption)
                            if showStreamKey {
                                TextField("", text: Binding(
                                    get: { StreamingService.shared.savedStreamKey },
                                    set: { StreamingService.shared.savedStreamKey = $0 }
                                ), prompt: Text("Stream Key").foregroundColor(Chalk.dust))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.system(size: 13).monospaced())
                                .foregroundColor(Chalk.crisp)
                                .tint(Chalk.yellow)
                            } else {
                                SecureField("", text: Binding(
                                    get: { StreamingService.shared.savedStreamKey },
                                    set: { StreamingService.shared.savedStreamKey = $0 }
                                ), prompt: Text("Stream Key").foregroundColor(Chalk.dust))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.system(size: 15))
                                .foregroundColor(Chalk.crisp)
                                .tint(Chalk.yellow)
                            }
                            Button {
                                showStreamKey.toggle()
                            } label: {
                                Image(systemName: showStreamKey ? "eye.slash" : "eye")
                                    .font(.caption)
                                    .foregroundColor(Chalk.dust)
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowBackground(Chalk.board2)
                    } header: {
                        sectionHeader("YouTube Live")
                    } footer: {
                        sectionFooter("YouTube Studio > Go Live > copy the Stream Key. Watch link is auto-generated per game when you toggle Stream Live in Game Setup.")
                    }

                    Section {
                        HStack {
                            Text("Version")
                                .font(.system(size: 15))
                                .foregroundColor(Chalk.chalk)
                            Spacer()
                            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                            let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                            Text("\(version) (\(build))")
                                .font(.system(size: 15))
                                .monospacedDigit()
                                .foregroundColor(Chalk.dust)
                        }
                        .listRowBackground(Chalk.board2)

                        HStack {
                            Text("Games Recorded")
                                .font(.system(size: 15))
                                .foregroundColor(Chalk.chalk)
                            Spacer()
                            Text("\(persistenceManager.careerGames)")
                                .font(.system(size: 15))
                                .monospacedDigit()
                                .foregroundColor(Chalk.dust)
                        }
                        .listRowBackground(Chalk.board2)
                    } header: {
                        sectionHeader("About")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .chalkBoard()
            .navigationBarHidden(true)
        }
    }

    // MARK: - Chalk section chrome

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.chalkScript(20))
            .foregroundColor(Chalk.chalk)
            .textCase(nil)
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Chalk.dust)
    }

    // MARK: - Calendar Selection Helpers

    private func isCalendarSelected(_ calendar: EKCalendar) -> Bool {
        if calendarManager.selectedCalendars.isEmpty {
            return false
        }
        return calendarManager.selectedCalendars.contains(calendar.calendarIdentifier)
    }

    private func toggleCalendar(_ calendar: EKCalendar) {
        var selected = calendarManager.selectedCalendars

        if selected.contains(calendar.calendarIdentifier) {
            selected.removeAll { $0 == calendar.calendarIdentifier }
        } else {
            selected.append(calendar.calendarIdentifier)
        }

        calendarManager.saveSelectedCalendars(selected)
    }
}
