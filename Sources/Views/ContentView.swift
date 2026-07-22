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
            .toolbar {
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
            if store.isLunchBlackout {
                SessionBanner(
                    text: "LUNCH \(Self.hhmm(store.plan.lunchStartMin))–\(Self.hhmm(store.plan.lunchEndMin)) ET — no new signals per plan",
                    color: Theme.amber)
            }
            if store.tradesRemaining == 0 {
                SessionBanner(
                    text: "\(store.stats.tradesTaken)/\(store.stats.maxTrades) DONE — plan says stop",
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
                HStack(spacing: 4) {
                    Circle()
                        .fill(store.tvConnected ? Theme.cyan : Theme.textDim.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text("TV")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(store.tvConnected ? Theme.cyan : Theme.textDim)
                }
                .help(store.tvConnected
                    ? "TradingView bridge live — levels sync off the chart"
                    : "TradingView bridge down — run `tv launch` in Terminal")
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
}

// MARK: - Banner strip (amber lunch / red done)

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
