import SwiftUI

/// TRADER PROFILE — the full data-processing section. Lifetime KPIs (Sharpe,
/// Sortino, profit factor, expectancy, drawdown, streaks…) plus cross filters
/// (date range / instrument / play / side / weekday / session bucket) and
/// time-structure breakdowns. Long-term record for optimization AND bragging.
struct AnalyticsView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [AnalyticsTradeRow] = []
    @State private var filter = AnalyticsFilter()
    @State private var report = AnalyticsReport()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.cardBorder)
            filterBar
            Divider().overlay(Theme.cardBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if report.tradeCount == 0 {
                        emptyState
                    } else {
                        kpiGrid
                        breakdownGrid
                        signalContextSection
                        footnote
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 920, height: 700)
        .background(Theme.bg)
        .foregroundColor(Theme.text)
        .onAppear { reload() }
        .onChange(of: filter) { _, _ in recompute() }
    }

    private func reload() {
        rows = store.analyticsRows()
        recompute()
    }

    private func recompute() {
        report = AnalyticsEngine.compute(rows: rows, filter: filter)
    }

    // MARK: - Header / filters

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 12))
                .foregroundColor(Theme.purple)
            Text("TRADER PROFILE — ANALYTICS")
                .font(Theme.mono)
                .kerning(1.5)
            Spacer()
            Text("\(report.tradeCount) closed · \(report.tradingDays) day\(report.tradingDays == 1 ? "" : "s")")
                .font(Theme.monoSmall)
                .foregroundColor(Theme.textDim)
            Button("Close") { dismiss() }
                .buttonStyle(PillButton(color: Theme.textDim))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter.dateRange) {
                ForEach(AnalyticsFilter.DateRange.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .labelsHidden()

            filterMenu("inst", value: $filter.instrument,
                       options: Instrument.allCases.map(\.rawValue))
            filterMenu("play", value: $filter.play,
                       options: PlayType.allCases.map(\.rawValue))
            filterMenu("side", value: $filter.side, options: ["long", "short"],
                       display: { $0.uppercased() })
            weekdayMenu
            bucketMenu

            if !filter.isDefault {
                Button {
                    filter = AnalyticsFilter()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 8, weight: .bold))
                        Text("reset")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundColor(Theme.cyan)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func filterMenu(_ label: String, value: Binding<String?>,
                            options: [String],
                            display: @escaping (String) -> String = { $0 }) -> some View {
        Menu {
            Button("all") { value.wrappedValue = nil }
            ForEach(options, id: \.self) { opt in
                Button(display(opt)) { value.wrappedValue = opt }
            }
        } label: {
            Text(value.wrappedValue.map(display) ?? label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(value.wrappedValue == nil ? Theme.textDim : Theme.cyan)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var weekdayMenu: some View {
        Menu {
            Button("all") { filter.weekday = nil }
            ForEach([2, 3, 4, 5, 6], id: \.self) { wd in
                Button(AnalyticsEngine.weekdayLabels[wd] ?? "?") { filter.weekday = wd }
            }
        } label: {
            Text(filter.weekday.flatMap { AnalyticsEngine.weekdayLabels[$0] } ?? "day")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(filter.weekday == nil ? Theme.textDim : Theme.cyan)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var bucketMenu: some View {
        Menu {
            Button("all") { filter.bucket = nil }
            ForEach(SessionBucket.allCases) { b in
                Button(b.rawValue) { filter.bucket = b }
            }
        } label: {
            Text(filter.bucket?.rawValue ?? "session")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(filter.bucket == nil ? Theme.textDim : Theme.cyan)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Circle().fill(Theme.textDim).frame(width: 6, height: 6)
            Text("No closed trades in this slice yet")
                .font(Theme.mono)
                .foregroundColor(Theme.textDim)
            Text("Trade, settle the day, and the profile builds itself.")
                .font(Theme.monoSmall)
                .foregroundColor(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - KPI grid

    private var kpiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                  spacing: 10) {
            kpi("NET P&L", Fmt.usd(report.netUsd), color: Fmt.pnl(report.netUsd))
            kpi("NET TICKS", Fmt.ticks(report.netTicks), color: Fmt.pnl(report.netTicks))
            kpi("WIN RATE", Fmt.pct(report.winRate),
                sub: "\(report.wins)W \(report.losses)L \(report.scratches)S")
            kpi("PROFIT FACTOR", Fmt.ratio(report.profitFactor),
                color: (report.profitFactor ?? 0) >= 1.5 ? Theme.green : Theme.text)

            kpi("EXPECTANCY / TRADE", Fmt.usd(report.expectancyUsd ?? 0),
                color: Fmt.pnl(report.expectancyUsd ?? 0))
            kpi("AVG WIN", report.avgWinUsd.map { Fmt.usd($0) } ?? "—", color: Theme.green)
            kpi("AVG LOSS", report.avgLossUsd.map { Fmt.usd($0) } ?? "—", color: Theme.red)
            kpi("PAYOFF RATIO", Fmt.ratio(report.payoffRatio))

            kpi("SHARPE (DAILY, ANN.)", Fmt.ratio(report.sharpe),
                color: (report.sharpe ?? 0) >= 1 ? Theme.green : Theme.text,
                sub: report.sharpe == nil ? "needs 2+ days" : nil)
            kpi("SORTINO", Fmt.ratio(report.sortino),
                sub: report.sortino == nil ? "needs 2+ days" : nil)
            kpi("MAX DRAWDOWN", "-$" + String(format: "%.2f", report.maxDrawdownUsd),
                color: report.maxDrawdownUsd > 0 ? Theme.red : Theme.textDim)
            kpi("STREAKS", "\(report.maxWinStreak)W / \(report.maxLossStreak)L",
                sub: streakSub)

            kpi("GROSS / FEES", Fmt.usd(report.grossUsd),
                sub: "fees -$" + String(format: "%.2f", report.commissions))
            kpi("LARGEST WIN / LOSS",
                report.largestWinUsd.map { Fmt.usd($0) } ?? "—",
                sub: report.largestLossUsd.map { Fmt.usd($0) } ?? "—")
            kpi("TRADES / DAY", report.tradesPerDay.map { String(format: "%.1f", $0) } ?? "—",
                sub: report.openCount > 0 ? "\(report.openCount) open excluded" : nil)
            kpi("AVG HOLD", Fmt.hold(report.avgHoldSeconds),
                sub: holdSub)

            kpi("BEST DAY", report.bestDayUsd.map { Fmt.usd($0) } ?? "—",
                color: Theme.green, sub: report.bestDayDate)
            kpi("WORST DAY", report.worstDayUsd.map { Fmt.usd($0) } ?? "—",
                color: (report.worstDayUsd ?? 0) < 0 ? Theme.red : Theme.text,
                sub: report.worstDayDate)
            kpi("AVG MAE", report.avgMaeTicks.map { String(format: "%.1ft", $0) } ?? "—",
                sub: report.avgMaeTicks == nil ? "needs broker times + replay" : nil)
            kpi("AVG MFE", report.avgMfeTicks.map { String(format: "%.1ft", $0) } ?? "—")
        }
    }

    private var streakSub: String {
        let c = report.currentStreak
        if c > 0 { return "current \(c)W" }
        if c < 0 { return "current \(-c)L" }
        return "current —"
    }

    private var holdSub: String? {
        report.avgHoldSeconds == nil ? "imported trades only" : nil
    }

    private func kpi(_ title: String, _ value: String,
                     color: Color = Theme.text, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.textDim)
                .kerning(1)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let sub {
                Text(sub)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textDim)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))
    }

    // MARK: - Breakdowns

    private var breakdownGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3),
                  spacing: 10) {
            breakdown("BY WEEKDAY", rows: report.byWeekday)
            breakdown("BY SESSION", rows: report.byBucket)
            breakdown("BY HOUR (ET)", rows: report.byHour)
            breakdown("BY INSTRUMENT", rows: report.byInstrument)
            breakdown("BY PLAY", rows: report.byPlay)
            breakdown("BY SIDE", rows: report.bySide)
            breakdown("BY LEVEL STARS", rows: report.byLevelStars)
        }
    }

    // MARK: - Recent signal contexts

    /// Last N closed trades' raw HUD text mirror alongside how they turned
    /// out — display-only, opaque, never re-parsed. Not numerically
    /// bucketed (ADX/RSI/stretch aren't stored fields yet), so this is an
    /// eyeball tool, not a stat.
    private var signalContextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENT SIGNAL CONTEXTS")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.textDim)
                .kerning(1)
            if report.recentSignalContexts.isEmpty {
                Text("No captured HUD context yet — log entries from the Grid's \"Log entry →\" to start collecting these.")
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.textDim)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.recentSignalContexts) { row in
                        signalContextRow(row)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))
    }

    private func signalContextRow(_ row: SignalContextEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(Fmt.resultLabel(row.result))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Fmt.resultColor(row.result))
                Text(Fmt.etTime(fromISO: row.ts))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textDim)
            }
            Text(row.text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.textDim)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
    }

    private func breakdown(_ title: String, rows: [BreakdownRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.textDim)
                .kerning(1)
            if rows.isEmpty {
                Text("—")
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.textDim)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    GridRow {
                        Text("")
                        Text("N")
                        Text("WIN%")
                        Text("NET")
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textDim)
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.label).foregroundColor(Theme.text)
                            Text("\(row.trades)").foregroundColor(Theme.text)
                            Text(Fmt.pct(row.winRate))
                                .foregroundColor(Fmt.rate(row.winRate))
                            Text(Fmt.usd(row.netUsd))
                                .foregroundColor(Fmt.pnl(row.netUsd))
                        }
                        .font(.system(size: 10, design: .monospaced))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))
    }

    private var footnote: some View {
        Text("Closed trades only · P&L net of commissions on imported rows · Sharpe/Sortino off daily nets, annualized √252 · hold/MAE/MFE need broker times (Settle Day import)")
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(Theme.textDim)
    }

    // MARK: - Formatters

    private enum Fmt {
        static func usd(_ v: Double) -> String {
            (v < 0 ? "-$" : "+$") + String(format: "%.2f", abs(v))
        }
        static func ticks(_ v: Double) -> String {
            String(format: "%+.0ft", v)
        }
        static func pct(_ r: Double?) -> String {
            r.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        }
        static func ratio(_ r: Double?) -> String {
            r.map { String(format: "%.2f", $0) } ?? "—"
        }
        static func hold(_ s: Double?) -> String {
            guard let s else { return "—" }
            if s < 90 { return String(format: "%.0fs", s) }
            let m = Int(s) / 60
            return "\(m)m \(Int(s) % 60)s"
        }
        static func pnl(_ v: Double) -> Color {
            v > 0 ? Theme.green : (v < 0 ? Theme.red : Theme.textDim)
        }
        static func rate(_ r: Double?) -> Color {
            guard let r else { return Theme.textDim }
            return r >= 0.5 ? Theme.green : Theme.red
        }
        static func resultLabel(_ r: String?) -> String {
            (r ?? "?").uppercased()
        }
        static func resultColor(_ r: String?) -> Color {
            switch r {
            case "win": return Theme.green
            case "loss": return Theme.red
            case "scratch": return Theme.textDim
            default: return Theme.textDim
            }
        }
        /// ISO8601 -> "MM/dd HH:mm" in ET. Falls back to the raw string.
        static func etTime(fromISO iso: String) -> String {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime]
            guard let date = parser.date(from: iso) else { return iso }
            let f = DateFormatter()
            f.dateFormat = "MM/dd HH:mm"
            f.timeZone = Workspace.eastern
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: date)
        }
    }
}
