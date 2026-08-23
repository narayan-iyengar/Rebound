//
//  HomeView.swift
//  SahilStatsLite
//
//  PURPOSE: Main home screen with upcoming games (calendar), game log, career
//           stats, and settings. Sub-views extracted to separate files:
//           UpcomingGamesViews, GameRow, CareerStatsSheet, GameDetailSheet,
//           AllGamesView, SettingsView.
//  KEY TYPES: HomeView
//  DEPENDS ON: GameCalendarManager, GamePersistenceManager, WatchConnectivityService
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import Combine
import EventKit

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var calendarManager = GameCalendarManager.shared
    @ObservedObject private var persistenceManager = GamePersistenceManager.shared
    @State private var showStatsSheet = false
    @State private var showAllGames = false
    @State private var showSettings = false
    @State private var showUpcomingGames = false

    // Undo toast state
    @State private var hiddenGameID: String? = nil
    @State private var showUndoToast = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection

                // Upcoming Games (smart filtered from calendar)
                if calendarManager.hasCalendarAccess {
                    upcomingGamesSection
                } else {
                    calendarAccessCard
                }

                // Career Stats Card (if we have games)
                if persistenceManager.careerGames > 0 {
                    careerStatsCard
                }

                // Game Log Card
                gameLogCard

                Spacer(minLength: 40)
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationBarHidden(true)
        .alert("Video Not Saved to Photos",
               isPresented: Binding(get: { appState.photosSaveFailureMessage != nil },
                                    set: { if !$0 { appState.photosSaveFailureMessage = nil } })) {
            Button("OK", role: .cancel) { appState.photosSaveFailureMessage = nil }
        } message: {
            Text(appState.photosSaveFailureMessage ?? "")
        }
        .sheet(isPresented: $showStatsSheet) {
            CareerStatsSheet()
        }
        .sheet(isPresented: $showAllGames) {
            AllGamesView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showUpcomingGames) {
            UpcomingGamesSheet(calendarManager: calendarManager, appState: appState)
        }
        .overlay(alignment: .bottom) {
            if showUndoToast {
                undoToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 40)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showUndoToast)
        .onAppear {
            // Sync calendar games to Watch when home view appears
            WatchConnectivityService.shared.syncCalendarGames()
            calendarManager.loadUpcomingGames()
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the app re-evaluates the calendar so games that ended while
            // we were away drop off (no more stale hero after a game passes).
            if phase == .active { calendarManager.loadUpcomingGames() }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            // Keep the list fresh while the user sits on Home — a game rolls off within
            // a minute of its scheduled end.
            calendarManager.loadUpcomingGames()
        }
    }

    // MARK: - Undo Toast

    private var undoToast: some View {
        HStack(spacing: 16) {
            Text("Game hidden")
                .font(.subheadline)
                .foregroundColor(.white)

            Button {
                if let id = hiddenGameID {
                    calendarManager.unignoreEvent(id)
                }
                showUndoToast = false
                hiddenGameID = nil
            } label: {
                Text("Undo")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .onAppear {
            // Auto-dismiss after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    showUndoToast = false
                    hiddenGameID = nil
                }
            }
        }
    }

    func hideGame(_ gameID: String) {
        hiddenGameID = gameID
        calendarManager.ignoreEvent(gameID)
        withAnimation {
            showUndoToast = true
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            // Settings gear
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .frame(width: 32, height: 32)

            Spacer()

            VStack(spacing: 4) {
                Text("Rebound")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Record. Track. Share.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // New Game button
            Button {
                appState.isLogOnly = false
                appState.currentScreen = .setup
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
            }
            .frame(width: 32, height: 32)
        }
        .padding(.top, 20)
    }

    // MARK: - Career Stats Card

    private var careerStatsCard: some View {
        Button(action: { showStatsSheet = true }) {
            VStack(spacing: 12) {
                HStack {
                    Text("Career Stats")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    Text("\(persistenceManager.careerGames) games")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 0) {
                    statItem(value: String(format: "%.1f", persistenceManager.careerPPG), label: "PPG", color: .orange)
                    statItem(value: String(format: "%.1f", persistenceManager.careerRPG), label: "RPG", color: .blue)
                    statItem(value: String(format: "%.1f", persistenceManager.careerAPG), label: "APG", color: .green)
                    statItem(value: persistenceManager.careerRecord, label: "W-L", color: .primary)
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }

    private func statItem(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Game Log Card

    private var gameLogCard: some View {
        HStack(spacing: 12) {
            Button(action: { showAllGames = true }) {
                HStack {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.title2)
                        .foregroundColor(.orange)
                        .frame(width: 44, height: 44)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(10)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Game Log")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("\(persistenceManager.careerGames) games recorded")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(16)
            }
            .buttonStyle(.plain)

            // Add game button (manual entry)
            Button {
                appState.isLogOnly = true
                appState.currentScreen = .setup
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundColor(.orange)
                    Text("Add")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(width: 56)
                .padding(.vertical, 16)
                .background(Color(.systemBackground))
                .cornerRadius(16)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Upcoming Games Section (Hero Card Design)

    private var upcomingGamesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Wall-clock LIVE filter (evaluated at render, not just at load): a game
            // drops out the moment its scheduled end passes, so an ended-but-unrecorded
            // game never sticks around as the big hero card. Everything below derives
            // from this one live list so the hero, today, and later stay consistent.
            let now = Date()
            let calendar = Calendar.current
            let liveGames = calendarManager.upcomingGames.filter { $0.endTime > now }
            let todayGames = liveGames.filter { calendar.isDateInToday($0.startTime) }
            let laterGames = liveGames.filter { !calendar.isDateInToday($0.startTime) }

            if liveGames.isEmpty {
                emptyGamesCard
            } else if let nextGame = liveGames.first {
                NextGameHeroCard(
                    game: nextGame,
                    todayCount: todayGames.count,
                    appState: appState,
                    onHide: hideGame
                )

                if todayGames.count > 1 {
                    LaterTodaySection(
                        games: Array(todayGames.dropFirst()),
                        appState: appState,
                        onHide: hideGame
                    )
                }

                if !laterGames.isEmpty {
                    upcomingGamesLink(count: laterGames.count)
                }
            }
        }
    }

    private var emptyGamesCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 44))
                .foregroundColor(.green.opacity(0.6))

            Text("No games scheduled")
                .font(.headline)
                .foregroundColor(.primary)

            Text("Calendar events with your team names will appear here automatically")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showSettings = true
            } label: {
                Text("Configure Teams")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal)
        .background(Color(.systemBackground))
        .cornerRadius(20)
    }

    private func upcomingGamesLink(count: Int) -> some View {
        Button {
            showUpcomingGames = true
        } label: {
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.secondary)
                Text("\(count) more game\(count == 1 ? "" : "s") this month")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private var calendarAccessCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.largeTitle)
                .foregroundColor(.orange)

            Text("Connect Calendar")
                .font(.headline)

            Text("See upcoming games from your calendar")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task {
                    await calendarManager.requestCalendarAccess()
                }
            } label: {
                Text("Allow Access")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
