import SwiftUI

/// Root shell. Two states:
///  1. fatal DB error  -> blocking panel (nothing else works without the journal)
///  2. otherwise       -> GRID, unconditionally. FEED (the old composer+feed
///                        session shell) is gone as a destination; its real
///                        capabilities — Log Entry, Generate Report, Settle
///                        Day, Stats, Rescan Inbox, End Session — now live as
///                        toolbar entry points below, same pattern as the
///                        existing Blog/Analytics/Settings buttons.
struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var showComposer = false
    @State private var showStats = false
    @State private var confirmEndSession = false
    @State private var showUpgradeLog = false
    @State private var confirmUpdate = false
    @State private var showSettings = false
    @State private var showSettleDay = false
    @State private var showAnalytics = false
    @State private var showBlog = false
    @State private var showNewSession = false
    @State private var newSessionName = ""
    @State private var newSessionInstrument: Instrument = .NQ

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            // errors are a TOAST now, never a modal — a modal error landing
            // on top of a confirmation dialog could deadlock the whole UI
            // (the end-session freeze). Toast can't block anything.
            .overlay(alignment: .top) {
                if let msg = store.errorMessage {
                    ErrorToast(message: msg) { store.errorMessage = nil }
                }
            }
            .sheet(isPresented: $showNewSession) {
                NewSessionSheet(
                    name: $newSessionName,
                    instrument: $newSessionInstrument
                ) {
                    store.createNamedSession(name: newSessionName, instrument: newSessionInstrument)
                    newSessionName = ""
                }
            }
            .sheet(isPresented: $showComposer) {
                ComposerSheet()
            }
            .sheet(isPresented: $showStats) {
                StatsSheet()
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
            .sheet(isPresented: $showBlog) {
                BlogView()
            }
            .toolbar {
                navigationToolbar
                sessionActionsToolbar
                utilityToolbar
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

    @ViewBuilder
    private var content: some View {
        if let fatal = store.fatalError {
            FatalErrorPanel(message: fatal)
        } else {
            // GRID, unconditionally — the only home screen now.
            GridHomeView(openComposer: { showComposer = true })
        }
    }

    // MARK: - Toolbar (split into separate @ToolbarContentBuilder vars —
    // one giant inline `.toolbar { }` closure made the compiler's whole-
    // expression type-check for `body` time out once this round added the
    // five relocated session-action buttons; splitting it the same way the
    // old FEED-only `sessionToolbar` already did keeps each chunk small
    // enough to infer quickly)

    /// Always visible — session browser, edition badge, TradingView tie.
    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // pick any session, jump to today, start a named workspace
            // ("LEAP tournament"), reopen a closed one
            Menu {
                Button("Today (\(store.todayDate))") { store.selectToday() }
                Divider()
                ForEach(store.allSessions.prefix(15)) { s in
                    Button {
                        store.selectSession(id: s.id)
                    } label: {
                        Text(sessionMenuTitle(s, net: store.sessionNets[s.id] ?? 0))
                    }
                }
                Divider()
                Button("New named session…") { showNewSession = true }
                if store.session?.status == "done" {
                    Button("Reopen this session") {
                        if let id = store.session?.id { store.reopenSession(id: id) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.session?.status == "open" ? Theme.green : Theme.textDim)
                        .frame(width: 8, height: 8)
                    Text(sessionTitle)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.text)
                    if store.pinnedSessionId != nil {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.amber)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sessions — switch, reopen, or start a named workspace")
        }
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
    }

    /// Relocated from the old FEED-only `sessionToolbar` — same store
    /// calls, same confirm-dialog/sheet plumbing, just reachable from
    /// anywhere now that GRID is the only screen.
    @ToolbarContentBuilder
    private var sessionActionsToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button {
                store.rescanInbox()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Re-scan today's inbox for new screenshots (⇧⌘R)")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                showStats = true
            } label: {
                Label("Stats", systemImage: "chart.bar")
            }
            .help("Live session stats — discipline, P&L, star-rank hit rate, levels")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                showSettleDay = true
            } label: {
                Label("Settle Day", systemImage: "checkmark.seal")
            }
            .help("Paste TradingView's account history — real fills become journal truth")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                store.generateReport()
            } label: {
                Label("Report", systemImage: "doc.text")
            }
            .help("Write today's session report to Reports/ (⇧⌘E)")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                confirmEndSession = true
            } label: {
                Label("End Session", systemImage: "stop.circle")
            }
            .help("Mark today's session done")
        }
    }

    /// App-wide utilities — unchanged from before this round.
    @ToolbarContentBuilder
    private var utilityToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button {
                showBlog = true
            } label: {
                Label("Blog", systemImage: "text.book.closed")
            }
            .help("Skuldswyrd Online Edition — write posts while trading, pull session notes, export markdown")
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

    private var sessionTitle: String {
        guard let s = store.session else { return "—" }
        if let name = s.name, !name.isEmpty {
            return "\(name) · \(s.instrument)"
        }
        return "\(s.instrument)  \(s.date)"
    }

    /// Plain-function string build (not inline in the ViewBuilder) — the
    /// nested ternaries inline inside the Menu's label closure pushed whole-
    /// expression type inference for `body` over the timeout once the
    /// toolbar grew the extra relocated buttons in this round.
    private func sessionMenuTitle(_ s: SessionRecord, net: Double) -> String {
        let closedSuffix = s.status == "done" ? " ·closed" : ""
        let netSuffix: String
        if net != 0 {
            netSuffix = String(format: " · %@$%.0f", net < 0 ? "-" : "+", abs(net))
        } else {
            netSuffix = ""
        }
        return "\(s.displayTitle)\(closedSuffix)\(netSuffix)"
    }
}

