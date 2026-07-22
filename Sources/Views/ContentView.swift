import SwiftUI

/// Root shell. Three states:
///  1. fatal DB error  -> blocking panel (nothing else works without the journal)
///  2. no session yet  -> SetupView (pre-market)
///  3. live session    -> banners + FeedView | StatsSidebarView, toolbar actions
struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var confirmEndSession = false
    @State private var showUpgradeLog = false
    @State private var confirmUpdate = false
    @State private var showSettings = false
    @State private var showSettleDay = false
    @State private var showAnalytics = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .alert("Skuld's Ledger", isPresented: errorPresented) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .sheet(isPresented: $showUpgradeLog) {
                UpgradeLogView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showSettleDay) {
                SettleDaySheet()
            }
            .sheet(isPresented: $showAnalytics) {
                AnalyticsView()
            }
            .toolbar {
                // Always visible — pre-session setup included: edition badge
                // and the TradingView tie live here.
                ToolbarItem(placement: .navigation) {
                    Text("LEDGER v\(AppVersion.string)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.purple)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.purple.opacity(0.12)))
                        .overlay(Capsule().stroke(Theme.purple.opacity(0.5), lineWidth: 1))
                        .help("Skuld's Ledger v\(AppVersion.string)")
                }
                ToolbarItem(placement: .navigation) {
                    TVStatusControl()
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showAnalytics = true
                    } label: {
                        Label("Analytics", systemImage: "chart.bar.xaxis")
                    }
                    .help("Trader profile — lifetime KPIs, Sharpe, streaks, cross filters")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Pace baseline, daily target, max loss, default instrument")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showUpgradeLog = true
                    } label: {
                        Label("Log", systemImage: "square.and.pencil")
                    }
                    .help("Upgrade / error log — jot it now, paste to Claude later")
                }
                if let behind = store.updateBehind {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            confirmUpdate = true
                        } label: {
                            HStack(spacing: 4) {
                                Circle().fill(Theme.amber).frame(width: 6, height: 6)
                                Text("Update (\(behind))")
                            }
                        }
                        .help("New Skuld's Ledger version on GitHub — pulls, rebuilds, relaunches. Your data never moves.")
                    }
                }
            }
            .confirmationDialog(
                "Install update?",
                isPresented: $confirmUpdate,
                titleVisibility: .visible
            ) {
                Button("Update & Relaunch") { store.installUpdate() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pulls the latest code from GitHub, rebuilds, and relaunches. Journal data is untouched.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let fatal = store.fatalError {
            FatalErrorPanel(message: fatal)
        } else if store.session == nil {
            SetupView()
        } else {
            sessionShell
        }
    }

    /// errorMessage is a settable @Published on the store; clearing on dismiss
    /// keeps the alert single-shot without extra local state.
    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { presented in if !presented { store.errorMessage = nil } }
        )
    }

    // MARK: - Live session layout

    @ViewBuilder
    private var sessionShell: some View {
        VStack(spacing: 0) {
            // Lunch = informational only (he trades all sessions, all day):
            // a dim one-liner, never amber, never a block.
            if store.isLunchBlackout {
                LunchBanner(
                    text: "lunch \(Self.hhmm(store.plan.lunchStartMin))–\(Self.hhmm(store.plan.lunchEndMin)) ET — thinner liquidity")
            }
            // The only red state up here: daily max loss breached (when the
            // user defined one). Display only — nothing auto-flattens.
            if let maxLoss = store.plan.dailyMaxLossUsd, store.stats.netUsd <= -maxLoss {
                SessionBanner(
                    text: "MAX LOSS HIT — \(Self.usd(-store.stats.netUsd)) down. Plan says flat.",
                    color: Theme.red)
            }
            HStack(spacing: 0) {
                FeedView()
                    .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                    .overlay(Theme.cardBorder)
                StatsSidebarView()
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
            }
        }
        .toolbar { sessionToolbar }
        .confirmationDialog(
            "End today's session?",
            isPresented: $confirmEndSession,
            titleVisibility: .visible
        ) {
            Button("End Session", role: .destructive) { store.endSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marks the session done. Entries are kept — generate the report any time.")
        }
    }

    @ToolbarContentBuilder
    private var sessionToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.session?.status == "open" ? Theme.green : Theme.textDim)
                    .frame(width: 8, height: 8)
                Text("\(store.session?.instrument ?? "?")  \(store.session?.date ?? "")")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.syncLevelsFromChart(manual: true)
            } label: {
                if store.levelSyncBusy {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Syncing…")
                    }
                } else {
                    Text("Sync Levels")
                }
            }
            .disabled(store.levelSyncBusy)
            .help(syncHelp)
            Button("Rescan Inbox") { store.rescanInbox() }
                .help("Re-scan today's inbox for new screenshots (⇧⌘R)")
            Button("Settle Day") { showSettleDay = true }
                .help("Paste TradingView's account history — real fills become journal truth")
            Button("Generate Report") { store.generateReport() }
                .help("Write today's session report to Reports/ (⇧⌘E)")
            Button("End Session") { confirmEndSession = true }
                .help("Mark today's session done")
        }
    }

    private var syncHelp: String {
        if let last = store.lastLevelSync {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            fmt.timeZone = Workspace.eastern
            return "Pull ★ clusters off the live chart (auto every 5 min · last \(fmt.string(from: last)) ET)"
        }
        return "Pull ★ clusters off the live chart (auto every 5 min)"
    }

    private static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private static func usd(_ value: Double) -> String {
        String(format: "$%.0f", max(0, value))
    }
}

