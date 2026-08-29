//
//  FirebaseGame.swift
//  SahilStatsLite
//
//  PURPOSE: Firestore document mapping and serialization. Converts between the
//           local Game model and Firebase's document schema (matching main app).
//           Handles complex date decoding and field name mapping.
//  KEY TYPES: FirebaseGame (Codable)
//  DEPENDS ON: Game.swift, FirebaseFirestore
//
//  NOTE: Keep this header updated when modifying this file.
//

import Foundation
import FirebaseFirestore

/// Represents a game document in Firebase (matching main app's schema)
struct FirebaseGame: Codable {
    // MARK: - Firebase Document ID
    @DocumentID var id: String?

    // MARK: - Game Info (matching main app field names)
    var teamName: String
    var opponent: String
    var location: String?
    var season: String?

    // Scores (main app uses myTeamScore, Lite uses myScore)
    var myTeamScore: Int
    var opponentScore: Int
    var outcome: String // "W", "L", or "T"

    // Game format (optional for backwards compatibility with older games)
    var gameFormat: String // "halves" or "quarters"
    var quarterLength: Int
    var numQuarter: Int
    var status: String // "final"

    // MARK: - YouTube
    var youtubeStatus: String?
    var youtubeVideoId: String?

    // MARK: - Player Stats (main app uses short field names)
    var points: Int
    var fg2m: Int
    var fg2a: Int
    var fg3m: Int
    var fg3a: Int
    var ftm: Int
    var fta: Int
    var rebounds: Int
    var assists: Int
    var steals: Int
    var blocks: Int
    var fouls: Int
    var turnovers: Int

    // MARK: - Timestamps
    @ServerTimestamp var timestamp: Date?
    @ServerTimestamp var createdAt: Date?

    // MARK: - Custom Decoding (handles missing fields in older games)

    enum CodingKeys: String, CodingKey {
        case id, teamName, opponent, location, season
        case myTeamScore, opponentScore, outcome
        case gameFormat, quarterLength, numQuarter, status
        case youtubeStatus, youtubeVideoId
        case points, fg2m, fg2a, fg3m, fg3a, ftm, fta
        case rebounds, assists, steals, blocks, fouls, turnovers
        case timestamp, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required fields
        id = try container.decodeIfPresent(String.self, forKey: .id)
        teamName = try container.decodeIfPresent(String.self, forKey: .teamName) ?? "Unknown"
        opponent = try container.decodeIfPresent(String.self, forKey: .opponent) ?? "Unknown"
        location = try container.decodeIfPresent(String.self, forKey: .location)
        season = try container.decodeIfPresent(String.self, forKey: .season)

        // Scores
        myTeamScore = try container.decodeIfPresent(Int.self, forKey: .myTeamScore) ?? 0
        opponentScore = try container.decodeIfPresent(Int.self, forKey: .opponentScore) ?? 0

        // Outcome - compute from scores if missing
        if let storedOutcome = try container.decodeIfPresent(String.self, forKey: .outcome) {
            outcome = storedOutcome
        } else {
            if myTeamScore > opponentScore {
                outcome = "W"
            } else if myTeamScore < opponentScore {
                outcome = "L"
            } else {
                outcome = "T"
            }
        }

        // Game format - defaults for missing fields
        gameFormat = try container.decodeIfPresent(String.self, forKey: .gameFormat) ?? "halves"
        quarterLength = try container.decodeIfPresent(Int.self, forKey: .quarterLength) ?? 18
        numQuarter = try container.decodeIfPresent(Int.self, forKey: .numQuarter) ?? 2
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "final"

        // YouTube
        youtubeStatus = try container.decodeIfPresent(String.self, forKey: .youtubeStatus)
        youtubeVideoId = try container.decodeIfPresent(String.self, forKey: .youtubeVideoId)

        // Player stats - default to 0 if missing
        points = try container.decodeIfPresent(Int.self, forKey: .points) ?? 0
        fg2m = try container.decodeIfPresent(Int.self, forKey: .fg2m) ?? 0
        fg2a = try container.decodeIfPresent(Int.self, forKey: .fg2a) ?? 0
        fg3m = try container.decodeIfPresent(Int.self, forKey: .fg3m) ?? 0
        fg3a = try container.decodeIfPresent(Int.self, forKey: .fg3a) ?? 0
        ftm = try container.decodeIfPresent(Int.self, forKey: .ftm) ?? 0
        fta = try container.decodeIfPresent(Int.self, forKey: .fta) ?? 0
        rebounds = try container.decodeIfPresent(Int.self, forKey: .rebounds) ?? 0
        assists = try container.decodeIfPresent(Int.self, forKey: .assists) ?? 0
        steals = try container.decodeIfPresent(Int.self, forKey: .steals) ?? 0
        blocks = try container.decodeIfPresent(Int.self, forKey: .blocks) ?? 0
        fouls = try container.decodeIfPresent(Int.self, forKey: .fouls) ?? 0
        turnovers = try container.decodeIfPresent(Int.self, forKey: .turnovers) ?? 0

        // Timestamps - handle both Firestore Timestamp and Date formats
        timestamp = Self.decodeTimestamp(from: container, forKey: .timestamp)
        createdAt = Self.decodeTimestamp(from: container, forKey: .createdAt)
    }

