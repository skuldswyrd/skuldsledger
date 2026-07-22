import SwiftUI

/// Live "poker stats" sidebar. Reads store.stats (recomputed on every write)
/// plus store.levels for the tap-to-toggle held/broke list.
/// Status is shown as green/red/amber lights, numbers in mono.
struct StatsSidebarView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                DisciplineCard(stats: store.stats)
                PnlCard(stats: store.stats)
                StarTableCard(rows: store.stats.starRows)
                PlayTableCard(rows: store.stats.playRows)
                SignalsCard(stats: store.stats)
                LevelsCard(stats: store.stats, levels: store.levels) { levelId, broken in
                    store.setLevelBroken(levelId, broken: broken)
                }
            }
            .padding(12)
        }
        .background(Theme.bg)
    }
}

// MARK: - Discipline (TRADES X/N + light)

private struct DisciplineCard: View {
    let stats: SessionStats

    /// green while >1 trade remains, amber on the last trade, red at/over max.
    private var light: Color {
        if stats.tradesTaken >= stats.maxTrades { return Theme.red }
        if stats.tradesTaken == stats.maxTrades - 1 { return Theme.amber }
        return Theme.green
    }

    var body: some View {
        SidebarCard(title: "DISCIPLINE") {
            HStack(spacing: 10) {
                Circle()
                    .fill(light)
                    .frame(width: 12, height: 12)
                Text("TRADES \(stats.tradesTaken)/\(stats.maxTrades)")
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.text)
            }
            if stats.openTrades > 0 {
                HStack(spacing: 6) {
                    Circle().fill(Theme.blue).frame(width: 6, height: 6)
                    Text("\(stats.openTrades) OPEN — close before EOD")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}

// MARK: - P&L

private struct PnlCard: View {
    let stats: SessionStats

    var body: some View {
        SidebarCard(title: "P&L") {
            HStack(spacing: 12) {
                Text(SidebarFmt.signedTicks(stats.netTicks))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(SidebarFmt.pnlColor(stats.netTicks))
                Text(SidebarFmt.signedUsd(stats.netUsd))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(SidebarFmt.pnlColor(stats.netUsd))
            }
            HStack(spacing: 8) {
                Text("\(stats.wins)W").foregroundStyle(Theme.green)
                Text("\(stats.losses)L").foregroundStyle(Theme.red)
                Text("\(stats.scratches)S").foregroundStyle(Theme.textDim)
            }
            .font(Theme.monoSmall.weight(.semibold))

            SidebarRow(
                label: "DAILY TARGET",
                value: stats.dailyTargetUsd.map { SidebarFmt.usd($0) } ?? "—",
                valueColor: Theme.text)

            if let maxLoss = stats.dailyMaxLossUsd {
                SidebarRow(
                    label: "DAILY MAX LOSS",
                    value: SidebarFmt.usd(maxLoss),
                    valueColor: Theme.text)
            } else {
                HStack(alignment: .top) {
                    Text("DAILY MAX LOSS")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("UNDEFINED")
                            .font(Theme.monoSmall.weight(.bold))
                            .foregroundStyle(Theme.amber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.amber.opacity(0.15))
                            )
                        Text("not enforced")
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }
        }
    }
}

// MARK: - Star-rank hit rate

private struct StarTableCard: View {
    let rows: [SessionStats.StarRow]

    var body: some View {
        SidebarCard(title: "STAR RANK HIT RATE") {
            if rows.isEmpty {
                Text("no signals yet")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("LEVEL")
                        Text("SIG")
                        Text("WIN%")
                    }
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    ForEach(rows) { row in
                        GridRow {
                            Text(Theme.starText(row.stars))
                                .foregroundStyle(Theme.starColor(row.stars))
                            Text("\(row.signals)")
                                .foregroundStyle(Theme.text)
                            Text(SidebarFmt.pct(row.hitRate))
                                .foregroundStyle(SidebarFmt.rateColor(row.hitRate))
                        }
                        .font(Theme.monoSmall)
                    }
                }
            }
        }
    }
}

// MARK: - Play types

private struct PlayTableCard: View {
    let rows: [SessionStats.PlayRow]

