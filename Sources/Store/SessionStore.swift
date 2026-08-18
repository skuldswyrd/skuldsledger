import Foundation
import SwiftUI

/// What the composer submits. Screenshot is optional — entries between
/// screenshots are legal; multiple pending shots queue until picked.
struct EntryDraft {
    var screenshot: URL?
    /// Auto-detected from the screenshot filename; user can override in the
    /// composer. nil = session default.
    var instrument: Instrument?
    var comment: String = ""
    var lookingFor: String = ""
    var wantToSee: String = ""
    var action: EntryAction = .wait
    var playType: PlayType?
    var levelId: String?
    // Chop details, only read when action == .chop
    var chopHigh: Double?
    var chopLow: Double?
    var chopCrossings: Int?
}

struct TradeForm {
    var playType: PlayType = .MR
    var levelId: String?
    var contracts: Int = 1
    var entryPrice: Double?
    var stopPrice: Double?
    var targetPrice: Double?
    var instrument: Instrument?      // nil = entry's, then session's
    var side: String?                // "long" / "short" from the sheet's chips
}

/// What a Settle Day import did — shown in the sheet after confirm.
struct TVImportSummary {
    var created = 0
    var matched = 0
    var duplicates = 0
    var phantoms = 0
    /// Distinct session days the import touched (multi-day pastes backfill).
    var days = 0
}

struct LevelDraft: Identifiable {
    var id = UUID()
    var name: String = ""
    var price: String = ""
    var stars: Int = 3
    var rankScore: String = ""
    var notes: String = ""
}

