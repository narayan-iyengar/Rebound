//
//  EditGameView.swift
//  SahilStatsLite
//
//  PURPOSE: Edit post-game stats and scores. "Jony Ive" style: interactive
//           tiles instead of a boring form. Tap to increment, long press to decrement.
//           Team & opponent names are editable so a wrong auto-detected name can be fixed.
//  KEY TYPES: EditGameView
//  DEPENDS ON: Game, GamePersistenceManager
//

import SwiftUI

struct EditGameView: View {
    @Binding var game: Game
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var persistenceManager = GamePersistenceManager.shared

    // Local state for editing
    @State private var editedGame: Game

    init(game: Binding<Game>) {
        self._game = game
        self._editedGame = State(initialValue: game.wrappedValue)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Chalk header replaces the system nav bar / toolbar.
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.system(size: 17))
                    .foregroundColor(Chalk.dust)

                    Spacer()

                    Text("Edit Game")
                        .font(.chalkScript(28))
                        .foregroundColor(Chalk.chalk)

                    Spacer()

                    Button("Save") {
                        saveChanges()
                    }
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Chalk.yellow)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ScrollView {
                    VStack(spacing: 24) {
                        // Header (Score)
                        scoreEditor

                        // Player Stats
                        playerStatsEditor

                        Spacer(minLength: 40)
                    }
                    .padding()
                }
            }
            .chalkBoard()
            .navigationBarHidden(true)
        }
    }

    private func saveChanges() {
        // Trim names so an accidental empty field doesn't wipe the label.
        editedGame.teamName = editedGame.teamName.trimmingCharacters(in: .whitespaces)
        editedGame.opponent = editedGame.opponent.trimmingCharacters(in: .whitespaces)

        // Update the bound game (updates UI immediately)
        game = editedGame

        // Persist changes
        persistenceManager.saveGame(editedGame)

        dismiss()
    }

    // MARK: - Score Editor

    private var scoreEditor: some View {
        VStack(spacing: 16) {
            Text("Game Score")
                .font(.chalkScript(22))
                .foregroundColor(Chalk.chalk)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 20) {
                // Home Team (name now editable)
                scoreTile(
                    name: $editedGame.teamName,
                    score: $editedGame.myScore,
                    color: Chalk.sky
                )

                // Opponent (name now editable)
                scoreTile(
                    name: $editedGame.opponent,
                    score: $editedGame.opponentScore,
                    color: Chalk.coral
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
    }

    private func scoreTile(name: Binding<String>, score: Binding<Int>, color: Color) -> some View {
        VStack(spacing: 12) {
            // Editable name — fixes a wrong auto-detected team/opponent name.
            TextField("", text: name,
                      prompt: Text("Name").foregroundColor(Chalk.dust))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(color)
                .tint(Chalk.yellow)
                .autocorrectionDisabled()
                .lineLimit(1)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Chalk.board.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 16) {
                Button {
                    if score.wrappedValue > 0 { score.wrappedValue -= 1 }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundColor(Chalk.dust)
                }
                .buttonStyle(.plain)

                ScoreText(value: "\(score.wrappedValue)", size: 32)
                    .frame(minWidth: 50)

                Button {
                    score.wrappedValue += 1
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(color)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(Chalk.board.opacity(0.4))
        .cornerRadius(12)
    }

    // MARK: - Player Stats Editor

    private var playerStatsEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Player Stats")
                .font(.chalkScript(22))
                .foregroundColor(Chalk.chalk)

            VStack(spacing: 16) {
                // Shooting
                VStack(spacing: 12) {
                    Text("Shooting (Made / Attempts)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Chalk.dust)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    shootingRow(label: "2PT", made: $editedGame.playerStats.fg2Made, att: $editedGame.playerStats.fg2Attempted, color: Chalk.sky)
                    shootingRow(label: "3PT", made: $editedGame.playerStats.fg3Made, att: $editedGame.playerStats.fg3Attempted, color: Chalk.green)
                    shootingRow(label: "FT", made: $editedGame.playerStats.ftMade, att: $editedGame.playerStats.ftAttempted, color: Chalk.yellow)
                }
                .padding()
                .background(Chalk.board.opacity(0.4))
                .cornerRadius(12)

                // Other Stats
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statEditor(label: "AST", value: $editedGame.playerStats.assists, color: Chalk.green)
                    statEditor(label: "REB", value: $editedGame.playerStats.rebounds, color: Chalk.sky)
                    statEditor(label: "STL", value: $editedGame.playerStats.steals, color: Chalk.chalkDim)
                    statEditor(label: "BLK", value: $editedGame.playerStats.blocks, color: Chalk.coral)
                    statEditor(label: "TO", value: $editedGame.playerStats.turnovers, color: Chalk.coral)
                    statEditor(label: "PF", value: $editedGame.playerStats.fouls, color: Chalk.dust)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
    }

    private func shootingRow(label: String, made: Binding<Int>, att: Binding<Int>, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(color)
                .frame(width: 40, alignment: .leading)

            Spacer()

            // Made
            HStack(spacing: 12) {
                Button { if made.wrappedValue > 0 { made.wrappedValue -= 1 } } label: {
                    Image(systemName: "minus")
                        .font(.caption)
                        .foregroundColor(Chalk.chalk)
                        .frame(width: 24, height: 24)
                        .background(Chalk.board.opacity(0.8))
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)

                Text("\(made.wrappedValue)")
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Chalk.crisp)
                    .frame(width: 20)

                Button { made.wrappedValue += 1; if made.wrappedValue > att.wrappedValue { att.wrappedValue = made.wrappedValue } } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .frame(width: 24, height: 24)
                        .background(Chalk.green.opacity(0.25))
                        .foregroundColor(Chalk.green)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }

            Text("/")
                .foregroundColor(Chalk.dust)
                .padding(.horizontal, 4)

            // Attempts
            HStack(spacing: 12) {
                Button { if att.wrappedValue > made.wrappedValue { att.wrappedValue -= 1 } } label: {
                    Image(systemName: "minus")
                        .font(.caption)
                        .foregroundColor(Chalk.chalk)
                        .frame(width: 24, height: 24)
                        .background(Chalk.board.opacity(0.8))
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)

                Text("\(att.wrappedValue)")
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Chalk.crisp)
                    .frame(width: 20)

                Button { att.wrappedValue += 1 } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .frame(width: 24, height: 24)
                        .background(Chalk.sky.opacity(0.25))
                        .foregroundColor(Chalk.sky)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func statEditor(label: String, value: Binding<Int>, color: Color) -> some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(color)

            Text("\(value.wrappedValue)")
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundColor(Chalk.crisp)

            HStack(spacing: 12) {
                Button { if value.wrappedValue > 0 { value.wrappedValue -= 1 } } label: {
                    Image(systemName: "minus")
                        .font(.caption2)
                        .foregroundColor(Chalk.chalk)
                        .frame(width: 24, height: 24)
                        .background(Chalk.board.opacity(0.8))
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)

                Button { value.wrappedValue += 1 } label: {
                    Image(systemName: "plus")
                        .font(.caption2)
                        .frame(width: 24, height: 24)
                        .background(color.opacity(0.25))
                        .foregroundColor(color)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Chalk.board.opacity(0.4))
        .cornerRadius(12)
    }
}
