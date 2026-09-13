//
//  CareerStatsSheet.swift
//  SahilStatsLite
//
//  PURPOSE: Career stats as a swipeable DECK of basketball trading cards — one per
//           season plus an all-time Career card. Each card: PPG marquee, record, a
//           quiet scoring trend, and the stat-line strip on the front; tap to flip to
//           the full line (shooting splits, eFG/TS) on the back. Below the deck: the
//           milestone "achievement badges". Season / team / age filters scope it all.
//  KEY TYPES: CareerStatsSheet, SeasonTradingCard
//  DEPENDS ON: GamePersistenceManager
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

struct CareerStatsSheet: View {
    @ObservedObject private var persistenceManager = GamePersistenceManager.shared
    @Environment(\.dismiss) private var dismiss

    // Sahil's birthday — grade is derived from the game date (Sept-1 school-year cutoff).
    private let birthday = Calendar.current.date(from: DateComponents(year: 2016, month: 11, day: 1))!

    @State private var seasonFilter: String? = nil
    @State private var teamFilter: String? = nil
    @State private var ageFilter: String? = nil
    @State private var deckIndex = 0
    @State private var detailGame: IDWrap? = nil

    struct IDWrap: Identifiable { let id: String }

    private var allGames: [Game] { persistenceManager.savedGames }

    private var filteredGames: [Game] {
        allGames.filter { g in
            (seasonFilter == nil || g.season == seasonFilter) &&
            (teamFilter == nil || g.teamName == teamFilter) &&
            (ageFilter == nil || g.ageLevel == ageFilter)
        }
    }

    private var seasons: [String] {
        var earliest: [String: Date] = [:]
        for g in allGames {
            if earliest[g.season] == nil || g.date < earliest[g.season]! { earliest[g.season] = g.date }
        }
        return earliest.keys.sorted { earliest[$0]! > earliest[$1]! }
    }
    private var teams: [String] { Array(Set(allGames.map { $0.teamName })).filter { !$0.isEmpty }.sorted() }
    private var ages: [String] { Array(Set(allGames.compactMap { $0.ageLevel })).filter { !$0.isEmpty }.sorted() }

    // MARK: - Aggregation

    struct Agg {
        var games = 0, wins = 0, losses = 0
        var ppg = 0.0, rpg = 0.0, apg = 0.0, spg = 0.0, bpg = 0.0
        var fgMade = 0, fgAtt = 0, tpMade = 0, tpAtt = 0, ftMade = 0, ftAtt = 0
        var totalPoints = 0
        var record: String { "\(wins)-\(losses)" }
        var winPct: Double { games > 0 ? Double(wins) / Double(games) * 100 : 0 }
        var fgPct: Double { fgAtt > 0 ? Double(fgMade) / Double(fgAtt) * 100 : 0 }
        var tpPct: Double { tpAtt > 0 ? Double(tpMade) / Double(tpAtt) * 100 : 0 }
        var ftPct: Double { ftAtt > 0 ? Double(ftMade) / Double(ftAtt) * 100 : 0 }
        var twoMade: Int { fgMade - tpMade }
        var twoAtt: Int { fgAtt - tpAtt }
        var twoPct: Double { twoAtt > 0 ? Double(twoMade) / Double(twoAtt) * 100 : 0 }
        var eFG: Double { fgAtt > 0 ? (Double(fgMade) + 0.5 * Double(tpMade)) / Double(fgAtt) * 100 : 0 }
        var ts: Double {
            let den = 2 * (Double(fgAtt) + 0.44 * Double(ftAtt))
            return den > 0 ? Double(totalPoints) / den * 100 : 0
        }
    }

    private func aggregate(_ g: [Game]) -> Agg {
        var a = Agg(); a.games = g.count
        guard !g.isEmpty else { return a }
        func avg(_ f: (Game) -> Int) -> Double { Double(g.reduce(0) { $0 + f($1) }) / Double(g.count) }
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
        a.totalPoints = g.reduce(0) { $0 + $1.playerStats.points }
        return a
    }

    // MARK: - Grade from date

