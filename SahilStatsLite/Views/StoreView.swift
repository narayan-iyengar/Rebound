//
//  StoreView.swift
//  SahilStatsLite
//
//  PURPOSE: The "Store" — saved Clips (highlights), grouped by game session
//           (Sahil's team vs opponent · date/time). Tap to play. Long-press to
//           enter multi-select, then tap clips (or a game header to grab the whole
//           game) and delete in bulk — from the app and optionally Photos. No
//           win/loss — clips are self-describing from clip-time metadata.
//  KEY TYPES: StoreView, ClipCard, ClipThumbnail, ClipPlayerSheet
//  DEPENDS ON: HighlightStore, AVKit
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import AVKit
import AVFoundation

/// A weekend/tournament cluster of sessions — same team, within 2 days — mirroring the
/// game log so the Store reads identically.
private struct ClipCluster: Identifiable {
    let id: String
    let team: String
    let isPractice: Bool
    let groups: [HighlightGroup]
    var endDate: Date { groups.map(\.date).max() ?? Date() }
    var startDate: Date { groups.map(\.date).min() ?? Date() }
    var isSingle: Bool { groups.count == 1 }
}

struct StoreView: View {
    @ObservedObject private var store = HighlightStore.shared
    @State private var playing: Highlight?
    @State private var fullGame: PlayerItem?
    @State private var expandedClusters: Set<String> = []

    // Multi-select
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var showDeleteConfirm = false

    // Tag editing
    @State private var editingGroupId: String?
    @State private var labelDraft = ""
    @State private var showTagEditor = false

    // Collapsible time sections (older years collapsed by default)
    @State private var expandedSections: Set<String> = []

    /// Clip sessions grouped into adaptive time sections (This Week / This Month / month /
    /// year), newest first — same philosophy as the game log.
    private var sections: [(title: String, collapsed: Bool, clusters: [ClipCluster])] {
        let cal = Calendar.current
        var clusters: [ClipCluster] = []
        // Games clustered per team into ≤2-day windows (same algorithm as the game log).
        let byTeam = Dictionary(grouping: allGameGroups) { $0.homeTeam }
        for (team, groups) in byTeam {
            let sorted = groups.sorted { $0.date > $1.date }
            var bucket: [HighlightGroup] = []
            for g in sorted {
                if let last = bucket.last,
                   let gap = cal.dateComponents([.day], from: cal.startOfDay(for: g.date),
                                                to: cal.startOfDay(for: last.date)).day, gap <= 2 {
                    bucket.append(g)
                } else {
                    if !bucket.isEmpty { clusters.append(ClipCluster(id: bucket[0].id, team: team, isPractice: false, groups: bucket)) }
                    bucket = [g]
                }
            }
            if !bucket.isEmpty { clusters.append(ClipCluster(id: bucket[0].id, team: team, isPractice: false, groups: bucket)) }
        }
        for p in store.grouped where p.isPractice {
            clusters.append(ClipCluster(id: p.id, team: "Practice", isPractice: true, groups: [p]))
        }
        clusters.sort { $0.endDate > $1.endDate }

        var result: [(title: String, collapsed: Bool, clusters: [ClipCluster])] = []
        for c in clusters {
            let info = AdaptiveTimeSection.info(for: c.endDate)
            if var last = result.last, last.title == info.title {
                last.clusters.append(c); result[result.count - 1] = last
            } else {
                result.append((info.title, info.collapsed, [c]))
            }
        }
        return result
    }

    /// Non-practice clip groups + synthesized groups for games that have a full-game video
    /// but no clips, so every recorded/imported game shows here with its links.
    private var allGameGroups: [HighlightGroup] {
        var groups = store.grouped.filter { !$0.isPractice }
        let existing = Set(groups.map(\.id))
        for game in GamePersistenceManager.shared.savedGames where !existing.contains(game.id) {
            if localVideoURL(game) != nil || game.youtubeVideoId != nil {
                groups.append(HighlightGroup(id: game.id, homeTeam: game.teamName, awayTeam: game.opponent,
                                             date: game.date, isPractice: false, label: nil, clips: []))
            }
        }
        return groups
    }

    private func isExpanded(_ title: String, collapsed: Bool) -> Bool {
        collapsed ? expandedSections.contains(title) : true
    }