    var body: some View {
        SidebarCard(title: "PLAYS") {
            if rows.isEmpty {
                Text("no plays yet")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("PLAY")
                        Text("TAKEN")
                        Text("WIN%")
                    }
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.play)
                                .foregroundStyle(Theme.text)
                            Text("\(row.taken)")
                                .foregroundStyle(Theme.text)
                            Text(SidebarFmt.pct(row.winRate))
                                .foregroundStyle(SidebarFmt.rateColor(row.winRate))
                        }
                        .font(Theme.monoSmall)
                    }
                }
            }
        }
    }
}

// MARK: - Signals offered vs taken + chop

private struct SignalsCard: View {
    let stats: SessionStats

    var body: some View {
        SidebarCard(title: "SIGNALS") {
            HStack(spacing: 16) {
                StatPair(label: "OFFERED", value: "\(stats.signalsOffered)")
                StatPair(label: "TAKEN", value: "\(stats.signalsTaken)")
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Circle().fill(Theme.amber).frame(width: 6, height: 6)
                Text("CHOP CALLS")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                Spacer(minLength: 8)
                Text("\(stats.chopCount)")
                    .font(Theme.monoSmall)
                    .foregroundStyle(stats.chopCount > 0 ? Theme.amber : Theme.text)
            }
        }
    }
}

// MARK: - Levels held vs broke + toggle list

private struct LevelsCard: View {
    let stats: SessionStats
    let levels: [LevelRecord]
    let toggle: (String, Bool) -> Void

    var body: some View {
        SidebarCard(title: "LEVELS") {
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Circle().fill(Theme.green).frame(width: 8, height: 8)
                    Text("\(stats.levelsHeld) HELD")
                        .font(Theme.monoSmall.weight(.semibold))
                        .foregroundStyle(Theme.green)
                }
                HStack(spacing: 5) {
                    Circle().fill(Theme.red).frame(width: 8, height: 8)
                    Text("\(stats.levelsBroken) BROKE")
                        .font(Theme.monoSmall.weight(.semibold))
                        .foregroundStyle(Theme.red)
                }
                Spacer(minLength: 0)
            }
            if levels.isEmpty {
                Text("no levels yet")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
            } else {
                VStack(spacing: 3) {
                    ForEach(levels) { level in
                        Button {
                            toggle(level.id, !level.broken)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(level.broken ? Theme.red : Theme.green)
                                    .frame(width: 6, height: 6)
                                Text(level.name)
                                    .font(Theme.monoSmall)
                                    .foregroundStyle(level.broken ? Theme.textDim : Theme.text)
                                    .strikethrough(level.broken, color: Theme.red)
                                    .lineLimit(1)
                                Text(Theme.starText(level.stars))
                                    .font(Theme.monoSmall)
                                    .foregroundStyle(Theme.starColor(level.stars))
                                Spacer(minLength: 6)
                                Text(SidebarFmt.price(level.price))
                                    .font(Theme.monoSmall)
                                    .foregroundStyle(level.broken ? Theme.textDim : Theme.text)
                                    .strikethrough(level.broken, color: Theme.red)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(level.broken
                              ? "Mark \(level.name) as holding"
                              : "Mark \(level.name) as broken")
                    }
                }
            }
        }
    }
}

// MARK: - Shared sidebar pieces

private struct SidebarCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
                .kerning(1.2)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))
    }
}

private struct SidebarRow: View {
    let label: String
    let value: String
    let valueColor: Color

    var body: some View {
        HStack {
            Text(label)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.monoSmall)
                .foregroundStyle(valueColor)
        }
    }
}

private struct StatPair: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
            Text(value)
                .font(Theme.mono.weight(.semibold))
                .foregroundStyle(Theme.text)
        }
    }
}

private enum SidebarFmt {
    static func signedTicks(_ v: Double) -> String {
        String(format: "%+.1ft", v)
    }

    static func signedUsd(_ v: Double) -> String {
        (v < 0 ? "-" : "+") + "$" + String(format: "%.2f", abs(v))
    }

    static func usd(_ v: Double) -> String {
        (v < 0 ? "-$" : "$") + String(format: "%.2f", abs(v))
    }

    static func price(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    static func pct(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return String(format: "%.0f%%", rate * 100)
    }

    static func pnlColor(_ v: Double) -> Color {
        if v > 0 { return Theme.green }
        if v < 0 { return Theme.red }
        return Theme.textDim
    }

    static func rateColor(_ rate: Double?) -> Color {
        guard let rate else { return Theme.textDim }
        return rate >= 0.5 ? Theme.green : Theme.red
    }
}
