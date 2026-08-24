//
//  AllGamesView.swift
//  SahilStatsLite
//
//  PURPOSE: Full game log with filtering (All/Wins/Losses), search by opponent,
//           pagination, context menu for details/delete, and delete confirmation.
//  KEY TYPES: AllGamesView
//  DEPENDS ON: GamePersistenceManager, GameRow, GameDetailSheet
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

// MARK: - All Games View

struct AllGamesView: View {
    @ObservedObject private var persistenceManager = GamePersistenceManager.shared
    @Environment(\.dismiss) private var dismiss

    // Game detail state (local, not binding to avoid double-sheet bug)
    @State private var selectedGameForDetail: Game? = nil

    // Delete confirmation state
    @State private var gameToDelete: Game? = nil
    @State private var showDeleteConfirmation = false

    // Filter state
    @State private var selectedFilter: GameFilter = .all
    @State private var searchText = ""

    // Pagination
    @State private var displayedCount = 20
    private let pageSize = 20

    enum GameFilter: String, CaseIterable {
        case all = "All"
        case wins = "Wins"
        case losses = "Losses"

        var icon: String {
            switch self {
            case .all: return "list.bullet"
            case .wins: return "trophy.fill"
            case .losses: return "xmark.circle"
            }
        }
    }

    private var filteredGames: [Game] {
        var games = persistenceManager.savedGames

        switch selectedFilter {
        case .all:
            break
        case .wins:
            games = games.filter { $0.isWin }
        case .losses:
            games = games.filter { $0.isLoss }
        }

        if !searchText.isEmpty {
            games = games.filter { game in
                game.opponent.localizedCaseInsensitiveContains(searchText) ||
                game.teamName.localizedCaseInsensitiveContains(searchText)
            }
        }

        return games
    }

    private var displayedGames: [Game] {
        Array(filteredGames.prefix(displayedCount))
    }

    private var hasMoreGames: Bool {
        displayedCount < filteredGames.count
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter bar
                filterBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search opponent...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.bottom, 8)

                // Stats summary for current filter
                filterSummary
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                // Games list
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(displayedGames) { game in
                            Button {
                                selectedGameForDetail = game
                            } label: {
                                GameRow(game: game)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    selectedGameForDetail = game
                                } label: {
                                    Label("View Details", systemImage: "info.circle")
                                }

                                Button(role: .destructive) {
                                    gameToDelete = game
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete Game", systemImage: "trash")
                                }
                            }
                        }

                        // Load more button
                        if hasMoreGames {
                            Button {
                                displayedCount += pageSize
                            } label: {
                                HStack {
                                    Text("Load More")
                                    Text("(\(filteredGames.count - displayedCount) remaining)")
                                        .foregroundColor(.secondary)
                                }
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.systemGray6))
                                .cornerRadius(10)
                            }
                        }

                        // Empty state
                        if filteredGames.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "basketball")
                                    .font(.largeTitle)
                                    .foregroundColor(Chalk.dust)
                                Text("No games found")
                                    .font(.chalkScript(26))
                                    .foregroundColor(Chalk.chalk)
                                if !searchText.isEmpty {
                                    Text("Try a different search term")
                                        .font(.chalkHand(14))
                                        .foregroundColor(Chalk.dust)
                                }
                            }
                            .padding(.vertical, 40)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
            .chalkBoard()
            .navigationTitle("All Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedGameForDetail) { game in
                GameDetailSheet(gameId: game.id)
            }
            .alert("Delete Game?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    gameToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let game = gameToDelete {
                        persistenceManager.deleteGame(game)
                        gameToDelete = nil
                    }
                }
            } message: {
                if let game = gameToDelete {
                    Text("Delete the game vs \(game.opponent) on \(game.date.formatted(date: .abbreviated, time: .omitted))? This cannot be undone.")
                }
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(GameFilter.allCases, id: \.self) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedFilter = filter
                        displayedCount = pageSize
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: filter.icon)
                            .font(.caption)
                        Text(filter.rawValue)
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(selectedFilter == filter ? Color.orange : Color(.systemGray6))
                    .foregroundColor(selectedFilter == filter ? .white : .primary)
                    .cornerRadius(20)
                }
            }
            Spacer()
        }
    }

    // MARK: - Filter Summary

    private var filterSummary: some View {
        HStack {
            Text("\(filteredGames.count) games")
                .font(.chalkHand(15))
                .foregroundColor(Chalk.dust)

            Spacer()

            if selectedFilter == .all && filteredGames.count > 0 {
                let wins = filteredGames.filter { $0.isWin }.count
                let losses = filteredGames.filter { $0.isLoss }.count
                HStack(spacing: 12) {
                    Label("\(wins)W", systemImage: "trophy.fill")
                        .foregroundColor(Chalk.green)
                    Label("\(losses)L", systemImage: "xmark.circle")
                        .foregroundColor(Chalk.coral)
                }
                .font(.caption)
            }
        }
    }
}
