//
//  Game.swift
//  SahilStatsLite
//
//  PURPOSE: Core data models for games, scores, and player stats.
//           Game struct holds all state for a single basketball game.
//           PlayerStats tracks Sahil's individual performance.
//  KEY TYPES: Game, PlayerStats, ScoreEvent, RecordingState
//  DEPENDS ON: None (foundation models)
//
//  NOTE: Keep this header updated when modifying this file.
//

import Foundation
import SwiftUI

// MARK: - Game Format

/// Halves (2 periods) or quarters (4 periods). AAU is usually halves; some leagues use quarters.
enum GameFormat: String, Codable, CaseIterable, Sendable {
    case halves
    case quarters

    var periodCount: Int { self == .quarters ? 4 : 2 }
    var noun: String { self == .quarters ? "Quarter" : "Half" }
    var regularPeriods: [String] {
        self == .quarters ? ["1st Q", "2nd Q", "3rd Q", "4th Q"] : ["1st Half", "2nd Half"]
    }
    /// Full period sequence for indexing (regulation + a few overtimes).
    var allPeriods: [String] { regularPeriods + ["OT", "OT2", "OT3"] }
}

// MARK: - Game Model

struct Game: Identifiable, Codable {
    var id: String
    var opponent: String
    var teamName: String
    var location: String?
    var date: Date

    // Season aggregation dimensions (Optional → safe to decode older saved games).
    // teamName already carries which team he played for (incl. one-off guest teams).
    var ageLevel: String?   // e.g. "3rd grade", "U10"; nil = unset/current default

    /// Season bucket derived from the game date. AAU: Fall = Aug–Nov, Winter = Dec–Feb
    /// (labeled by the year it began), Spring = Mar–May, Summer = Jun–Jul. Tunable.
    var season: String { Self.seasonLabel(for: date) }

    static func seasonLabel(for date: Date) -> String {
        let cal = Calendar.current
        let m = cal.component(.month, from: date)
        let y = cal.component(.year, from: date)
        switch m {
        case 8...11: return "Fall \(y)"
        case 12:     return "Winter \(y)"       // Dec belongs to the winter that just began
        case 1, 2:   return "Winter \(y - 1)"   // Jan–Feb belong to the prior year's winter
        case 3...5:  return "Spring \(y)"
        default:     return "Summer \(y)"        // Jun–Jul
        }
    }

    // Scores
    var myScore: Int = 0
    var opponentScore: Int = 0

    // Game structure — halves (2) or quarters (4). halfLength is the per-period minutes.
    var halfLength: Int = 18 // minutes per period
    var currentHalf: Int = 1
    var totalHalves: Int = 2
    // Optional so older saved games (no key) still decode; nil means halves.
    var format: GameFormat? = nil

    /// Resolved format (defaults to halves for legacy games).
    var gameFormat: GameFormat { format ?? .halves }
    /// Regulation period names for this game, e.g. ["1st Half","2nd Half"] or the four quarters.
    var regularPeriods: [String] { gameFormat.regularPeriods }
    /// "Half" or "Quarter".
    var periodNoun: String { gameFormat.noun }

    // Legacy support (for compatibility)
    var quarterLength: Int { halfLength }
    var currentQuarter: Int {
        get { currentHalf }
        set { currentHalf = newValue }
    }

    // Video
    var videoURL: URL?
    var videoDuration: TimeInterval?

    // Score timeline for overlay
    var scoreEvents: [ScoreEvent] = []

    // Player stats (Sahil)
    var playerStats: PlayerStats = PlayerStats()

    // Timestamps
    var createdAt: Date = Date()
    var completedAt: Date?
    
    // Cloud Status
    var youtubeStatus: YouTubeStatus = .local
    var youtubeVideoId: String?

    // Stream recording ID (same as broadcastId on YouTube; used to delete the
    // inferior 1080p stream copy after the 4K upload succeeds)
    var broadcastVideoId: String?

    init(opponent: String, teamName: String = "Wildcats", location: String? = nil) {
        self.id = UUID().uuidString
        self.opponent = opponent
        self.teamName = teamName
        self.location = location
        self.date = Date()
    }

