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

// MARK: - Upcoming Games Stack (flip-through deck of chalk cards)

struct UpcomingGamesStack: View {
    let games: [GameCalendarManager.CalendarGame]
    let appState: AppState
    let onHide: (String) -> Void

    @State private var order: [Int] = []      // game indices; order[0] = top card
    @State private var viewedIndex: Int = 0   // which card you're on (for the "N / total")
    @State private var drag: CGSize = .zero

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(Array(order.enumerated()), id: \.element) { depth, gi in
                    if depth < 3 {
                        GameStackCard(game: games[gi], appState: appState, onHide: onHide)
                            .scaleEffect(1 - CGFloat(depth) * 0.05)
                            .offset(y: CGFloat(depth) * 14)
                            .rotationEffect(.degrees(depth == 0 ? 0 : (depth.isMultiple(of: 2) ? 2 : -2)))
                            .offset(depth == 0 ? drag : .zero)
                            .opacity(depth == 0 ? 1 : (depth == 1 ? 0.85 : 0.5))
                            .zIndex(Double(order.count - depth))
                            .allowsHitTesting(depth == 0)
                            .gesture(depth == 0 && games.count > 1 ? dragGesture : nil)
                    }
                }
            }

            if games.count > 1 {
                HStack(spacing: 20) {
                    Button { advance(-1) } label: { chevron("chevron.left") }
                    Text("\(viewedIndex + 1) / \(games.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Chalk.dust)
                        .frame(minWidth: 54)
                    Button { advance(1) } label: { chevron("chevron.right") }
                }
            }
        }
        .onAppear { if order.isEmpty { order = Array(games.indices) } }
        .onChange(of: games.count) { _, _ in order = Array(games.indices); viewedIndex = 0 }
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(Chalk.chalk)
            .frame(width: 44, height: 44)
            .overlay(Circle().stroke(Chalk.chalk.opacity(0.3), lineWidth: 1.5))
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                if abs(value.translation.width) > 90 {
                    let dir = value.translation.width > 0 ? -1 : 1
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        drag = CGSize(width: dir > 0 ? -620 : 620, height: 0)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        advance(dir)
                        drag = .zero
                    }
                } else {
                    withAnimation(.spring()) { drag = .zero }
                }
            }
    }

    private func advance(_ dir: Int) {
        guard games.count > 1 else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            if dir > 0 { order.append(order.removeFirst()) }
            else { order.insert(order.removeLast(), at: 0) }
            viewedIndex = (viewedIndex + dir + games.count) % games.count
        }
    }
}

// One game card face for the stack.
struct GameStackCard: View {
    let game: GameCalendarManager.CalendarGame
    let appState: AppState
    let onHide: (String) -> Void

    private var isToday: Bool { Calendar.current.isDateInToday(game.startTime) }
    private var isTomorrow: Bool { Calendar.current.isDateInTomorrow(game.startTime) }
    private var dayLabel: String {
        if isToday { return "TODAY" }
        if isTomorrow { return "TOMORROW" }
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"
        return f.string(from: game.startTime).uppercased()
    }
    private var accent: Color { isToday ? Chalk.green : Chalk.yellow }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 8, height: 8)
                    Text(dayLabel)
                        .font(.system(size: 12, weight: .semibold)).tracking(0.8)
                        .foregroundColor(accent)
                }
                Spacer()
                Button { onHide(game.id) } label: {
                    Image(systemName: "eye.slash")
                        .font(.footnote).foregroundColor(Chalk.dust.opacity(0.7))
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)

            VStack(spacing: 12) {
                Text(game.timeString)
                    .font(.system(size: 44, weight: .bold)).monospacedDigit()
                    .foregroundColor(Chalk.crisp)
                Text(game.opponent)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Chalk.chalk)
                    .multilineTextAlignment(.center).lineLimit(2)
                if let team = game.detectedTeam {
                    Text(team).font(.system(size: 13, weight: .medium)).foregroundColor(Chalk.sky)
                }
                if !game.location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin").font(.caption2)
                        Text(game.location).font(.system(size: 13)).lineLimit(1)
                    }
                    .foregroundColor(Chalk.dust)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 16)

            ChalkButton(title: "Record Game", icon: "video.fill", color: Chalk.yellow) {
                appState.pendingCalendarGame = (opponent: game.opponent, location: game.location, team: game.detectedTeam)
                appState.isLogOnly = false
                appState.currentScreen = .setup
            }
            .padding(.horizontal, 20).padding(.bottom, 18)
        }
        .chalkCard(padding: 0)
    }
}
