import SwiftUI

/// PANE SCANNER — reads every pane in the live TradingView multi-chart
/// layout at once (vs. the single active-chart 5-minute auto-sync), so all
/// six symbols' live state sit in one place. "Scan All" focuses each pane in
/// turn and pulls its levels + SKULD dashboard; levels merge into the
/// session automatically, tagged per pane. HUD lines are a plain read-only
/// mirror of whatever the indicator's table currently draws — never
/// re-parsed into typed fields, so a HUD layout change in the .pine can
/// never silently break this view.
struct ScannerView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.cardBorder)
            content
        }
        .frame(width: 720, height: 640)
        .background(Theme.bg)
        .foregroundColor(Theme.text)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.grid.2x2")
                .font(.system(size: 12))
                .foregroundColor(Theme.purple)
            Text("PANE SCANNER")
                .font(Theme.mono.weight(.bold))
                .kerning(1.5)
            Text("all panes, one pull")
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
            Text("Focuses every pane in your TradingView multi-chart layout in turn and reads its levels and SKULD dashboard.")
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
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.purple.opacity(0.35), lineWidth: 1))
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
