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
    let homeTeam: String
    let awayTeam: String
    let homeScore: Int
    let awayScore: Int
    let period: String
    let clockTime: String

    var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Highlights", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    var scoreLine: String { "\(homeTeam) \(homeScore) – \(awayScore) \(awayTeam)" }
}

@MainActor
final class HighlightStore: ObservableObject {
    static let shared = HighlightStore()

    @Published private(set) var highlights: [Highlight] = []

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
    nonisolated func add(fileURL: URL, homeTeam: String, awayTeam: String,
                         homeScore: Int, awayScore: Int, period: String, clockTime: String) {
        let h = Highlight(id: UUID(), fileName: fileURL.lastPathComponent, createdAt: Date(),
                          homeTeam: homeTeam, awayTeam: awayTeam,
                          homeScore: homeScore, awayScore: awayScore,
                          period: period, clockTime: clockTime)
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
