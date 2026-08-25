//
//  HighlightStore.swift
//  SahilStatsLite
//
//  PURPOSE: Lightweight persistence for saved Clips ("Highlights"). Clip files
//           live in Documents/Highlights; this stores their metadata (score at
//           the moment, teams, timestamp) as a UserDefaults JSON list so a
//           Highlights UI can list/play/share them. Clips are also saved to
//           Photos by RecordingManager for durable, shareable backup.
//  KEY TYPES: Highlight, HighlightStore (@MainActor ObservableObject singleton)
//
//  NOTE: Keep this header updated when modifying this file.
//

import Foundation
import Combine

struct Highlight: Codable, Identifiable, Sendable {
    let id: UUID
    let fileName: String          // relative to Documents/Highlights
    let createdAt: Date
    var gameId: String?           // grouping key: clips from one game session cluster together
    let homeTeam: String          // Sahil's team
    let awayTeam: String          // opponent
    let homeScore: Int
    let awayScore: Int
    let period: String
    let clockTime: String
    var isPractice: Bool = false

    var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Highlights", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    var scoreLine: String { "\(homeTeam) \(homeScore) – \(awayScore) \(awayTeam)" }
}

/// One game session's worth of clips, for the Store's grouped layout.
struct HighlightGroup: Identifiable, Sendable {
    let id: String            // gameId, or the clip's own id when a game was never stamped
    let homeTeam: String      // Sahil's team
    let awayTeam: String      // opponent
    let date: Date            // earliest clip in the session
    let isPractice: Bool
    let clips: [Highlight]    // newest first

    var matchup: String {
        if isPractice { return "Practice" }
        return awayTeam.isEmpty ? homeTeam : "\(homeTeam) vs \(awayTeam)"
    }
}

@MainActor
final class HighlightStore: ObservableObject {
    static let shared = HighlightStore()

    @Published private(set) var highlights: [Highlight] = []

    /// Clips grouped by game session (newest session first), for the Store.
    var grouped: [HighlightGroup] {
        let byGame = Dictionary(grouping: highlights) { $0.gameId ?? $0.id.uuidString }
        return byGame.map { key, clips in
            let sorted = clips.sorted { $0.createdAt > $1.createdAt }
            let anchor = sorted[0]
            return HighlightGroup(
                id: key,
                homeTeam: anchor.homeTeam, awayTeam: anchor.awayTeam,
                date: clips.map(\.createdAt).min() ?? anchor.createdAt,
                isPractice: anchor.isPractice,
                clips: sorted
            )
        }
        .sorted { $0.date > $1.date }
    }

    private let key = "savedHighlights"

    private init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Highlight].self, from: data) else { return }
        // Newest first; drop entries whose files are gone.
        highlights = decoded
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(highlights) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Thread-safe entry point — hops to main to mutate published state.
    nonisolated func add(fileURL: URL, gameId: String?, homeTeam: String, awayTeam: String,
                         homeScore: Int, awayScore: Int, period: String, clockTime: String,
                         isPractice: Bool = false) {
        let h = Highlight(id: UUID(), fileName: fileURL.lastPathComponent, createdAt: Date(),
                          gameId: gameId, homeTeam: homeTeam, awayTeam: awayTeam,
                          homeScore: homeScore, awayScore: awayScore,
                          period: period, clockTime: clockTime, isPractice: isPractice)
        Task { @MainActor in
            self.highlights.insert(h, at: 0)
            self.persist()
        }
    }

    func delete(_ highlight: Highlight) {
        try? FileManager.default.removeItem(at: highlight.url)
        highlights.removeAll { $0.id == highlight.id }
        persist()
    }
}