// MARK: - TradingView tie (status + safe open)

/// Tri-state TV indicator + the one-click safe path to a bridged TradingView.
///  cyan  = bridge live (level pull on)
///  blue  = TV running without the bridge (screenshots fine; user restarts
///          TV when convenient — Ledger NEVER touches a running chart)
///  dim   = TV closed -> button opens it WITH the bridge flag
private struct TVStatusControl: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Button {
            store.openTradingView()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(textColor)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.inset))
            .overlay(Capsule().stroke(dotColor.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(store.tvStatus == .bridge)
        .help(helpText)
    }

    private var dotColor: Color {
        switch store.tvStatus {
        case .bridge: return Theme.cyan
        case .filesOnly: return Theme.blue
        case .closed: return Theme.textDim.opacity(0.5)
        }
    }

    private var textColor: Color {
        switch store.tvStatus {
        case .bridge: return Theme.cyan
        case .filesOnly: return Theme.blue
        case .closed: return Theme.textDim
        }
    }

    private var label: String {
        switch store.tvStatus {
        case .bridge: return "TV LIVE"
        case .filesOnly: return "TV"
        case .closed: return "OPEN TV"
        }
    }

    private var helpText: String {
        switch store.tvStatus {
        case .bridge:
            return "TradingView bridge live — levels sync straight off the chart"
        case .filesOnly:
            return "TradingView running without the bridge — screenshots work fine. Click for the safe way to enable level pull (never auto-restarts your chart)."
        case .closed:
            return "Open TradingView with the bridge on — one click, connected"
        }
    }
}

// MARK: - Banner strips (red max-loss / dim lunch)

private struct SessionBanner: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(Theme.monoSmall.weight(.semibold))
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(color.opacity(0.35))
        }
    }
}

/// Dim, tiny, neutral — lunch is context, not a warning.
private struct LunchBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.textDim.opacity(0.6))
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Theme.card)
        .overlay(alignment: .bottom) {
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Theme.cardBorder)
        }
    }
}

// MARK: - Fatal DB error panel

private struct FatalErrorPanel: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(Theme.red)
                .frame(width: 14, height: 14)
            Text("JOURNAL OFFLINE")
                .font(Theme.mono.weight(.bold))
                .foregroundStyle(Theme.red)
            Text(message)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Text(Workspace.databaseURL.path)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
                .textSelection(.enabled)
            Text("Fix the database file (or move it aside) and relaunch.")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
