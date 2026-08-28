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
import Photos

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
    var photoAssetId: String? = nil   // PHAsset localIdentifier, so delete can also clear Photos
    var label: String? = nil          // freeform tag (e.g. practice location / drill)

    var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Highlights", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    var scoreLine: String { "\(homeTeam) \(homeScore) – \(awayScore) \(awayTeam)" }
}

// Tolerant decoding so adding a field never wipes previously-saved clips. Swift's
// synthesized Codable throws keyNotFound for a missing NON-optional key (it ignores
// the property's default) — which would fail the whole array decode and empty the
// Store. Fields added after v1 (gameId, isPractice) are decoded with decodeIfPresent.
extension Highlight {
    private enum CodingKeys: String, CodingKey {
        case id, fileName, createdAt, gameId, homeTeam, awayTeam, homeScore, awayScore, period, clockTime, isPractice, photoAssetId, label
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        gameId = try c.decodeIfPresent(String.self, forKey: .gameId)
        homeTeam = try c.decode(String.self, forKey: .homeTeam)
        awayTeam = try c.decode(String.self, forKey: .awayTeam)
        homeScore = try c.decode(Int.self, forKey: .homeScore)
        awayScore = try c.decode(Int.self, forKey: .awayScore)
        period = try c.decode(String.self, forKey: .period)
        clockTime = try c.decode(String.self, forKey: .clockTime)
        isPractice = try c.decodeIfPresent(Bool.self, forKey: .isPractice) ?? false
        photoAssetId = try c.decodeIfPresent(String.self, forKey: .photoAssetId)
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }
}

/// One game session's worth of clips, for the Store's grouped layout.
struct HighlightGroup: Identifiable, Sendable {
    let id: String            // gameId, or the clip's own id when a game was never stamped
    let homeTeam: String      // Sahil's team
    let awayTeam: String      // opponent
    let date: Date            // earliest clip in the session
    let isPractice: Bool
    let label: String?        // freeform session tag (practice location / drill)
    let clips: [Highlight]    // newest first

    var matchup: String {
        if isPractice { return label?.isEmpty == false ? "Practice · \(label!)" : "Practice" }
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
                label: sorted.compactMap { $0.label }.first,
                clips: sorted
            )
        }
        .sorted { $0.date > $1.date }
    }

    private let key = "savedHighlights"

    private static var highlightsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Highlights", isDirectory: true)
    }

    private init() { load() }

    private func load() {
        var loaded: [Highlight] = []
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Highlight].self, from: data) {
            loaded = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }

        // Recover orphans: clip files on disk with no metadata (e.g. lost to the old
        // Codable-wipe bug). Re-adopt them so no highlight silently disappears.
        let known = Set(loaded.map { $0.fileName })
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: Self.highlightsDir,
                                                   includingPropertiesForKeys: [.creationDateKey]) {
            for file in files where file.pathExtension.lowercased() == "mov" && !known.contains(file.lastPathComponent) {
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                loaded.append(Highlight(
                    id: UUID(), fileName: file.lastPathComponent, createdAt: created,
                    gameId: nil, homeTeam: "Clip", awayTeam: "",
                    homeScore: 0, awayScore: 0, period: "", clockTime: "", isPractice: false
                ))
            }
        }

        highlights = loaded.sorted { $0.createdAt > $1.createdAt }
        persist()  // fold any recovered orphans back into the metadata store
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(highlights) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Thread-safe entry point — hops to main to mutate published state. Returns the
    /// id it will use so the caller can attach a Photos asset id once that save finishes.
    @discardableResult
    nonisolated func add(id: UUID = UUID(), fileURL: URL, gameId: String?,
                         homeTeam: String, awayTeam: String,
                         homeScore: Int, awayScore: Int, period: String, clockTime: String,
                         isPractice: Bool = false, label: String? = nil) -> UUID {
        let h = Highlight(id: id, fileName: fileURL.lastPathComponent, createdAt: Date(),
                          gameId: gameId, homeTeam: homeTeam, awayTeam: awayTeam,
                          homeScore: homeScore, awayScore: awayScore,
                          period: period, clockTime: clockTime, isPractice: isPractice,
                          label: label)
        Task { @MainActor in
            self.highlights.insert(h, at: 0)
            self.persist()
        }
        return id
    }

    /// Record the Photos localIdentifier for a clip so a later delete can also clear Photos.
    nonisolated func setPhotoAsset(id: UUID, assetId: String) {
        Task { @MainActor in
            guard let idx = self.highlights.firstIndex(where: { $0.id == id }) else { return }
            self.highlights[idx].photoAssetId = assetId
            self.persist()
        }
    }

    /// All clips for a game session (newest first) — used by the Game Log detail.
    func clips(forGameId gameId: String?) -> [Highlight] {
        guard let gameId else { return [] }
        return highlights.filter { $0.gameId == gameId }.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ highlight: Highlight, fromPhotos: Bool = false) {
        deleteMany([highlight.id], fromPhotos: fromPhotos)
    }

    /// Delete a set of clips: remove local files + metadata, and (optionally) the
    /// tracked Photos copies. Clips saved before asset-id tracking simply skip Photos.
    func deleteMany(_ ids: Set<UUID>, fromPhotos: Bool) {
        let targets = highlights.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }

        for h in targets { try? FileManager.default.removeItem(at: h.url) }

        if fromPhotos {
            let assetIds = targets.compactMap { $0.photoAssetId }
            if !assetIds.isEmpty {
                deleteFromPhotos(assetIds)
            } else {
                debugPrint("🗑️ No Photos asset ids on the selected clips — nothing to delete from Photos (saved before asset tracking).")
            }
        }

        highlights.removeAll { ids.contains($0.id) }
        persist()
    }

    /// Delete tracked Photos copies. Requires **read-write** authorization: clips are saved
    /// with `.addOnly` access, which can add but can neither read nor delete — so without
    /// this upgrade the fetch returns empty and the video is left behind in Photos.
    private func deleteFromPhotos(_ assetIds: [String]) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                debugPrint("🗑️ Photos delete skipped — read-write access not granted (status \(status.rawValue)). Clip removed from app only.")
                return
            }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
            guard assets.count > 0 else {
                debugPrint("🗑️ Photos delete: none of \(assetIds.count) asset id(s) resolved (already removed, or not visible under limited access).")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, error in
                if let error = error {
                    debugPrint("❌ Photos delete failed: \(error)")
                } else {
                    debugPrint("🗑️ Photos delete \(success ? "succeeded" : "was cancelled") for \(assets.count) asset(s).")
                }
            }
        }
    }
}
