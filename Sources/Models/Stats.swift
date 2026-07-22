import Foundation

/// Live "poker stats" for the sidebar — recomputed on every entry/trade write.
/// StatsQueries.compute() fills this from SQL over the journal tables.
struct SessionStats: Equatable {
    struct StarRow: Equatable, Identifiable {
        var stars: Int              // 1-5
        var signals: Int            // trades tagged to levels of this star band
        var wins: Int
        var losses: Int
        var id: Int { stars }
        var hitRate: Double? { (wins + losses) > 0 ? Double(wins) / Double(wins + losses) : nil }
    }

    struct PlayRow: Equatable, Identifiable {
        var play: String            // IB/MR/BRT
        var taken: Int
        var wins: Int
        var losses: Int
        var id: String { play }
        var winRate: Double? { (wins + losses) > 0 ? Double(wins) / Double(wins + losses) : nil }
    }

    var tradesTaken: Int = 0
    var maxTrades: Int = 3

    var netTicks: Double = 0
    var netUsd: Double = 0
    var wins: Int = 0
    var losses: Int = 0
    var scratches: Int = 0
    var openTrades: Int = 0

    var starRows: [StarRow] = []
    var playRows: [PlayRow] = []

    /// Entries by action — "signals offered vs taken" reads from wait/skip vs enter.
    var actionCounts: [String: Int] = [:]
    var chopCount: Int = 0

    var levelsHeld: Int = 0
    var levelsBroken: Int = 0

    var dailyTargetUsd: Double?     // from milestone row for current balance
    var dailyMaxLossUsd: Double?    // nil = UNDEFINED in plan (surface, don't enforce)

    var signalsOffered: Int {
        (actionCounts["enter"] ?? 0) + (actionCounts["skip"] ?? 0)
    }
    var signalsTaken: Int { actionCounts["enter"] ?? 0 }

    static let empty = SessionStats()
}
