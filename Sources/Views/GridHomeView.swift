import SwiftUI

/// GRID — the app's default home screen: a fixed 2-row x 3-column mirror of
/// the user's real 6-pane TradingView layout. `ScanResult.index` (0-5, the
/// same 0-based index `tv pane list` reports) maps DIRECTLY to grid position
/// in standard reading order — row = index/3, col = index%3 — because
/// that's how TradingView's own 6-chart grid numbers its panes: top row
/// left-to-right is 0,1,2, bottom row left-to-right is 3,4,5.
///
/// One "Refresh All" sweep (manual here, or automatic every 15 minutes ET
/// regardless of session state — see SessionStore.checkLaneAutoRefresh) still
/// focuses each pane in turn and reads its levels + SKULD dashboard exactly
/// like the Pane Scanner always did; on top of that, each pane's HUD read
/// auto-logs what changed into that symbol's own thread (deduped per launch
/// so identical back-to-back reads don't spam it), and a WAITING->SIGNAL
/// transition wakes that lane's own mentor. Every lane also has its own
/// persistent conversation — reachable via each cell's "Thread" drill-down
/// so the 6-up grid itself stays dense and glanceable rather than showing a
/// full scrolling thread in all six cells at once. HUD lines stay a plain
/// read-only mirror of whatever the indicator's table currently draws —
/// never re-parsed into typed fields, so a HUD layout change in the .pine
/// can never silently break this view.
struct GridHomeView: View {
    @EnvironmentObject private var store: SessionStore
    /// Fired by "Log entry ->" after it preselects the composer's instrument
    /// — the parent (ContentView) uses this to flip its home-mode pill over
    /// to FEED so the preselected composer is actually visible.
    let openComposer: () -> Void

    @State private var laneDetailSymbol: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.cardBorder)
            grid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .foregroundColor(Theme.text)
        .sheet(isPresented: laneDetailBinding) {
            if let symbol = laneDetailSymbol {
                LaneDetailSheet(symbol: symbol)
            }
        }
    }

    private var laneDetailBinding: Binding<Bool> {
        Binding(get: { laneDetailSymbol != nil }, set: { if !$0 { laneDetailSymbol = nil } })
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
                Text("6 panes, 6 threads")
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
                .help("Focuses each pane in turn and reads its levels + SKULD dashboard — 20-40s for six panes")
            }
            Text("Auto-refreshes every 15 minutes ET — Refresh All forces one now.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Fixed 2x3 grid

    /// slots[i] = the last scan result for pane index i, or nil if that pane
    /// hasn't been read yet this launch. Always exactly 6 slots in this
    /// fixed order — two HStacks of three inside a VStack, never an
    /// adaptive/reflowing grid, so the shape can't change at any window
    /// width the way a LazyVGrid(.adaptive) could.
    private var slots: [ScanResult?] {
        var arr: [ScanResult?] = Array(repeating: nil, count: 6)
        for result in store.scanResults where (0..<6).contains(result.index) {
            arr[result.index] = result
        }
        return arr
    }

    private var grid: some View {
        let s = slots
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                cell(s[0], index: 0)   // T1 — top left
                cell(s[1], index: 1)   // T2 — top middle
                cell(s[2], index: 2)   // T3 — top right
            }
            HStack(spacing: 10) {
                cell(s[3], index: 3)   // B1 — bottom left
                cell(s[4], index: 4)   // B2 — bottom middle
                cell(s[5], index: 5)   // B3 — bottom right
            }
        }
        .padding(16)
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

            Divider().overlay(Theme.cardBorder)
            latestUpdateLine(result?.symbol)

            HStack(spacing: 8) {
                if let result {
                    Button("Log entry →") { logEntry(result) }
                        .buttonStyle(PillButton(color: Theme.green))
                }
                Spacer(minLength: 4)
                Button {
                    if let symbol = result?.symbol { laneDetailSymbol = symbol }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 10))
                        Text("Thread")
                    }
                }
                .buttonStyle(PillButton(color: Theme.purple))
                .disabled(result == nil)
                .help("Full conversation with this lane's mentor")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.purple.opacity(0.35), lineWidth: 1))
    }

    /// The full `hudLines` mirror, unsummarized — wrapped in its own
    /// ScrollView so a HUD dashboard longer than the cell's height scrolls
    /// in place instead of getting clipped or truncated. Typical HUD content
    /// fits without scrolling, matching the "glanceable, no scrolling by
    /// default" goal.
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
            .frame(maxHeight: .infinity)
        } else {
            Text(result == nil
                 ? "no read yet — Refresh All to scan this pane"
                 : "no dashboard read — SKULD may not be visible on this pane")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Only the single most recent thread entry — the full history is one
    /// "Thread" tap away. Keeps the default cell dense.
    @ViewBuilder
    private func latestUpdateLine(_ symbol: String?) -> some View {
        let latest = symbol.flatMap { store.laneUpdates[$0]?.last }
        if let latest {
            Text(latest.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text("no lane activity yet")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim.opacity(0.6))
        }
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
        openComposer()
    }
}

// MARK: - Lane detail sheet (full thread + compose, one symbol)

/// Drill-down from a cell's "Thread" button — the full per-symbol mentor
/// conversation the old Lanes sheet used to show inline in every card, now
/// on-demand so the 6-up grid itself stays dense. Same visual language as
/// FeedView's mentor block: dim italic-weight system/HUD text, a purple
/// "MENTOR" caption over mentor replies, plain text for the trader's own
/// lines — same Theme tokens, no new style.
private struct LaneDetailSheet: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let symbol: String
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.cardBorder)
            thread
            Divider().overlay(Theme.cardBorder)
            composer
        }
        .frame(width: 520, height: 560)
        .background(Theme.bg)
        .foregroundColor(Theme.text)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.cyan).frame(width: 7, height: 7)
            Text(symbol)
                .font(Theme.mono.weight(.bold))
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(PillButton(color: Theme.textDim))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var thread: some View {
        let updates = store.laneUpdates[symbol] ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if updates.isEmpty {
                    Text("no lane activity yet")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                } else {
                    ForEach(updates) { update in
                        row(update)
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
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ update: LaneUpdateRecord) -> some View {
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

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Talk to this lane…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardBorder))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(canSend ? Theme.purple : Theme.textDim)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.inset))
            }
            .buttonStyle(.plain)
            .disabled(!canSend || store.laneMentorBusy.contains(symbol))
            .help("Send — this lane's mentor answers in its own thread")
        }
        .padding(12)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.sendLaneComment(symbol: symbol, text: text)
        draft = ""
    }
}
