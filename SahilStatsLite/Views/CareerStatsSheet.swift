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
    @State private var detailGame: IDWrap? = nil
    @AppStorage("careerCardShowTrend") private var showCardTrend = true

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

    private func gradeNumber(on date: Date) -> Int {
        let cal = Calendar.current
        let m = cal.component(.month, from: date), y = cal.component(.year, from: date)
        let schoolStartYear = m >= 8 ? y : y - 1
        let by = cal.component(.year, from: birthday), bm = cal.component(.month, from: birthday)
        let kStart = by + (bm >= 9 ? 6 : 5)
        return schoolStartYear - kStart
    }

    /// "K", "2nd", "4th" — compact grade tag.
    private func gradeShort(_ grade: Int) -> String {
        switch grade {
        case ..<0: return "Pre-K"
        case 0: return "K"
        default:
            let suf: String
            switch grade % 10 {
            case 1 where grade != 11: suf = "st"
            case 2 where grade != 12: suf = "nd"
            case 3 where grade != 13: suf = "rd"
            default: suf = "th"
            }
            return "\(grade)\(suf)"
        }
    }

    /// Academic year a date falls in (school year starts in August).
    private func academicYear(_ date: Date) -> Int {
        let cal = Calendar.current
        let m = cal.component(.month, from: date), y = cal.component(.year, from: date)
        return m >= 8 ? y : y - 1
    }

    /// Most recent grade in a set of games, e.g. "4th grade".
    private func latestGrade(_ g: [Game]) -> String {
        guard let d = g.map({ $0.date }).max() else { return "" }
        return "\(gradeShort(gradeNumber(on: d))) grade"
    }

    /// Season-by-season (grade) rows for the card back — the real trading-card stat table.
    func gradeRows(_ games: [Game]) -> [(label: String, agg: Agg)] {
        var byYear: [Int: [Game]] = [:]
        for g in games { byYear[academicYear(g.date), default: []].append(g) }
        return byYear.keys.sorted(by: >).map { yr in
            let gs = byYear[yr]!
            return (gradeShort(gradeNumber(on: gs.first!.date)), aggregate(gs))
        }
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
                HStack(spacing: 14) {
                    Text("Career Stats").font(.chalkScript(30)).foregroundColor(Chalk.chalk)
                    Spacer()
                    Button { showCardTrend.toggle() } label: {
                        Image(systemName: showCardTrend ? "waveform.path.ecg" : "waveform.path.ecg.rectangle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(showCardTrend ? Chalk.yellow : Chalk.dust)
                    }
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
                            posterCard
                            if showCardTrend { trendStrip }
                            statTableSection
                            badgesSection
                        }
                    }
                    .padding()
                }
            }
            .chalkBoard()
            .navigationBarHidden(true)
            .sheet(item: $detailGame) { wrap in GameDetailSheet(gameId: wrap.id) }
        }
    }

    // MARK: - Poster card (single identity card; stats live below it)

    private var overall: Agg { aggregate(filteredGames) }
    private var posterAccent: Color { teamFilter != nil ? TeamPalette.color(for: teamFilter!) : Chalk.yellow }
    private var kicker: String { seasonFilter ?? latestGrade(filteredGames) }

    private var posterCard: some View {
        let a = overall
        let accent = posterAccent
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let t = teamFilter {
                    Text(t.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(1).foregroundColor(accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(accent.opacity(0.16), in: Capsule())
                        .overlay(Capsule().stroke(accent.opacity(0.4), lineWidth: 1))
                }
                Spacer()
                rarityBadge(a.games, accent)
            }
            Spacer()
            Text(kicker.uppercased())
                .font(.system(size: 12, weight: .bold)).tracking(2).foregroundColor(Chalk.dust)
            Text("Sahil").font(.chalkHand(64)).foregroundColor(Chalk.chalk)
                .lineLimit(1).minimumScaleFactor(0.5)
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 52, height: 4).padding(.top, 8)
            HStack(spacing: 8) {
                Text("\(a.games) game\(a.games == 1 ? "" : "s")").font(.system(size: 12)).foregroundColor(Chalk.dust)
                Text("·").foregroundColor(Chalk.dust)
                HStack(spacing: 2) {
                    Text("\(a.wins)").foregroundColor(Chalk.green)
                    Text("–").foregroundColor(Chalk.dust)
                    Text("\(a.losses)").foregroundColor(Chalk.coral)
                }.font(.system(size: 12, weight: .bold)).monospacedDigit()
            }
            .padding(.top, 10)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
        .background(courtBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).inset(by: 7).stroke(Chalk.chalk.opacity(0.12), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(foil(accent), lineWidth: 3))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
    }

    private func foil(_ accent: Color) -> LinearGradient {
        LinearGradient(colors: [accent.opacity(0.55), .white.opacity(0.9), accent, .white.opacity(0.55), accent.opacity(0.7)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var courtBackground: some View {
        ZStack {
            LinearGradient(colors: [Chalk.board2, Chalk.board], startPoint: .top, endPoint: .bottom)
            GeometryReader { g in
                Path { p in
                    let w = g.size.width, h = g.size.height
                    p.addEllipse(in: CGRect(x: w * 0.5, y: h * 0.12, width: w * 0.55, height: h * 0.8))
                }
                .stroke(Chalk.chalk.opacity(0.05), lineWidth: 2)
            }
        }
    }

    private func rarityBadge(_ games: Int, _ accent: Color) -> some View {
        let r: (Int, String) = games >= 30 ? (3, "FRANCHISE") : (games >= 10 ? (2, "VETERAN") : (1, "ROOKIE"))
        return HStack(spacing: 4) {
            HStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: i < r.0 ? "star.fill" : "star").font(.system(size: 8))
                        .foregroundColor(i < r.0 ? accent : Chalk.dust.opacity(0.4))
                }
            }
            Text(r.1).font(.system(size: 9, weight: .heavy)).tracking(0.5).foregroundColor(accent)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(accent.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(accent.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Optional trend strip

    @ViewBuilder
    private var trendStrip: some View {
        let vals = trendValues(filteredGames)
        if vals.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("SCORING TREND").font(.system(size: 10, weight: .bold)).tracking(1).foregroundColor(Chalk.dust)
                Sparkline(values: vals, color: posterAccent).frame(height: 40)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
        }
    }

    private func trendValues(_ g: [Game]) -> [Double] {
        let pts = g.sorted { $0.date < $1.date }.map { Double($0.playerStats.points) }
        guard pts.count > 1 else { return pts }
        return pts.indices.map { i in
            let lo = max(0, i - 2); let slice = Array(pts[lo...i])
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    // MARK: - Stat table (always visible, reflects filters)

    private var statTableSection: some View {
        let rows = gradeRows(filteredGames)
        let a = overall
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Stat line").font(.chalkScript(20)).foregroundColor(Chalk.chalk)
                Rectangle().fill(Chalk.chalk.opacity(0.12)).frame(height: 1)
            }
            VStack(spacing: 0) {
                tableRow("", "GP", "PPG", "RPG", "APG", "FG", header: true)
                ForEach(rows.indices, id: \.self) { i in
                    let r = rows[i]
                    tableRow(r.label, "\(r.agg.games)",
                             String(format: "%.1f", r.agg.ppg),
                             String(format: "%.1f", r.agg.rpg),
                             String(format: "%.1f", r.agg.apg),
                             "\(Int(r.agg.fgPct.rounded()))")
                }
                if rows.count > 1 {
                    Rectangle().fill(Chalk.chalk.opacity(0.18)).frame(height: 1)
                    tableRow("CAR", "\(a.games)",
                             String(format: "%.1f", a.ppg),
                             String(format: "%.1f", a.rpg),
                             String(format: "%.1f", a.apg),
                             "\(Int(a.fgPct.rounded()))", total: true)
                }
            }
            .padding(.vertical, 4)
            .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))

            HStack(spacing: 0) {
                splitCell("2P", a.twoPct, Chalk.sky)
                splitCell("3P", a.tpPct, Chalk.yellow)
                splitCell("FT", a.ftPct, Chalk.green)
                splitCell("eFG", a.eFG, Chalk.chalkDim)
                splitCell("TS", a.ts, Chalk.chalkDim)
            }
            .padding(.vertical, 8)
            .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
        }
    }

    private func tableRow(_ c0: String, _ c1: String, _ c2: String, _ c3: String, _ c4: String, _ c5: String,
                          header: Bool = false, total: Bool = false) -> some View {
        let color: Color = header ? Chalk.dust : (total ? posterAccent : Chalk.chalk)
        let weight: Font.Weight = (header || total) ? .heavy : .semibold
        let size: CGFloat = header ? 10 : 13
        return HStack(spacing: 0) {
            Text(c0).font(.system(size: header ? 10 : 12, weight: .heavy)).foregroundColor(total ? posterAccent : Chalk.dust)
                .frame(width: 44, alignment: .leading)
            Group { Text(c1); Text(c2); Text(c3); Text(c4); Text(c5) }
                .font(.system(size: size, weight: weight)).monospacedDigit().foregroundColor(color)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14).padding(.vertical, header ? 6 : 7)
    }

    private func splitCell(_ label: String, _ pct: Double, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(pct.rounded()))%").font(.system(size: 15, weight: .heavy)).monospacedDigit().foregroundColor(color)
            Text(label).font(.system(size: 9)).foregroundColor(Chalk.dust)
        }
        .frame(maxWidth: .infinity)
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
