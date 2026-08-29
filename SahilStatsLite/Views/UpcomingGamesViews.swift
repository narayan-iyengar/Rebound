//
//  UpcomingGamesViews.swift
//  SahilStatsLite
//
//  PURPOSE: Calendar-based upcoming games UI components. Hero card for next game,
//           tournament day rows, upcoming games sheet with grouped list.
//  KEY TYPES: NextGameHeroCard, LaterTodaySection, LaterTodayRow,
//             UpcomingGamesSheet, UpcomingGameListRow
//  DEPENDS ON: GameCalendarManager, AppState
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

// MARK: - Next Game Hero Card

struct NextGameHeroCard: View {
    let game: GameCalendarManager.CalendarGame
    let todayCount: Int
    let appState: AppState
    let onHide: (String) -> Void

    private var isToday: Bool {
        Calendar.current.isDateInToday(game.startTime)
    }

    private var isTomorrow: Bool {
        Calendar.current.isDateInTomorrow(game.startTime)
    }

    private var dayLabel: String {
        if isToday {
            return "TODAY"
        } else if isTomorrow {
            return "TOMORROW"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: game.startTime).uppercased()
        }
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: game.startTime)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header - NEXT GAME badge
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isToday ? Chalk.green : Chalk.yellow)
                        .frame(width: 8, height: 8)
                    Text("NEXT GAME")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(isToday ? Chalk.green : Chalk.yellow)
                }

                Spacer()

                // Tournament day indicator
                if todayCount > 1 && isToday {
                    Text("1 of \(todayCount) today")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Chalk.dust)
                }

                // Hide button - subtle, one tap
                Button {
                    onHide(game.id)
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.footnote)
                        .foregroundColor(Chalk.dust.opacity(0.7))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Main content
            VStack(spacing: 16) {
                // Day and Date
                VStack(spacing: 2) {
                    Text(dayLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(isToday ? Chalk.green : Chalk.yellow)

                    if !isToday && !isTomorrow {
                        Text(dateLabel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Chalk.dust)
                    }
                }

                // Time - large and prominent (crisp data)
                Text(game.timeString)
                    .font(.system(size: 48, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(Chalk.crisp)

                // Opponent - the main info
                Text(game.opponent)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Chalk.chalk)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                // Which of Sahil's teams is playing
                if let team = game.detectedTeam {
                    Text(team)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Chalk.sky)
                }

                // Location
                if !game.location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.caption2)
                        Text(game.location)
                            .font(.system(size: 13))
                    }
                    .foregroundColor(Chalk.dust)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            // Record Game button
            ChalkButton(title: "Record Game", icon: "video.fill", color: Chalk.yellow) {
                appState.pendingCalendarGame = (opponent: game.opponent, location: game.location, team: game.detectedTeam)
                appState.isLogOnly = false
                appState.currentScreen = .setup
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .chalkCard(padding: 0)
    }
}

// MARK: - Later Today Section (Tournament Days)

struct LaterTodaySection: View {
    let games: [GameCalendarManager.CalendarGame]
    let appState: AppState
    let onHide: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LATER TODAY")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(Chalk.dust)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(games) { game in
                    LaterTodayRow(game: game, appState: appState, onHide: onHide)

                    if game.id != games.last?.id {
                        Divider()
                            .overlay(Chalk.chalk.opacity(0.15))
                            .padding(.leading, 60)
                    }
                }
            }
            .chalkCard(padding: 0)
        }
    }
}

struct LaterTodayRow: View {
    let game: GameCalendarManager.CalendarGame
    let appState: AppState
    let onHide: (String) -> Void

    var body: some View {
        Button {
            appState.pendingCalendarGame = (opponent: game.opponent, location: game.location, team: game.detectedTeam)
            appState.isLogOnly = false
            appState.currentScreen = .setup
        } label: {
            HStack(spacing: 12) {
                // Time (crisp data)
                Text(game.timeString)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Chalk.crisp)
                    .frame(width: 50, alignment: .leading)

                // Color indicator
                RoundedRectangle(cornerRadius: 2)
                    .fill(Chalk.yellow.opacity(0.7))
                    .frame(width: 3, height: 32)

                // Opponent
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.opponent)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Chalk.chalk)

                    if !game.location.isEmpty {
                        Text(game.location)
                            .font(.system(size: 12))
                            .foregroundColor(Chalk.dust)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Subtle action indicator
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Chalk.dust.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                onHide(game.id)
            } label: {
                Label("Hide this game", systemImage: "eye.slash")
            }
        }
    }
}

// MARK: - Upcoming Games Sheet

struct UpcomingGamesSheet: View {
    @ObservedObject var calendarManager: GameCalendarManager
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if calendarManager.upcomingGames.isEmpty {
                    ContentUnavailableView(
                        "No Upcoming Games",
                        systemImage: "calendar",
                        description: Text("Games with your team names will appear here")
                    )
                } else {
                    ForEach(groupedGames, id: \.0) { date, games in
                        Section(header: Text(sectionHeader(for: date))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Chalk.dust)) {
                            ForEach(games) { game in
                                UpcomingGameListRow(game: game, appState: appState, dismiss: dismiss)
                                    .listRowBackground(Chalk.board2)
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    calendarManager.ignoreEvent(games[index].id)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .chalkBoard()
            .navigationTitle("Upcoming Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var groupedGames: [(Date, [GameCalendarManager.CalendarGame])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: calendarManager.upcomingGames) { game in
            calendar.startOfDay(for: game.startTime)
        }
        return grouped.sorted { $0.key < $1.key }
    }

    private func sectionHeader(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: date)
        }
    }
}

