//
//  AllGamesView.swift
//  SahilStatsLite
//
//  PURPOSE: Full game log, grouped cleverly: weekend/tournament CLUSTERS (same team,
//           games within 2 days) nested under ADAPTIVE time sections (This Week /
//           This Month / month / year), each header carrying its W–L record. Team is
//           color-coded (Lava = yellow; every other team gets a stable auto-assigned
//           color). Filters: All/Wins/Losses + a team filter + opponent search, all
//           working within the grouping.
//  KEY TYPES: AllGamesView, GameCluster, TimeSection
//  DEPENDS ON: GamePersistenceManager, GameRow, GameDetailSheet
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

// MARK: - Grouping models

private struct GameCluster: Identifiable {
    let id: String
    let team: String
    let games: [Game]              // newest-first

    var startDate: Date { games.map(\.date).min() ?? Date() }
    var endDate: Date { games.map(\.date).max() ?? Date() }
    var wins: Int { games.filter(\.isWin).count }
    var losses: Int { games.filter(\.isLoss).count }
    var isSingle: Bool { games.count == 1 }

    /// A shared venue across the cluster's games, if they all agree — used as the sub-label.
    var sharedLocation: String? {
        let locs = Set(games.compactMap { $0.location?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        return locs.count == 1 ? locs.first : nil
    }
}

private struct TimeSection: Identifiable {
    let id: String                 // == title
    let title: String
    let clusters: [GameCluster]
    let collapsedByDefault: Bool

    var wins: Int { clusters.reduce(0) { $0 + $1.wins } }
    var losses: Int { clusters.reduce(0) { $0 + $1.losses } }
    var gameCount: Int { clusters.reduce(0) { $0 + $1.games.count } }
}

// MARK: - All Games View

struct AllGamesView: View {
    @ObservedObject private var persistenceManager = GamePersistenceManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedGameForDetail: Game? = nil
    @State private var gameToDelete: Game? = nil
    @State private var showDeleteConfirmation = false

    // Filters
    @State private var selectedFilter: GameFilter = .all
    @State private var selectedTeam: String? = nil       // nil = all teams
    @State private var searchText = ""

    // Expansion state
    @State private var expandedSections: Set<String> = []   // collapsed-by-default sections opened
    @State private var expandedClusters: Set<String> = []   // multi-game clusters opened inline

    enum GameFilter: String, CaseIterable {
        case all = "All"
        case wins = "Wins"
        case losses = "Losses"

        var icon: String {
            switch self {
            case .all: return "list.bullet"
            case .wins: return "trophy.fill"
            case .losses: return "xmark.circle"
            }
        }
    }

    // MARK: Filtering

    private var filteredGames: [Game] {
        var games = persistenceManager.savedGames

        switch selectedFilter {
        case .all: break
        case .wins: games = games.filter { $0.isWin }
        case .losses: games = games.filter { $0.isLoss }
        }

        if let team = selectedTeam {
            games = games.filter { $0.teamName == team }
        }

        if !searchText.isEmpty {
            games = games.filter {
                $0.opponent.localizedCaseInsensitiveContains(searchText) ||
                $0.teamName.localizedCaseInsensitiveContains(searchText)
            }
        }
        return games
    }

    /// Distinct teams across ALL games (not the filtered set), Lava first then alphabetical.
    private var allTeams: [String] {
        let teams = Set(persistenceManager.savedGames.map(\.teamName)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        return teams.sorted { a, b in
            if a.lowercased() == "lava" { return true }
            if b.lowercased() == "lava" { return false }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    // MARK: Clustering + sectioning

    private var sections: [TimeSection] {
        let games = filteredGames

        // 1) Cluster: per team, split into windows where consecutive games are ≤2 days apart.
        var clusters: [GameCluster] = []
        let byTeam = Dictionary(grouping: games) { $0.teamName }
        let cal = Calendar.current
        for (team, teamGames) in byTeam {
            let sorted = teamGames.sorted { $0.date > $1.date }   // newest first
            var bucket: [Game] = []
            for game in sorted {
                if let last = bucket.last,
                   let gap = cal.dateComponents([.day],
                                                from: cal.startOfDay(for: game.date),
                                                to: cal.startOfDay(for: last.date)).day,
                   gap <= 2 {
                    bucket.append(game)
                } else {
                    if !bucket.isEmpty {
                        clusters.append(GameCluster(id: bucket[0].id, team: team, games: bucket))
                    }
                    bucket = [game]
                }
            }
            if !bucket.isEmpty {
                clusters.append(GameCluster(id: bucket[0].id, team: team, games: bucket))
            }
        }

        // 2) Order clusters by recency, then group consecutive ones into time sections.
        clusters.sort { $0.endDate > $1.endDate }

        var result: [TimeSection] = []
        var current: [GameCluster] = []
        var currentInfo: (title: String, collapsed: Bool)? = nil
        for cluster in clusters {
            let info = Self.sectionInfo(for: cluster.endDate)
            if let ci = currentInfo, ci.title == info.title {
                current.append(cluster)
            } else {
                if let ci = currentInfo, !current.isEmpty {
                    result.append(TimeSection(id: ci.title, title: ci.title,
                                              clusters: current, collapsedByDefault: ci.collapsed))
                }
                current = [cluster]
                currentInfo = info
            }
        }
        if let ci = currentInfo, !current.isEmpty {
            result.append(TimeSection(id: ci.title, title: ci.title,
                                      clusters: current, collapsedByDefault: ci.collapsed))
        }
        return result
    }

    /// Adaptive bucket for a date: This Week / This Month / month (this year) / year (older).
    private static func sectionInfo(for date: Date) -> (title: String, collapsed: Bool) {
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

    private func isExpanded(_ section: TimeSection) -> Bool {
        section.collapsedByDefault ? expandedSections.contains(section.title) : true
    }

    // MARK: Team color (Lava pinned; everyone else stable-hashed, avoiding W/L green & coral)

    private static let teamPalette: [Color] = [
        Chalk.sky,
        Color(red: 0.78, green: 0.72, blue: 0.88),   // lavender
        Color(red: 0.88, green: 0.66, blue: 0.77),   // rose
        Color(red: 0.66, green: 0.71, blue: 0.88),   // periwinkle
        Color(red: 0.85, green: 0.77, blue: 0.55)    // sand
    ]

    private func teamColor(_ name: String) -> Color {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if key == "lava" { return Chalk.yellow }
        var hash: UInt64 = 5381
        for scalar in key.unicodeScalars { hash = (hash &* 33) &+ UInt64(scalar.value) }
        return Self.teamPalette[Int(hash % UInt64(Self.teamPalette.count))]
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
                HStack {
                    Text("All Games")
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
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                if allTeams.count > 1 {
                    teamFilterBar
                        .padding(.bottom, 8)
                }

                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(Chalk.dust)
                    TextField("", text: $searchText,
                              prompt: Text("Search opponent...").foregroundColor(Chalk.dust))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundColor(Chalk.crisp)
                        .tint(Chalk.yellow)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Chalk.dust)
                        }
                    }
                }
                .padding(10)
                .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Chalk.chalk.opacity(0.2), lineWidth: 1.5))
                .padding(.horizontal)

                filterSummary
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                // Grouped list
                ScrollView {
                    LazyVStack(spacing: 8, pinnedViews: []) {
                        ForEach(sections) { section in
                            sectionHeader(section)
                            if isExpanded(section) {
                                ForEach(section.clusters) { cluster in
                                    clusterView(cluster)
                                }
                            }
                        }

                        if filteredGames.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "basketball")
                                    .font(.largeTitle)
                                    .foregroundColor(Chalk.dust)
                                Text("No games found")
                                    .font(.chalkScript(26))
                                    .foregroundColor(Chalk.chalk)
                                if !searchText.isEmpty {
                                    Text("Try a different search term")
                                        .foregroundColor(Chalk.dust)
                                }
                            }
                            .padding(.vertical, 40)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
            .chalkBoard()
            .navigationBarHidden(true)
            .sheet(item: $selectedGameForDetail) { game in
                GameDetailSheet(gameId: game.id)
            }
            .alert("Delete Game?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { gameToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let game = gameToDelete {
                        persistenceManager.deleteGame(game)
                        gameToDelete = nil
                    }
                }
            } message: {
                if let game = gameToDelete {
                    Text("Delete the game vs \(game.opponent) on \(game.date.formatted(date: .abbreviated, time: .omitted))? This cannot be undone.")
                }
            }
        }
    }

    // MARK: - Result filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(GameFilter.allCases, id: \.self) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedFilter = filter }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: filter.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(filter.rawValue)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(selectedFilter == filter ? Chalk.yellow : Chalk.board2, in: Capsule())
                    .foregroundColor(selectedFilter == filter ? Chalk.board : Chalk.chalkDim)
                    .overlay(Capsule().strokeBorder(
                        selectedFilter == filter ? Color.clear : Chalk.chalk.opacity(0.2), lineWidth: 1.5))
                }
            }
            Spacer()
        }
    }

    // MARK: - Team filter bar (color-coded, only shown when >1 team exists)

    private var teamFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                teamChipButton(title: "All Teams", color: Chalk.chalkDim, isSelected: selectedTeam == nil) {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTeam = nil }
                }
                ForEach(allTeams, id: \.self) { team in
                    teamChipButton(title: team, color: teamColor(team), isSelected: selectedTeam == team) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTeam = (selectedTeam == team) ? nil : team
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func teamChipButton(title: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? color : Chalk.board2, in: Capsule())
                .foregroundColor(isSelected ? Chalk.board : color)
                .overlay(Capsule().strokeBorder(
                    isSelected ? Color.clear : color.opacity(0.4), lineWidth: 1.5))
        }
    }

    // MARK: - Summary (adapts to the active team filter)

    private var filterSummary: some View {
        let wins = filteredGames.filter { $0.isWin }.count
        let losses = filteredGames.filter { $0.isLoss }.count
        let label = selectedTeam.map { "\($0) · " } ?? ""
        return HStack {
            Text("\(label)\(filteredGames.count) games")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(selectedTeam != nil ? teamColor(selectedTeam!) : Chalk.dust)
            Spacer()
            if filteredGames.count > 0 {
                HStack(spacing: 12) {
                    Label("\(wins)W", systemImage: "trophy.fill").foregroundColor(Chalk.green)
                    Label("\(losses)L", systemImage: "xmark.circle").foregroundColor(Chalk.coral)
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Section header

    private func sectionHeader(_ section: TimeSection) -> some View {
        Button {
            guard section.collapsedByDefault else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                if expandedSections.contains(section.title) { expandedSections.remove(section.title) }
                else { expandedSections.insert(section.title) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(section.title.uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(Chalk.chalkDim)
                if section.collapsedByDefault {
                    Image(systemName: isExpanded(section) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Chalk.dust)
                }
                Spacer()
                Text("\(section.wins)–\(section.losses)")
                    .font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .foregroundColor(Chalk.yellow)
            }
            .padding(.top, 10)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cluster view

    @ViewBuilder
    private func clusterView(_ cluster: GameCluster) -> some View {
        if cluster.isSingle, let game = cluster.games.first {
            singleGameRow(game)
        } else {
            multiClusterCard(cluster)
        }
    }

    private func singleGameRow(_ game: Game) -> some View {
        Button { selectedGameForDetail = game } label: { GameRow(game: game) }
            .buttonStyle(.plain)
            .contextMenu { gameContextMenu(game) }
    }

    private func multiClusterCard(_ cluster: GameCluster) -> some View {
        let expanded = expandedClusters.contains(cluster.id)
        let color = teamColor(cluster.team)
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expanded { expandedClusters.remove(cluster.id) }
                    else { expandedClusters.insert(cluster.id) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(dateRangeText(cluster))
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(Chalk.chalk)
                                teamChip(cluster.team, color: color)
                            }
                            Text(clusterSubLabel(cluster))
                                .font(.system(size: 11))
                                .foregroundColor(Chalk.dust)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(cluster.wins)–\(cluster.losses)")
                            .font(.system(size: 16, weight: .bold)).monospacedDigit()
                            .foregroundColor(Chalk.crisp)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Chalk.dust)
                            .padding(.leading, 2)
                    }
                    if !expanded { winLossStrip(cluster) }
                }
                .padding(12)
                .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(color.opacity(0.25), lineWidth: 1.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 8) {
                    // Oldest → newest, matching how the weekend actually played out.
                    ForEach(cluster.games.sorted { $0.date < $1.date }) { game in
                        singleGameRow(game)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // Chronological "form guide": one colored score tile per game. The tile color IS the
    // result (green = win, coral = loss), so the score lives right inside it — no separate
    // letter or caption. Left-aligned, tidy whether the weekend had 2 games or 6.
    private func winLossStrip(_ cluster: GameCluster) -> some View {
        HStack(spacing: 6) {
            ForEach(cluster.games.sorted { $0.date < $1.date }) { game in
                HStack(spacing: 5) {
                    // Letter as well as color, so win/loss reads without relying on the
                    // green-vs-coral distinction alone (the classic colorblind pairing).
                    Text(game.isWin ? "W" : "L")
                        .font(.system(size: 12, weight: .heavy))
                    Text(game.scoreString)
                        .font(.system(size: 12, weight: .bold)).monospacedDigit()
                }
                .foregroundColor(Chalk.board)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(game.isWin ? Chalk.green : Chalk.coral,
                            in: RoundedRectangle(cornerRadius: 7))
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    /// Cluster sub-label: a shortened venue/city (street number + street dropped), else count.
    private func clusterSubLabel(_ cluster: GameCluster) -> String {
        if let loc = cluster.sharedLocation, let short = Self.shortLocation(loc) {
            return short
        }
        return "\(cluster.games.count) games"
    }

    /// Trim a freeform address to something glanceable: drop trailing state + ZIP, and if it
    /// starts with a street number, drop through the street-type word so a city/venue remains.
    private static func shortLocation(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // Drop trailing ZIP.
        s = s.replacingOccurrences(of: #"\s*\d{5}(-\d{4})?$"#, with: "", options: .regularExpression)
        // Drop trailing state token.
        for st in [", CA", " CA", ", California", " California"] where s.hasSuffix(st) {
            s = String(s.dropLast(st.count)); break
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        // If it opens with a street address, drop up to the street-type word → leaves the city.
        if let first = s.first, first.isNumber {
            let suffixes: Set<String> = ["st", "st.", "street", "dr", "dr.", "drive", "ave", "ave.",
                                         "avenue", "rd", "rd.", "road", "blvd", "blvd.", "ln", "ln.",
                                         "lane", "way", "ct", "ct.", "court", "pkwy", "hwy", "pl", "pl."]
            let words = s.split(separator: " ").map(String.init)
            if let idx = words.firstIndex(where: { suffixes.contains($0.lowercased()) }), idx + 1 < words.count {
                s = words[(idx + 1)...].joined(separator: " ")
            }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return s.isEmpty ? nil : s
    }

    private func teamChip(_ name: String, color: Color) -> some View {
        Text(name.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .lineLimit(1)
    }

    @ViewBuilder
    private func gameContextMenu(_ game: Game) -> some View {
        Button { selectedGameForDetail = game } label: {
            Label("View Details", systemImage: "info.circle")
        }
        Button(role: .destructive) {
            gameToDelete = game
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showDeleteConfirmation = true }
        } label: {
            Label("Delete Game", systemImage: "trash")
        }
    }

    // Date range label: "Sep 13", "Sep 13–14", or "Aug 30 – Sep 1".
    private func dateRangeText(_ cluster: GameCluster) -> String {
        let cal = Calendar.current
        let start = cluster.startDate, end = cluster.endDate
        let md = DateFormatter(); md.dateFormat = "MMM d"
        let d = DateFormatter(); d.dateFormat = "d"
        if cal.isDate(start, inSameDayAs: end) { return md.string(from: end) }
        if cal.isDate(start, equalTo: end, toGranularity: .month) {
            return "\(md.string(from: start))–\(d.string(from: end))"
        }
        return "\(md.string(from: start)) – \(md.string(from: end))"
    }
}
