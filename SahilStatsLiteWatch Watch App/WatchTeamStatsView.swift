//
//  WatchTeamStatsView.swift
//  SahilStatsLiteWatch
//
//  PURPOSE: "Team" page (4th Crown page). Team fouls + timeouts tally for both
//           teams, mirroring the phone scoreboard's tally box. Tap a cell to add
//           one, swipe down to remove one. Syncs both ways with the phone.
//  KEY TYPES: WatchTeamStatsView
//  DEPENDS ON: WatchConnectivityClient, WatchTheme (WatchTallyMarks)
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

struct WatchTeamStatsView: View {
    @EnvironmentObject var connectivity: WatchConnectivityClient

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Team")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(WChalk.chalk)
                Spacer()
                Text("FOULS · T.O.")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(WChalk.dust)
            }
            .padding(.top, 6)

            teamCard(name: connectivity.teamName, accent: WChalk.yellow,
                     fouls: connectivity.homeFouls, timeouts: connectivity.homeTimeouts,
                     foulsKey: WatchMessage.homeFouls, timeoutsKey: WatchMessage.homeTimeouts)

            teamCard(name: connectivity.opponent, accent: WChalk.sky,
                     fouls: connectivity.awayFouls, timeouts: connectivity.awayTimeouts,
                     foulsKey: WatchMessage.awayFouls, timeoutsKey: WatchMessage.awayTimeouts)
        }
        .padding(.horizontal, 8)
        .watchBoard()
    }

    // MARK: - Team card (name + fouls/timeouts cells)

    private func teamCard(name: String, accent: Color,
                          fouls: Int, timeouts: Int,
                          foulsKey: String, timeoutsKey: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text(String(name.prefix(10)))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accent)
                    .lineLimit(1)
                Spacer()
            }

            HStack(spacing: 6) {
                tallyCell(label: "FOULS", count: fouls, color: WChalk.coral, key: foulsKey)
                tallyCell(label: "T.O.",  count: timeouts, color: accent,    key: timeoutsKey)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(WChalk.chalk.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Tally cell (tap +1, swipe down -1)

    private func tallyCell(label: String, count: Int, color: Color, key: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(WChalk.dust)
            WatchTallyMarks(count: count, color: color, barHeight: 15)
                .frame(minHeight: 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(WChalk.chalk.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            connectivity.updateTeamTally(key, delta: 1)
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    let isVertical = abs(value.translation.height) > abs(value.translation.width) * 1.2
                    if value.translation.height > 20 && isVertical {
                        connectivity.updateTeamTally(key, delta: -1)
                    }
                }
        )
    }
}

#Preview {
    WatchTeamStatsView()
        .environmentObject(WatchConnectivityClient.shared)
}
