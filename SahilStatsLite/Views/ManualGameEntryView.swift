//
//  ManualGameEntryView.swift
//  SahilStatsLite
//
//  PURPOSE: Manual post-game stats entry without video recording. Input final
//           scores and individual player stats. Saves to persistence manager.
//  KEY TYPES: ManualGameEntryView
//  DEPENDS ON: GamePersistenceManager, AppState
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

struct ManualGameEntryView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var persistenceManager = GamePersistenceManager.shared

    // Scores
    @State private var myScore: Int = 0
    @State private var opponentScore: Int = 0

    // Player stats
    @State private var fg2Made: Int = 0
    @State private var fg2Att: Int = 0
    @State private var fg3Made: Int = 0
    @State private var fg3Att: Int = 0
    @State private var ftMade: Int = 0
    @State private var ftAtt: Int = 0
    @State private var assists: Int = 0
    @State private var rebounds: Int = 0
    @State private var steals: Int = 0
    @State private var blocks: Int = 0
    @State private var turnovers: Int = 0
    @State private var fouls: Int = 0

    // Computed
    private var sahilPoints: Int {
        (fg2Made * 2) + (fg3Made * 3) + ftMade
    }

    private var teamName: String {
        appState.currentGame?.teamName ?? "My Team"
    }

    private var opponent: String {
        appState.currentGame?.opponent ?? "Opponent"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            ScrollView {
                VStack(spacing: 20) {
                    // Score Entry
                    scoreSection

                    // Player Stats
                    statsSection

                    Spacer(minLength: 20)
                }
                .padding()
            }

            // Save Button
            saveButton
        }
        .chalkBoard()
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                appState.isLogOnly = false
                appState.currentScreen = .home
            } label: {
                Image(systemName: "xmark")
                    .font(.title2)
                    .foregroundColor(Chalk.dust)
            }

            Spacer()

            Text("Log Game")
                .font(.chalkScript(28))
                .foregroundColor(Chalk.chalk)

            Spacer()

            // Placeholder for balance
            Image(systemName: "xmark")
                .font(.title2)
                .foregroundColor(.clear)
        }
        .padding()
    }

    // MARK: - Score Section

    private var scoreSection: some View {
        VStack(spacing: 16) {
            Text("Final Score")
                .font(.chalkScript(22))
                .foregroundColor(Chalk.chalk)

            HStack(spacing: 20) {
                // My Team
                VStack(spacing: 8) {
                    Text(teamName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Chalk.sky)
                        .lineLimit(1)

                    scoreInput(value: $myScore, accent: Chalk.sky)
                }
                .frame(maxWidth: .infinity)

                Text("vs")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(Chalk.dust)

                // Opponent
                VStack(spacing: 8) {
                    Text(opponent)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Chalk.coral)
                        .lineLimit(1)

                    scoreInput(value: $opponentScore, accent: Chalk.coral)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
    }

    private func scoreInput(value: Binding<Int>, accent: Color) -> some View {
        HStack(spacing: 12) {
            Button {
                if value.wrappedValue > 0 {
                    value.wrappedValue -= 1
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title2)
                    .foregroundColor(Chalk.dust)
            }

            ScoreText(value: "\(value.wrappedValue)", size: 36)
                .frame(minWidth: 60)

            Button {
                value.wrappedValue += 1
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundColor(accent)
            }
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Player Stats")
                    .font(.chalkScript(22))
                    .foregroundColor(Chalk.chalk)

                Spacer()

                Text("\(sahilPoints) pts")
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Chalk.yellow)
            }

            // Shooting stats
            HStack(spacing: 12) {
                shootingTile("2PT", made: $fg2Made, att: $fg2Att, color: Chalk.sky)
                shootingTile("3PT", made: $fg3Made, att: $fg3Att, color: Chalk.green)
                shootingTile("FT", made: $ftMade, att: $ftAtt, color: Chalk.yellow)
            }

            // Other stats
            HStack(spacing: 8) {
                statTile("AST", $assists, Chalk.green)
                statTile("REB", $rebounds, Chalk.sky)
                statTile("STL", $steals, Chalk.chalkDim)
                statTile("BLK", $blocks, Chalk.coral)
                statTile("TO", $turnovers, Chalk.coral)
                statTile("PF", $fouls, Chalk.dust)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
    }

    // MARK: - Reusable Tiles (same pattern as UltraMinimalRecordingView)

    private func shootingTile(_ label: String, made: Binding<Int>, att: Binding<Int>, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(color)

            Text("\(made.wrappedValue)/\(att.wrappedValue)")
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .foregroundColor(Chalk.crisp)

            HStack(spacing: 6) {
                // Make button
                Button {
                    made.wrappedValue += 1
                    att.wrappedValue += 1
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Chalk.board)
                        .frame(width: 32, height: 26)
                        .background(Chalk.green)
                        .cornerRadius(6)
                }

                // Miss button
                Button {
                    att.wrappedValue += 1
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Chalk.board)
                        .frame(width: 32, height: 26)
                        .background(Chalk.coral)
                        .cornerRadius(6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Chalk.board.opacity(0.5))
        .cornerRadius(10)
    }

    private func statTile(_ label: String, _ value: Binding<Int>, _ color: Color) -> some View {
        Button {
            value.wrappedValue += 1
        } label: {
            VStack(spacing: 2) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 20, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(color)
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Chalk.dust)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Chalk.board.opacity(0.5))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save Button

    private var saveButton: some View {
        ChalkButton(title: "Save Game", icon: "checkmark.circle.fill", color: Chalk.yellow) {
            saveGame()
        }
        .padding()
    }

    // MARK: - Actions

    private func saveGame() {
        guard var game = appState.currentGame else { return }

        // Update scores
        game.myScore = myScore
        game.opponentScore = opponentScore

        // Update player stats
        game.playerStats = PlayerStats(
            fg2Made: fg2Made,
            fg2Attempted: fg2Att,
            fg3Made: fg3Made,
            fg3Attempted: fg3Att,
            ftMade: ftMade,
            ftAttempted: ftAtt,
            assists: assists,
            rebounds: rebounds,
            steals: steals,
            blocks: blocks,
            turnovers: turnovers,
            fouls: fouls
        )

        // Mark as completed
        game.completedAt = Date()

        // Save
        appState.currentGame = game
        persistenceManager.saveGame(game)

        // Reset log-only mode and go to summary
        appState.isLogOnly = false
        appState.currentScreen = .summary
    }
}

#Preview {
    ManualGameEntryView()
        .environmentObject(AppState())
}