// MARK: - Log Entry sheet (wraps the unmodified FeedView as a modal)

/// "Log entry ->" on a grid cell is the only way into the composer now that
/// FEED isn't a permanent destination. FeedView.swift itself — composer +
/// entry history — is untouched; this is just a title bar + Close button
/// around it, same idea as AnalyticsView/BlogView presenting themselves as
/// self-contained sheets.
private struct ComposerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.cardBorder)
            FeedView()
        }
        .frame(width: 720, height: 760)
        .background(Theme.bg)
        .foregroundColor(Theme.text)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12))
                .foregroundColor(Theme.green)
            Text("LOG ENTRY")
                .font(Theme.mono)
                .kerning(1.5)
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(PillButton(color: Theme.textDim))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Stats sheet (wraps the unmodified StatsSidebarView as a modal)

/// StatsSidebarView used to sit permanently next to FeedView; now it's its
/// own toolbar-triggered popover in a fixed-width container, same idea as
/// AnalyticsView/BlogView. StatsSidebarView.swift itself is untouched.
private struct StatsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.cardBorder)
            StatsSidebarView()
        }
        .frame(width: 380, height: 680)
        .background(Theme.bg)
        .foregroundColor(Theme.text)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar")
                .font(.system(size: 12))
                .foregroundColor(Theme.purple)
            Text("STATS")
                .font(Theme.mono)
                .kerning(1.5)
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(PillButton(color: Theme.textDim))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Session Hub (the home screen — CRUD-simple)

/// Where the app lands with no active session: today's action up top, every
/// session below as a clickable card. End Session brings you here.
private struct SessionHubView: View {
    @EnvironmentObject private var store: SessionStore
    let newNamed: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SESSIONS")
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .foregroundStyle(Theme.text)
                        .kerning(2)
                    Text("Pick one, reopen one, or start fresh. Everything is kept.")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }

                HStack(spacing: 10) {
                    Button {
                        store.composingSession = true
                    } label: {
                        Label("Start today's session", systemImage: "sunrise")
                            .font(Theme.mono)
                            .foregroundStyle(Theme.bg)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Theme.green))
                    }
                    .buttonStyle(.plain)
                    Button {
                        newNamed()
                    } label: {
                        Label("New named session", systemImage: "folder.badge.plus")
                            .font(Theme.mono)
                            .foregroundStyle(Theme.purple)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Theme.purple.opacity(0.12)))
                            .overlay(Capsule().stroke(Theme.purple.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .help("A dedicated workspace — e.g. LEAP tournament")
                }

                if store.allSessions.isEmpty {
                    Text("No sessions yet — start today's and post the first chart.")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                        .padding(.top, 20)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                        ForEach(store.allSessions) { s in
                            SessionCard(
                                session: s,
                                net: store.sessionNets[s.id] ?? 0
                            ) {
                                store.selectSession(id: s.id)
                            } reopen: {
                                store.reopenSession(id: s.id)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
    }
}

private struct SessionCard: View {
    let session: SessionRecord
    let net: Double
    let open: () -> Void
    let reopen: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(session.status == "open" ? Theme.green : Theme.textDim)
                        .frame(width: 7, height: 7)
                    Text(session.name ?? session.instrument)
                        .font(Theme.mono.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(session.status == "open" ? "LIVE" : "CLOSED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(session.status == "open" ? Theme.green : Theme.textDim)
                }
                HStack(spacing: 8) {
                    Text(session.date)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                    Text(session.instrument)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.cyan)
                    Spacer(minLength: 4)
                    Text((net < 0 ? "-$" : "+$") + String(format: "%.0f", abs(net)))
                        .font(Theme.monoSmall.weight(.semibold))
                        .foregroundStyle(net > 0 ? Theme.green : (net < 0 ? Theme.red : Theme.textDim))
                }
                if session.status == "done" {
                    Button("Reopen") { reopen() }
                        .buttonStyle(.plain)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.amber)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Error toast (non-modal by design — modals can deadlock over dialogs)

private struct ErrorToast: View {
    let message: String
    let dismiss: () -> Void
    @State private var ticking = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.amber).frame(width: 7, height: 7)
            Text(message)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.text)
                .lineLimit(3)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.amber.opacity(0.5)))
        )
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            guard !ticking else { return }
            ticking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { dismiss() }
        }
    }
}

// MARK: - New named session sheet

private struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    @Binding var instrument: Instrument
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NEW NAMED SESSION")
                .font(Theme.mono)
                .foregroundStyle(Theme.text)
            Text("A dedicated workspace — every post, trade and mentor thread for one effort (a tournament, an experiment) lives in it. Reopen it any day from the session menu.")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name — e.g. LEAP tournament", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.mono)
                .foregroundStyle(Theme.text)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardBorder))
            Picker("Instrument", selection: $instrument) {
                ForEach(Instrument.allCases) { inst in
                    Text(inst.rawValue).tag(inst)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    create()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(Theme.bg)
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
