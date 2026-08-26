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
            ScrollView {
                VStack(spacing: 12) {
                    // Header
                    HStack {
                        Image(systemName: "basketball.fill")
                            .font(.system(size: 20))
                            .foregroundColor(WChalk.yellow)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("SahilStats")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(WChalk.chalk)
                            if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                                Text("build \(build)")
                                    .font(.system(size: 8, weight: .regular))
                                    .foregroundColor(WChalk.chalk.opacity(0.3))
                            }
                        }
                    }
                    .padding(.top, 8)

                    // Show connection warning but don't block the UI anymore
                    if !connectivity.isPhoneReachable {
                        HStack(spacing: 6) {
                            Image(systemName: "iphone.slash")
                            Text("Phone offline")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(WChalk.coral)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(WChalk.coral.opacity(0.15))
                        .cornerRadius(8)
                    }

                    if !calendarManager.hasCalendarAccess {
                        if calendarManager.isAccessNotDetermined {
                            Button(action: {
                                calendarManager.requestAccess()
                            }) {
                                Text("Allow Calendar Access")
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(WChalk.yellow.opacity(0.8))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 8)
                        } else {
                            VStack(spacing: 4) {
                                Text("No Calendar Access")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Enable in Watch Settings")
                                    .font(.system(size: 9))
                                    .foregroundColor(WChalk.dust)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.vertical, 8)
                        }
                    }

                    if calendarManager.upcomingGames.isEmpty {
                        // No games synced - show quick start
                        VStack(spacing: 8) {
                            Text("No games scheduled")
                                .font(.system(size: 11))
                                .foregroundColor(WChalk.chalk.opacity(0.5))

                            quickGameButton
                        }
                        .padding(.vertical, 12)
                    } else {
                        // Show upcoming games from WATCH calendar directly
                        VStack(spacing: 8) {
                            // Today's games
                            let todayGames = calendarManager.upcomingGames.filter { $0.isToday }
                            if !todayGames.isEmpty {
                                sectionHeader("Today")
                                ForEach(todayGames) { game in
                                    gameRow(game)
                                }
                            }

                            // Upcoming games (not today)
                            let futureGames = calendarManager.upcomingGames.filter { !$0.isToday }
                            if !futureGames.isEmpty {
                                sectionHeader("Upcoming")
                                ForEach(futureGames.prefix(5)) { game in
                                    gameRow(game)
                                }
                            }

                            // Quick game option at bottom
                            Divider()
                                .background(WChalk.chalk.opacity(0.2))
                                .padding(.vertical, 4)

                            quickGameButton
                        }
                    }
                }
                .padding(.horizontal, 8)
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
                    if let game = gameToHide {
                        calendarManager.ignoreGame(game.id)
                    }
                    gameToHide = nil
                }
                Button("Cancel", role: .cancel) {
                    gameToHide = nil
                }
            } message: {
                if let game = gameToHide {
                    Text("vs \(game.opponent)")
                }
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(WChalk.chalk.opacity(0.5))
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Game Row (NavigationLink to confirmation)

    private func gameRow(_ game: WatchGame) -> some View {
        NavigationLink(destination: WatchGameConfirmationView(game: game).environmentObject(connectivity)) {
            HStack(spacing: 8) {
                // Time
                VStack(alignment: .leading, spacing: 2) {
                    if !game.isToday {
                        Text(game.dayString)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(WChalk.yellow)
                    }
                    Text(game.timeString)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(WChalk.chalk)
                }
                .frame(width: 50, alignment: .leading)

                // Opponent
                VStack(alignment: .leading, spacing: 2) {
                    Text("vs \(game.opponent)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(WChalk.chalk)
                        .lineLimit(1)

                    Text(game.teamName)
                        .font(.system(size: 9))
                        .foregroundColor(WChalk.yellow.opacity(0.8))
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(WChalk.yellow.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(WChalk.chalk.opacity(0.08))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        // highPriorityGesture intercepts the long press before it becomes a tap,
        // preventing the NavigationLink from triggering accidentally.
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            // Haptic feedback for long press
            WKInterfaceDevice.current().play(.directionUp)
            gameToHide = game
        })
    }

    // MARK: - Quick Game Button

    private var quickGameButton: some View {
        Button(action: { showQuickGameConfirmation = true }) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                Text("Quick Game")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(WChalk.chalk.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(WChalk.chalk.opacity(0.1))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    WatchContentView()
        .environmentObject(WatchConnectivityClient.shared)
}
