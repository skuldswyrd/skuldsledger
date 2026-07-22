import Foundation

/// Instruments the journal knows. Tick size/value are exchange constants
/// (not plan values), safe to hardcode.
enum Instrument: String, CaseIterable, Identifiable {
    case NQ, MNQ, ES, MES
    var id: String { rawValue }

    var tickSize: Double { 0.25 }
    var tickValue: Double {
        switch self {
        case .NQ: return 5.0
        case .MNQ: return 0.5
        case .ES: return 12.5
        case .MES: return 1.25
        }
    }
    var autoTuneKey: String {
        switch self {
        case .NQ, .MNQ: return "NQ_MNQ"
        case .ES, .MES: return "ES_MES"
        }
    }

    /// TradingView saves grabs as "MNQ1!_2026-07-22_12-40-23_5a21c.png" —
    /// symbol root leads the filename. Longest roots first (MNQ before NQ).
    static func detect(fromFilename name: String) -> Instrument? {
        let upper = name.uppercased()
        for inst in [Instrument.MNQ, .MES, .NQ, .ES] where upper.hasPrefix(inst.rawValue) {
            return inst
        }
        return nil
    }
}

/// Per-user knobs, stored beside the data at Records/user_settings.json.
/// Overlays the plan JSON (doctrine stays hand-edited; knobs live here).
struct UserSettings: Codable, Equatable {
    var paceBaselinePerDay: Int?     // trades/day pace — a baseline, NEVER a cap
    var dailyTargetUsd: Double?      // overrides the milestone-derived target
    var dailyMaxLossUsd: Double?     // defines the plan's UNDEFINED — display + banner only
    var minRankToTrade: Int?
    var defaultInstrument: String?

    static var url: URL {
        Workspace.recordsDir.appendingPathComponent("user_settings.json")
    }

    static func load() -> UserSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(UserSettings.self, from: data) else {
            return UserSettings()
        }
        return s
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? FileManager.default.createDirectory(
                at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}

/// Live-parsed view of skuld_trading_operation.json. Parsed leniently with
/// JSONSerialization: plan edits must propagate without recompiling, and a
/// malformed field degrades to a default + warning instead of a crash.
struct TradingPlan {
    struct AutoTune {
        var targetTicks: Int
        var stopTicks: Int
        var targetPoints: Double
        var stopPoints: Double
    }

    struct Milestone: Identifiable {
        var id: Int { Int(accountBalance) }
        var accountBalance: Double
        var contracts: String
        var usdPerPoint: Double
        var winAtTargetUsd: Double
        var lossAtStopUsd: Double
        var dailyTargetUsd: Double
    }

    var version: String = "?"
    var maxTradesPerDay: Int = 3
    var minRankToTrade: Int = 6
    /// Lunch blackout window, minutes past midnight ET. Banner only, never a hard block.
    var lunchStartMin: Int = 11 * 60 + 30
    var lunchEndMin: Int = 13 * 60 + 30
    /// nil = UNDEFINED in the plan (open_items #3). Surface, never invent.
    var dailyMaxLossUsd: Double?
    var startingCapital: Double = 1000
    var autoTune: [String: AutoTune] = [:]
    var milestones: [Milestone] = []
    var warnings: [String] = []
    /// Settings-layer override for the daily target (else milestone-derived).
    var dailyTargetOverrideUsd: Double?

    /// User settings overlay the plan — pace/max-loss/min-rank knobs win.
    func applying(_ s: UserSettings) -> TradingPlan {
        var plan = self
        if let pace = s.paceBaselinePerDay { plan.maxTradesPerDay = pace }
        if let maxLoss = s.dailyMaxLossUsd { plan.dailyMaxLossUsd = maxLoss }
        if let rank = s.minRankToTrade { plan.minRankToTrade = rank }
        plan.dailyTargetOverrideUsd = s.dailyTargetUsd
        return plan
    }

