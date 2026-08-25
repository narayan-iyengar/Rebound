//
//  CareerStatsSheet.swift
//  SahilStatsLite
//
//  PURPOSE: Career stats dashboard with trend charts, recent form, career averages,
//           and shooting stats. Supports multiple time periods (Last 5, By Week,
//           By Month, By Age) and stat categories (Points, Rebounds, etc.).
//  KEY TYPES: CareerStatsSheet
//  DEPENDS ON: GamePersistenceManager, Charts
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import Charts

// MARK: - Career Stats Sheet

struct CareerStatsSheet: View {
    @ObservedObject private var persistenceManager = GamePersistenceManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTrendStat: TrendStat = .points
    @State private var selectedTimePeriod: TimePeriod = .byWeek

    // Sahil's birthday for age calculation
    private let birthday = Calendar.current.date(from: DateComponents(year: 2016, month: 11, day: 1))!

    enum TimePeriod: String, CaseIterable {
        case lastFive = "Last 5"
        case byWeek = "By Week"
        case byMonth = "By Month"
        case byAge = "By Age"

        var icon: String {
            switch self {
            case .lastFive: return "flame.fill"
            case .byAge: return "person.fill"
            case .byMonth: return "calendar"
            case .byWeek: return "calendar.day.timeline.left"
            }
        }
    }

    enum TrendStat: String, CaseIterable {
        case points = "Points"
        case rebounds = "Rebounds"
        case assists = "Assists"
        case defense = "Defense"
        case shooting = "Shooting"
        case winRate = "Wins"

        // Chalk accent colors so the chart reads as the same board.
        var color: Color {
            switch self {
            case .points: return Chalk.yellow
            case .rebounds: return Chalk.sky
            case .assists: return Chalk.green
            case .defense: return Chalk.chalkDim
            case .shooting: return Chalk.sky
            case .winRate: return Chalk.green
            }
        }

        var label: String {
            switch self {
            case .points: return "PPG"
            case .rebounds: return "RPG"
            case .assists: return "APG"
            case .defense: return "STL+BLK"
            case .shooting: return "FG%"
            case .winRate: return "Win%"
            }
        }

        var isPercentage: Bool {
            switch self {
            case .shooting, .winRate: return true
            default: return false
            }
        }
    }

    // Calculate age at a given date
    private func ageAtDate(_ date: Date) -> Int {
        let calendar = Calendar.current
        let ageComponents = calendar.dateComponents([.year], from: birthday, to: date)
        return ageComponents.year ?? 0
    }

    // Calculate stat value for a group of games
    private func calculateStatValue(for stat: TrendStat, games: [Game]) -> Double {
        guard !games.isEmpty else { return 0 }

        switch stat {
        case .points:
            let total = games.reduce(0) { $0 + $1.playerStats.points }
            return Double(total) / Double(games.count)
        case .rebounds:
            let total = games.reduce(0) { $0 + $1.playerStats.rebounds }
            return Double(total) / Double(games.count)
        case .assists:
            let total = games.reduce(0) { $0 + $1.playerStats.assists }
            return Double(total) / Double(games.count)
        case .defense:
            let total = games.reduce(0) { $0 + $1.playerStats.steals + $1.playerStats.blocks }
            return Double(total) / Double(games.count)
        case .shooting:
            let made = games.reduce(0) { $0 + $1.playerStats.fg2Made + $1.playerStats.fg3Made }
            let attempted = games.reduce(0) { $0 + $1.playerStats.fg2Attempted + $1.playerStats.fg3Attempted }
            return attempted > 0 ? (Double(made) / Double(attempted)) * 100 : 0
        case .winRate:
            let wins = games.filter { $0.isWin }.count
            return (Double(wins) / Double(games.count)) * 100
        }
    }

    // Group games by age and calculate stat averages
    private func statsByAge(for stat: TrendStat) -> [(label: String, value: Double)] {
        let games = persistenceManager.savedGames
        guard !games.isEmpty else { return [] }

        var gamesByAge: [Int: [Game]] = [:]
        for game in games {
            let age = ageAtDate(game.date)
            gamesByAge[age, default: []].append(game)
        }

        return gamesByAge.keys.sorted().compactMap { age in
            guard let gamesAtAge = gamesByAge[age], !gamesAtAge.isEmpty else { return nil }
            return (label: "Age \(age)", value: calculateStatValue(for: stat, games: gamesAtAge))
        }
    }