    /// Decode a timestamp field that might be a Firestore Timestamp, Date, ISO8601 string, or missing
    private static func decodeTimestamp(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Date? {
        // Try decoding as Firestore Timestamp first (has _seconds and _nanoseconds)
        if let firestoreTimestamp = try? container.decode(Timestamp.self, forKey: key) {
            return firestoreTimestamp.dateValue()
        }

        // Try decoding as regular Date
        if let date = try? container.decode(Date.self, forKey: key) {
            return date
        }

        // Try decoding as Double (seconds since epoch)
        if let seconds = try? container.decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }

        // Try decoding as ISO8601 string (various formats)
        if let timestampString = try? container.decode(String.self, forKey: key) {
            // ISO8601 with fractional seconds
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsedDate = iso8601Formatter.date(from: timestampString) {
                return parsedDate
            }

            // ISO8601 without fractional seconds
            let iso8601FormatterNoFraction = ISO8601DateFormatter()
            iso8601FormatterNoFraction.formatOptions = [.withInternetDateTime]
            if let parsedDate = iso8601FormatterNoFraction.date(from: timestampString) {
                return parsedDate
            }

            // Custom date format fallbacks
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")

            // Try "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            if let parsedDate = dateFormatter.date(from: timestampString) {
                return parsedDate
            }

            // Try "yyyy-MM-dd'T'HH:mm:ssZ"
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            if let parsedDate = dateFormatter.date(from: timestampString) {
                return parsedDate
            }

            // Try simple date format "yyyy-MM-dd"
            dateFormatter.dateFormat = "yyyy-MM-dd"
            if let parsedDate = dateFormatter.date(from: timestampString) {
                return parsedDate
            }
        }

        return nil
    }

    // MARK: - Conversion from Lite Game

    init(from game: Game) {
        self.id = game.id
        self.teamName = game.teamName
        self.opponent = game.opponent
        self.location = game.location
        self.season = nil // Lite doesn't track seasons

        // Map scores (Lite uses myScore, Firebase uses myTeamScore)
        self.myTeamScore = game.myScore
        self.opponentScore = game.opponentScore

        // Determine outcome
        if game.myScore > game.opponentScore {
            self.outcome = "W"
        } else if game.myScore < game.opponentScore {
            self.outcome = "L"
        } else {
            self.outcome = "T"
        }

        // Game format — halves or quarters, with the per-period length and count.
        self.gameFormat = game.gameFormat.rawValue
        self.quarterLength = game.halfLength
        self.numQuarter = game.totalHalves
        self.status = "final"

        // YouTube
        self.youtubeStatus = game.youtubeStatus.rawValue
        self.youtubeVideoId = game.youtubeVideoId

        // Map player stats (Lite uses long names, Firebase uses short)
        let stats = game.playerStats
        self.points = stats.points
        self.fg2m = stats.fg2Made
        self.fg2a = stats.fg2Attempted
        self.fg3m = stats.fg3Made
        self.fg3a = stats.fg3Attempted
        self.ftm = stats.ftMade
        self.fta = stats.ftAttempted
        self.rebounds = stats.rebounds
        self.assists = stats.assists
        self.steals = stats.steals
        self.blocks = stats.blocks
        self.fouls = stats.fouls
        self.turnovers = stats.turnovers

        // Timestamps
        self.timestamp = game.date
        self.createdAt = game.createdAt
    }

    // MARK: - Conversion to Lite Game

    func toGame() -> Game {
        var game = Game(
            id: id ?? UUID().uuidString,
            opponent: opponent,
            teamName: teamName,
            location: location,
            date: timestamp ?? Date(),
            myScore: myTeamScore,
            opponentScore: opponentScore,
            halfLength: quarterLength,
            currentHalf: numQuarter,
            totalHalves: numQuarter,
            playerStats: PlayerStats(
                fg2Made: fg2m,
                fg2Attempted: fg2a,
                fg3Made: fg3m,
                fg3Attempted: fg3a,
                ftMade: ftm,
                ftAttempted: fta,
                assists: assists,
                rebounds: rebounds,
                steals: steals,
                blocks: blocks,
                turnovers: turnovers,
                fouls: fouls
            ),
            createdAt: createdAt ?? Date(),
            youtubeStatus: YouTubeStatus(rawValue: youtubeStatus ?? "local") ?? .local,
            youtubeVideoId: youtubeVideoId
        )
        game.format = (gameFormat == "quarters") ? .quarters : .halves
        return game
    }

    // MARK: - Convert to Firestore Data (for writes)

    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "teamName": teamName,
            "opponent": opponent,
            "myTeamScore": myTeamScore,
            "opponentScore": opponentScore,
            "outcome": outcome,
            "gameFormat": gameFormat,
            "quarterLength": quarterLength,
            "numQuarter": numQuarter,
            "status": status,
            "youtubeStatus": youtubeStatus ?? "local",
            "youtubeVideoId": youtubeVideoId as Any,
            "points": points,
            "fg2m": fg2m,
            "fg2a": fg2a,
            "fg3m": fg3m,
            "fg3a": fg3a,
            "ftm": ftm,
            "fta": fta,
            "rebounds": rebounds,
            "assists": assists,
            "steals": steals,
            "blocks": blocks,
            "fouls": fouls,
            "turnovers": turnovers,
            "achievements": [] // Empty array for Lite games
        ]

        if let location = location, !location.isEmpty {
            data["location"] = location
        }

        if let season = season {
            data["season"] = season
        }

        // Handle timestamps
        if let timestamp = timestamp {
            data["timestamp"] = Timestamp(date: timestamp)
        } else {
            data["timestamp"] = FieldValue.serverTimestamp()
        }

        if let createdAt = createdAt {
            data["createdAt"] = Timestamp(date: createdAt)
        } else {
            data["createdAt"] = FieldValue.serverTimestamp()
        }

        return data
    }
}
