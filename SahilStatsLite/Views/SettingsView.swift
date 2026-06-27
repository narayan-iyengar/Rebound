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
                                .foregroundColor(.purple)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Skynet AI Tracking")
                                    .font(.body)
                                Text("Auto-zoom follows players, ignores refs")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .tint(.purple)

                    // Gimbal Tracking
                    HStack {
                        Image(systemName: gimbalManager.gimbalMode.icon)
                            .font(.title2)
                            .foregroundColor(gimbalManager.gimbalMode == .track ? .green : .secondary)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gimbal Mode")
                                .font(.body)
                            Text(gimbalManager.gimbalMode.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Picker("", selection: $gimbalManager.gimbalMode) {
                            ForEach(GimbalMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Skynet uses AI to track players and adjust zoom automatically. These settings apply to all recordings.")
                }

                // YouTube Section
                Section {
                    if youtubeService.isAuthorized {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("YouTube Connected")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Disconnect") {
                                youtubeService.revokeAccess()
                            }
                            .font(.caption)
                            .foregroundColor(.red)
                        }
                    } else {
                        Button {
                            Task {
                                do {
                                    try await youtubeService.authorize()
                                } catch {
                                    debugPrint("YouTube auth error: \(error)")
                                }
                            }
                        } label: {
                            Label("Connect YouTube", systemImage: "play.rectangle.fill")
                        }
                    }
                } header: {
                    Text("YouTube")
                } footer: {
                    Text("Connect to upload game videos manually from the Game Log.")
                }

                // My Teams Section (for smart opponent detection)
                Section {
                    ForEach(calendarManager.knownTeamNames, id: \.self) { team in
                        Text(team)
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
                            TextField("Team name", text: $newTeamName)
                                .textFieldStyle(.plain)
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
                                    .foregroundColor(.green)
                            }
                            .disabled(newTeamName.trimmingCharacters(in: .whitespaces).isEmpty)

                            Button {
                                showAddTeam = false
                                newTeamName = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Button {
                            showAddTeam = true
                        } label: {
                            Label("Add Team", systemImage: "plus")
                        }
                    }
                } header: {
                    Text("My Teams")
                } footer: {
                    Text("Sahil's teams (Uneqld, Lava, etc). Calendar events with these names will auto-detect the opponent.")
                }

                // Calendar Section
                if calendarManager.hasCalendarAccess {
                    Section {
                        let availableCalendars = calendarManager.getAvailableCalendars()
                        if availableCalendars.isEmpty {
                            Text("No calendars found")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(availableCalendars, id: \.calendarIdentifier) { calendar in
                                HStack {
                                    Circle()
                                        .fill(Color(cgColor: calendar.cgColor))
                                        .frame(width: 12, height: 12)

                                    Text(calendar.title)

                                    Spacer()

                                    if isCalendarSelected(calendar) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.orange)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    toggleCalendar(calendar)
                                }
                            }
                        }
                    } header: {
                        Text("Calendars")
                    } footer: {
                        Text("Select calendars to show games from. Leave all unchecked to show all calendars.")
                    }
                }

                // Account Section
                Section {
                    if authService.isSignedIn {
                        HStack(spacing: 12) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.green)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(authService.displayName ?? "Signed In")
                                    .font(.headline)
                                if let email = authService.userEmail {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            if persistenceManager.isSyncing {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else if persistenceManager.syncError != nil {
                                Image(systemName: "exclamationmark.icloud.fill")
                                    .foregroundColor(.red)
                            } else {
                                Image(systemName: "checkmark.icloud.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.vertical, 8)

                        Button {
                            Task {
                                await persistenceManager.forceSyncFromFirebase()
                            }
                        } label: {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(persistenceManager.isSyncing)

                        Button(role: .destructive) {
                            authService.signOut()
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "person.circle")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Not Signed In")
                                    .font(.headline)
                                Text("Sign in to sync games across devices")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)

                        Button {
                            Task {
                                await authService.signInWithGoogle()
                            }
                        } label: {
                            Label("Sign in with Google", systemImage: "g.circle.fill")
                        }
                        .disabled(authService.isLoading)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    if let error = authService.error {
                        Text(error)
                            .foregroundColor(.red)
                    } else if let syncError = persistenceManager.syncError {
                        Text(syncError)
                            .foregroundColor(.red)
                    } else if authService.isSignedIn {
                        if let lastSync = persistenceManager.lastSyncTime {
                            Text("Last synced: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
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
                                .foregroundColor(.red)
                            Spacer()
                            Image(systemName: "questionmark.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(persistenceManager.isSyncing)
                } header: {
                    Text("Maintenance")
                } footer: {
                    Text("Removes test games with no scores and no video recordings from local storage and Firebase.")
                }

                // YouTube Live Streaming
                Section("YouTube Live") {
                    HStack {
                        Image(systemName: "key.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        if showStreamKey {
                            TextField("Stream Key", text: Binding(
                                get: { StreamingService.shared.savedStreamKey },
                                set: { StreamingService.shared.savedStreamKey = $0 }
                            ))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.caption.monospaced())
                        } else {
                            SecureField("Stream Key", text: Binding(
                                get: { StreamingService.shared.savedStreamKey },
                                set: { StreamingService.shared.savedStreamKey = $0 }
                            ))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        }
                        Button {
                            showStreamKey.toggle()
                        } label: {
                            Image(systemName: showStreamKey ? "eye.slash" : "eye")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("YouTube Studio > Go Live > copy the Stream Key. Watch link is auto-generated per game when you toggle Stream Live in Game Setup.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                        Text("\(version) (\(build))")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Games Recorded")
                        Spacer()
                        Text("\(persistenceManager.careerGames)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
