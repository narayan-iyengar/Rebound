//
//  GameRow.swift
//  SahilStatsLite
//
//  PURPOSE: Game log row component showing result indicator, opponent, team name,
//           date, score, YouTube status, and Sahil's points.
//  KEY TYPES: GameRow
//  DEPENDS ON: Game
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

// MARK: - Game Row

struct GameRow: View {
    let game: Game

    var body: some View {
        HStack {
            // Result badge — Win = sky outline, Loss = dust outline (per mock)
            let badgeColor = game.isWin ? Chalk.sky : Chalk.dust
            Text(game.resultString)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(badgeColor)
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(badgeColor.opacity(0.6), lineWidth: 1.5))

            VStack(alignment: .leading, spacing: 2) {
                Text("vs \(game.opponent)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Chalk.chalk)

                if !game.teamName.isEmpty {
                    Text(game.teamName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Chalk.sky)
                }

                Text(game.date, style: .date)
                    .font(.system(size: 12))
                    .foregroundColor(Chalk.dust)
            }

            Spacer()

            // Score and points (crisp data)
            VStack(alignment: .trailing, spacing: 2) {
                Text(game.scoreString)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Chalk.crisp)

                HStack(spacing: 4) {
                    if game.youtubeStatus == .uploading {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else if game.youtubeStatus == .uploaded {
                        Image(systemName: "checkmark.icloud.fill")
                            .font(.caption2)
                            .foregroundColor(Chalk.green)
                    } else if game.youtubeStatus == .failed {
                        Image(systemName: "exclamationmark.icloud.fill")
                            .font(.caption2)
                            .foregroundColor(Chalk.coral)
                    }

                    Text("\(game.playerStats.points) pts")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(Chalk.yellow)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(Chalk.dust)
        }
        .chalkCard()
    }
}