    private func gradeLabel(on date: Date) -> String {
        let cal = Calendar.current
        let m = cal.component(.month, from: date), y = cal.component(.year, from: date)
        let schoolStartYear = m >= 8 ? y : y - 1
        let by = cal.component(.year, from: birthday), bm = cal.component(.month, from: birthday)
        let kStart = by + (bm >= 9 ? 6 : 5)
        let grade = schoolStartYear - kStart
        switch grade {
        case ..<0: return "Pre-K"
        case 0: return "Kindergarten"
        default:
            let suf: String
            switch grade % 10 {
            case 1 where grade != 11: suf = "st"
            case 2 where grade != 12: suf = "nd"
            case 3 where grade != 13: suf = "rd"
            default: suf = "th"
            }
            return "\(grade)\(suf) grade"
        }
    }

    // MARK: - Cards

    struct CardModel: Identifiable {
        let id: String
        let title: String       // season name, or "Career"
        let subtitle: String    // grade (season) or "All seasons" (career)
        let games: [Game]
        let isCareer: Bool
    }

    private func dominantTeam(_ g: [Game]) -> String {
        let counts = Dictionary(grouping: g, by: { $0.teamName }).mapValues { $0.count }
        return counts.max { $0.value < $1.value }?.key ?? "Lava"
    }

    private var cards: [CardModel] {
        let g = filteredGames
        guard !g.isEmpty else { return [] }
        // One card per season, newest first.
        var bySeason: [String: [Game]] = [:]
        var latest: [String: Date] = [:]
        for game in g {
            bySeason[game.season, default: []].append(game)
            if latest[game.season] == nil || game.date > latest[game.season]! { latest[game.season] = game.date }
        }
        var out: [CardModel] = bySeason.keys.sorted { latest[$0]! > latest[$1]! }.map { s in
            let games = bySeason[s]!
            let repDate = games.max { $0.date < $1.date }!.date
            return CardModel(id: s, title: s, subtitle: gradeLabel(on: repDate), games: games, isCareer: false)
        }
        // All-time Career card at the end (only when there's more than one season).
        if out.count > 1 || seasonFilter != nil {
            out.append(CardModel(id: "__career", title: "Career", subtitle: "All seasons", games: g, isCareer: true))
        }
        return out
    }

    // MARK: - Milestones (over the filtered set)

    private var careerHighGame: Game? {
        filteredGames.filter { $0.playerStats.points > 0 }.max { $0.playerStats.points < $1.playerStats.points }
    }
    private var longestWinStreak: Int {
        var best = 0, run = 0
        for g in filteredGames.sorted(by: { $0.date < $1.date }) {
            if g.isWin { run += 1; best = max(best, run) } else if g.isLoss { run = 0 }
        }
        return best
    }
    private var doubleDigitGames: Int { filteredGames.filter { $0.playerStats.points >= 10 }.count }
    private var totalPoints: Int { filteredGames.reduce(0) { $0 + $1.playerStats.points } }

    // MARK: - Chrome

    var embedded: Bool = false

