//
//  WatchContentView.swift
//  SahilStatsLiteWatch
//
//  PURPOSE: Root navigation view. Shows waiting screen when no game active,
//           vertical TabView (Scoring + Stats) during a game, and upcoming
//           games list from calendar. Handles quick-start game from Watch.
//  KEY TYPES: WatchContentView, WatchGame
//  DEPENDS ON: WatchConnectivityClient, WatchScoringView, WatchStatsView,
//              WatchGameConfirmationView
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var connectivity: WatchConnectivityClient
    @StateObject private var calendarManager = WatchCalendarManager.shared
    @State private var selectedTab: Int = 0
    @State private var showQuickGameConfirmation = false
    @State private var gameToHide: WatchGame?
    @State private var deckSelection: Int = 0

    var body: some View {
        Group {
            if connectivity.hasActiveGame {
                // Game in progress - show scoring interface with 3 vertical pages
                // Use Digital Crown to scroll: Scoring -> Shooting -> Details
                TabView(selection: $selectedTab) {
                    WatchScoringView()
                        .environmentObject(connectivity)
                        .tag(0)

                    WatchShootingStatsView()
                        .environmentObject(connectivity)
                        .tag(1)
                    
                    WatchOtherStatsView()
                        .environmentObject(connectivity)
                        .tag(2)

                    WatchTeamStatsView()
                        .environmentObject(connectivity)
                        .tag(3)
                }
                .tabViewStyle(.verticalPage)
            } else {
                // No active game - show game picker
                gamePickerView
            }
        }
        .onAppear {
            calendarManager.checkAccess()
        }
    }

    // MARK: - Game Picker View

    private var gamePickerView: some View {
        NavigationStack {
            Group {
                if calendarManager.hasCalendarAccess || !calendarManager.isAccessNotDetermined {
                    gameDeck
                } else {
                    accessCard
                }
            }
            .watchBoard()
            .sheet(isPresented: $showQuickGameConfirmation) {
                WatchQuickGameConfirmationView()
                    .environmentObject(connectivity)
            }
            .confirmationDialog("Hide this game?", isPresented: Binding(
                get: { gameToHide != nil },
                set: { if !$0 { gameToHide = nil } }
            ), titleVisibility: .visible) {
                Button("Hide Game", role: .destructive) {
                    if let game = gameToHide { calendarManager.ignoreGame(game.id) }
                    gameToHide = nil
                }
                Button("Cancel", role: .cancel) { gameToHide = nil }
            } message: {
                if let game = gameToHide { Text("vs \(game.opponent)") }
            }
        }
    }

    // Deck games: today's games (even if their time has passed — delays) + future;
    // drop past days. Mirrors the phone.
    private var deckGames: [WatchGame] {
        let now = Date(); let cal = Calendar.current
        return calendarManager.upcomingGames
            .filter { cal.isDateInToday($0.startTime) || $0.startTime > now }
            .sorted { $0.startTime < $1.startTime }
    }

    // Default card = current/next game (estimated end still ahead); else the last.
    private func defaultDeckIndex(_ games: [WatchGame]) -> Int {
        let now = Date()
        if let i = games.firstIndex(where: {
            $0.startTime.addingTimeInterval(Double($0.halfLength * 2 + 20) * 60) > now
        }) { return i }
        return max(0, games.count - 1)
    }

    // Single-card swipe deck + trailing New Game card — mirrors the phone home.
    private var gameDeck: some View {
        let games = deckGames
        return VStack(spacing: 2) {
            HStack {
                Spacer()
                connectionGlyph
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)

            TabView(selection: $deckSelection) {
                ForEach(Array(games.enumerated()), id: \.element.id) { i, game in
                    WatchGameCard(game: game, onHide: { gameToHide = game })
                        .environmentObject(connectivity)
                        .tag(i)
                }
                WatchNewGameCard { showQuickGameConfirmation = true }
                    .tag(games.count)
            }
            .tabViewStyle(.page)
            .onAppear { deckSelection = defaultDeckIndex(games) }
            .onChange(of: games.count) { _, _ in deckSelection = defaultDeckIndex(games) }
        }
    }

    // Quiet phone-link indicator. Green phone = the phone app is reachable (a game will
    // record video); muted phone-slash = not reachable right now (stats-only / phone app
    // not foregrounded). Kept quiet on purpose — reachability drops whenever the phone app
    // isn't in front, so this is a status glance, not an alarm.
    private var connectionGlyph: some View {
        Image(systemName: connectivity.isPhoneReachable ? "iphone" : "iphone.slash")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(connectivity.isPhoneReachable ? WChalk.green : WChalk.dust)
    }

    private var accessCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus").font(.system(size: 30)).foregroundColor(WChalk.yellow)
            Text("Connect Calendar").font(.system(size: 14, weight: .semibold)).foregroundColor(WChalk.chalk)
            Button { calendarManager.requestAccess() } label: {
                Text("Allow").font(.system(size: 13, weight: .bold)).foregroundColor(WChalk.board)
                    .padding(.horizontal, 18).padding(.vertical, 8).background(WChalk.yellow, in: Capsule())
            }.buttonStyle(.plain)
            Button { showQuickGameConfirmation = true } label: {
                Text("New Game").font(.system(size: 12, weight: .medium)).foregroundColor(WChalk.sky)
            }.buttonStyle(.plain)
        }
        .padding()
    }

}

// MARK: - Watch Game Card (mirrors phone GameCard)

private struct WatchGameCard: View {
    let game: WatchGame
    let onHide: () -> Void
    @EnvironmentObject var connectivity: WatchConnectivityClient

    private var chip: (String, Color) {
        if game.isToday { return ("TODAY", WChalk.yellow) }
        return ("UPCOMING", WChalk.sky)
    }

    private var whenLabel: String {
        game.isToday ? "Today · \(game.timeString)" : "\(game.dayString) · \(game.timeString)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    // Chip
                    Text(chip.0)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(chip.1)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(chip.1.opacity(0.15), in: Capsule())

                    Text("vs")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WChalk.dust)
                        .padding(.top, 2)

                    Text(game.opponent)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(WChalk.sky)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)

                    Text(game.teamName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(WChalk.yellow)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 9))
                        Text(whenLabel).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(WChalk.chalk.opacity(0.7))
                    .padding(.top, 1)

                    if !game.location.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin").font(.system(size: 9))
                            Text(game.location).font(.system(size: 10)).lineLimit(1)
                        }
                        .foregroundColor(WChalk.chalk.opacity(0.5))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }

            NavigationLink(destination: WatchGameConfirmationView(game: game).environmentObject(connectivity)) {
                HStack(spacing: 6) {
                    Image(systemName: "video.fill").font(.system(size: 13, weight: .semibold))
                    Text("Record").font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(WChalk.board)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(WChalk.yellow, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WChalk.chalk.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 2)
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            WKInterfaceDevice.current().play(.directionUp)
            onHide()
        })
    }
}

// MARK: - Watch New Game Card (mirrors phone NewGameCard)

private struct WatchNewGameCard: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundColor(WChalk.yellow)
                Text("New Game")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(WChalk.chalk)
                Text("start now")
                    .font(.system(size: 11))
                    .foregroundColor(WChalk.dust)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WChalk.chalk.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    WatchContentView()
        .environmentObject(WatchConnectivityClient.shared)
}
