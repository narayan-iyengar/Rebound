//
//  WatchStatsView.swift
//  SahilStatsLiteWatch
//
//  PURPOSE: "Stat Entry" screen (Shooting). Tracks Points, 2PT/3PT/FT,
//           and Make/Miss. Large touch targets for easy entry.
//           Designed for vertical paging navigation.
//  KEY TYPES: WatchShootingStatsView, ShotType
//  DEPENDS ON: WatchConnectivityClient
//

import SwiftUI
import WatchKit

struct WatchShootingStatsView: View {
    @EnvironmentObject var connectivity: WatchConnectivityClient
    @State private var selectedShotType: ShotType = .twoPoint

    enum ShotType: String, CaseIterable {
        case twoPoint = "2PT"
        case threePoint = "3PT"
        case freeThrow = "FT"
    }

    private var points: Int {
        (connectivity.fg2Made * 2) + (connectivity.fg3Made * 3) + connectivity.ftMade
    }

    private var currentMade: Int {
        switch selectedShotType {
        case .twoPoint: return connectivity.fg2Made
        case .threePoint: return connectivity.fg3Made
        case .freeThrow: return connectivity.ftMade
        }
    }

    private var currentAtt: Int {
        switch selectedShotType {
        case .twoPoint: return connectivity.fg2Att
        case .threePoint: return connectivity.fg3Att
        case .freeThrow: return connectivity.ftAtt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Points header
            HStack {
                Text("\(points)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(WChalk.yellow)
                Text("PTS")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WChalk.yellow.opacity(0.7))
                Spacer()
                Text("\(currentMade)/\(currentAtt)")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(WChalk.chalk.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            // Shot type selector - pill style
            HStack(spacing: 0) {
                ForEach(ShotType.allCases, id: \.self) { type in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedShotType = type
                        }
                    } label: {
                        Text(type.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(selectedShotType == type ? .black : WChalk.chalk.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selectedShotType == type
                                    ? WChalk.chalk
                                    : Color.clear
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(WChalk.chalk.opacity(0.15))
            .cornerRadius(20)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Spacer()

            // Big make/miss buttons
            HStack(spacing: 12) {
                // MAKE button
                Button {
                    recordShot(made: true)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 28, weight: .bold))
                        Text("MAKE")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(WChalk.chalk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(WChalk.green)
                    )
                }
                .buttonStyle(.plain)

                // MISS button
                Button {
                    recordShot(made: false)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 28, weight: .bold))
                        Text("MISS")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(WChalk.chalk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(WChalk.coral.opacity(0.85))
                    )
                }
                .buttonStyle(.plain)
            }
            .frame(height: 80)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .watchBoard()
    }

    // MARK: - Actions

    private func recordShot(made: Bool) {
        switch selectedShotType {
        case .twoPoint:
            if made {
                connectivity.updateStat("fg2Made", value: 1)
            }
            connectivity.updateStat("fg2Att", value: 1)
        case .threePoint:
            if made {
                connectivity.updateStat("fg3Made", value: 1)
            }
            connectivity.updateStat("fg3Att", value: 1)
        case .freeThrow:
            if made {
                connectivity.updateStat("ftMade", value: 1)
            }
            connectivity.updateStat("ftAtt", value: 1)
        }

        // Haptic feedback
        WKInterfaceDevice.current().play(.click)
    }
}

#Preview {
    WatchShootingStatsView()
        .environmentObject(WatchConnectivityClient.shared)
}