    func tune(for instrument: Instrument) -> AutoTune {
        autoTune[instrument.autoTuneKey]
            ?? AutoTune(targetTicks: 32, stopTicks: 48, targetPoints: 8, stopPoints: 12)
    }

    /// Milestone row for a given account balance (highest row at or below balance).
    func milestone(forBalance balance: Double) -> Milestone? {
        milestones
            .filter { $0.accountBalance <= balance }
            .max(by: { $0.accountBalance < $1.accountBalance })
            ?? milestones.first
    }

    static func load(from url: URL) -> TradingPlan {
        var plan = TradingPlan()
        guard let data = try? Data(contentsOf: url) else {
            plan.warnings.append("Plan JSON not found at \(url.path) — using defaults.")
            return plan
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            plan.warnings.append("Plan JSON unreadable — using defaults.")
            return plan
        }

        plan.version = obj["version"] as? String ?? "?"

        if let instruments = obj["instruments"] as? [String: Any],
           let tunes = instruments["auto_tune"] as? [String: Any] {
            for (key, raw) in tunes {
                guard let t = raw as? [String: Any] else { continue }
                plan.autoTune[key] = AutoTune(
                    targetTicks: intVal(t["target_ticks"]) ?? 32,
                    stopTicks: intVal(t["stop_ticks"]) ?? 48,
                    targetPoints: dblVal(t["target_points"]) ?? 8,
                    stopPoints: dblVal(t["stop_points"]) ?? 12
                )
            }
        }
        if plan.autoTune.isEmpty {
            plan.warnings.append("instruments.auto_tune missing — using NQ 32/48t defaults.")
        }

        if let levelSystem = obj["level_system"] as? [String: Any] {
            plan.minRankToTrade = intVal(levelSystem["min_rank_to_trade"]) ?? 6
        }

        if let risk = obj["risk"] as? [String: Any],
           let rules = risk["rules"] as? [[String: Any]] {
            for rule in rules {
                let name = (rule["rule"] as? String ?? "").lowercased()
                if name.contains("max trades") {
                    plan.maxTradesPerDay = intVal(rule["value"]) ?? 3
                } else if name.contains("lunch") {
                    if let str = rule["value"] as? String,
                       let window = parseTimeWindow(str) {
                        (plan.lunchStartMin, plan.lunchEndMin) = window
                    }
                } else if name.contains("daily max loss") {
                    // Numeric only. "UNDEFINED — SPEC GAP" string stays nil.
                    plan.dailyMaxLossUsd = dblVal(rule["value"])
                    if plan.dailyMaxLossUsd == nil {
                        plan.warnings.append("Daily max loss UNDEFINED in plan — shown, not enforced.")
                    }
                }
            }
        }

        if let account = obj["account_plan"] as? [String: Any] {
            plan.startingCapital = dblVal(account["starting_capital"]) ?? 1000
            if let rows = account["milestones"] as? [[String: Any]] {
                plan.milestones = rows.compactMap { row in
                    guard let bal = dblVal(row["account_balance"]) else { return nil }
                    return Milestone(
                        accountBalance: bal,
                        contracts: row["contracts"] as? String ?? "?",
                        usdPerPoint: dblVal(row["usd_per_point"]) ?? 0,
                        winAtTargetUsd: dblVal(row["win_at_target_usd"]) ?? 0,
                        lossAtStopUsd: dblVal(row["loss_at_12pt_stop_usd"]) ?? 0,
                        dailyTargetUsd: dblVal(row["daily_target_usd"]) ?? 0
                    )
                }
            }
        }

        return plan
    }

    /// "11:30-13:30 ET no new signals (toggleable)" -> (690, 810)
    private static func parseTimeWindow(_ s: String) -> (Int, Int)? {
        let pattern = #"(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges == 5 else { return nil }
        func group(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            return Int(s[r])
        }
        guard let h1 = group(1), let m1 = group(2), let h2 = group(3), let m2 = group(4) else { return nil }
        return (h1 * 60 + m1, h2 * 60 + m2)
    }

    private static func intVal(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func dblVal(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