/// Central hub. All mutations flow through here; every write recomputes stats.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var plan: TradingPlan = TradingPlan()
    @Published private(set) var session: SessionRecord?
    @Published private(set) var levels: [LevelRecord] = []
    @Published private(set) var entries: [EntryRecord] = []
    @Published private(set) var trades: [TradeRecord] = []
    @Published private(set) var chops: [ChopRecord] = []
    /// entryId -> thread, oldest first.
    @Published private(set) var comments: [String: [CommentRecord]] = [:]
    @Published private(set) var settings: UserSettings = UserSettings()
    @Published private(set) var pendingScreenshots: [URL] = []
    @Published private(set) var stats: SessionStats = .empty
    /// Session browser: every session, newest first, with net badges.
    @Published private(set) var allSessions: [SessionRecord] = []
    /// Blog posts (all of them — the blog spans sessions), newest touch first.
    @Published private(set) var blogPosts: [BlogPostRecord] = []
    @Published private(set) var sessionNets: [String: Double] = [:]
    /// Non-nil = the user is working INSIDE a picked session (maybe a past
    /// day, maybe a named workspace) — day rollover must not yank them out.
    @Published private(set) var pinnedSessionId: String?
    /// True while the setup screen is composing a new session (Hub -> Setup).
    @Published var composingSession = false
    /// Entry ids with a mentor call in flight ("thinking..." on the card).
    @Published private(set) var mentorBusy: Set<String> = []
    /// Latest pre-trade EDGE CHECK verdict (GO/WAIT/NO + reason), shown in
    /// the composer strip. nil = none yet.
    @Published var preCheckReply: String?
    /// True while a pre-trade edge check is in flight.
    @Published var preCheckBusy: Bool = false
    @Published var errorMessage: String? {
        didSet {
            // Every surfaced app error also lands in the upgrade log —
            // paste-ready context for the next patch round. Bridge-state
            // messages ("TV bridge: …") stay OUT: the status dot already
            // shows them and logging every blip buried real bugs.
            if let msg = errorMessage, msg != oldValue, !msg.hasPrefix("TV bridge") {
                UpgradeLog.append(note: msg, type: "APP-ERROR")
            }
        }
    }
    @Published private(set) var lastReportURL: URL?
    /// Non-nil when the DB could not open — app shows a blocking error screen.
    @Published private(set) var fatalError: String?
    @Published private(set) var mentorAvailable: Bool = true
    /// TradingView connection, three rungs: bridge (CDP live) / filesOnly
    /// (TV up without the debug flag) / closed. Screenshots + mentor work in
    /// every state — this only gates the optional live-chart level pull.
    @Published private(set) var tvStatus: TVStatus = .closed
    /// Legacy convenience — true only when the CDP bridge answers.
    var tvConnected: Bool { tvStatus == .bridge }
    @Published private(set) var lastLevelSync: Date?
    @Published private(set) var levelSyncBusy: Bool = false
    /// Latest "Scan All" sweep of every pane in the live multi-chart layout —
    /// the Scanner sheet's source of truth. Levels from it also merge into
    /// `levels` (tagged per pane); this array is the raw per-pane snapshot.
    @Published private(set) var scanResults: [ScanResult] = []
    @Published private(set) var scanBusy: Bool = false
    /// Set by the Scanner sheet's "Log entry →" — the composer preselects
    /// its instrument from this on appear, then clears it back to nil.
    @Published var pendingComposerInstrument: Instrument?
    /// Commits behind origin/main; nil = up to date or unknown.
    @Published private(set) var updateBehind: Int?

    private var db: AppDatabase?
    private var watchers: [InboxWatcher] = []
    private var mentor: MentorService?
    private let levelSync = LevelSyncService()
    private var levelSyncTimer: Timer?
    private var dayCheckTimer: Timer?

    @Published private(set) var todayDate: String = Workspace.todayString()

    /// Source paths (outside the day inbox) already journaled — screenshots in
    /// the shared TradingView folder are copied, not moved, so without this
    /// they would re-queue on every launch.
    private var consumedSourcePaths: Set<String> = []
    private static let consumedDefaultsKey = "consumedInboxPaths"

    init() {
        bootstrap()
    }

    // MARK: - Bootstrap

    func bootstrap() {
        Workspace.migrateLegacyDefaultsIfNeeded()
        settings = UserSettings.load()
        plan = TradingPlan.load(from: Workspace.planURL).applying(settings)
        Workspace.ensureDayFolders(todayDate)

        // Tied-together launch: TradingView opens WITH the CDP flag whenever
        // Ledger starts and TV isn't already up. A running TV is never
        // touched — that is the hard rule.
        if settings.launchTVWithLedger ?? true {
            if TVLauncher.launchWithBridgeIfClosed() {
                scheduleTVStatusRetries()
            }
        }

        do {
            let database = try AppDatabase.open()
            db = database
            // auto-enter only a LIVE session; an ended one means the user
            // left deliberately — land on the Hub instead
            let todays = try database.fetchSession(date: todayDate)
            session = todays?.status == "open" ? todays : nil
            mentor = MentorService(repoRoot: Workspace.root)
            mentorAvailable = MentorService.locateCLI() != nil
            reloadAll()
            refreshSessionList()
            reloadBlogPosts()
            startWatcher()
            startTimers()
            Task { await self.refreshTVStatus() }
            checkForUpdates()
            // Mid-day relaunch: chart levels flow in right away, not at the
            // next 5-minute tick.
            if session != nil { syncLevelsFromChart(manual: false) }
        } catch {
            fatalError = "Could not open journal database: \(error.localizedDescription)"
        }
    }

    // MARK: - Day rollover & timers

    private func startTimers() {
        dayCheckTimer?.invalidate()
        dayCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDayIfNeeded()
                await self?.refreshTVStatus()
            }
        }
        levelSyncTimer?.invalidate()
        levelSyncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncLevelsFromChart(manual: false) }
        }
    }

    /// App left open overnight must not journal under yesterday's date —
    /// unless the user deliberately pinned a session (named workspace or a
    /// past day they're reviewing); then the pin wins.
    func refreshDayIfNeeded() {
        let current = Workspace.todayString()
        guard current != todayDate else { return }
        todayDate = current
        Workspace.ensureDayFolders(current)
        pendingScreenshots = []
        if pinnedSessionId == nil {
            let todays = (try? db?.fetchSession(date: current)) ?? nil
            session = todays?.status == "open" ? todays : nil
            reloadAll()
        }
        startWatcher()
    }

    // MARK: - Session browser (pick · pin · name · reopen)

    func refreshSessionList() {
        guard let db else { return }
        allSessions = (try? db.allSessions()) ?? []
        sessionNets = (try? db.sessionNets()) ?? [:]
    }

    /// Load any session into the feed. Selecting today's natural session
    /// clears the pin; anything else pins.
    func selectSession(id: String) {
        guard let db, let s = (try? db.fetchSession(id: id)) ?? nil else { return }
        session = s
        pinnedSessionId = s.date == todayDate && s.name == nil ? nil : s.id
        reloadAll()
    }

    /// Back to the live day (Hub when today has no open session).
    func selectToday() {
        pinnedSessionId = nil
        composingSession = false
        let todays = (try? db?.fetchSession(date: todayDate)) ?? nil
        session = todays?.status == "open" ? todays : nil
        reloadAll()
    }

    /// Dedicated workspace ("LEAP tournament"): its own session, named,
    /// reopenable any day — trades, posts and mentor thinking all live in it.
    func createNamedSession(name: String, instrument: Instrument) {
        guard let db else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = SessionRecord(
            id: UUID().uuidString,
            date: todayDate,
            instrument: instrument.rawValue,
            ibHigh: nil,
            ibLow: nil,
            tradesTaken: 0,
            status: "open",
            createdAt: Workspace.isoNow(),
            name: trimmed.isEmpty ? nil : trimmed)
        do {
            try db.save(s)
            session = s
            pinnedSessionId = s.id
            reloadAll()
            refreshSessionList()
        } catch {
            errorMessage = "Could not create session: \(error.localizedDescription)"
        }
    }

    func renameSession(id: String, to name: String) {
        guard let db, var s = (try? db.fetchSession(id: id)) ?? nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        s.name = trimmed.isEmpty ? nil : trimmed
        do {
            try db.save(s)
            if session?.id == id { session = s }
            refreshSessionList()
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    /// Closed is never locked — reopen and keep working.
    func reopenSession(id: String) {
        guard let db, var s = (try? db.fetchSession(id: id)) ?? nil else { return }
        s.status = "open"
        do {
            try db.save(s)
            selectSession(id: id)
            refreshSessionList()
        } catch {
            errorMessage = "Reopen failed: \(error.localizedDescription)"
        }
    }

    // MARK: - TradingView status

    func refreshTVStatus() async {
        tvStatus = await TVLauncher.status()
    }

    /// TradingView boots in seconds, its CDP socket a beat later — poll a few
    /// times after WE launched it so the dot goes green without user action.
    private func scheduleTVStatusRetries() {
        Task { [weak self] in
            for delay in [3.0, 8.0, 15.0, 30.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                await self.refreshTVStatus()
                if self.tvStatus == .bridge { return }
            }
        }
    }

    /// Toolbar action. Closed -> launch with the bridge flag. Running without
    /// the bridge -> explain the safe path (we NEVER restart a live chart).
    func openTradingView() {
        switch tvStatus {
        case .closed:
            if TVLauncher.launchWithBridgeIfClosed() {
                scheduleTVStatusRetries()
            } else {
                errorMessage = "TV bridge: TradingView.app not found in /Applications."
            }
        case .filesOnly:
            errorMessage = "TV bridge: TradingView is running without the bridge. Screenshots work fine. For live level pull: quit TradingView yourself when convenient, then click the TV button — Ledger relaunches it with the bridge on. Ledger never restarts a running chart."
        case .bridge:
            break
        }
    }

    // MARK: - Updates (git pull from the repo — code only, data stays put)

    func checkForUpdates() {
        Task { [weak self] in
            let status = await UpdateService.check()
            await MainActor.run {
                if case .behind(let n) = status {
                    self?.updateBehind = n
                } else {
                    self?.updateBehind = nil
                }
            }
        }
    }

    func installUpdate() {
        UpdateService.runUpdate()
    }

    private func startWatcher() {
        watchers.forEach { $0.stop() }
        watchers = []
        loadConsumedPaths()

        var dirs = [Workspace.inboxDir(todayDate)]
        if let tvDir = Workspace.tvGrabsDir { dirs.append(tvDir) }

        for dir in dirs {
            let w = InboxWatcher(directory: dir) { [weak self] newFiles in
                self?.enqueuePending(newFiles)
            }
            w.start()
            watchers.append(w)
        }
    }

    private func enqueuePending(_ newFiles: [URL]) {
        let cutoff = Workspace.startOfTodayET()
        let known = Set(pendingScreenshots.map(\.path))
        let fresh = newFiles.filter { url in
            guard !known.contains(url.path),
                  !consumedSourcePaths.contains(url.path) else { return false }
            // Shots older than today's trading date stay out of the queue
            // (the shared TradingView folder holds weeks of grabs).
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let stamp = values?.creationDate ?? values?.contentModificationDate ?? Date()
            return stamp >= cutoff
        }
        if !fresh.isEmpty { pendingScreenshots.append(contentsOf: fresh) }
    }

    private func loadConsumedPaths() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.consumedDefaultsKey) ?? []
        // Prune entries whose files are gone — the set stays small.
        consumedSourcePaths = Set(stored.filter { FileManager.default.fileExists(atPath: $0) })
        UserDefaults.standard.set(Array(consumedSourcePaths), forKey: Self.consumedDefaultsKey)
    }

    private func markConsumed(_ url: URL) {
        consumedSourcePaths.insert(url.path)
        UserDefaults.standard.set(Array(consumedSourcePaths), forKey: Self.consumedDefaultsKey)
    }

    func rescanInbox() {
        watchers.forEach { $0.rescan() }
    }

    func discardPendingScreenshot(_ url: URL) {
        pendingScreenshots.removeAll { $0 == url }
    }

    // MARK: - Session lifecycle

    func startSession(instrument: Instrument, ibHigh: Double?, ibLow: Double?, levelDrafts: [LevelDraft]) {
        guard let db else { return }
        let s = SessionRecord(
            id: UUID().uuidString,
            date: todayDate,
            instrument: instrument.rawValue,
            ibHigh: ibHigh,
            ibLow: ibLow,
            tradesTaken: 0,
            status: "open",
            createdAt: Workspace.isoNow())
        let levelRecords: [LevelRecord] = levelDrafts.compactMap { draft in
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let price = Double(draft.price) else { return nil }
            return LevelRecord(
                id: UUID().uuidString,
                sessionId: s.id,
                name: name,
                price: price,
                stars: max(1, min(5, draft.stars)),
                rankScore: Int(draft.rankScore),
                broken: false,
                notes: draft.notes.isEmpty ? nil : draft.notes)
        }
        do {
            try db.save(s)
            try db.saveLevels(levelRecords)
            session = s
            composingSession = false
            reloadAll()
            refreshSessionList()
            // Chart levels flow in immediately if TV is up.
            syncLevelsFromChart(manual: false)
        } catch {
            errorMessage = "Failed to start session: \(error.localizedDescription)"
        }
    }

    /// Ends the CURRENT session and returns to the Session Hub. One DB
    /// write, one navigation — nothing that can hang.
    func endSession() {
        guard let db, var s = session else { return }
        s.status = "done"
        do {
            try db.save(s)
            session = nil
            pinnedSessionId = nil
            composingSession = false
            refreshSessionList()
            reloadAll()
        } catch {
            errorMessage = "Failed to end session: \(error.localizedDescription)"
        }
    }

    // MARK: - Entries

    func submitEntry(_ draft: EntryDraft) {
        guard let db, let s = session else { return }
        let entryId = UUID().uuidString

        var relPath = ""
        if let shot = draft.screenshot {
            if let moved = moveScreenshotToAssets(shot, entryId: entryId) {
                relPath = Workspace.relativePath(moved)
                pendingScreenshots.removeAll { $0 == shot }
            } else {
                errorMessage = "Could not move screenshot into assets/ — entry saved without image."
            }
        }

        let entry = EntryRecord(
            id: entryId,
            sessionId: s.id,
            ts: Workspace.isoNow(),
            screenshotPath: relPath,
            comment: nilIfEmpty(draft.comment),
            lookingFor: nilIfEmpty(draft.lookingFor),
            wantToSee: nilIfEmpty(draft.wantToSee),
            action: draft.action.rawValue,
            playType: draft.playType?.rawValue,
            levelId: draft.levelId,
            mentorReply: nil,
            mentorClaudeSessionId: nil,
            instrument: (draft.instrument ?? Instrument(rawValue: s.instrument))?.rawValue)

        do {
            try db.save(entry)
            if draft.action == .chop {
                let chop = ChopRecord(
                    id: UUID().uuidString,
                    sessionId: s.id,
                    ts: entry.ts,
                    rangeHigh: draft.chopHigh,
                    rangeLow: draft.chopLow,
                    crossings: draft.chopCrossings)
                try db.save(chop)
            }
            reloadAll()
            requestMentor(for: entry)
            // Every chart post refreshes the level table — OCR is ~2s and
            // local, so the map tracks the chart all day, bridge or no bridge.
            if !relPath.isEmpty {
                syncLevelsFromChart(manual: false)
            }
        } catch {
            errorMessage = "Failed to save entry: \(error.localizedDescription)"
        }
    }

    private func moveScreenshotToAssets(_ source: URL, entryId: String) -> URL? {
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let dest = Workspace.assetsDir(todayDate).appendingPathComponent("\(entryId).\(ext)")
        // Our own day inbox is consumed (move); the shared TradingView folder
        // is the user's archive — copy and remember it as journaled.
        let inboxPath = Workspace.inboxDir(todayDate).standardizedFileURL.path
        let isOwnInbox = source.standardizedFileURL.path.hasPrefix(inboxPath + "/")
        do {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if isOwnInbox {
                try FileManager.default.moveItem(at: source, to: dest)
            } else {
                try FileManager.default.copyItem(at: source, to: dest)
                markConsumed(source)
            }
            return dest
        } catch {
            NSLog("moveScreenshotToAssets failed: \(error)")
            return nil
        }
    }

    // MARK: - Mentor

    func requestMentor(for entry: EntryRecord) {
        guard let db, let s = session, let mentor, mentorAvailable else { return }
        guard !mentorBusy.contains(entry.id) else { return }
        mentorBusy.insert(entry.id)

        let level = levels.first { $0.id == entry.levelId }
        let resumeId = (try? db.latestMentorSessionId(sessionId: s.id)) ?? nil
        let planSnapshot = plan
        let statsSnapshot = stats

        Task { [weak self] in
            let outcome = await mentor.review(
                entry: entry,
                session: s,
                level: level,
                plan: planSnapshot,
                stats: statsSnapshot,
                resumeSessionId: resumeId)
            await MainActor.run {
                guard let self else { return }
                self.mentorBusy.remove(entry.id)
                switch outcome {
                case .success(let result):
                    try? self.db?.updateEntryMentor(
                        id: entry.id,
                        reply: result.reply,
                        claudeSessionId: result.claudeSessionId)
                    self.reloadEntries()
                case .failure(let err):
                    // Entry already saved — mentor stays empty, card shows retry.
                    NSLog("Mentor failed for entry \(entry.id): \(err)")
                }
            }
        }
    }

    func retryMentor(entryId: String) {
        guard let entry = entries.first(where: { $0.id == entryId }) else { return }
        requestMentor(for: entry)
    }

    /// Pre-trade EDGE CHECK: GO / WAIT / NO against the one-edge checklist.
    /// Fresh mentor conversation every time — never resumed.
    func preTradeCheck(adx: Double?, stretchSigma: Double?, rsi: Double?,
                       levelName: String?, levelScore: Double?, side: String) {
        guard let mentor, mentorAvailable, !preCheckBusy else { return }
        preCheckBusy = true
        preCheckReply = nil
        let instrument = session?.instrument ?? lastUsedInstrument?.rawValue ?? "NQ"
        let planSnapshot = plan
        Task { [weak self] in
            let outcome = await mentor.preTradeCheck(
                instrument: instrument,
                adx: adx,
                stretchSigma: stretchSigma,
                rsi: rsi,
                levelName: levelName,
                levelScore: levelScore,
                side: side,
                plan: planSnapshot)
            await MainActor.run {
                guard let self else { return }
                self.preCheckBusy = false
                switch outcome {
                case .success(let result):
                    self.preCheckReply = result.reply
                case .failure(let err):
                    self.preCheckReply = "NO — check failed: \(err.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Comment threads (user <-> mentor, per post)

    func addUserComment(entryId: String, text: String) {
        guard let db, let s = session,
              let entry = entries.first(where: { $0.id == entryId }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let userComment = CommentRecord(
            id: UUID().uuidString,
            entryId: entryId,
            ts: Workspace.isoNow(),
            author: "user",
            text: trimmed)
        do {
            try db.save(userComment)
            reloadComments()
        } catch {
            errorMessage = "Failed to save comment: \(error.localizedDescription)"
            return
        }

        guard let mentor, mentorAvailable, !mentorBusy.contains(entryId) else { return }
        mentorBusy.insert(entryId)
        let thread = comments[entryId] ?? []
        let level = levels.first { $0.id == entry.levelId }
        let resumeId = (try? db.latestMentorSessionId(sessionId: s.id)) ?? nil
        let planSnapshot = plan
        let statsSnapshot = stats

        Task { [weak self] in
            let outcome = await mentor.threadReply(
                entry: entry,
                thread: thread,
                newComment: trimmed,
                session: s,
                level: level,
                plan: planSnapshot,
                stats: statsSnapshot,
                resumeSessionId: resumeId)
            await MainActor.run {
                guard let self else { return }
                self.mentorBusy.remove(entryId)
                if case .success(let result) = outcome {
                    let reply = CommentRecord(
                        id: UUID().uuidString,
                        entryId: entryId,
                        ts: Workspace.isoNow(),
                        author: "mentor",
                        text: result.reply)
                    try? self.db?.save(reply)
                    if let sid = result.claudeSessionId {
                        try? self.db?.updateEntryMentor(
                            id: entryId,
                            reply: entry.mentorReply,
                            claudeSessionId: sid)
                    }
                    self.reloadComments()
                    self.reloadEntries()
                }
            }
        }
    }

    // MARK: - Post CRUD

    /// Deletes a post plus its thread, trade, and screenshot file.
    func deleteEntry(entryId: String) {
        guard let db, var s = session,
              let entry = entries.first(where: { $0.id == entryId }) else { return }
        let hadTrades = trades.filter { $0.entryId == entryId }.count
        do {
            try db.deleteEntry(id: entryId)
            if !entry.screenshotPath.isEmpty {
                try? FileManager.default.removeItem(
                    at: Workspace.absoluteURL(relative: entry.screenshotPath))
            }
            if hadTrades > 0 {
                s.tradesTaken = max(0, s.tradesTaken - hadTrades)
                try db.save(s)
                session = s
            }
            reloadAll()
        } catch {
            errorMessage = "Failed to delete post: \(error.localizedDescription)"
        }
    }

    func deleteTrade(tradeId: String) {
        guard let db, var s = session else { return }
        do {
            try db.deleteTrade(id: tradeId)
            s.tradesTaken = max(0, s.tradesTaken - 1)
            try db.save(s)
            session = s
            reloadAll()
        } catch {
            errorMessage = "Failed to delete trade: \(error.localizedDescription)"
        }
    }

    /// Saves edited post fields (caption, tags, level, instrument).
    func updateEntry(_ entry: EntryRecord) {
        guard let db else { return }
        do {
            try db.save(entry)
            reloadAll()
        } catch {
            errorMessage = "Failed to update post: \(error.localizedDescription)"
        }
    }

    // MARK: - Settings

    func saveSettings(_ newSettings: UserSettings) {
        settings = newSettings
        newSettings.save()
        plan = TradingPlan.load(from: Workspace.planURL).applying(newSettings)
        reloadAll()
    }

    // MARK: - Trades

    var tradesRemaining: Int {
        max(0, plan.maxTradesPerDay - (session?.tradesTaken ?? 0))
    }

    /// Quality check for the confirm-override flow. nil = clear to trade.
    /// Trade COUNT is deliberately not checked — pace is context, not a cap
    /// (all-day trading, 2026-07-22). Level strength still matters.
    func tradeWarning(for form: TradeForm) -> String? {
        if let levelId = form.levelId,
           let level = levels.first(where: { $0.id == levelId }),
           level.effectiveRank < plan.minRankToTrade {
            return "Level \(level.name) rank \(level.effectiveRank) < min \(plan.minRankToTrade)."
        }
        return nil
    }

    func recordTrade(entryId: String, form: TradeForm) {
        guard let db, var s = session else { return }
        let trade = TradeRecord(
            id: UUID().uuidString,
            entryId: entryId,
            playType: form.playType.rawValue,
            levelId: form.levelId,
            contracts: max(1, form.contracts),
            entryPrice: form.entryPrice,
            stopPrice: form.stopPrice,
            targetPrice: form.targetPrice,
            exitPrice: nil,
            ticksResult: nil,
            usdResult: nil,
            result: "open",
            instrument: (form.instrument
                ?? entries.first(where: { $0.id == entryId }).flatMap { Instrument(rawValue: $0.instrument ?? "") }
                ?? Instrument(rawValue: s.instrument))?.rawValue,
            entryTime: Workspace.isoNow(),
            side: form.side)
        do {
            try db.save(trade)
            s.tradesTaken += 1
            try db.save(s)
            session = s
            reloadAll()
        } catch {
            errorMessage = "Failed to record trade: \(error.localizedDescription)"
        }
    }

    func closeTrade(tradeId: String, exitPrice: Double) {
        guard let db, let s = session,
              var trade = trades.first(where: { $0.id == tradeId }) else { return }
        guard let entry = trade.entryPrice else {
            errorMessage = "Trade has no entry price — set it before closing."
            return
        }
        // Per-trade instrument first — session default is only a fallback.
        let instrument = Instrument(rawValue: trade.instrument ?? "")
            ?? Instrument(rawValue: s.instrument) ?? .NQ
        // Direction from the bracket: target above entry = long; else stop below = long.
        let direction: Double
        if let target = trade.targetPrice {
            direction = target >= entry ? 1 : -1
        } else if let stop = trade.stopPrice {
            direction = stop <= entry ? 1 : -1
        } else {
            direction = 1
        }
        let ticks = (exitPrice - entry) / instrument.tickSize * direction
        let usd = ticks * instrument.tickValue * Double(trade.contracts)
        trade.exitPrice = exitPrice
        trade.ticksResult = (ticks * 100).rounded() / 100
        trade.usdResult = (usd * 100).rounded() / 100
        trade.result = ticks > 0 ? "win" : (ticks < 0 ? "loss" : "scratch")
        trade.exitTime = Workspace.isoNow()
        if trade.side == nil { trade.side = direction > 0 ? "long" : "short" }
        do {
            try db.save(trade)
            reloadAll()
        } catch {
            errorMessage = "Failed to close trade: \(error.localizedDescription)"
        }
    }

    // MARK: - Settle Day (TradingView account-history import)

    /// Round trips already journaled — the preview marks them DUP up front.
    func duplicateTripIds(_ parse: TVImportParse) -> Set<UUID> {
        guard let db else { return [] }
        var dupes: Set<UUID> = []
        for trip in parse.trips {
            if (try? db.importedTradeExists(
                instrument: trip.instrumentName,
                exitTime: Workspace.isoNow(now: trip.exitTime),
                exitPrice: trip.exitPrice)) == true {
                dupes.insert(trip.id)
            }
        }
        return dupes
    }

    /// Broker fills become journal truth. Multi-day pastes route each trip
    /// to its OWN session by ET date — missing past sessions are created
    /// closed, so a whole tournament export backfills the journal and the
    /// Trader Profile in one paste. Per trip: duplicate -> skipped; a
    /// same-day open manual trade at the same entry -> completed in place;
    /// else a new feed post + trade tagged tv_import. Mentor never called
    /// on imports.
    func importTVTrades(_ parse: TVImportParse, plays: [UUID: PlayType], rawText: String) -> TVImportSummary? {
        guard let db else { return nil }
        var summary = TVImportSummary()
        var touched: [String: SessionRecord] = [:]

        func sessionFor(date: String, instrument: String) -> SessionRecord? {
            if let s = touched[date] { return s }
            if let existing = (try? db.fetchSession(date: date)) ?? nil {
                touched[date] = existing
                return existing
            }
            let fresh = SessionRecord(
                id: UUID().uuidString,
                date: date,
                instrument: instrument,
                ibHigh: nil,
                ibLow: nil,
                tradesTaken: 0,
                status: date == todayDate ? "open" : "done",
                createdAt: Workspace.isoNow())
            do {
                try db.save(fresh)
            } catch {
                errorMessage = "Settle Day: could not create session for \(date): \(error.localizedDescription)"
                return nil
            }
            touched[date] = fresh
            return fresh
        }

        for trip in parse.trips {
            let instrumentStr = trip.instrumentName
            let exitISO = Workspace.isoNow(now: trip.exitTime)
            let entryISO = trip.entryTime.map { Workspace.isoNow(now: $0) }
            let tripDate = Workspace.todayString(now: trip.exitTime)
            if (try? db.importedTradeExists(
                instrument: instrumentStr, exitTime: exitISO, exitPrice: trip.exitPrice)) == true {
                summary.duplicates += 1
                continue
            }
            guard let s = sessionFor(date: tripDate, instrument: instrumentStr) else { continue }

            let net = ((trip.netUsd) * 100).rounded() / 100
            let result = net > 0 ? "win" : (net < 0 ? "loss" : "scratch")
            let tickSize = trip.instrument?.tickSize ?? 0.25

            // Same-day open manual trade at (about) the same entry -> the
            // broker row completes it instead of duplicating it.
            if tripDate == todayDate, let idx = trades.firstIndex(where: { t in
                t.source == nil && t.exitTime == nil && t.result == "open"
                    && (t.instrument ?? s.instrument) == instrumentStr
                    && t.entryPrice.map { abs($0 - trip.entryPrice) <= tickSize * 4 } == true
            }) {
                var t = trades[idx]
                t.exitPrice = trip.exitPrice
                t.ticksResult = trip.ticks.map { ($0 * 100).rounded() / 100 }
                t.usdResult = net
                t.result = result
                t.entryTime = entryISO ?? t.entryTime
                t.exitTime = exitISO
                t.side = trip.side
                t.commission = trip.commissionUsd
                t.grossUsd = trip.grossUsd
                t.source = "reconciled"
                do {
                    try db.save(t)
                    summary.matched += 1
                } catch {
                    errorMessage = "Settle Day: failed to update a matched trade: \(error.localizedDescription)"
                }
                continue
            }

            // New backfilled post + trade at the broker's entry timestamp.
            let entryId = UUID().uuidString
            let caption = String(
                format: "TV import — %@ %@ %@ → %@ · %@",
                trip.side.uppercased(), instrumentStr,
                trimmedPrice(trip.entryPrice), trimmedPrice(trip.exitPrice),
                signedUsd(net))
            let entry = EntryRecord(
                id: entryId,
                sessionId: s.id,
                ts: entryISO ?? exitISO,
                screenshotPath: "",
                comment: caption,
                lookingFor: nil,
                wantToSee: nil,
                action: "enter",
                playType: (plays[trip.id] ?? .OFF).rawValue,
                levelId: nil,
                mentorReply: nil,
                mentorClaudeSessionId: nil,
                instrument: instrumentStr)
            let trade = TradeRecord(
                id: UUID().uuidString,
                entryId: entryId,
                playType: (plays[trip.id] ?? .OFF).rawValue,
                levelId: nil,
                contracts: max(1, trip.units),
                entryPrice: trip.entryPrice,
                stopPrice: nil,
                targetPrice: nil,
                exitPrice: trip.exitPrice,
                ticksResult: trip.ticks.map { ($0 * 100).rounded() / 100 },
                usdResult: net,
                result: result,
                instrument: instrumentStr,
                entryTime: entryISO,
                exitTime: exitISO,
                side: trip.side,
                commission: trip.commissionUsd,
                grossUsd: trip.grossUsd,
                source: "tv_import")
            do {
                try db.save(entry)
                try db.save(trade)
                summary.created += 1
            } catch {
                errorMessage = "Settle Day: failed to import a trade: \(error.localizedDescription)"
            }
        }

        // Honest per-session counts for every day the import touched.
        for (_, var s) in touched {
            s.tradesTaken = (try? db.trades(sessionId: s.id).count) ?? s.tradesTaken
            try? db.save(s)
            if s.date == todayDate { session = s }
        }
        summary.days = touched.count

        // Manual rows the broker never produced — surfaced, never deleted.
        reloadAll()
        summary.phantoms = trades.filter { $0.source == nil && $0.exitTime == nil }.count

        // Raw paste kept beside the day's assets — audit trail + future
        // MAE replay input.
        Workspace.ensureDayFolders(todayDate)
        let pasteURL = Workspace.dayDir(todayDate).appendingPathComponent("tv_ledger_paste.txt")
        try? rawText.write(to: pasteURL, atomically: true, encoding: .utf8)

        return summary
    }

    private func trimmedPrice(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private func signedUsd(_ v: Double) -> String {
        (v < 0 ? "-$" : "+$") + String(format: "%.2f", abs(v))
    }

    // MARK: - Analytics

    /// Lifetime trade feed for the Analytics sheet (all sessions, all days).
    func analyticsRows() -> [AnalyticsTradeRow] {
        guard let db else { return [] }
        return (try? db.allTradesForAnalytics()) ?? []
    }

    // MARK: - Levels

    func setLevelBroken(_ levelId: String, broken: Bool) {
        guard let db, var level = levels.first(where: { $0.id == levelId }) else { return }
        level.broken = broken
        do {
            try db.save(level)
            reloadAll()
        } catch {
            errorMessage = "Failed to update level: \(error.localizedDescription)"
        }
    }

    func addLevel(_ draft: LevelDraft) {
        guard let db, let s = session,
              let price = Double(draft.price),
              !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let level = LevelRecord(
            id: UUID().uuidString,
            sessionId: s.id,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            price: price,
            stars: max(1, min(5, draft.stars)),
            rankScore: Int(draft.rankScore),
            broken: false,
            notes: draft.notes.isEmpty ? nil : draft.notes)
        do {
            try db.save(level)
            reloadAll()
        } catch {
            errorMessage = "Failed to add level: \(error.localizedDescription)"
        }
    }

    // MARK: - Chart level sync (tv CLI / CDP)

    /// Merges levels read from the chart (bridge or screenshot) into the
    /// session: same (name, instrument) -> price/stars/rank refresh (broken
    /// flag, notes preserved); new -> inserted. Manual levels never deleted.
    /// `instrument` nil (the single-pane path's default) keys purely on name,
    /// exactly as before this method learned about panes — a pane scan's
    /// tagged levels (e.g. "sesH" on XAUUSD vs "sesH" on MES) live under
    /// their own keys and never collide with it.
    private func mergeChartLevels(_ chartLevels: [ChartLevel], instrument: String? = nil, source: String) throws {
        guard let db, let s = session else { return }
        func key(_ name: String, _ inst: String?) -> String { "\(name.lowercased())|\(inst ?? "")" }
        var byKey: [String: LevelRecord] = [:]
        for level in levels { byKey[key(level.name, level.instrument)] = level }
        for chart in chartLevels {
            if var existing = byKey[key(chart.name, instrument)] {
                if existing.price != chart.price || existing.stars != chart.stars
                    || existing.rankScore != (chart.rank ?? existing.rankScore) {
                    existing.price = chart.price
                    existing.stars = chart.stars
                    if let rank = chart.rank { existing.rankScore = rank }
                    try db.save(existing)
                }
            } else {
                try db.save(LevelRecord(
                    id: UUID().uuidString,
                    sessionId: s.id,
                    name: chart.name,
                    price: chart.price,
                    stars: chart.stars,
                    rankScore: chart.rank,
                    broken: false,
                    notes: source,
                    instrument: instrument))
            }
        }
        lastLevelSync = Date()
        reloadAll()
    }

    /// Manual, user-triggered sweep of every pane in the live TradingView
    /// multi-chart layout (Scanner sheet's "Scan All"). 20-40s for six panes
    /// is expected — this never rides the 5-minute single-pane auto-timer.
    /// Each pane's levels merge in tagged with that pane's raw symbol, so
    /// the same level name on two different instruments stays two rows.
    func scanAllPanes() async {
        guard !scanBusy else { return }
        scanBusy = true
        let outcome = await levelSync.scanAllPanes()
        scanBusy = false
        switch outcome {
        case .success(let results):
            scanResults = results
            var saveFailures = 0
            for result in results {
                do {
                    try mergeChartLevels(result.levels, instrument: result.symbol, source: "pane-scan")
                } catch {
                    saveFailures += 1
                }
            }
            if saveFailures > 0 {
                errorMessage = "Pane scan: \(saveFailures) of \(results.count) panes' levels failed to save."
            }
        case .failure(let err):
            errorMessage = err.localizedDescription
        }
    }

    /// Level acquisition, two rungs: tv CLI off the live chart (fast, needs
    /// the CDP bridge), else claude reads the labels straight off the latest
    /// posted SCREENSHOT — levels work even with the bridge down.
    func syncLevelsFromChart(manual: Bool) {
        guard let s = session, !levelSyncBusy else { return }
        // done sessions don't need the 5-minute OCR walk churning away —
        // background work on a closed session was pure heat
        if !manual && s.status != "open" { return }
        levelSyncBusy = true
        // Recent posted screenshots, newest first — footprint-only shots can
        // hide the labels, so OCR walks back until one reads clean.
        let fallbackShots = Array(entries.filter { !$0.screenshotPath.isEmpty }
            .prefix(3).map(\.screenshotPath))
        let fallbackShot = fallbackShots.first
        Task { [weak self] in
            guard let self else { return }
            // Fast probe picks the path: bridge up -> tv CLI; down -> straight
            // to OCR (no 20s timeout prelude on every post).
            var outcome: Result<[ChartLevel], LevelSyncError>
            var source: String
            func ocrWalk() async -> Result<[ChartLevel], LevelSyncError> {
                var last: Result<[ChartLevel], LevelSyncError> =
                    .failure(.failed("No TV bridge and no posted screenshot yet — post a chart shot, then sync."))
                for shot in fallbackShots {
                    last = await self.levelSync.extractLevels(fromScreenshot: shot, repoRoot: Workspace.root)
                    if case .success = last { return last }
                }
                return last
            }
            if await LevelSyncService.cdpAlive() {
                outcome = await self.levelSync.fetchLevels()
                source = "chart-sync"
                if case .failure = outcome, fallbackShot != nil {
                    outcome = await ocrWalk()
                    source = "screenshot-sync"
                }
            } else {
                outcome = await ocrWalk()
                source = "screenshot-sync"
            }
            let finalOutcome = outcome
            let finalSource = source
            await MainActor.run {
                self.levelSyncBusy = false
                switch finalOutcome {
                case .success(let chartLevels):
                    do {
                        try self.mergeChartLevels(chartLevels, source: finalSource)
                        if finalSource == "chart-sync" { self.tvStatus = .bridge }
                    } catch {
                        if manual { self.errorMessage = "Level sync save failed: \(error.localizedDescription)" }
                    }
                case .failure(let err):
                    if manual {
                        self.errorMessage = fallbackShot == nil
                            ? "No TV bridge and no posted screenshot yet — post a chart shot, then sync."
                            : err.localizedDescription
                    }
                    Task { await self.refreshTVStatus() }
                }
            }
        }
        _ = s
    }

    /// Pre-session variant for SetupView — chart levels as editable drafts.
    func fetchChartLevelDrafts() async -> [LevelDraft] {
        let result = await levelSync.fetchLevels()
        switch result {
        case .success(let chartLevels):
            await MainActor.run { self.tvStatus = .bridge }
            return chartLevels.map { chart in
                var draft = LevelDraft()
                draft.name = chart.name
                draft.price = String(chart.price)
                draft.stars = chart.stars
                if let rank = chart.rank { draft.rankScore = String(rank) }
                return draft
            }
        case .failure(let err):
            await MainActor.run { self.errorMessage = err.localizedDescription }
            return []
        }
    }

    // MARK: - Blog (Skuldswyrd Online Edition)

    func reloadBlogPosts() {
        guard let db else { return }
        blogPosts = (try? db.allBlogPosts()) ?? []
    }

    /// New empty draft, linked to the session on screen (if any).
    func createBlogPost() -> BlogPostRecord? {
        guard let db else { return nil }
        let now = Workspace.isoNow()
        let post = BlogPostRecord(
            id: UUID().uuidString,
            title: "",
            body: "",
            sessionId: session?.id,
            status: "draft",
            createdAt: now,
            updatedAt: now)
        do {
            try db.save(post)
            reloadBlogPosts()
            return post
        } catch {
            errorMessage = "Could not create blog post: \(error.localizedDescription)"
            return nil
        }
    }

    func saveBlogPost(_ post: BlogPostRecord) {
        guard let db else { return }
        var p = post
        p.updatedAt = Workspace.isoNow()
        do {
            try db.save(p)
            reloadBlogPosts()
        } catch {
            errorMessage = "Could not save blog post: \(error.localizedDescription)"
        }
    }

    func deleteBlogPost(id: String) {
        guard let db else { return }
        do {
            try db.deleteBlogPost(id: id)
            reloadBlogPosts()
        } catch {
            errorMessage = "Could not delete blog post: \(error.localizedDescription)"
        }
    }

    /// The on-screen session condensed to markdown — pasted into a draft so
    /// the post is written from the day's record. nil when no session loaded.
    func sessionDigestMarkdown() -> String? {
        guard let s = session else { return nil }
        return SessionDigest.markdown(
            session: s, stats: stats, levels: levels,
            entries: entries, trades: trades)
    }

    /// Writes Blog/exports/<date>-<slug>.md and reveals it in Finder.
    @discardableResult
    func exportBlogPost(id: String) -> URL? {
        guard let post = blogPosts.first(where: { $0.id == id }) else { return nil }
        do {
            let url = try BlogExporter.write(post: post, root: Workspace.root)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch {
            errorMessage = "Blog export failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Report

    func generateReport() {
        guard let s = session else { return }
        do {
            let url = try ReportGenerator.generate(
                root: Workspace.root,
                session: s,
                levels: levels,
                entries: entries,
                trades: trades,
                chops: chops,
                comments: comments,
                stats: stats,
                plan: plan)
            lastReportURL = url
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = "Report failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Derived

    /// Lunch blackout banner (11:30-13:30 ET per plan). Visible, never a hard block.
    var isLunchBlackout: Bool {
        let now = Workspace.minutesNowET()
        return now >= plan.lunchStartMin && now < plan.lunchEndMin
    }

    func level(id: String?) -> LevelRecord? {
        guard let id else { return nil }
        return levels.first { $0.id == id }
    }

    /// Yesterday's instrument seeds today's setup (he trades the same product
    /// for stretches — MNQ session logged against NQ fills cost a 10x P&L
    /// under-report on day 1).
    var lastUsedInstrument: Instrument? {
        guard let db, let s = try? db.latestSession() else { return nil }
        return Instrument(rawValue: s.instrument)
    }

    func trade(forEntry entryId: String) -> TradeRecord? {
        trades.first { $0.entryId == entryId }
    }

    // MARK: - Reload

    private func reloadEntries() {
        guard let db, let s = session else { return }
        entries = (try? db.entries(sessionId: s.id)) ?? []
    }

    private func reloadComments() {
        guard let db, let s = session else { return }
        comments = (try? db.comments(sessionId: s.id)) ?? [:]
    }

    private func reloadAll() {
        guard let db, let s = session else {
            levels = []; entries = []; trades = []; chops = []; comments = [:]; stats = .empty
            return
        }
        levels = (try? db.levels(sessionId: s.id)) ?? []
        entries = (try? db.entries(sessionId: s.id)) ?? []
        trades = (try? db.trades(sessionId: s.id)) ?? []
        chops = (try? db.chops(sessionId: s.id)) ?? []
        comments = (try? db.comments(sessionId: s.id)) ?? [:]
        stats = (try? StatsQueries.compute(db: db, session: s, levels: levels, plan: plan)) ?? .empty
        refreshSessionList()
    }

    private func nilIfEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
