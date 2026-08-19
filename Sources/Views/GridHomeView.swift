import SwiftUI

/// GRID — the app's ONLY home screen (FEED / the old session shell is gone):
/// a grid mirroring the user's real TradingView layout, sized to however many
/// panes the last scan actually found. `ScanResult.index` (0-based, the same
/// index `tv pane list` reports) maps DIRECTLY to grid position in standard
/// reading order — row = index/columns, col = index%columns — because that's
/// how TradingView's own multi-chart grids number their panes.
///
/// One "Refresh All" sweep (manual here, or automatic every 15 minutes ET
/// regardless of session state — see SessionStore.checkLaneAutoRefresh) still
/// focuses each pane in turn and reads its levels + SKULD dashboard exactly
/// like the Pane Scanner always did; on top of that, each pane's HUD read
/// auto-logs what changed into that symbol's own thread (deduped per launch
/// so identical back-to-back reads don't spam it), and a WAITING->SIGNAL
/// transition wakes that lane's own mentor. Every lane's thread now lives
/// INLINE in its own cell (always visible, no drill-down popup) so the trader
/// never has to leave the grid to see or answer it. HUD lines stay a plain
/// read-only mirror of whatever the indicator's table currently draws —
/// never re-parsed into typed fields, so a HUD layout change in the .pine
/// can never silently break this view.
struct GridHomeView: View {
    @EnvironmentObject private var store: SessionStore
    /// Fired by "Log entry ->" after it preselects the composer's instrument
    /// — the parent (ContentView) uses this to present the composer sheet.
    let openComposer: () -> Void