    private func game(for group: HighlightGroup) -> Game? {
        guard !group.isPractice else { return nil }
        return GamePersistenceManager.shared.savedGames.first { $0.id == group.id }
    }

    private func games(_ cluster: ClipCluster) -> [Game] {
        cluster.groups.compactMap { grp in GamePersistenceManager.shared.savedGames.first { $0.id == grp.id } }
    }

    private func record(_ clusters: [ClipCluster]) -> (w: Int, l: Int) {
        let gs = clusters.flatMap { games($0) }
        return (gs.filter(\.isWin).count, gs.filter(\.isLoss).count)
    }

    private func localVideoURL(_ game: Game) -> URL? {
        guard let url = game.videoURL else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(url.lastPathComponent)
        return FileManager.default.fileExists(atPath: doc.path) ? doc : nil
    }

    /// Final result of the game a clip session belongs to (nil for practice / unlinked clips).
    private func result(for group: HighlightGroup) -> (letter: String, color: Color)? {
        guard !group.isPractice else { return nil }
        guard let game = GamePersistenceManager.shared.savedGames.first(where: { $0.id == group.id })
        else { return nil }
        return (game.isWin ? "W" : "L", game.isWin ? Chalk.green : Chalk.coral)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if sections.isEmpty {
                    emptyState
                } else {
                    ForEach(sections, id: \.title) { section in
                        sectionHeader(title: section.title, collapsed: section.collapsed,
                                      clusters: section.clusters)
                        if isExpanded(section.title, collapsed: section.collapsed) {
                            ForEach(section.clusters) { cluster in
                                if cluster.isSingle {
                                    gameSection(cluster.groups[0])
                                } else if selecting {
                                    ForEach(cluster.groups.sorted { $0.date < $1.date }) { gameSection($0) }
                                } else {
                                    clusterCard(cluster)
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 30)
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .chalkBoard()
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar }
        }
        .fullScreenCover(item: $playing) { clip in
            VideoPlayerSheet(url: clip.url, caption: clip.isPractice ? "Practice" : clip.scoreLine)
        }
        .fullScreenCover(item: $fullGame) { item in
            VideoPlayerSheet(url: item.url, caption: item.caption)
        }
        .alert("Tag", isPresented: $showTagEditor) {
            TextField("e.g. Rec Center · shooting", text: $labelDraft)
            Button("Save") {
                if let gid = editingGroupId { store.setLabel(labelDraft, forGroupId: gid) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Label this session's clips.")
        }
        .confirmationDialog("Delete \(selected.count) clip\(selected.count == 1 ? "" : "s")?",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete from app + Photos", role: .destructive) {
                store.deleteMany(selected, fromPhotos: true)
                exitSelection()
            }
            Button("Delete from app only", role: .destructive) {
                store.deleteMany(selected, fromPhotos: false)
                exitSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting from Photos will ask for permission. Clips saved before this update can only be removed from the app.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Store")
                    .font(.chalkScript(40))
                    .foregroundColor(Chalk.chalk)
                Text(store.highlights.isEmpty
                     ? "Your saved clips live here"
                     : "\(store.highlights.count) clip\(store.highlights.count == 1 ? "" : "s") · \(store.grouped.count) game\(store.grouped.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Chalk.dust)
            }
            Spacer()
            if !store.highlights.isEmpty {
                Button(selecting ? "Cancel" : "Select") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if selecting { exitSelection() } else { selecting = true }
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Chalk.yellow)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundColor(Chalk.coral.opacity(0.8))
            Text("No clips yet")
                .font(.chalkScript(28))
                .foregroundColor(Chalk.chalk)
            Text("Tap Clip during a game or practice to save the last ~30s as a highlight. Saved clips appear here, grouped by game.")
                .font(.system(size: 15))
                .foregroundColor(Chalk.dust)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .chalkCard()
    }

    // MARK: - Time section header

    private func sectionHeader(title: String, collapsed: Bool, clusters: [ClipCluster]) -> some View {
        let rec = record(clusters)
        return Button {
            guard collapsed else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                if expandedSections.contains(title) { expandedSections.remove(title) }
                else { expandedSections.insert(title) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(Chalk.chalkDim)
                if collapsed {
                    Image(systemName: isExpanded(title, collapsed: collapsed) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Chalk.dust)
                }
                Spacer()
                if rec.w + rec.l > 0 {
                    Text("\(rec.w)–\(rec.l)")
                        .font(.system(size: 13, weight: .bold)).monospacedDigit()
                        .foregroundColor(Chalk.yellow)
                } else {
                    Text("\(clusters.count) session\(clusters.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Chalk.dust)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Weekend/tournament cluster (outer box) → per-game inner boxes

    @ViewBuilder
    private func clusterCard(_ cluster: ClipCluster) -> some View {
        let expanded = expandedClusters.contains(cluster.id)
        let color = TeamPalette.color(for: cluster.team)
        let gs = games(cluster)
        let clipCount = cluster.groups.reduce(0) { $0 + $1.clips.count }
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expanded { expandedClusters.remove(cluster.id) } else { expandedClusters.insert(cluster.id) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(dateRangeText(cluster))
                                    .font(.system(size: 16, weight: .bold)).foregroundColor(Chalk.chalk)
                                teamChip(cluster.team)
                            }
                            Text("\(cluster.groups.count) games · \(clipCount) clip\(clipCount == 1 ? "" : "s")")
                                .font(.system(size: 11)).foregroundColor(Chalk.dust)
                        }
                        Spacer()
                        if !gs.isEmpty {
                            Text("\(gs.filter(\.isWin).count)–\(gs.filter(\.isLoss).count)")
                                .font(.system(size: 16, weight: .bold)).monospacedDigit().foregroundColor(Chalk.crisp)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .bold)).foregroundColor(Chalk.dust).padding(.leading, 2)
                    }
                    if !expanded, !gs.isEmpty { winLossStrip(gs) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(cluster.groups.sorted { $0.date < $1.date }) { group in
                    gameSection(group)
                }
            }
        }
        .padding(12)
        .background(Chalk.board2.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.3), lineWidth: 1.5))
    }

    private func winLossStrip(_ games: [Game]) -> some View {
        HStack(spacing: 6) {
            ForEach(games.sorted { $0.date < $1.date }) { game in
                HStack(spacing: 5) {
                    Text(game.isWin ? "W" : "L").font(.system(size: 12, weight: .heavy))
                    Text(game.scoreString).font(.system(size: 12, weight: .bold)).monospacedDigit()
                }
                .foregroundColor(Chalk.board)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(game.isWin ? Chalk.green : Chalk.coral, in: RoundedRectangle(cornerRadius: 7))
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    private func dateRangeText(_ cluster: ClipCluster) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        let s = f.string(from: cluster.startDate), e = f.string(from: cluster.endDate)
        return s == e ? s : "\(s) – \(e)"
    }

    // MARK: - Game section (inner box)

    private func gameSection(_ group: HighlightGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if selecting { toggleGroup(group) }
            } label: {
                // Same typography as the game log's GameRow: W/L circle, opponent-first
                // (system font, not chalk script), team in sky, date — so the two read alike.
                HStack(spacing: 10) {
                    if selecting {
                        Image(systemName: groupAllSelected(group) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundColor(groupAllSelected(group) ? Chalk.yellow : Chalk.dust)
                    }
                    if let g = game(for: group) {
                        let badgeColor = g.isWin ? Chalk.green : Chalk.coral
                        Text(g.resultString)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(badgeColor)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(badgeColor.opacity(0.6), lineWidth: 1.5))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.isPractice ? "Practice" : "vs \(group.awayTeam)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Chalk.chalk)
                            .lineLimit(1)
                        if !group.isPractice, !group.homeTeam.isEmpty {
                            Text(group.homeTeam)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Chalk.sky)
                        }
                        Text(Self.sessionDate(group.date))
                            .font(.system(size: 12))
                            .foregroundColor(Chalk.dust)
                    }
                    Spacer()
                    if let g = game(for: group) {
                        Text(g.scoreString)
                            .font(.system(size: 20, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(Chalk.crisp)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!selecting)

            if !selecting { tagChip(group) }

            // Full-game links (local recording + YouTube), same media the game log exposes.
            if !selecting, let g = game(for: group) {
                let local = localVideoURL(g)
                if local != nil || g.youtubeVideoId != nil {
                    HStack(spacing: 8) {
                        if let local {
                            mediaChip(icon: "play.circle.fill", label: "Full game", color: Chalk.chalk) {
                                fullGame = PlayerItem(url: local, caption: group.matchup)
                            }
                        }
                        if let vid = g.youtubeVideoId {
                            mediaChip(icon: "play.rectangle.fill", label: "YouTube", color: Chalk.coral) {
                                if let url = URL(string: "https://youtu.be/\(vid)") { UIApplication.shared.open(url) }
                            }
                        }
                        Spacer()
                    }
                }
            }

            ForEach(group.clips) { clip in
                ClipCard(clip: clip, selecting: selecting, isSelected: selected.contains(clip.id))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selecting { toggle(clip) } else { playing = clip }
                    }
                    .onLongPressGesture {
                        if !selecting {
                            withAnimation(.easeInOut(duration: 0.2)) { selecting = true }
                            selected = [clip.id]
                        }
                    }
                    .contextMenu {
                        if !selecting {
                            ShareLink(item: clip.url) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button { selecting = true; selected = [clip.id] } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            Button(role: .destructive) {
                                selected = [clip.id]
                                // Defer so the context menu dismisses before the dialog shows.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    showDeleteConfirm = true
                                }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
            }
        }
        .chalkCard()
    }

    private func mediaChip(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(color)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Chalk.board, in: Capsule())
            .overlay(Capsule().stroke(Chalk.chalk.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // Team chip — same color rules as the game log (Lava yellow, others auto-hashed).
    private func teamChip(_ name: String) -> some View {
        let color = TeamPalette.color(for: name)
        return Text(name.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .lineLimit(1)
    }

    // Editable tag chip for a session (any group — practice or game).
    private func tagChip(_ group: HighlightGroup) -> some View {
        Button {
            editingGroupId = group.id
            labelDraft = group.label ?? ""
            showTagEditor = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: (group.label?.isEmpty == false) ? "tag.fill" : "tag")
                    .font(.system(size: 11, weight: .semibold))
                Text((group.label?.isEmpty == false) ? group.label! : "Add tag")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor((group.label?.isEmpty == false) ? Chalk.yellow : Chalk.dust)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection bar

    private var selectionBar: some View {
        HStack(spacing: 16) {
            Button(selected.count == store.highlights.count ? "Deselect All" : "Select All") {
                if selected.count == store.highlights.count { selected.removeAll() }
                else { selected = Set(store.highlights.map(\.id)) }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Chalk.chalk)

            Spacer()

            Text("\(selected.count) selected")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Chalk.dust)

            Spacer()

            Button {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(selected.isEmpty ? Chalk.dust : Chalk.board)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(selected.isEmpty ? Color.clear : Chalk.coral, in: Capsule())
            }
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Chalk.board2.opacity(0.98), in: Capsule())
        .overlay(Capsule().stroke(Chalk.chalk.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Selection helpers

    private func toggle(_ clip: Highlight) {
        if selected.contains(clip.id) { selected.remove(clip.id) } else { selected.insert(clip.id) }
    }
    private func groupAllSelected(_ g: HighlightGroup) -> Bool {
        !g.clips.isEmpty && g.clips.allSatisfy { selected.contains($0.id) }
    }
    private func toggleGroup(_ g: HighlightGroup) {
        if groupAllSelected(g) { g.clips.forEach { selected.remove($0.id) } }
        else { g.clips.forEach { selected.insert($0.id) } }
    }
    private func exitSelection() {
        selecting = false
        selected.removeAll()
    }

    static func sessionDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "'Today' · h:mm a"
            : (Calendar.current.isDateInYesterday(date) ? "'Yesterday' · h:mm a" : "MMM d · h:mm a")
        return f.string(from: date)
    }
}

// MARK: - Clip card (one saved highlight)

private struct ClipCard: View {
    let clip: Highlight
    var selecting: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            if selecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? Chalk.yellow : Chalk.dust)
                    .transition(.scale.combined(with: .opacity))
            }

            ClipThumbnail(url: clip.url)
                .frame(width: 108, height: 61)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(selecting ? 0.4 : 0.9))
                        .shadow(radius: 3)
                )
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Chalk.chalk.opacity(0.18), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                if clip.isPractice {
                    Text("Practice clip")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Chalk.chalk)
                    Text(clip.createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Chalk.dust)
                } else {
                    Text(clip.scoreLine)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(Chalk.chalk)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(clip.period)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Chalk.yellow)
                        Text(clip.clockTime)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(Chalk.dust)
                    }
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(isSelected ? Chalk.yellow.opacity(0.8) : Chalk.chalk.opacity(0.10),
                    lineWidth: isSelected ? 2 : 1))
    }
}

