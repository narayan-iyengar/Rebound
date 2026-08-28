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

    // Home-screen-style paging: Game Setup · Career Stats · Game Log · Store · Settings
    @State private var page = 0

    // Undo toast state
    @State private var hiddenGameID: String? = nil
    @State private var showUndoToast = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $page) {
            boardPage(setupPage).tag(0)
            boardPage(CareerStatsSheet(embedded: true)).tag(1)
            boardPage(AllGamesView(embedded: true)).tag(2)
            boardPage(StoreView()).tag(3)
            boardPage(SettingsView(embedded: true).chalkBoard()).tag(4)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Chalk.board.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { pageBar }
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
            WatchConnectivityService.shared.sendTeams(GameCalendarManager.shared.knownTeamNames)
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

    // MARK: - Paging helpers

    /// Every page sits on the green board so all five read as one surface.
    /// Cheap solid ground behind every page. The play-diagram backdrop comes from each
    /// page's own .chalkBoard() (exactly once per page) so we never stack two Canvases.
    @ViewBuilder
    private func boardPage<V: View>(_ content: V) -> some View {
        ZStack {
            Chalk.board.ignoresSafeArea()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The SF Symbol representing each page — shown on the edge affordance so you
    /// can see what you're swiping toward (instead of anonymous dots/chevrons).
    static func pageIcon(_ index: Int) -> String {
        switch index {
        case 0: return "basketball.fill"      // Game Setup / home
        case 1: return "chart.bar.fill"       // Career Stats
        case 2: return "list.bullet.clipboard" // Game Log
        case 3: return "film.stack"           // Store
        default: return "gearshape.fill"      // Settings
        }
    }

    /// Short label for the active page (shown only on the lit pill).
    static func pageName(_ index: Int) -> String {
        switch index {
        case 0: return "Home"
        case 1: return "Stats"
        case 2: return "Log"
        case 3: return "Store"
        default: return "Settings"
        }
    }

    /// Persistent chalk tab bar with active-emphasis: the current page expands into a lit
    /// icon+label pill, the others recede to subtle icon hints. Every page stays one tap away.
    private var pageBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { i in
                let active = (i == page)
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { page = i }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Self.pageIcon(i))
                            .font(.system(size: active ? 16 : 15, weight: .semibold))
                        if active {
                            Text(Self.pageName(i))
                                .font(.system(size: 14, weight: .bold))
                                .fixedSize()
                        }
                    }
                    .foregroundColor(active ? Chalk.board : Chalk.chalk.opacity(0.28))
                    .padding(.horizontal, active ? 14 : 9)
                    .frame(height: 36)
                    .background(active ? Chalk.yellow : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(Chalk.board2.opacity(0.96), in: Capsule())
        .overlay(Capsule().stroke(Chalk.chalk.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: page)
    }

    /// Page 0 — the "home": wordmark, upcoming games, and the start-a-game actions.
    private var setupPage: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection

                if calendarManager.hasCalendarAccess {
                    upcomingGamesSection
                } else {
                    calendarAccessCard
                }

                startButtons

                Spacer(minLength: 60)
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .chalkBoard()
    }

    private var startButtons: some View {
        // "New Game" now lives as the trailing card in the games deck above, so this
        // is just Practice + the quiet manual-entry link.
        VStack(spacing: 12) {
            ChalkButton(title: "Practice", icon: "figure.basketball", color: Chalk.sky, filled: false) {
                appState.startPractice()
            }

            Button {
                appState.isLogOnly = true
                appState.currentScreen = .setup
            } label: {
                Text("Add a past game manually")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Chalk.dust)
            }
            .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    // MARK: - Undo Toast

    private var undoToast: some View {
        HStack(spacing: 16) {
            Text("Game hidden")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Chalk.chalk)

            Button {
                if let id = hiddenGameID {
                    calendarManager.unignoreEvent(id)
                }
                showUndoToast = false
                hiddenGameID = nil
            } label: {
                Text("Undo")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Chalk.yellow)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Chalk.board2, in: Capsule())
        .overlay(Capsule().strokeBorder(Chalk.chalk.opacity(0.3), lineWidth: 1.5))
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
        VStack(spacing: 0) {
            ReboundWordmark(size: 44)

            Text("Record. Track. Share.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Chalk.dust)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    // MARK: - Career Stats Card

    private var careerStatsCard: some View {
        Button(action: { showStatsSheet = true }) {
            VStack(spacing: 14) {
                HStack {
                    Text("Career Stats")
                        .font(.chalkScript(28))
                        .foregroundColor(Chalk.chalk)

                    Spacer()

                    Text("\(persistenceManager.careerGames) games")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Chalk.dust)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(Chalk.dust)
                }

                HStack(spacing: 0) {
                    statItem(value: String(format: "%.1f", persistenceManager.careerPPG), label: "PPG", color: Chalk.yellow)
                    statItem(value: String(format: "%.1f", persistenceManager.careerRPG), label: "RPG", color: Chalk.sky)
                    statItem(value: String(format: "%.1f", persistenceManager.careerAPG), label: "APG", color: Chalk.green)
                    statItem(value: persistenceManager.careerRecord, label: "W-L", color: Chalk.chalk)
                }
            }
            .chalkCard()
        }
        .buttonStyle(.plain)
    }

    private func statItem(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Chalk.dust)
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
                        .foregroundColor(Chalk.yellow)
                        .frame(width: 44, height: 44)
                        .background(Chalk.yellow.opacity(0.15))
                        .cornerRadius(10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Game Log")
                            .font(.chalkScript(26))
                            .foregroundColor(Chalk.chalk)

                        Text("\(persistenceManager.careerGames) games recorded")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Chalk.dust)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(Chalk.dust)
                }
                .chalkCard()
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
                        .foregroundColor(Chalk.yellow)
                    Text("Add")
                        .font(.system(size: 12))
                        .foregroundColor(Chalk.dust)
                }
                .frame(width: 56)
                .chalkCard(padding: 16)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Upcoming Games Section (Hero Card Design)

    private var upcomingGamesSection: some View {
        // Deck games: keep ALL of today's games (even ones whose scheduled time
        // passed — delays mean you may still be on the "past" one, swipeable back)
        // plus future games; drop past DAYS. The stack defaults to the current/next
        // game and always ends with a "New Game" card (so no separate button).
        let now = Date()
        let cal = Calendar.current
        let deckGames = calendarManager.upcomingGames
            .filter { cal.isDateInToday($0.startTime) || $0.startTime > now }
            .sorted { $0.startTime < $1.startTime }
        return UpcomingGamesStack(games: deckGames, appState: appState, onHide: hideGame)
    }

    private var emptyGamesCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 44))
                .foregroundColor(Chalk.green.opacity(0.7))

            Text("No games scheduled")
                .font(.chalkScript(28))
                .foregroundColor(Chalk.chalk)

            Text("Calendar events with your team names will appear here automatically")
                .font(.system(size: 15))
                .foregroundColor(Chalk.dust)
                .multilineTextAlignment(.center)

            Button {
                showSettings = true
            } label: {
                Text("Configure Teams")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Chalk.yellow)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .chalkCard()
    }

    private func upcomingGamesLink(count: Int) -> some View {
        Button {
            showUpcomingGames = true
        } label: {
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(Chalk.dust)
                Text("\(count) more game\(count == 1 ? "" : "s") this month")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Chalk.dust)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Chalk.dust.opacity(0.6))
            }
            .chalkCard()
        }
        .buttonStyle(.plain)
    }

    private var calendarAccessCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.largeTitle)
                .foregroundColor(Chalk.yellow)

            Text("Connect Calendar")
                .font(.chalkScript(28))
                .foregroundColor(Chalk.chalk)

            Text("See upcoming games from your calendar")
                .font(.system(size: 15))
                .foregroundColor(Chalk.dust)
                .multilineTextAlignment(.center)

            ChalkButton(title: "Allow Access", icon: "calendar") {
                Task {
                    await calendarManager.requestCalendarAccess()
                }
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .chalkCard()
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