    @ViewBuilder
    private func navWrap<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if embedded { content() } else { NavigationView { content() } }
    }

    var body: some View {
        navWrap {
            VStack(spacing: 0) {
                HStack {
                    Text("Career Stats").font(.chalkScript(30)).foregroundColor(Chalk.chalk)
                    Spacer()
                    if !embedded {
                        Button { dismiss() } label: {
                            Text("Done").font(.system(size: 17, weight: .semibold)).foregroundColor(Chalk.chalk)
                        }
                    }
                }
                .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)

                filterBar

                ScrollView {
                    VStack(spacing: 20) {
                        if allGames.isEmpty {
                            emptyCard("No games yet", "Record or log a game and Sahil's cards start printing here.")
                        } else if filteredGames.isEmpty {
                            emptyCard("No games match", "Nothing for this filter. Try clearing one.")
                        } else {
                            deck
                            badgesSection
                        }
                    }
                    .padding()
                }
            }
            .chalkBoard()
            .navigationBarHidden(true)
            .sheet(item: $detailGame) { wrap in GameDetailSheet(gameId: wrap.id) }
            .onChange(of: filteredGames.count) { _, _ in deckIndex = 0 }
        }
    }

    // MARK: - Deck

    private var deck: some View {
        let list = cards
        return VStack(spacing: 10) {
            TabView(selection: $deckIndex) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, card in
                    SeasonTradingCard(
                        title: card.title,
                        subtitle: card.subtitle,
                        accent: card.isCareer ? Chalk.yellow : TeamPalette.color(for: dominantTeam(card.games)),
                        teamLabel: card.isCareer ? "ALL TEAMS" : dominantTeam(card.games).uppercased(),
                        agg: aggregate(card.games),
                        trend: trendValues(card.games),
                        onTapHigh: { if let h = high(card.games) { detailGame = IDWrap(id: h.id) } },
                        highLabel: high(card.games).map { "\($0.playerStats.points) vs \($0.opponent)" }
                    )
                    .padding(.horizontal, 4)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 452)

            // Custom page dots + swipe hint.
            HStack(spacing: 6) {
                ForEach(list.indices, id: \.self) { i in
                    Circle()
                        .fill(i == deckIndex ? Chalk.yellow : Chalk.dust.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            if list.count > 1 {
                Text("swipe · " + list.map { $0.isCareer ? "Career" : shortSeason($0.title) }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(Chalk.dust)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal)
            }
        }
    }

    private func high(_ g: [Game]) -> Game? {
        g.filter { $0.playerStats.points > 0 }.max { $0.playerStats.points < $1.playerStats.points }
    }

    /// Smoothed per-game points for the card's quiet trend line.
    private func trendValues(_ g: [Game]) -> [Double] {
        let pts = g.sorted { $0.date < $1.date }.map { Double($0.playerStats.points) }
        guard pts.count > 1 else { return pts }
        return pts.indices.map { i in
            let lo = max(0, i - 2)
            let slice = Array(pts[lo...i])
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    private func shortSeason(_ s: String) -> String {
        let parts = s.split(separator: " ")
        guard parts.count == 2, let yr = parts.last, yr.count == 4 else { return s }
        return "\(parts[0]) '\(yr.suffix(2))"
    }

    // MARK: - Badges

    private var badgesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Achievements").font(.chalkScript(20)).foregroundColor(Chalk.chalk)
                Rectangle().fill(Chalk.chalk.opacity(0.12)).frame(height: 1)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let h = careerHighGame {
                    Button { detailGame = IDWrap(id: h.id) } label: {
                        badge("⭐", "\(h.playerStats.points)", "high", Chalk.yellow)
                    }.buttonStyle(.plain)
                } else {
                    badge("⭐", "—", "high", Chalk.yellow)
                }
                badge("🔥", "\(longestWinStreak)", "streak", Chalk.coral)
                badge("🎯", "\(doubleDigitGames)", "2-digit", Chalk.green)
                badge("🏀", "\(totalPoints)", "pts", Chalk.sky)
            }
        }
    }

    private func badge(_ icon: String, _ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(icon).font(.system(size: 20))
            Text(value).font(.system(size: 16, weight: .heavy)).monospacedDigit().foregroundColor(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 9)).foregroundColor(Chalk.dust)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.35), lineWidth: 1.5))
    }

    // MARK: - Filter bar

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
            .padding(.horizontal).padding(.bottom, 10)
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
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 40)).foregroundColor(Chalk.dust)
            Text(title).font(.chalkScript(24)).foregroundColor(Chalk.chalk)
            Text(subtitle).font(.system(size: 14)).foregroundColor(Chalk.dust).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
    }
}

// MARK: - Trading card (front = marquee + stat strip, back = full line; tap to flip)

private struct SeasonTradingCard: View {
    let title: String
    let subtitle: String
    let accent: Color
    let teamLabel: String
    let agg: CareerStatsSheet.Agg
    let trend: [Double]
    let onTapHigh: () -> Void
    let highLabel: String?

    @State private var flipped = false

    var body: some View {
        ZStack {
            front.opacity(flipped ? 0 : 1)
            back.opacity(flipped ? 1 : 0)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: flipped)
        .onTapGesture { flipped.toggle() }
    }

    // MARK: Front

