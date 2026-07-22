import Foundation

/// ET session buckets for the time-of-day cross filter.
enum SessionBucket: String, CaseIterable, Identifiable {
    case globex = "GLOBEX"      // 00:00–09:30 ET (overnight + premarket)
    case morning = "AM"         // 09:30–11:30
    case lunch = "LUNCH"        // 11:30–13:30
    case afternoon = "PM"       // 13:30–16:00
    case post = "POST"          // 16:00–24:00

    var id: String { rawValue }

    static func bucket(forMinutesET m: Int) -> SessionBucket {
        switch m {
        case ..<570: return .globex          // < 09:30
        case ..<690: return .morning         // < 11:30
        case ..<810: return .lunch           // < 13:30
        case ..<960: return .afternoon      // < 16:00
        default: return .post
        }
    }
}

/// Cross filters over the lifetime trade feed. nil = all.
struct AnalyticsFilter: Equatable {
    enum DateRange: String, CaseIterable, Identifiable {
        case all = "ALL", month = "30D", week = "7D", today = "TODAY"
        var id: String { rawValue }
    }
    var dateRange: DateRange = .all
    var instrument: String?
    var play: String?
    var side: String?
    var weekday: Int?            // 2=Mon … 6=Fri (Calendar weekday, ET)
    var bucket: SessionBucket?

    var isDefault: Bool { self == AnalyticsFilter() }
}

struct BreakdownRow: Identifiable {
    let label: String
    var trades = 0
    var wins = 0
    var losses = 0
    var netUsd = 0.0
    var id: String { label }
    var winRate: Double? { (wins + losses) > 0 ? Double(wins) / Double(wins + losses) : nil }
}

/// The trader-profile KPI sheet: everything computable from the journal's
/// closed trades — money, quality ratios, risk-adjusted returns, streaks,
/// time structure. Long-term record for optimization AND bragging rights.
struct AnalyticsReport {
    var tradeCount = 0
    var wins = 0
    var losses = 0
    var scratches = 0
    var openCount = 0
    var winRate: Double?

    var netUsd = 0.0
    var grossUsd = 0.0
    var commissions = 0.0
    var netTicks = 0.0

    var profitFactor: Double?
    var expectancyUsd: Double?
    var avgWinUsd: Double?
    var avgLossUsd: Double?
    var payoffRatio: Double?
    var largestWinUsd: Double?
    var largestLossUsd: Double?

    var maxWinStreak = 0
    var maxLossStreak = 0
    /// Positive = current win streak, negative = current loss streak.
    var currentStreak = 0

    var maxDrawdownUsd = 0.0
    var sharpe: Double?
    var sortino: Double?

    var tradingDays = 0
    var tradesPerDay: Double?
    var bestDayDate: String?
    var bestDayUsd: Double?
    var worstDayDate: String?
    var worstDayUsd: Double?

    var avgHoldSeconds: Double?
    var avgMaeTicks: Double?
    var avgMfeTicks: Double?

    var byWeekday: [BreakdownRow] = []
    var byHour: [BreakdownRow] = []
    var byBucket: [BreakdownRow] = []
    var byInstrument: [BreakdownRow] = []
    var byPlay: [BreakdownRow] = []
    var bySide: [BreakdownRow] = []
}

