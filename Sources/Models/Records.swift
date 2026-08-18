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
    var instrument: String           // NQ/MNQ/ES/MES/CL/GC/MBT
    var ibHigh: Double?
    var ibLow: Double?
    var tradesTaken: Int
    var status: String               // "open" / "done"
    var createdAt: String            // ISO8601
    /// Optional label ("LEAP tournament") — named workspaces are findable
    /// and reopenable in the session browser.
    var name: String?

    init(id: String, date: String, instrument: String, ibHigh: Double?,
         ibLow: Double?, tradesTaken: Int, status: String, createdAt: String,
         name: String? = nil) {
        self.id = id
        self.date = date
        self.instrument = instrument
        self.ibHigh = ibHigh
        self.ibLow = ibLow
        self.tradesTaken = tradesTaken
        self.status = status
        self.createdAt = createdAt
        self.name = name
    }

    /// "08-06 · LEAP tournament" — browser display.
    var displayTitle: String {
        let short = String(date.dropFirst(5))
        return name.map { "\(short) · \($0)" } ?? "\(short) · \(instrument)"
    }
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
    /// Raw TradingView pane symbol this level came from (multi-pane scan,
    /// e.g. "XAUUSD", "MNQ1!"). nil = belongs to the session's own single
    /// instrument — every pre-scan row and single-symbol session unaffected.
    var instrument: String?

    init(id: String, sessionId: String, name: String, price: Double, stars: Int,
         rankScore: Int?, broken: Bool, notes: String?, instrument: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.name = name
        self.price = price
        self.stars = stars
        self.rankScore = rankScore
        self.broken = broken
        self.notes = notes
        self.instrument = instrument
    }

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
    var playType: String?            // MR/OFF (legacy rows: IB/BRT/APP)
    var levelId: String?
    var mentorReply: String?
    var mentorClaudeSessionId: String?
    /// Per-post instrument (he switches NQ/ES mid-day) — auto-detected from
    /// the TradingView screenshot filename, falls back to the session's.
    var instrument: String?
}

struct TradeRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "trades"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var entryId: String
    var playType: String             // MR/OFF (legacy rows: IB/BRT/APP)
    var levelId: String?
    var contracts: Int
    var entryPrice: Double?
    var stopPrice: Double?
    var targetPrice: Double?
    var exitPrice: Double?
    var ticksResult: Double?
    var usdResult: Double?
    var result: String?              // win/loss/scratch/open
    /// Instrument this trade was priced in — tick math uses THIS, never the
    /// session default (day-1 lesson: MNQ session, NQ fills, 10x under-report).
    var instrument: String?
    // Broker-truth fields (schema v3) — filled by the TradingView account
    // history import; nil on manual rows. usdResult is NET of commission on
    // imported rows; grossUsd keeps the pre-commission number.
    var entryTime: String?           // ISO8601
    var exitTime: String?            // ISO8601
    var side: String?                // "long" / "short"
    var commission: Double?
    var grossUsd: Double?
    var source: String?              // nil = manual, "tv_import" = broker paste
    var maeTicks: Double?
    var mfeTicks: Double?

    init(id: String, entryId: String, playType: String, levelId: String?,
         contracts: Int, entryPrice: Double?, stopPrice: Double?,
         targetPrice: Double?, exitPrice: Double?, ticksResult: Double?,
         usdResult: Double?, result: String?, instrument: String?,
         entryTime: String? = nil, exitTime: String? = nil, side: String? = nil,
         commission: Double? = nil, grossUsd: Double? = nil, source: String? = nil,
         maeTicks: Double? = nil, mfeTicks: Double? = nil) {
        self.id = id
        self.entryId = entryId
        self.playType = playType
        self.levelId = levelId
        self.contracts = contracts
        self.entryPrice = entryPrice
        self.stopPrice = stopPrice
        self.targetPrice = targetPrice
        self.exitPrice = exitPrice
        self.ticksResult = ticksResult
        self.usdResult = usdResult
        self.result = result
        self.instrument = instrument
        self.entryTime = entryTime
        self.exitTime = exitTime
        self.side = side
        self.commission = commission
        self.grossUsd = grossUsd
        self.source = source
        self.maeTicks = maeTicks
        self.mfeTicks = mfeTicks
    }
}

/// Trade row + its post timestamp and session date — the flat feed the
/// analytics engine filters and aggregates. Mirrors allTradesForAnalytics().
struct AnalyticsTradeRow: Codable, FetchableRecord {
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    var id: String
    var playType: String
    var contracts: Int
    var entryPrice: Double?
    var exitPrice: Double?
    var ticksResult: Double?
    var usdResult: Double?
    var result: String?
    var instrument: String?
    var entryTime: String?
    var exitTime: String?
    var side: String?
    var commission: Double?
    var grossUsd: Double?
    var source: String?
    var maeTicks: Double?
    var mfeTicks: Double?
    var postTs: String
    var sessionDate: String
    var sessionInstrument: String

    var resolvedInstrument: String { instrument ?? sessionInstrument }
    /// Best clock for time-of-day/weekday bucketing: broker entry time when
    /// imported, else the post's timestamp.
    var clockISO: String { entryTime ?? postTs }
}

/// One reply in a post's thread — user and mentor go back and forth like
/// comments under an X post.
struct CommentRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "comments"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var entryId: String
    var ts: String                   // ISO8601
    var author: String               // "user" | "mentor"
    var text: String
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

/// ONE edge (SKULD 3.0): session VWAP mean reversion. MR is the play;
/// OFF is the honest tag for anything taken outside it. Old DB rows may
/// still carry 'IB'/'BRT'/'APP' strings — display sites must tolerate a
/// failed `PlayType(rawValue:)` and show those as OFF.
enum PlayType: String, CaseIterable, Identifiable {
    case MR
    /// Honest tag for trades taken outside the edge — keeps the
    /// play-type win-rate table truthful instead of polluting MR's row.
    case OFF
    var id: String { rawValue }
}
