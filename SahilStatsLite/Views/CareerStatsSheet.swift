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

    // MARK: - Filters (season · team · age) — scope every card below

    @State private var seasonFilter: String? = nil
    @State private var teamFilter: String? = nil
    @State private var ageFilter: String? = nil
    @State private var showDetail = false          // reveals the week/month line chart
    @State private var detailGame: IDWrap? = nil    // career-high tap → that game's detail

    struct IDWrap: Identifiable { let id: String }

    private var allGames: [Game] { persistenceManager.savedGames }

    /// Games matching the active filters (nil filter = "all").
    private var filteredGames: [Game] {
        allGames.filter { g in
            (seasonFilter == nil || g.season == seasonFilter) &&
            (teamFilter == nil || g.teamName == teamFilter) &&
            (ageFilter == nil || g.ageLevel == ageFilter)
        }
    }

    /// Distinct seasons present, newest first.
    private var seasons: [String] {
        var earliest: [String: Date] = [:]
        for g in allGames {
            let s = g.season
            if earliest[s] == nil || g.date < earliest[s]! { earliest[s] = g.date }
        }
        return earliest.keys.sorted { earliest[$0]! > earliest[$1]! }
    }
    private var teams: [String] {
        Array(Set(allGames.map { $0.teamName })).filter { !$0.isEmpty }.sorted()
    }
    private var ages: [String] {
        Array(Set(allGames.compactMap { $0.ageLevel })).filter { !$0.isEmpty }.sorted()
    }
    private var anyFilterActive: Bool { seasonFilter != nil || teamFilter != nil || ageFilter != nil }

    /// All career numbers, recomputed over the filtered subset.
    private struct Agg {
        var games = 0, wins = 0, losses = 0
        var ppg = 0.0, rpg = 0.0, apg = 0.0, spg = 0.0, bpg = 0.0
        var fgMade = 0, fgAtt = 0, tpMade = 0, tpAtt = 0, ftMade = 0, ftAtt = 0
        var record: String { "\(wins)-\(losses)" }
        var winPct: Double { games > 0 ? Double(wins) / Double(games) * 100 : 0 }
        var fgPct: Double { fgAtt > 0 ? Double(fgMade) / Double(fgAtt) * 100 : 0 }
        var tpPct: Double { tpAtt > 0 ? Double(tpMade) / Double(tpAtt) * 100 : 0 }
        var ftPct: Double { ftAtt > 0 ? Double(ftMade) / Double(ftAtt) * 100 : 0 }
    }

    private var agg: Agg {
        let g = filteredGames
        var a = Agg()
        a.games = g.count
        guard !g.isEmpty else { return a }
        func avg(_ f: (Game) -> Int) -> Double {
            let total = g.reduce(0) { $0 + f($1) }
            return Double(total) / Double(g.count)
        }
        a.ppg = avg { $0.playerStats.points }
        a.rpg = avg { $0.playerStats.rebounds }
        a.apg = avg { $0.playerStats.assists }
        a.spg = avg { $0.playerStats.steals }
        a.bpg = avg { $0.playerStats.blocks }
        a.wins = g.filter { $0.isWin }.count
        a.losses = g.filter { $0.isLoss }.count
        a.fgMade = g.reduce(0) { $0 + $1.playerStats.fg2Made + $1.playerStats.fg3Made }
        a.fgAtt = g.reduce(0) { $0 + $1.playerStats.fg2Attempted + $1.playerStats.fg3Attempted }
        a.tpMade = g.reduce(0) { $0 + $1.playerStats.fg3Made }
        a.tpAtt = g.reduce(0) { $0 + $1.playerStats.fg3Attempted }
        a.ftMade = g.reduce(0) { $0 + $1.playerStats.ftMade }
        a.ftAtt = g.reduce(0) { $0 + $1.playerStats.ftAttempted }
        return a
    }

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
        let games = filteredGames
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
        let games = filteredGames
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
        let games = filteredGames
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
        let games = Array(filteredGames.prefix(5).reversed())
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

                filterBar

                ScrollView {
                    VStack(spacing: 16) {
                        if allGames.isEmpty {
                            emptyCard("No games yet", "Record or log a game and Sahil's season board fills in here.")
                        } else if filteredGames.isEmpty {
                            emptyCard("No games match", "Nothing for this filter combination. Try clearing a filter.")
                        } else {
                            heroCard
                            growthSection
                            milestonesSection
                            statLineBox
                            detailDisclosure
                        }
                    }
                    .padding()
                }
            }
            .chalkBoard()
            .navigationBarHidden(true)
            .sheet(item: $detailGame) { wrap in
                GameDetailSheet(gameId: wrap.id)
            }
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

    // MARK: - Redesign: data

    /// Growth ignores the season filter (it shows the arc across ALL seasons) but
    /// still respects team + age.
    private var growthGames: [Game] {
        allGames.filter { g in
            (teamFilter == nil || g.teamName == teamFilter) &&
            (ageFilter == nil || g.ageLevel == ageFilter)
        }
    }
    private var highlightSeason: String? {
        seasonFilter ?? growthGames.max(by: { $0.date < $1.date })?.season
    }
    private var seasonPPG: [(season: String, ppg: Double, current: Bool)] {
        let g = growthGames
        guard !g.isEmpty else { return [] }
        var byS: [String: [Game]] = [:]
        var earliest: [String: Date] = [:]
        for game in g {
            byS[game.season, default: []].append(game)
            let s = game.season
            if earliest[s] == nil || game.date < earliest[s]! { earliest[s] = game.date }
        }
        let ordered = byS.keys.sorted { earliest[$0]! < earliest[$1]! }
        return ordered.map { s in
            let games = byS[s]!
            let ppg = Double(games.reduce(0) { $0 + $1.playerStats.points }) / Double(games.count)
            return (s, ppg, s == highlightSeason)
        }
    }
    private var growthDelta: (delta: Double, prevSeason: String)? {
        let arr = seasonPPG
        guard let idx = arr.firstIndex(where: { $0.current }), idx > 0 else { return nil }
        return (arr[idx].ppg - arr[idx - 1].ppg, arr[idx - 1].season)
    }
    private var careerHighGame: Game? {
        filteredGames.filter { $0.playerStats.points > 0 }
            .max { $0.playerStats.points < $1.playerStats.points }
    }
    private var longestWinStreak: Int {
        let sorted = filteredGames.sorted { $0.date < $1.date }
        var best = 0, run = 0
        for g in sorted {
            if g.isWin { run += 1; best = max(best, run) } else if g.isLoss { run = 0 }
        }
        return best
    }
    private var doubleDigitGames: Int { filteredGames.filter { $0.playerStats.points >= 10 }.count }
    private var totalPoints: Int { filteredGames.reduce(0) { $0 + $1.playerStats.points } }

    /// "Fall 2026" -> "Fall '26"
    private func shortSeason(_ s: String) -> String {
        let parts = s.split(separator: " ")
        guard parts.count == 2, let yr = parts.last, yr.count == 4 else { return s }
        return "\(parts[0]) '\(yr.suffix(2))"
    }

    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.chalkScript(20)).foregroundColor(Chalk.chalk)
            Rectangle().fill(Chalk.chalk.opacity(0.12)).frame(height: 1)
            if let trailing {
                Text(trailing).font(.system(size: 11, weight: .medium)).foregroundColor(Chalk.dust)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Redesign: filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if seasons.count > 1 {
                    filterMenu(icon: "calendar", allLabel: "All seasons", options: seasons, selection: $seasonFilter)
                }
                if teams.count > 1 {
                    filterMenu(icon: "tshirt", allLabel: "All teams", options: teams, selection: $teamFilter)
                }
                if !ages.isEmpty {
                    filterMenu(icon: "figure.child", allLabel: "All ages", options: ages, selection: $ageFilter)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
    }

    private func filterMenu(icon: String, allLabel: String, options: [String], selection: Binding<String?>) -> some View {
        Menu {
            Button { selection.wrappedValue = nil } label: {
                if selection.wrappedValue == nil { Label(allLabel, systemImage: "checkmark") } else { Text(allLabel) }
            }
            ForEach(options, id: \.self) { opt in
                Button { selection.wrappedValue = opt } label: {
                    if selection.wrappedValue == opt { Label(opt, systemImage: "checkmark") } else { Text(opt) }
                }
            }
        } label: {
            let active = selection.wrappedValue != nil
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(selection.wrappedValue ?? allLabel).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(active ? Chalk.board : Chalk.dust)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(active ? Chalk.yellow : Chalk.board2, in: Capsule())
            .overlay(Capsule().stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
        }
    }

    private func emptyCard(_ title: String, _ subtitle: String) -> some View {
        card {
            VStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 40)).foregroundColor(Chalk.dust)
                Text(title).font(.chalkScript(24)).foregroundColor(Chalk.chalk)
                Text(subtitle).font(.system(size: 14)).foregroundColor(Chalk.dust).multilineTextAlignment(.center)
            }.padding(.vertical, 20)
        }
    }

    // MARK: - Redesign: hero

    private var heroCard: some View {
        VStack(spacing: 4) {
            Text(highlightSeason ?? "Career")
                .font(.chalkScript(30)).foregroundColor(Chalk.chalk)
            HStack(spacing: 2) {
                Text("\(agg.wins)").foregroundColor(Chalk.green)
                Text("–").foregroundColor(Chalk.dust.opacity(0.6))
                Text("\(agg.losses)").foregroundColor(Chalk.coral)
            }
            .font(.system(size: 58, weight: .heavy)).monospacedDigit()
            Text("\(Int(agg.winPct.rounded()))% wins · \(agg.games) game\(agg.games == 1 ? "" : "s")")
                .font(.chalkScript(16)).foregroundColor(Chalk.sky)
            HStack(spacing: 5) {
                Text(String(format: "Averaging %.1f PPG", agg.ppg))
                    .font(.system(size: 14)).foregroundColor(Chalk.chalkDim)
                if let d = growthDelta {
                    Text(String(format: "%@ %+.1f", d.delta >= 0 ? "↑" : "↓", d.delta))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(d.delta >= 0 ? Chalk.green : Chalk.coral)
                    Text("vs \(shortSeason(d.prevSeason))")
                        .font(.system(size: 13)).foregroundColor(Chalk.dust)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: - Redesign: growth

    @ViewBuilder
    private var growthSection: some View {
        let data = seasonPPG
        if data.count > 1 {
            sectionHeader("Growth", trailing: "PPG by season")
            let maxPPG = max(data.map { $0.ppg }.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(data, id: \.season) { d in
                    VStack(spacing: 4) {
                        Text(String(format: "%.1f", d.ppg))
                            .font(.system(size: 12, weight: .bold)).monospacedDigit()
                            .foregroundColor(d.current ? Chalk.yellow : Chalk.dust)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(d.current ? Chalk.yellow : Chalk.sky.opacity(0.4))
                            .frame(height: max(8, CGFloat(d.ppg / maxPPG) * 96))
                        Text(shortSeason(d.season))
                            .font(.system(size: 10)).foregroundColor(Chalk.dust)
                            .lineLimit(1).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 130)
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Redesign: milestones

    private var milestonesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Milestones", trailing: nil)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                if let high = careerHighGame {
                    Button { detailGame = IDWrap(id: high.id) } label: {
                        milestone("⭐", "\(high.playerStats.points)", "High vs \(high.opponent)", Chalk.yellow, tappable: true)
                    }.buttonStyle(.plain)
                }
                milestone("🔥", "\(longestWinStreak)", "Win streak", Chalk.coral, tappable: false)
                milestone("🎯", "\(doubleDigitGames)", "Double-digit games", Chalk.green, tappable: false)
                milestone("🏀", "\(totalPoints)", "Total points", Chalk.sky, tappable: false)
            }
        }
    }

    private func milestone(_ icon: String, _ value: String, _ label: String, _ color: Color, tappable: Bool) -> some View {
        HStack(spacing: 10) {
            Text(icon).font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 19, weight: .heavy)).monospacedDigit().foregroundColor(color)
                Text(label).font(.system(size: 11)).foregroundColor(Chalk.dust).lineLimit(1)
            }
            Spacer(minLength: 0)
            if tappable {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundColor(Chalk.dust)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Chalk.chalk.opacity(0.18), lineWidth: 1.5))
    }

    // MARK: - Redesign: stat line

    private var statLineBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Stat line", trailing: nil)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    statCell(String(format: "%.1f", agg.ppg), "PPG", Chalk.yellow)
                    statCell(String(format: "%.1f", agg.rpg), "RPG", Chalk.sky)
                    statCell(String(format: "%.1f", agg.apg), "APG", Chalk.green)
                    statCell(String(format: "%.1f", agg.spg), "SPG", Chalk.chalkDim)
                    statCell(String(format: "%.1f", agg.bpg), "BPG", Chalk.coral)
                }
                Divider().overlay(Chalk.chalk.opacity(0.12))
                HStack(spacing: 0) {
                    shootCell("FG", agg.fgPct, agg.fgMade, agg.fgAtt, Chalk.sky)
                    shootCell("3PT", agg.tpPct, agg.tpMade, agg.tpAtt, Chalk.green)
                    shootCell("FT", agg.ftPct, agg.ftMade, agg.ftAtt, Chalk.yellow)
                }
            }
            .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Chalk.chalk.opacity(0.18), lineWidth: 1.5))
        }
    }

    private func statCell(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 21, weight: .heavy)).monospacedDigit().foregroundColor(color)
            Text(label).font(.system(size: 10)).foregroundColor(Chalk.dust)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func shootCell(_ label: String, _ pct: Double, _ made: Int, _ att: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%.0f%%", pct)).font(.system(size: 16, weight: .heavy)).monospacedDigit().foregroundColor(color)
            Text("\(made)/\(att)").font(.system(size: 10)).foregroundColor(Chalk.dust).monospacedDigit()
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(Chalk.chalkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    // MARK: - Redesign: detail disclosure (the existing week/month line chart, tucked away)

    @ViewBuilder
    private var detailDisclosure: some View {
        if filteredGames.count > 1 {
            VStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showDetail.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(showDetail ? "Hide progress detail" : "Show progress detail")
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(Chalk.sky)
                        Image(systemName: showDetail ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold)).foregroundColor(Chalk.sky)
                    }
                }.buttonStyle(.plain)
                if showDetail && !currentTrendData.isEmpty {
                    trendCard
                }
            }
            .padding(.top, 4)
        }
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
                .frame(width: max(300, CGFloat(currentTrendData.count) * 48),
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