enum AnalyticsEngine {

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static var etCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Workspace.eastern
        return cal
    }()

    static let weekdayLabels = [2: "MON", 3: "TUE", 4: "WED", 5: "THU", 6: "FRI", 7: "SAT", 1: "SUN"]

    // MARK: - Compute

    static func compute(rows: [AnalyticsTradeRow], filter: AnalyticsFilter,
                        today: String = Workspace.todayString()) -> AnalyticsReport {
        var report = AnalyticsReport()

        let filtered = rows.filter { include($0, filter: filter, today: today) }
        report.openCount = filtered.filter { $0.result == "open" }.count

        // Closed trades in time order drive every number below.
        let closed = filtered.filter { $0.result == "win" || $0.result == "loss" || $0.result == "scratch" }
        report.tradeCount = closed.count
        guard !closed.isEmpty else { return report }

        var winUsdSum = 0.0, lossUsdSum = 0.0
        var equity = 0.0, peak = 0.0
        var winStreak = 0, lossStreak = 0
        var holds: [Double] = []
        var maes: [Double] = []
        var mfes: [Double] = []
        var dayNet: [String: Double] = [:]
        var dayCount: [String: Int] = [:]

        var byWeekday: [Int: BreakdownRow] = [:]
        var byHour: [Int: BreakdownRow] = [:]
        var byBucket: [String: BreakdownRow] = [:]
        var byInstrument: [String: BreakdownRow] = [:]
        var byPlay: [String: BreakdownRow] = [:]
        var bySide: [String: BreakdownRow] = [:]

        for trade in closed {
            let usd = trade.usdResult ?? 0
            let ticks = trade.ticksResult ?? 0
            report.netUsd += usd
            report.netTicks += ticks
            report.grossUsd += trade.grossUsd ?? usd
            report.commissions += trade.commission ?? 0

            switch trade.result {
            case "win":
                report.wins += 1
                winUsdSum += usd
                winStreak += 1; lossStreak = 0
                report.maxWinStreak = max(report.maxWinStreak, winStreak)
                report.largestWinUsd = max(report.largestWinUsd ?? usd, usd)
            case "loss":
                report.losses += 1
                lossUsdSum += usd
                lossStreak += 1; winStreak = 0
                report.maxLossStreak = max(report.maxLossStreak, lossStreak)
                report.largestLossUsd = min(report.largestLossUsd ?? usd, usd)
            default:
                report.scratches += 1
            }

            equity += usd
            peak = max(peak, equity)
            report.maxDrawdownUsd = max(report.maxDrawdownUsd, peak - equity)

            dayNet[trade.sessionDate, default: 0] += usd
            dayCount[trade.sessionDate, default: 0] += 1

            if let entryISO = trade.entryTime, let exitISO = trade.exitTime,
               let e = isoParser.date(from: entryISO), let x = isoParser.date(from: exitISO),
               x > e {
                holds.append(x.timeIntervalSince(e))
            }
            if let mae = trade.maeTicks { maes.append(mae) }
            if let mfe = trade.mfeTicks { mfes.append(mfe) }

            // Time structure off the best available clock (broker entry time
            // on imports, post time on manual rows), in ET.
            if let clock = isoParser.date(from: trade.clockISO) {
                let comps = etCalendar.dateComponents([.weekday, .hour, .minute], from: clock)
                let weekday = comps.weekday ?? 0
                let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                accumulate(&byWeekday, key: weekday, label: weekdayLabels[weekday] ?? "?", trade: trade, usd: usd)
                accumulate(&byHour, key: comps.hour ?? 0,
                           label: String(format: "%02d:00", comps.hour ?? 0), trade: trade, usd: usd)
                let bucket = SessionBucket.bucket(forMinutesET: minutes)
                accumulate(&byBucket, key: bucket.rawValue, label: bucket.rawValue, trade: trade, usd: usd)
            }
            accumulate(&byInstrument, key: trade.resolvedInstrument, label: trade.resolvedInstrument, trade: trade, usd: usd)
            accumulate(&byPlay, key: trade.playType, label: trade.playType, trade: trade, usd: usd)
            if let side = trade.side {
                accumulate(&bySide, key: side, label: side.uppercased(), trade: trade, usd: usd)
            }
        }

        report.currentStreak = winStreak > 0 ? winStreak : -lossStreak
        let decided = report.wins + report.losses
        report.winRate = decided > 0 ? Double(report.wins) / Double(decided) : nil
        report.expectancyUsd = report.netUsd / Double(closed.count)
        report.avgWinUsd = report.wins > 0 ? winUsdSum / Double(report.wins) : nil
        report.avgLossUsd = report.losses > 0 ? lossUsdSum / Double(report.losses) : nil
        if let aw = report.avgWinUsd, let al = report.avgLossUsd, al != 0 {
            report.payoffRatio = aw / abs(al)
        }
        report.profitFactor = lossUsdSum != 0 ? winUsdSum / abs(lossUsdSum) : nil

        report.tradingDays = dayNet.count
        report.tradesPerDay = dayNet.isEmpty ? nil
            : Double(closed.count) / Double(dayNet.count)
        if let best = dayNet.max(by: { $0.value < $1.value }) {
            report.bestDayDate = best.key; report.bestDayUsd = best.value
        }
        if let worst = dayNet.min(by: { $0.value < $1.value }) {
            report.worstDayDate = worst.key; report.worstDayUsd = worst.value
        }

        // Risk-adjusted returns off DAILY net — annualized √252. Needs 2+
        // trading days for a standard deviation worth printing.
        let dailyReturns = Array(dayNet.values)
        if dailyReturns.count >= 2 {
            let mean = dailyReturns.reduce(0, +) / Double(dailyReturns.count)
            let variance = dailyReturns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(dailyReturns.count - 1)
            let std = variance.squareRoot()
            if std > 0 { report.sharpe = mean / std * Double(252).squareRoot() }
            let downside = dailyReturns.map { min(0, $0) }
            let ddVariance = downside.reduce(0) { $0 + $1 * $1 } / Double(dailyReturns.count)
            let dd = ddVariance.squareRoot()
            if dd > 0 { report.sortino = mean / dd * Double(252).squareRoot() }
        }

        if !holds.isEmpty { report.avgHoldSeconds = holds.reduce(0, +) / Double(holds.count) }
        if !maes.isEmpty { report.avgMaeTicks = maes.reduce(0, +) / Double(maes.count) }
        if !mfes.isEmpty { report.avgMfeTicks = mfes.reduce(0, +) / Double(mfes.count) }

        report.byWeekday = ordered(byWeekday, order: [2, 3, 4, 5, 6, 7, 1])
        report.byHour = byHour.keys.sorted().compactMap { byHour[$0] }
        report.byBucket = SessionBucket.allCases.compactMap { byBucket[$0.rawValue] }
        report.byInstrument = byInstrument.values.sorted { $0.trades > $1.trades }
        report.byPlay = byPlay.values.sorted { $0.trades > $1.trades }
        report.bySide = bySide.values.sorted { $0.label < $1.label }
        return report
    }

    // MARK: - Filtering

    static func include(_ trade: AnalyticsTradeRow, filter: AnalyticsFilter, today: String) -> Bool {
        switch filter.dateRange {
        case .all: break
        case .today:
            guard trade.sessionDate == today else { return false }
        case .week:
            guard let cutoff = cutoffString(daysBack: 7, today: today),
                  trade.sessionDate >= cutoff else { return false }
        case .month:
            guard let cutoff = cutoffString(daysBack: 30, today: today),
                  trade.sessionDate >= cutoff else { return false }
        }
        if let inst = filter.instrument, trade.resolvedInstrument != inst { return false }
        if let play = filter.play, trade.playType != play { return false }
        if let side = filter.side, trade.side != side { return false }
        if filter.weekday != nil || filter.bucket != nil {
            guard let clock = isoParser.date(from: trade.clockISO) else { return false }
            let comps = etCalendar.dateComponents([.weekday, .hour, .minute], from: clock)
            if let wd = filter.weekday, comps.weekday != wd { return false }
            if let bucket = filter.bucket {
                let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                if SessionBucket.bucket(forMinutesET: minutes) != bucket { return false }
            }
        }
        return true
    }

    /// "YYYY-MM-DD" cutoff N days back from today (ET, string-comparable).
    private static func cutoffString(daysBack: Int, today: String) -> String? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = Workspace.eastern
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let todayDate = fmt.date(from: today),
              let cutoff = etCalendar.date(byAdding: .day, value: -daysBack, to: todayDate) else {
            return nil
        }
        return fmt.string(from: cutoff)
    }

    private static func accumulate<K: Hashable>(
        _ dict: inout [K: BreakdownRow], key: K, label: String,
        trade: AnalyticsTradeRow, usd: Double
    ) {
        var row = dict[key] ?? BreakdownRow(label: label)
        row.trades += 1
        if trade.result == "win" { row.wins += 1 }
        if trade.result == "loss" { row.losses += 1 }
        row.netUsd += usd
        dict[key] = row
    }

    private static func ordered(_ dict: [Int: BreakdownRow], order: [Int]) -> [BreakdownRow] {
        order.compactMap { dict[$0] }
    }
}