struct UpcomingGameListRow: View {
    let game: GameCalendarManager.CalendarGame
    let appState: AppState
    let dismiss: DismissAction

    var body: some View {
        Button {
            appState.pendingCalendarGame = (opponent: game.opponent, location: game.location, team: game.detectedTeam)
            appState.isLogOnly = false
            appState.currentScreen = .setup
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.opponent)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Chalk.chalk)

                    if !game.location.isEmpty {
                        Text(game.location)
                            .font(.system(size: 13))
                            .foregroundColor(Chalk.dust)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(game.timeString)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Chalk.crisp)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Upcoming Games Stack (clean single-card swipe deck + trailing "New Game" card)
//
// One game per card, swipe/page between them, and the LAST card is a giant-+ New
// Game (no separate button). Default card = the game happening now / next up; you
// can swipe BACK to earlier same-day games (delays mean you may still be on the
// "past" one). Same metaphor as the Watch.

struct UpcomingGamesStack: View {
    let games: [GameCalendarManager.CalendarGame]
    let appState: AppState
    let onHide: (String) -> Void

    @State private var index: Int = 0

    // Default to the current/next game (first whose end time is still in the future);
    // if every game's scheduled end has passed (a delayed last game), land on the last.
    private var defaultIndex: Int {
        let now = Date()
        if let i = games.firstIndex(where: { $0.endTime > now }) { return i }
        return max(0, games.count - 1)
    }

    private var pageCount: Int { games.count + 1 }  // +1 for the New Game card

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: $index) {
                ForEach(Array(games.enumerated()), id: \.element.id) { i, game in
                    GameCard(game: game, appState: appState, onHide: onHide)
                        .padding(.horizontal, 2)
                        .tag(i)
                }
                NewGameCard(appState: appState)
                    .padding(.horizontal, 2)
                    .tag(games.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 320)

            // Custom page dots (active = wide yellow). Last dot = the New Game card.
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Chalk.yellow : Chalk.chalk.opacity(0.25))
                        .frame(width: i == index ? 18 : 7, height: 7)
                }
            }
        }
        .onAppear { index = defaultIndex }
        .onChange(of: games.count) { _, _ in index = defaultIndex }
    }
}

// One clean game card — opponent is the hero (sky), team in yellow, tap Record.
struct GameCard: View {
    let game: GameCalendarManager.CalendarGame
    let appState: AppState
    let onHide: (String) -> Void

    private var isToday: Bool { Calendar.current.isDateInToday(game.startTime) }
    private var isTomorrow: Bool { Calendar.current.isDateInTomorrow(game.startTime) }
    private var isLive: Bool { game.startTime <= Date() && game.endTime > Date() }
    private var whenLabel: String {
        let day: String
        if isToday { day = "Today" }
        else if isTomorrow { day = "Tomorrow" }
        else { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; day = f.string(from: game.startTime) }
        return "\(day) · \(game.timeString)"
    }
    private var accent: Color { isToday ? Chalk.green : Chalk.yellow }

    var body: some View {
        VStack(spacing: 0) {
            // Day chip + hide
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 8, height: 8)
                    Text(isLive ? "NOW" : (isToday ? "TODAY" : "UPCOMING"))
                        .font(.system(size: 11, weight: .semibold)).tracking(0.8)
                        .foregroundColor(accent)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 16)

            Spacer(minLength: 4)

            VStack(spacing: 6) {
                Text(whenLabel)
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundColor(Chalk.dust)
                Text("vs").font(.chalkScript(20)).foregroundColor(Chalk.dust)
                Text(game.opponent)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(Chalk.sky)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                if let team = game.detectedTeam {
                    Text(team).font(.system(size: 15, weight: .semibold)).foregroundColor(Chalk.yellow)
                }
                if !game.location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin").font(.caption2)
                        Text(game.location).font(.system(size: 13)).lineLimit(1)
                    }
                    .foregroundColor(Chalk.dust)
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 6)

            HStack(spacing: 10) {
                ChalkButton(title: "Record Game", icon: "video.fill", color: Chalk.yellow) {
                    appState.pendingCalendarGame = (opponent: game.opponent, location: game.location, team: game.detectedTeam)
                    appState.isLogOnly = false
                    appState.currentScreen = .setup
                }
                Button { onHide(game.id) } label: {
                    Text("Hide")
                        .font(.chalkHand(17))
                        .foregroundColor(Chalk.chalk)
                        .padding(.vertical, 11).padding(.horizontal, 18)
                        .overlay(RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(Chalk.chalk.opacity(0.4), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 20).padding(.bottom, 18)
        }
        .frame(maxHeight: .infinity)
        .chalkCard(padding: 0)
    }
}

// The trailing "New Game" card (replaces the separate button). Whole card is tappable.
struct NewGameCard: View {
    let appState: AppState

    private func start() {
        appState.pendingCalendarGame = nil
        appState.isLogOnly = false
        appState.currentScreen = .setup
    }

    var body: some View {
        Button(action: start) {
            VStack(spacing: 14) {
                Spacer()
                ZStack {
                    Circle().fill(Chalk.yellow).frame(width: 84, height: 84)
                    Image(systemName: "plus")
                        .font(.system(size: 42, weight: .regular))
                        .foregroundColor(Chalk.board)
                }
                Text("New Game").font(.chalkScript(28)).foregroundColor(Chalk.chalk)
                Text("Pick team & opponent · record")
                    .font(.system(size: 13)).foregroundColor(Chalk.dust)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .chalkCard(padding: 0)
        }
        .buttonStyle(.plain)
    }
}
