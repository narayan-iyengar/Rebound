//
//  WatchOtherStatsView.swift
//  SahilStatsLiteWatch
//
//  PURPOSE: "Detail Stat Entry" screen. Grid layout for tracking non-shooting
//           stats (Assists, Rebounds, Steals, Blocks, Turnovers, Fouls).
//           Designed for vertical paging navigation.
//  KEY TYPES: WatchOtherStatsView
//  DEPENDS ON: WatchConnectivityClient
//

import SwiftUI
import WatchKit

struct WatchOtherStatsView: View {
    @EnvironmentObject var connectivity: WatchConnectivityClient

    var body: some View {
        VStack(spacing: 8) {
            // Header
            HStack {
                Text("Detail Stats")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(WChalk.chalk.opacity(0.8))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            // Stats grid - 2x3 layout with big buttons
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                statTile("AST", connectivity.assists, WChalk.green) {
                    connectivity.updateStat("assists", value: 1)
                }
                statTile("REB", connectivity.rebounds, WChalk.yellow) {
                    connectivity.updateStat("rebounds", value: 1)
                }
                statTile("STL", connectivity.steals, WChalk.sky) {
                    connectivity.updateStat("steals", value: 1)
                }
                statTile("BLK", connectivity.blocks, WChalk.coral) {
                    connectivity.updateStat("blocks", value: 1)
                }
                statTile("TO", connectivity.turnovers, WChalk.coral) {
                    connectivity.updateStat("turnovers", value: 1)
                }
                statTile("PF", connectivity.fouls, WChalk.dust) {
                    connectivity.updateStat("fouls", value: 1)
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .watchBoard()
    }

    // MARK: - Stat Tile

    private func statTile(_ label: String, _ value: Int, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: {
            action()
            WKInterfaceDevice.current().play(.click)
        }) {
            VStack(spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(WChalk.chalk)
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(color)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.2))
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    WatchOtherStatsView()
        .environmentObject(WatchConnectivityClient.shared)
}
