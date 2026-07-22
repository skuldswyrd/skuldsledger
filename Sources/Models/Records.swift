import Foundation
import GRDB

// GRDB records mirroring the SQLite schema (snake_case columns <-> camelCase
// properties via GRDB column strategies).

struct SessionRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var date: String                 // YYYY-MM-DD (ET)
    var instrument: String           // NQ/MNQ/ES/MES
    var ibHigh: Double?
    var ibLow: Double?
    var tradesTaken: Int
    var status: String               // "open" / "done"
    var createdAt: String            // ISO8601
}

struct LevelRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "levels"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var sessionId: String
    var name: String                 // "pdPOC", "AS VAH", "VWAP", ...
    var price: Double
    var stars: Int                   // 1-5
    var rankScore: Int?              // raw summed rank if clustered
    var broken: Bool
    var notes: String?

    /// Effective rank for the min_rank_to_trade check: raw rank if known,
    /// else the floor of the star band (5→10, 4→8, 3→6, 2→4, 1→1).
    var effectiveRank: Int {
        if let r = rankScore { return r }
        switch stars {
        case 5: return 10
        case 4: return 8
        case 3: return 6
        case 2: return 4
        default: return 1
        }
    }
}

struct EntryRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "entries"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var sessionId: String
    var ts: String                   // ISO8601
    var screenshotPath: String       // relative to workspace root; "" if none
    var comment: String?
    var lookingFor: String?
    var wantToSee: String?
    var action: String?              // wait/enter/exit/skip/chop
    var playType: String?            // IB/MR/BRT
    var levelId: String?
    var mentorReply: String?
    var mentorClaudeSessionId: String?
}

struct TradeRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "trades"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var entryId: String
    var playType: String             // IB/MR/BRT
    var levelId: String?
    var contracts: Int
    var entryPrice: Double?
    var stopPrice: Double?
    var targetPrice: Double?
    var exitPrice: Double?
    var ticksResult: Double?
    var usdResult: Double?
    var result: String?              // win/loss/scratch/open
}

struct ChopRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chops"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var sessionId: String
    var ts: String
    var rangeHigh: Double?
    var rangeLow: Double?
    var crossings: Int?
}

enum EntryAction: String, CaseIterable, Identifiable {
    case wait, enter, exit, skip, chop
    var id: String { rawValue }
}

enum PlayType: String, CaseIterable, Identifiable {
    case IB, MR, BRT, APP
    /// Honest tag for trades taken outside every defined play — keeps the
    /// play-type win-rate table truthful instead of polluting MR's row.
    case OFF
    var id: String { rawValue }
}