    // Group games by week and calculate stat averages
    private func statsByWeek(for stat: TrendStat) -> [(label: String, value: Double)] {
        let games = persistenceManager.savedGames
        guard !games.isEmpty else { return [] }

        let calendar = Calendar.current
        var gamesByWeek: [String: [Game]] = [:]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM/dd"

        for game in games {
            let weekOfYear = calendar.component(.weekOfYear, from: game.date)
            let year = calendar.component(.year, from: game.date)
            let key = "\(year)-W\(weekOfYear)"
            gamesByWeek[key, default: []].append(game)
        }

        // Sort by date and take last 12 weeks for readability
        let sortedKeys = gamesByWeek.keys.sorted()
        let recentKeys = sortedKeys.suffix(12)

        return recentKeys.compactMap { key in
            guard let gamesInWeek = gamesByWeek[key], !gamesInWeek.isEmpty else { return nil }
            let weekStart = gamesInWeek.first!.date
            let label = dateFormatter.string(from: weekStart)
            return (label: label, value: calculateStatValue(for: stat, games: gamesInWeek))
        }
    }

    // Group games by month and calculate stat averages
    private func statsByMonth(for stat: TrendStat) -> [(label: String, value: Double)] {
        let games = persistenceManager.savedGames
        guard !games.isEmpty else { return [] }

        let calendar = Calendar.current
        var gamesByMonth: [String: [Game]] = [:]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM yy"

        for game in games {
            let month = calendar.component(.month, from: game.date)
            let year = calendar.component(.year, from: game.date)
            let key = "\(year)-\(month)"
            gamesByMonth[key, default: []].append(game)
        }

        // Sort by date
        let sortedKeys = gamesByMonth.keys.sorted()

        return sortedKeys.compactMap { key in
            guard let gamesInMonth = gamesByMonth[key], !gamesInMonth.isEmpty else { return nil }
            let label = dateFormatter.string(from: gamesInMonth.first!.date)
            return (label: label, value: calculateStatValue(for: stat, games: gamesInMonth))
        }
    }

    // Last 5 games individually
    private func statsByLastFive(for stat: TrendStat) -> [(label: String, value: Double)] {
        let games = Array(persistenceManager.savedGames.prefix(5).reversed())
        guard !games.isEmpty else { return [] }
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d"
        return games.map { game in
            let value = calculateStatValue(for: stat, games: [game])
            return (label: fmt.string(from: game.date), value: value)
        }
    }

    private var currentTrendData: [(label: String, value: Double)] {
        switch selectedTimePeriod {
        case .lastFive:
            return statsByLastFive(for: selectedTrendStat)
        case .byAge:
            return statsByAge(for: selectedTrendStat)
        case .byWeek:
            return statsByWeek(for: selectedTrendStat)
        case .byMonth:
            return statsByMonth(for: selectedTrendStat)
        }
    }

    /// When shown as a page in the home pager (not a sheet): no nav wrapper, no Done.
    var embedded: Bool = false

