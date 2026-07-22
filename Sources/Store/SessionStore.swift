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
    /// Entry ids with a mentor call in flight ("thinking..." on the card).
    @Published private(set) var mentorBusy: Set<String> = []
    @Published var errorMessage: String? {
        didSet {
            // Every surfaced app error also lands in the upgrade log —
            // paste-ready context for the next patch round.
            if let msg = errorMessage, msg != oldValue {
                UpgradeLog.append(note: msg, type: "APP-ERROR")
            }
        }
    }
    @Published private(set) var lastReportURL: URL?
    /// Non-nil when the DB could not open — app shows a blocking error screen.
    @Published private(set) var fatalError: String?
    @Published private(set) var mentorAvailable: Bool = true
    /// TradingView CDP bridge reachable (tv CLI can read the chart).
    @Published private(set) var tvConnected: Bool = false
    @Published private(set) var lastLevelSync: Date?
    @Published private(set) var levelSyncBusy: Bool = false
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

        do {
            let database = try AppDatabase.open()
            db = database
            session = try database.fetchSession(date: todayDate)
            mentor = MentorService(repoRoot: Workspace.root)
            mentorAvailable = MentorService.locateCLI() != nil
            reloadAll()
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
            Task { @MainActor in self?.refreshDayIfNeeded() }
        }
        levelSyncTimer?.invalidate()
        levelSyncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncLevelsFromChart(manual: false) }
        }
    }

    /// App left open overnight must not journal under yesterday's date.
    func refreshDayIfNeeded() {
        let current = Workspace.todayString()
        guard current != todayDate else { return }
        todayDate = current
        Workspace.ensureDayFolders(current)
        pendingScreenshots = []
        session = (try? db?.fetchSession(date: current)) ?? nil
        reloadAll()
        startWatcher()
    }

    // MARK: - TradingView status

    func refreshTVStatus() async {
        let alive = await LevelSyncService.cdpAlive()
        tvConnected = alive && LevelSyncService.locateCLI() != nil
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
            reloadAll()
            // Chart levels flow in immediately if TV is up.
            syncLevelsFromChart(manual: false)
        } catch {
            errorMessage = "Failed to start session: \(error.localizedDescription)"
        }
    }

    func endSession() {
        guard let db, var s = session else { return }
        s.status = "done"
        do {
            try db.save(s)
            session = s
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
                ?? Instrument(rawValue: s.instrument))?.rawValue)
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
        do {
            try db.save(trade)
            reloadAll()
        } catch {
            errorMessage = "Failed to close trade: \(error.localizedDescription)"
        }
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
    /// session: same name -> price/stars/rank refresh (broken flag, notes
    /// preserved); new name -> inserted. Manual levels never deleted.
    private func mergeChartLevels(_ chartLevels: [ChartLevel], source: String) throws {
        guard let db, let s = session else { return }
        var byName: [String: LevelRecord] = [:]
        for level in levels { byName[level.name.lowercased()] = level }
        for chart in chartLevels {
            if var existing = byName[chart.name.lowercased()] {
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
                    notes: source))
            }
        }
        lastLevelSync = Date()
        reloadAll()
    }

    /// Level acquisition, two rungs: tv CLI off the live chart (fast, needs
    /// the CDP bridge), else claude reads the labels straight off the latest
    /// posted SCREENSHOT — levels work even with the bridge down.
    func syncLevelsFromChart(manual: Bool) {
        guard let s = session, !levelSyncBusy else { return }
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
                        if finalSource == "chart-sync" { self.tvConnected = true }
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
            await MainActor.run { self.tvConnected = true }
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
    }

    private func nilIfEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