    /// Full initializer for Firebase sync
    init(id: String, opponent: String, teamName: String, location: String?, date: Date,
         myScore: Int, opponentScore: Int, halfLength: Int, currentHalf: Int, totalHalves: Int,
         playerStats: PlayerStats, createdAt: Date, youtubeStatus: YouTubeStatus = .local, youtubeVideoId: String? = nil) {
        self.id = id
        self.opponent = opponent
        self.teamName = teamName
        self.location = location
        self.date = date
        self.myScore = myScore
        self.opponentScore = opponentScore
        self.halfLength = halfLength
        self.currentHalf = currentHalf
        self.totalHalves = totalHalves
        self.playerStats = playerStats
        self.createdAt = createdAt
        self.youtubeStatus = youtubeStatus
        self.youtubeVideoId = youtubeVideoId
    }

    // MARK: - Computed Properties

    var isWin: Bool {
        myScore > opponentScore
    }

    var isLoss: Bool {
        opponentScore > myScore
    }

    var isTie: Bool {
        myScore == opponentScore
    }

    var resultString: String {
        if isWin { return "W" }
        if isLoss { return "L" }
        return "T"
    }

    var scoreString: String {
        "\(myScore) - \(opponentScore)"
    }

    var displayTitle: String {
        "vs \(opponent)"
    }
}

// MARK: - YouTube Status

enum YouTubeStatus: String, Codable, Equatable {
    case local      // On device only
    case uploading  // Currently uploading
    case uploaded   // Success
    case failed     // Upload failed
}

// MARK: - Player Stats (Sahil)

struct PlayerStats: Codable, Equatable {
    // Shooting stats
    var fg2Made: Int = 0
    var fg2Attempted: Int = 0
    var fg3Made: Int = 0
    var fg3Attempted: Int = 0
    var ftMade: Int = 0
    var ftAttempted: Int = 0

    // Other stats
    var assists: Int = 0
    var rebounds: Int = 0
    var steals: Int = 0
    var blocks: Int = 0
    var turnovers: Int = 0
    var fouls: Int = 0

    // MARK: - Computed Properties

    var points: Int {
        (fg2Made * 2) + (fg3Made * 3) + ftMade
    }

    var totalFGMade: Int { fg2Made + fg3Made }
    var totalFGAttempted: Int { fg2Attempted + fg3Attempted }

    var fgPercentage: Double {
        totalFGAttempted > 0 ? Double(totalFGMade) / Double(totalFGAttempted) * 100 : 0
    }

    var fg2Percentage: Double {
        fg2Attempted > 0 ? Double(fg2Made) / Double(fg2Attempted) * 100 : 0
    }

    var fg3Percentage: Double {
        fg3Attempted > 0 ? Double(fg3Made) / Double(fg3Attempted) * 100 : 0
    }

    var ftPercentage: Double {
        ftAttempted > 0 ? Double(ftMade) / Double(ftAttempted) * 100 : 0
    }

    // Advanced stats
    var efgPercentage: Double {
        // eFG% = (FGM + 0.5 * 3PM) / FGA
        totalFGAttempted > 0 ? (Double(totalFGMade) + 0.5 * Double(fg3Made)) / Double(totalFGAttempted) * 100 : 0
    }

    var tsPercentage: Double {
        // TS% = PTS / (2 * (FGA + 0.44 * FTA))
        let denominator = 2 * (Double(totalFGAttempted) + 0.44 * Double(ftAttempted))
        return denominator > 0 ? Double(points) / denominator * 100 : 0
    }
}

// MARK: - Score Event

struct ScoreEvent: Identifiable, Codable {
    let id: String
    let timestamp: TimeInterval // seconds from recording start
    let team: Team
    let points: Int
    let quarter: Int
    let myScoreAfter: Int
    let opponentScoreAfter: Int

    init(timestamp: TimeInterval, team: Team, points: Int, quarter: Int, myScoreAfter: Int, opponentScoreAfter: Int) {
        self.id = UUID().uuidString
        self.timestamp = timestamp
        self.team = team
        self.points = points
        self.quarter = quarter
        self.myScoreAfter = myScoreAfter
        self.opponentScoreAfter = opponentScoreAfter
    }

    enum Team: String, Codable {
        case my
        case opponent
    }
}

// MARK: - Quarter

struct Quarter: Identifiable {
    let id: Int
    let number: Int
    var startTime: TimeInterval?
    var endTime: TimeInterval?

    var displayName: String {
        "Q\(number)"
    }
}

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case recording
    case paused
    case stopped
}

// MARK: - Clock State

enum ClockState: Equatable {
    case stopped
    case running
    case paused
}