    /// Per-cell compose drafts, keyed by symbol — the inline thread box is
    /// live in every cell at once now, so this can't be a single `@State`
    /// string the way the old drill-down sheet's composer was.
    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.cardBorder)
            grid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .foregroundColor(Theme.text)
        .onAppear {
            // The 15-min auto-refresh only fires in a narrow window after
            // each real bar close — without this, a fresh launch (or
            // relaunch) sits on empty "no dashboard read" cells until the
            // clock happens to catch up, even though TradingView is sitting
            // right there ready. Scan once immediately if nothing's loaded
            // yet; the timer and the manual button own every refresh after
            // that.
            if store.scanResults.isEmpty, !store.scanBusy {
                Task { await store.scanAllPanes() }
            }
        }
    }

    // MARK: - Header (Refresh All lives here, not per-cell)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.purple)
                Text("GRID")
                    .font(Theme.mono.weight(.bold))
                    .kerning(1.5)
                Text(paneCountLabel)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                Spacer()
                Button {
                    Task { await store.scanAllPanes() }
                } label: {
                    if store.scanBusy {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("Refreshing…")
                        }
                    } else {
                        Text("Refresh All")
                    }
                }
                .buttonStyle(PillButton(color: Theme.green, filled: true))
                .disabled(store.scanBusy)
                .help("Focuses each pane in turn and reads its levels + SKULD dashboard")
            }
            Text("Auto-refreshes every 15 minutes ET — Refresh All forces one now.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var paneCountLabel: String {
        let n = store.scanResults.count
        guard n > 0 else { return "no scan yet" }
        return "\(n) pane\(n == 1 ? "" : "s"), \(n) thread\(n == 1 ? "" : "s")"
    }

    // MARK: - Grid sizing (real pane count, not a hardcoded 6)

    /// slots[i] = the last scan result for pane index i, or nil if that pane
    /// hasn't been read yet this launch. Sized to the ACTUAL scan count
    /// (`store.scanResults.count`), never `ScanResult.index` max+1, so a gap
    /// in indices can't silently inflate the grid.
    private var slots: [ScanResult?] {
        let n = store.scanResults.count
        guard n > 0 else { return [] }
        var arr: [ScanResult?] = Array(repeating: nil, count: n)
        for result in store.scanResults where (0..<n).contains(result.index) {
            arr[result.index] = result
        }
        return arr
    }

    /// N<=1 -> 1 col, N<=2 -> 2, N<=4 -> 2, N<=6 -> 3, else 4. His real
    /// 6-pane layout resolves to exactly 3 columns x 2 rows.
    private var columns: Int {
        let n = store.scanResults.count
        if n <= 1 { return 1 }
        if n <= 2 { return 2 }
        if n <= 4 { return 2 }
        if n <= 6 { return 3 }
        return 4
    }

    @ViewBuilder
    private var grid: some View {
        let s = slots
        if s.isEmpty {
            emptyState
        } else {
            let cols = columns
            let rowCount = (s.count + cols - 1) / cols
            VStack(spacing: 10) {
                ForEach(0..<rowCount, id: \.self) { r in
                    HStack(spacing: 10) {
                        ForEach(0..<cols, id: \.self) { c in
                            let idx = r * cols + c
                            if idx < s.count {
                                cell(s[idx], index: idx)
                            } else {
                                Color.clear
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Before any scan has completed this launch the true pane count is
    /// genuinely unknown — no placeholder grid of some guessed size, just
    /// one centered message. The onAppear auto-scan resolves this within
    /// moments on a normal launch.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Circle().fill(Theme.textDim.opacity(0.4)).frame(width: 8, height: 8)
            Text("Refresh All to read your TradingView layout")
                .font(Theme.mono)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Cell

    private func cell(_ result: ScanResult?, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(stateColor(result)).frame(width: 7, height: 7)
                Text(result.map { displaySymbol($0.symbol) } ?? "PANE \(index + 1)")
                    .font(Theme.mono.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let res = result?.resolution, !res.isEmpty {
                    Text(res)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 4)
            }

            hudBlock(result)
                .frame(maxHeight: 100)

            Divider().overlay(Theme.cardBorder)

            threadScroll(result?.symbol)
            composeRow(result?.symbol)

            if let result {
                Button("Log entry →") { logEntry(result) }
                    .buttonStyle(PillButton(color: Theme.green))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.purple.opacity(0.35), lineWidth: 1))
    }

    /// The full `hudLines` mirror, unsummarized — wrapped in its own
    /// ScrollView, bounded so it can't crowd the inline thread out of the
    /// cell now that the cell has real competing content below it.
    @ViewBuilder
    private func hudBlock(_ result: ScanResult?) -> some View {
        if let result, !result.hudLines.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(result.hudLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(result == nil
                 ? "no read yet — Refresh All to scan this pane"
                 : "no dashboard read — SKULD may not be visible on this pane")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Inline thread (was LaneDetailSheet's drill-down popup — now
    // always visible in the cell itself, no separate sheet/button)

    /// Fixed-height scroll of this lane's full thread history — the exact
    /// row rendering the old "Thread" popup used (dim system/HUD lines,
    /// purple MENTOR caption, plain trader text), just inline now.
    @ViewBuilder
    private func threadScroll(_ symbol: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let symbol {
                    let updates = store.laneUpdates[symbol] ?? []
                    if updates.isEmpty {
                        Text("no lane activity yet")
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.textDim)
                    } else {
                        ForEach(updates) { update in
                            laneUpdateRow(update)
                        }
                    }
                    if store.laneMentorBusy.contains(symbol) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("mentor thinking…")
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.textDim)
                        }
                    }
                } else {
                    Text("no lane activity yet")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .frame(height: 140)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
    }

    /// Lifted verbatim from the old LaneDetailSheet's row(_:) before that
    /// struct was deleted — same visual language as FeedView's mentor block:
    /// dim italic-weight system/HUD text, a purple "MENTOR" caption over
    /// mentor replies, plain text for the trader's own lines.
    @ViewBuilder
    private func laneUpdateRow(_ update: LaneUpdateRecord) -> some View {
        switch update.kind {
        case "mentor":
            VStack(alignment: .leading, spacing: 3) {
                Text("MENTOR")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.purple)
                Text(update.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "user":
            Text(update.text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        default:
            // "system" — an auto-logged HUD snapshot mirror, dimmest tier.
            Text(update.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Always-visible compose row under the thread — same
    /// `store.sendLaneComment(symbol:text:)` call the old popup's composer
    /// made, clearing its own draft on send.
    private func composeRow(_ symbol: String?) -> some View {
        HStack(spacing: 6) {
            TextField("Talk to this lane…", text: draftBinding(symbol))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardBorder))
                .disabled(symbol == nil)
                .onSubmit { send(symbol) }
            Button {
                send(symbol)
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(canSend(symbol) ? Theme.purple : Theme.textDim)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.inset))
            }
            .buttonStyle(.plain)
            .disabled(!canSend(symbol))
            .help("Send — this lane's mentor answers right here in the cell")
        }
    }

    private func draftBinding(_ symbol: String?) -> Binding<String> {
        Binding(
            get: { symbol.flatMap { drafts[$0] } ?? "" },
            set: { newValue in
                guard let symbol else { return }
                drafts[symbol] = newValue
            }
        )
    }

    private func canSend(_ symbol: String?) -> Bool {
        guard let symbol else { return false }
        let text = (drafts[symbol] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && !store.laneMentorBusy.contains(symbol)
    }

    private func send(_ symbol: String?) {
        guard let symbol else { return }
        let text = (drafts[symbol] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.sendLaneComment(symbol: symbol, text: text)
        drafts[symbol] = ""
    }

    // MARK: - Display helpers

    /// Header cosmetics ONLY — strips the TradingView exchange prefix so the
    /// grid header reads "XAUUSD" not "FOREXCOM:XAUUSD". `result.symbol`
    /// itself (the real data key — laneUpdates, scanResults, instrument
    /// detection, etc.) is never touched; this never leaves the label.
    private func displaySymbol(_ raw: String) -> String {
        for prefix in ["FOREXCOM:", "CME_MINI:", "CME:"] where raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }
        return raw
    }

    /// amber = WAITING, green/purple = SIGNAL (side from a plain BUY/SELL
    /// substring check on the opaque HUD text mirror), gray = no read yet.
    /// "SIGNAL"/"WAITING" match the exact substrings SessionStore's own
    /// WAITING->SIGNAL mentor trigger already keys off of.
    private func stateColor(_ result: ScanResult?) -> Color {
        guard let result, !result.hudLines.isEmpty else { return Theme.textDim.opacity(0.4) }
        let text = result.hudLines.joined(separator: "\n")
        if text.contains("SIGNAL") {
            if text.contains("SELL") { return Theme.purple }
            return Theme.green
        }
        if text.contains("WAITING") { return Theme.amber }
        return Theme.textDim.opacity(0.4)
    }

    // MARK: - Actions

    private func logEntry(_ result: ScanResult) {
        // Best-effort: pane symbols line up with the Instrument enum for the
        // futures roots it knows (MNQ1! -> .MNQ, MES1! -> .MES, MBT1! ->
        // .MBT). Forex/CFD panes (XAUUSD, NAS100, USDCAD) have no Instrument
        // case yet, so this resolves nil — the composer just lands on
        // "session default" for those instead of preselecting.
        store.pendingComposerInstrument = Instrument.detect(fromFilename: result.symbol)
        // Empty hudLines means no HUD read yet on this pane — leave the
        // hand-off nil rather than capturing an empty string, so the
        // composer's "SIGNAL CONTEXT CAPTURED" indicator only lights up
        // when there's actually something captured.
        store.pendingComposerContext = result.hudLines.isEmpty
            ? nil : result.hudLines.joined(separator: "\n")
        openComposer()
    }
}
