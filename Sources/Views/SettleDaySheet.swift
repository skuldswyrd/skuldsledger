import SwiftUI

/// EOD settle flow: paste TradingView's account history, preview every
/// reconstructed round trip (tag plays inline), confirm, done. Nothing
/// writes without the preview — broker data is truth, but the user signs it.
struct SettleDaySheet: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var pasteText = ""
    @State private var parse: TVImportParse?
    @State private var duplicates: Set<UUID> = []
    @State private var plays: [UUID: PlayType] = [:]
    @State private var summary: TVImportSummary?

    private static let etTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = Workspace.eastern
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let summary {
                donePanel(summary)
            } else if let parse {
                previewPanel(parse)
            } else {
                pastePanel
            }
        }
        .padding(16)
        .frame(width: 780, height: 560)
        .background(Theme.bg)
        .foregroundColor(Theme.text)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 12))
                .foregroundColor(Theme.cyan)
            Text("SETTLE DAY — TRADINGVIEW LEDGER IMPORT")
                .font(Theme.mono)
                .kerning(1.2)
            Spacer()
            Text("real fills become journal truth")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.textDim)
        }
    }

    // MARK: - Step 1: paste

    private var pastePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TradingView → trading panel → account history → copy rows → paste here. The balance-history CSV export's contents paste fine too. Multi-day pastes backfill each day's session — a whole tournament in one go.")
                .font(Theme.monoSmall)
                .foregroundColor(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $pasteText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.text)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButton(color: Theme.textDim))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Parse") { runParse() }
                    .buttonStyle(PillButton(color: Theme.cyan, filled: true))
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func runParse() {
        let parsed = TVImportParser.parse(pasteText)
        parse = parsed
        duplicates = store.duplicateTripIds(parsed)
        plays = [:]
    }

    // MARK: - Step 2: preview

    private func previewPanel(_ parse: TVImportParse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !parse.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(parse.warnings, id: \.self) { w in
                        HStack(spacing: 5) {
                            Circle().fill(Theme.amber).frame(width: 5, height: 5)
                            Text(w)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.amber)
                        }
                    }
                }
            }

            if parse.trips.isEmpty {
                Spacer()
                Text("No round trips found in the paste.")
                    .font(Theme.mono)
                    .foregroundColor(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                previewHeader
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(parse.trips) { trip in
                            tripRow(trip)
                        }
                    }
                }
                totalsRow(parse)
            }

            HStack {
                Button("Back") { self.parse = nil }
                    .buttonStyle(PillButton(color: Theme.textDim))
                Spacer()
                let importable = parse.trips.filter { !duplicates.contains($0.id) }.count
                Button("Import \(importable) trade\(importable == 1 ? "" : "s")") { runImport(parse) }
                    .buttonStyle(PillButton(color: Theme.green, filled: true))
                    .disabled(importable == 0)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var previewHeader: some View {
        HStack(spacing: 0) {
            cell("EXIT ET", width: 70)
            cell("INST", width: 46)
            cell("SIDE", width: 52)
            cell("ENTRY → EXIT", width: 150)
            cell("TICKS", width: 52)
            cell("GROSS", width: 72)
            cell("FEES", width: 56)
            cell("NET", width: 76)
            cell("PLAY", width: 70)
            cell("", width: 60)
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundColor(Theme.textDim)
    }

    private func tripRow(_ trip: TVRoundTrip) -> some View {
        let dup = duplicates.contains(trip.id)
        return HStack(spacing: 0) {
            cell(Self.etTime.string(from: trip.exitTime), width: 70)
            cell(trip.instrumentName, width: 46)
            HStack {
                Text(trip.side.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(trip.side == "long" ? Theme.green : Theme.purple)
                Spacer(minLength: 0)
            }
            .frame(width: 52)
            cell("\(price(trip.entryPrice)) → \(price(trip.exitPrice))", width: 150)
            cell(trip.ticks.map { String(format: "%+.0ft", $0) } ?? "—", width: 52,
                 color: (trip.ticks ?? 0) >= 0 ? Theme.green : Theme.red)
            cell(usd(trip.grossUsd), width: 72, color: trip.grossUsd >= 0 ? Theme.green : Theme.red)
            cell(String(format: "-%.2f", trip.commissionUsd), width: 56, color: Theme.textDim)
            cell(usd(trip.netUsd), width: 76, color: trip.netUsd >= 0 ? Theme.green : Theme.red)
            playMenu(trip, disabled: dup)
            HStack {
                Text(dup ? "DUP" : "NEW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(dup ? Theme.textDim : Theme.cyan)
                Spacer(minLength: 0)
            }
            .frame(width: 60)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.card))
        .opacity(dup ? 0.45 : 1)
    }

    private func playMenu(_ trip: TVRoundTrip, disabled: Bool) -> some View {
        Menu {
            ForEach(PlayType.allCases) { p in
                Button(p.rawValue) { plays[trip.id] = p }
            }
        } label: {
            Text((plays[trip.id] ?? .OFF).rawValue)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(plays[trip.id] == nil ? Theme.textDim : Theme.teal)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(width: 70, alignment: .leading)
        .disabled(disabled)
        .help("Tag the play this trade was — OFF = outside every defined play")
    }

    private func totalsRow(_ parse: TVImportParse) -> some View {
        HStack(spacing: 14) {
            Text("\(parse.trips.count) round trips")
            Text("gross \(usd(parse.totalGross))")
                .foregroundColor(parse.totalGross >= 0 ? Theme.green : Theme.red)
            Text("fees -$\(String(format: "%.2f", parse.totalCommission))")
                .foregroundColor(Theme.textDim)
            Text("net \(usd(parse.totalNet))")
                .foregroundColor(parse.totalNet >= 0 ? Theme.green : Theme.red)
                .fontWeight(.bold)
            Spacer()
        }
        .font(Theme.monoSmall)
        .padding(.top, 2)
    }

    // MARK: - Step 3: done

    private func runImport(_ parse: TVImportParse) {
        summary = store.importTVTrades(parse, plays: plays, rawText: pasteText)
    }

    private func donePanel(_ s: TVImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(Theme.green).frame(width: 10, height: 10)
                Text("DAY SETTLED")
                    .font(Theme.mono.weight(.bold))
                    .foregroundColor(Theme.green)
            }
            Group {
                Text("\(s.created) imported as new posts")
                if s.days > 1 { Text("\(s.days) session days touched — past days created as closed sessions") }
                if s.matched > 0 { Text("\(s.matched) matched to manual trades (completed in place)") }
                if s.duplicates > 0 { Text("\(s.duplicates) already journaled — skipped") }
                if s.phantoms > 0 {
                    Text("\(s.phantoms) manual open trade\(s.phantoms == 1 ? "" : "s") the broker never saw — check them")
                        .foregroundColor(Theme.amber)
                }
            }
            .font(Theme.monoSmall)
            .foregroundColor(Theme.text)
            Text("Sidebar P&L is now broker-true (net of commissions). Raw paste saved beside today's assets.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textDim)
            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PillButton(color: Theme.green, filled: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Small helpers

    private func cell(_ text: String, width: CGFloat, color: Color = Theme.text) -> some View {
        HStack {
            Text(text)
                .foregroundColor(color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(width: width)
    }

    private func price(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private func usd(_ v: Double) -> String {
        (v < 0 ? "-$" : "+$") + String(format: "%.2f", abs(v))
    }
}

/// Local pill style (FeedView's is file-private).
struct PillButton: ButtonStyle {
    var color: Color
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.monoSmall)
            .foregroundStyle(filled ? Theme.bg : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(filled ? color : color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