    @ViewBuilder
    private func navWrap<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if embedded { content() } else { NavigationView { content() } }
    }

    var body: some View {
        navWrap {
            VStack(spacing: 0) {
                // Chalk header replaces the system nav bar.
                HStack {
                    Text("Career Stats")
                        .font(.chalkScript(30))
                        .foregroundColor(Chalk.chalk)

                    Spacer()

                    if !embedded {
                        Button { dismiss() } label: {
                            Text("Done")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Chalk.chalk)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ScrollView {
                    VStack(spacing: 20) {
                        recentFormCard

                        careerAveragesCard

                        if !currentTrendData.isEmpty {
                            trendCard
                        }

                        shootingStatsCard
                    }
                    .padding()
                }
            }
            .chalkBoard()
            .navigationBarHidden(true)
        }
    }

    // MARK: - Card chrome

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding()
            .frame(maxWidth: .infinity)
            .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
    }

    // MARK: - Trend Card

    private var trendCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Progress")
                        .font(.chalkScript(22))
                        .foregroundColor(Chalk.chalk)
                    Spacer()
                }

                // Time period picker - pill style
                HStack(spacing: 0) {
                    ForEach(TimePeriod.allCases, id: \.self) { period in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedTimePeriod = period
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: period.icon)
                                    .font(.caption2)
                                Text(period.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(selectedTimePeriod == period ? Chalk.board : Chalk.dust)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                selectedTimePeriod == period
                                    ? selectedTrendStat.color
                                    : Color.clear
                            )
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Chalk.board.opacity(0.6))
                .cornerRadius(16)

                // Stat picker
                HStack {
                    Text("Stat:")
                        .font(.system(size: 15))
                        .foregroundColor(Chalk.dust)

                    Menu {
                        ForEach(TrendStat.allCases, id: \.self) { stat in
                            Button {
                                selectedTrendStat = stat
                            } label: {
                                HStack {
                                    Text(stat.rawValue)
                                    if stat == selectedTrendStat {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedTrendStat.rawValue)
                                .font(.system(size: 15, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                        .foregroundColor(selectedTrendStat.color)
                    }

                    Spacer()
                }

                // Current value label
                if let latest = currentTrendData.last {
                    HStack {
                        Spacer()
                        let formattedValue = selectedTrendStat.isPercentage
                            ? String(format: "%.0f%%", latest.value)
                            : String(format: "%.1f", latest.value)
                        Text("\(latest.label): \(formattedValue) \(selectedTrendStat.isPercentage ? "" : selectedTrendStat.label)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundColor(selectedTrendStat.color)
                    }
                }

                // Scrollable chart
                ScrollView(.horizontal, showsIndicators: false) {
                 Chart {
                    ForEach(currentTrendData, id: \.label) { dataPoint in
                        LineMark(
                            x: .value("Period", dataPoint.label),
                            y: .value(selectedTrendStat.label, dataPoint.value)
                        )
                        .foregroundStyle(selectedTrendStat.color.gradient)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 3))

                        PointMark(
                            x: .value("Period", dataPoint.label),
                            y: .value(selectedTrendStat.label, dataPoint.value)
                        )
                        .foregroundStyle(selectedTrendStat.color)
                        .symbolSize(60)

                        AreaMark(
                            x: .value("Period", dataPoint.label),
                            y: .value(selectedTrendStat.label, dataPoint.value)
                        )
                        .foregroundStyle(selectedTrendStat.color.opacity(0.1).gradient)
                    }
                }
                .frame(width: max(UIScreen.main.bounds.width - 64,
                                  CGFloat(currentTrendData.count) * 44),
                       height: 160)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Chalk.dust.opacity(0.3))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(selectedTrendStat.isPercentage
                                     ? String(format: "%.0f%%", v)
                                     : String(format: "%.0f", v))
                                    .font(.caption2)
                                    .foregroundColor(Chalk.dust)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: min(currentTrendData.count, 6))) { value in
                        AxisValueLabel {
                            if let s = value.as(String.self) {
                                Text(s)
                                    .font(.caption2)
                                    .foregroundColor(Chalk.dust)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: selectedTrendStat)
                .animation(.easeInOut(duration: 0.3), value: selectedTimePeriod)
                } // end ScrollView
            }
        }
    }

    // MARK: - Recent Form Card

    private var recentFormData: (ppg: Double, diff: Double, count: Int,
                                  bestPts: Int, bestOpponent: String, bestDate: String)? {
        let games = persistenceManager.savedGames
        guard games.count >= 3 else { return nil }
        let last5 = Array(games.prefix(5))
        let ppg = last5.reduce(0.0) { $0 + Double($1.playerStats.points) } / Double(last5.count)
        let diff = ppg - persistenceManager.careerPPG
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        if let best = games.max(by: { $0.playerStats.points < $1.playerStats.points }), best.playerStats.points > 0 {
            return (ppg, diff, last5.count, best.playerStats.points, best.opponent, fmt.string(from: best.date))
        }
        return (ppg, diff, last5.count, 0, "", "")
    }

    @ViewBuilder
    private var recentFormCard: some View {
        if let d = recentFormData {
            card {
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: d.diff >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundColor(d.diff >= 0 ? Chalk.green : Chalk.coral)
                        Text("Last \(d.count) games:")
                            .font(.system(size: 15))
                            .foregroundColor(Chalk.dust)
                        Text(String(format: "%.1f PPG", d.ppg))
                            .font(.system(size: 15, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(Chalk.chalk)
                        Text(String(format: "%+.1f vs season", d.diff))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundColor(d.diff >= 0 ? Chalk.green : Chalk.coral)
                        Spacer()
                    }
                    if d.bestPts > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill").foregroundColor(Chalk.yellow)
                            Text("Best:").font(.system(size: 12)).foregroundColor(Chalk.dust)
                            Text("\(d.bestPts) pts vs \(d.bestOpponent)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Chalk.chalk)
                            Spacer()
                            Text(d.bestDate).font(.caption2).foregroundColor(Chalk.dust)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Career Averages Card

    private var careerAveragesCard: some View {
        card {
            VStack(spacing: 16) {
                HStack {
                    Text("Career Averages")
                        .font(.chalkScript(22))
                        .foregroundColor(Chalk.chalk)
                    Spacer()
                    Text("\(persistenceManager.careerGames) games")
                        .font(.system(size: 12))
                        .foregroundColor(Chalk.dust)
                }

                HStack(spacing: 0) {
                    careerStat(value: String(format: "%.1f", persistenceManager.careerPPG), label: "PPG", color: Chalk.yellow)
                    careerStat(value: String(format: "%.1f", persistenceManager.careerRPG), label: "RPG", color: Chalk.sky)
                    careerStat(value: String(format: "%.1f", persistenceManager.careerAPG), label: "APG", color: Chalk.green)
                    careerStat(value: String(format: "%.1f", persistenceManager.careerSPG), label: "SPG", color: Chalk.chalkDim)
                    careerStat(value: String(format: "%.1f", persistenceManager.careerBPG), label: "BPG", color: Chalk.coral)
                }

                // Record
                HStack(spacing: 20) {
                    Label(persistenceManager.careerRecord, systemImage: "trophy.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(Chalk.chalk)

                    if persistenceManager.careerGames > 0 {
                        let winPct = Double(persistenceManager.careerWins) / Double(persistenceManager.careerGames) * 100
                        Text(String(format: "%.0f%% Win Rate", winPct))
                            .font(.system(size: 15))
                            .monospacedDigit()
                            .foregroundColor(Chalk.dust)
                    }
                }
            }
        }
    }

    private func careerStat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Chalk.dust)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shooting Stats Card

    private var shootingStatsCard: some View {
        card {
            VStack(spacing: 16) {
                HStack {
                    Text("Shooting")
                        .font(.chalkScript(22))
                        .foregroundColor(Chalk.chalk)
                    Spacer()
                }

                HStack(spacing: 20) {
                    shootingCircle(
                        label: "FG",
                        made: persistenceManager.careerFGMade,
                        attempted: persistenceManager.careerFGAttempted,
                        pct: persistenceManager.careerFGPercentage,
                        color: Chalk.sky
                    )
                    shootingCircle(
                        label: "3PT",
                        made: persistenceManager.career3PMade,
                        attempted: persistenceManager.career3PAttempted,
                        pct: persistenceManager.career3PPercentage,
                        color: Chalk.green
                    )
                    shootingCircle(
                        label: "FT",
                        made: persistenceManager.careerFTMade,
                        attempted: persistenceManager.careerFTAttempted,
                        pct: persistenceManager.careerFTPercentage,
                        color: Chalk.yellow
                    )
                }
            }
        }
    }

    private func shootingCircle(label: String, made: Int, attempted: Int, pct: Double, color: Color) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Chalk.chalk.opacity(0.15), lineWidth: 6)
                    .frame(width: 70, height: 70)

                Circle()
                    .trim(from: 0, to: min(pct / 100, 1.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 70, height: 70)
                    .rotationEffect(.degrees(-90))

                Text(String(format: "%.0f%%", pct))
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(color)
            }

            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Chalk.chalk)

            Text("\(made)/\(attempted)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundColor(Chalk.dust)
        }
        .frame(maxWidth: .infinity)
    }
}
