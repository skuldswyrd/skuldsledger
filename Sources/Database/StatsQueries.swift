import Foundation
import GRDB

/// Read-side aggregation: turns the day's journal rows into the live
/// `SessionStats` snapshot the sidebar renders. No writes, no caching —
/// SessionStore recomputes after every mutation.
enum StatsQueries {

    static func compute(db: AppDatabase, session: SessionRecord,
                        levels: [LevelRecord], plan: TradingPlan) throws -> SessionStats {
        let trades = try db.trades(sessionId: session.id)
        let entries = try db.entries(sessionId: session.id)
        let chops = try db.chops(sessionId: session.id)

        var stats = SessionStats()

        // Discipline counters: session row is the source of truth for trades
        // taken (bumped on recordTrade), plan for the cap.
        stats.tradesTaken = session.tradesTaken
        stats.maxTrades = plan.maxTradesPerDay

        // P&L over closed trades — open trades carry nil ticks/usd results,
        // so summing non-nil values naturally excludes them.
        for trade in trades {
            if let ticks = trade.ticksResult { stats.netTicks += ticks }
            if let usd = trade.usdResult { stats.netUsd += usd }
            switch trade.result {
            case "win": stats.wins += 1
            case "loss": stats.losses += 1
            case "scratch": stats.scratches += 1
            case "open": stats.openTrades += 1
            default: break
            }
        }

        // Star-rank hit rate: each trade joined to its level (via levelId ->
        // levels array), bucketed by the level's star band. Rendered 5 -> 1;
        // bands with zero signals are dropped.
        let levelById = Dictionary(levels.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var starBuckets: [Int: SessionStats.StarRow] = [:]
        for trade in trades {
            guard let levelId = trade.levelId, let level = levelById[levelId] else { continue }
            let stars = max(1, min(5, level.stars))
            var row = starBuckets[stars]
                ?? SessionStats.StarRow(stars: stars, signals: 0, wins: 0, losses: 0)
            row.signals += 1
            if trade.result == "win" { row.wins += 1 }
            if trade.result == "loss" { row.losses += 1 }
            starBuckets[stars] = row
        }
        stats.starRows = (1...5).reversed()
            .compactMap { starBuckets[$0] }
            .filter { $0.signals > 0 }

        // Play-type table: only plays actually present today. Canonical
        // IB/MR/BRT order first, any off-book play strings after.
        var playBuckets: [String: SessionStats.PlayRow] = [:]
        for trade in trades {
            var row = playBuckets[trade.playType]
                ?? SessionStats.PlayRow(play: trade.playType, taken: 0, wins: 0, losses: 0)
            row.taken += 1
            if trade.result == "win" { row.wins += 1 }
            if trade.result == "loss" { row.losses += 1 }
            playBuckets[trade.playType] = row
        }
        var playRows: [SessionStats.PlayRow] = PlayType.allCases
            .compactMap { playBuckets.removeValue(forKey: $0.rawValue) }
        playRows.append(contentsOf: playBuckets.values.sorted { $0.play < $1.play })
        stats.playRows = playRows

        // Entry counts per action — feeds "signals offered vs taken".
        var actionCounts: [String: Int] = [:]
        for entry in entries {
            guard let action = entry.action, !action.isEmpty else { continue }
            actionCounts[action, default: 0] += 1
        }
        stats.actionCounts = actionCounts

        stats.chopCount = chops.count
        stats.levelsHeld = levels.filter { !$0.broken }.count
        stats.levelsBroken = levels.count - stats.levelsHeld

        // Daily target reads off the milestone ladder at the RUNNING balance:
        // starting capital + lifetime net USD across ALL sessions in the DB
        // (SQLite SUM skips NULLs, so open trades don't distort it).
        let lifetimeNetUsd = try db.dbQueue.read { dbc in
            try Double.fetchOne(
                dbc, sql: "SELECT COALESCE(SUM(usd_result), 0.0) FROM trades") ?? 0
        }
        stats.dailyTargetUsd = plan
            .milestone(forBalance: plan.startingCapital + lifetimeNetUsd)?
            .dailyTargetUsd

        // nil = UNDEFINED in the plan — surfaced by the UI, never enforced here.
        stats.dailyMaxLossUsd = plan.dailyMaxLossUsd

        return stats
    }
}
