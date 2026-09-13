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

// MARK: - Shared grouping helpers (used by the game log AND the clip store, so they stay
// visually identical)

/// Team → color. Lava is pinned to the app's yellow; every other team (Elements, one-off
/// guest teams) gets a stable color from a small palette that deliberately avoids the W/L
/// green + coral. Deterministic hash so a given team is always the same color, no picking.
enum TeamPalette {
    static let colors: [Color] = [
        Chalk.sky,
        Color(red: 0.78, green: 0.72, blue: 0.88),   // lavender
        Color(red: 0.88, green: 0.66, blue: 0.77),   // rose
        Color(red: 0.66, green: 0.71, blue: 0.88),   // periwinkle
        Color(red: 0.85, green: 0.77, blue: 0.55)    // sand
    ]

    static func color(for name: String) -> Color {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if key == "lava" { return Chalk.yellow }
        if key.isEmpty { return Chalk.chalkDim }
        var hash: UInt64 = 5381
        for scalar in key.unicodeScalars { hash = (hash &* 33) &+ UInt64(scalar.value) }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

/// Adaptive time bucket for a date: This Week / This Month / month (this year) / year (older,
/// collapsed by default). Fine detail for recent, coarse for old.
enum AdaptiveTimeSection {
    static func info(for date: Date) -> (title: String, collapsed: Bool) {
        let cal = Calendar.current
        let now = Date()
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date),
                                         to: cal.startOfDay(for: now)).day, days >= 0, days < 7 {
            return ("This Week", false)
        }
        if cal.isDate(date, equalTo: now, toGranularity: .month) {
            return ("This Month", false)
        }
        let df = DateFormatter()
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            df.dateFormat = "MMMM"
            return (df.string(from: date), false)
        }
        df.dateFormat = "yyyy"
        return (df.string(from: date), true)
    }
}

// MARK: - Game Row

struct GameRow: View {
    let game: Game

    var body: some View {
        HStack {
            // Result badge — matches the W/L totals up top: Win = green, Loss = coral.
            let badgeColor = game.isWin ? Chalk.green : Chalk.coral
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