    private var front: some View {
        VStack(spacing: 0) {
            // Team-color header band.
            HStack {
                Text(teamLabel).font(.system(size: 13, weight: .heavy)).tracking(1).foregroundColor(Chalk.board)
                Spacer()
                Text(title.uppercased()).font(.system(size: 11, weight: .bold)).foregroundColor(Chalk.board.opacity(0.85))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(accent)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sahil").font(.chalkHand(34)).foregroundColor(Chalk.chalk)
                    Spacer()
                    Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundColor(Chalk.dust)
                }
                .padding(.top, 12)

                // PPG marquee + record.
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(String(format: "%.1f", agg.ppg))
                        .font(.system(size: 60, weight: .heavy)).monospacedDigit().foregroundColor(accent)
                    Text("PPG").font(.system(size: 15, weight: .bold)).foregroundColor(Chalk.chalkDim)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 2) {
                            Text("\(agg.wins)").foregroundColor(Chalk.green)
                            Text("–").foregroundColor(Chalk.dust)
                            Text("\(agg.losses)").foregroundColor(Chalk.coral)
                        }
                        .font(.system(size: 24, weight: .heavy)).monospacedDigit()
                        Text("record").font(.system(size: 10)).foregroundColor(Chalk.dust)
                    }
                }
                .padding(.top, 2)

                // Quiet scoring trend.
                Sparkline(values: trend, color: accent.opacity(0.55))
                    .frame(height: 30)
                    .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)

            // Stat-line strip.
            HStack(spacing: 0) {
                strip(String(format: "%.1f", agg.rpg), "RPG")
                strip(String(format: "%.1f", agg.apg), "APG")
                strip(String(format: "%.1f", agg.spg), "SPG")
                strip(String(format: "%.1f", agg.bpg), "BPG")
                strip(String(format: "%.0f%%", agg.fgPct), "FG")
            }
            .background(Chalk.board.opacity(0.5))

            HStack {
                Text("\(agg.games) game\(agg.games == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundColor(Chalk.dust)
                Spacer()
                Text("★ tap to flip").font(.system(size: 10, weight: .bold)).foregroundColor(accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Chalk.board.opacity(0.5))
        }
        .background(Chalk.board2)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(accent, lineWidth: 2))
    }

    private func strip(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .heavy)).monospacedDigit().foregroundColor(Chalk.chalk)
            Text(label).font(.system(size: 9)).foregroundColor(Chalk.dust)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
    }

    // MARK: Back — full line

    private var back: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(teamLabel).font(.system(size: 13, weight: .heavy)).tracking(1).foregroundColor(Chalk.board)
                Spacer()
                Text("STAT LINE").font(.system(size: 11, weight: .bold)).foregroundColor(Chalk.board.opacity(0.85))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(accent)

            VStack(spacing: 14) {
                Text("\(title) · \(subtitle)").font(.system(size: 13, weight: .semibold)).foregroundColor(Chalk.chalkDim)
                    .frame(maxWidth: .infinity, alignment: .leading)

                shootBar("2PT", agg.twoPct, agg.twoMade, agg.twoAtt, Chalk.sky)
                shootBar("3PT", agg.tpPct, agg.tpMade, agg.tpAtt, Chalk.yellow)
                shootBar("FT", agg.ftPct, agg.ftMade, agg.ftAtt, Chalk.green)

                HStack(spacing: 10) {
                    mini(String(format: "%.0f%%", agg.eFG), "eFG")
                    mini(String(format: "%.0f%%", agg.ts), "TS")
                    mini(String(format: "%.1f", agg.ppg), "PPG")
                    mini("\(agg.totalPoints)", "pts")
                }

                if let h = highLabel {
                    Button(action: onTapHigh) {
                        HStack(spacing: 6) {
                            Text("⭐ Career high").font(.system(size: 12, weight: .semibold)).foregroundColor(Chalk.dust)
                            Spacer()
                            Text(h).font(.system(size: 12, weight: .bold)).foregroundColor(Chalk.yellow)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundColor(Chalk.dust)
                        }
                        .padding(10)
                        .background(Chalk.board.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            Spacer(minLength: 0)

            Text("★ tap to flip back").font(.system(size: 10, weight: .bold)).foregroundColor(accent)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Chalk.board.opacity(0.5))
        }
        .background(Chalk.board2)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(accent, lineWidth: 2))
    }

    private func shootBar(_ label: String, _ pct: Double, _ made: Int, _ att: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(color)
                Spacer()
                Text("\(made)/\(att) · \(Int(pct.rounded()))%").font(.system(size: 11)).monospacedDigit().foregroundColor(Chalk.dust)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.3)).frame(height: 8)
                    Capsule().fill(color).frame(width: max(4, geo.size.width * CGFloat(min(pct, 100) / 100)), height: 8)
                }
            }
            .frame(height: 8)
        }
    }

    private func mini(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .heavy)).monospacedDigit().foregroundColor(Chalk.crisp)
            Text(label).font(.system(size: 9)).foregroundColor(Chalk.dust)
        }
        .frame(maxWidth: .infinity)
    }
}

// A tiny inline trend line for the card's quiet scoring arc.
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let mn = values.min(), let mx = values.max() {
                let range = max(mx - mn, 0.0001)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        let y = geo.size.height * (1 - CGFloat((v - mn) / range))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            } else {
                Rectangle().fill(color.opacity(0.4)).frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}
