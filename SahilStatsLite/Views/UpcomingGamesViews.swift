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
                        .font(.chalkHand(14))
                        .foregroundColor(isToday ? Chalk.green : Chalk.yellow)
                }

                Spacer()

                // Tournament day indicator
                if todayCount > 1 && isToday {
                    Text("1 of \(todayCount) today")
                        .font(.chalkHand(13))
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
                        .font(.chalkHand(16))
                        .foregroundColor(isToday ? Chalk.green : Chalk.yellow)

                    if !isToday && !isTomorrow {
                        Text(dateLabel)
                            .font(.chalkHand(13))
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
                    .font(.chalkHand(24))
                    .foregroundColor(Chalk.chalk)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                // Which of Sahil's teams is playing
                if let team = game.detectedTeam {
                    Text(team)
                        .font(.chalkHand(15))
                        .foregroundColor(Chalk.sky)
                }

                // Location
                if !game.location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.caption2)
                        Text(game.location)
                            .font(.chalkHand(13))
                    }
                    .foregroundColor(Chalk.dust)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            // Record Game button
            ChalkButton(title: "Record Game", color: Chalk.yellow) {
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
                .font(.chalkHand(14))
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
                        .font(.chalkHand(16))
                        .foregroundColor(Chalk.chalk)

                    if !game.location.isEmpty {
                        Text(game.location)
                            .font(.chalkHand(12))
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
                            .font(.chalkHand(14))
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
                        .font(.chalkHand(18))
                        .foregroundColor(Chalk.chalk)

                    if !game.location.isEmpty {
                        Text(game.location)
                            .font(.chalkHand(13))
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
