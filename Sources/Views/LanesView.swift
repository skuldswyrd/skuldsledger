import SwiftUI

/// LANES — six persistent, per-pane threads built on top of the pane scan.
/// One "Scan All" sweep (manual here, or automatic every 15 minutes ET while
/// a session is open — see SessionStore.checkLaneAutoRefresh) still focuses
/// each pane in turn and reads its levels + SKULD dashboard exactly like the
/// Pane Scanner always did; on top of that, each pane's HUD read now
/// auto-logs what changed into that symbol's own thread (deduped per launch
/// so identical back-to-back reads don't spam it), and a WAITING->SIGNAL
/// transition wakes that lane's own mentor. Every lane also has its own
/// composer — talk to a symbol like it's a dedicated chat thread that
/// persists across days. HUD lines stay a plain read-only mirror of
/// whatever the indicator's table currently draws — never re-parsed into
/// typed fields, so a HUD layout change in the .pine can never silently
/// break this view.
struct LanesView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftText: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.cardBorder)
            content
        }
        .frame(width: 760, height: 680)
        .background(Theme.bg)
        .foregroundColor(Theme.text)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.purple)
                Text("LANES")
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
                            Text("Scanning…")
                        }
                    } else {
                        Text("Scan All")
                    }
                }
                .buttonStyle(PillButton(color: Theme.green, filled: true))
                .disabled(store.scanBusy)
                .help("Focuses each pane in turn and reads its levels + SKULD dashboard — 20-40s for six panes")
                Button("Close") { dismiss() }
                    .buttonStyle(PillButton(color: Theme.textDim))
                    .keyboardShortcut(.cancelAction)
            }
            Text("Auto-refreshes every 15 minutes ET while a session is open — Scan All forces one now.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.scanResults.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.scanResults, id: \.index) { result in
                        card(result)
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Circle().fill(Theme.textDim).frame(width: 6, height: 6)
            Text("No scan yet — tap Scan All")
                .font(Theme.mono)
                .foregroundStyle(Theme.textDim)
            Text("Focuses every pane in your TradingView multi-chart layout in turn, reads its levels and SKULD dashboard, and opens that symbol's own lane thread below.")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Card

    private func card(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Theme.cyan).frame(width: 6, height: 6)
                Text(result.symbol)
                    .font(Theme.mono.weight(.semibold))
                    .foregroundStyle(Theme.text)
                if let res = result.resolution, !res.isEmpty {
                    Text(res)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 8)
                if !result.levels.isEmpty {
                    Text("\(result.levels.count) levels")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                }
                Button {
                    logEntry(result)
                } label: {
                    Text("Log entry →")
                }
                .buttonStyle(PillButton(color: Theme.green))
                .help("Preselects \(result.symbol) in the composer and jumps there")
            }

            if result.hudLines.isEmpty {
                Text("no dashboard read — SKULD may not be visible on this pane")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(result.hudLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }

            Divider().overlay(Theme.cardBorder)
            laneThread(result.symbol)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.purple.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Lane thread (persistent per-symbol mentor conversation)

    /// Visual language matches FeedView's mentor block: dim italic-weight
    /// system/HUD text, a purple "MENTOR" caption over mentor replies, plain
    /// text for the trader's own lines — same Theme tokens, no new style.
    @ViewBuilder
    private func laneThread(_ symbol: String) -> some View {
        let thread = store.laneUpdates[symbol] ?? []
        let busy = store.laneMentorBusy.contains(symbol)

        VStack(alignment: .leading, spacing: 6) {
            if thread.isEmpty && !busy {
                Text("no lane activity yet")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(thread) { update in
                            laneUpdateRow(update)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            if busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("mentor thinking…")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
            }
            laneComposer(symbol)
        }
    }

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

    private func laneComposer(_ symbol: String) -> some View {
        HStack(spacing: 8) {
            TextField("Talk to this lane…", text: draftBinding(symbol))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardBorder))
                .onSubmit { send(symbol) }
            Button {
                send(symbol)
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(canSend(symbol) ? Theme.purple : Theme.textDim)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.inset))
            }
            .buttonStyle(.plain)
            .disabled(!canSend(symbol) || store.laneMentorBusy.contains(symbol))
            .help("Send — that lane's mentor answers in its own thread")
        }
    }

    private func draftBinding(_ symbol: String) -> Binding<String> {
        Binding(
            get: { draftText[symbol] ?? "" },
            set: { draftText[symbol] = $0 })
    }

    private func canSend(_ symbol: String) -> Bool {
        !(draftText[symbol] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ symbol: String) {
        let text = (draftText[symbol] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.sendLaneComment(symbol: symbol, text: text)
        draftText[symbol] = ""
    }

    // MARK: - Actions

    private func logEntry(_ result: ScanResult) {
        // Best-effort: pane symbols line up with the Instrument enum for the
        // futures roots it knows (MNQ1! -> .MNQ, MES1! -> .MES, MBT1! ->
        // .MBT). Forex/CFD panes (XAUUSD, NAS100, USDCAD) have no Instrument
        // case yet, so this resolves nil — the composer just lands on
        // "session default" for those instead of preselecting.
        store.pendingComposerInstrument = Instrument.detect(fromFilename: result.symbol)
        dismiss()
    }
}
