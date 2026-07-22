import Foundation

/// Resolves the Trading workspace root and its well-known paths.
/// Root defaults to ~/Desktop/Trading; overridable via UserDefaults
/// ("workspaceRoot") so the .app works from anywhere.
enum Workspace {
    static let rootDefaultsKey = "workspaceRoot"

    /// One-time import of settings from the pre-rebrand bundle id
    /// (com.skuld.SkuldJournal) so nothing re-queues or resets after the
    /// rename to Skuld's Ledger.
    static func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "legacyMigrated") == nil else { return }
        if let old = defaults.persistentDomain(forName: "com.skuld.SkuldJournal") {
            for key in ["workspaceRoot", "tvInboxDir", "consumedInboxPaths", "repoPath"]
            where defaults.object(forKey: key) == nil && old[key] != nil {
                defaults.set(old[key], forKey: key)
            }
        }
        defaults.set(true, forKey: "legacyMigrated")
    }

    /// Eastern Time drives the trading date — a 19:00 PT screenshot still
    /// belongs to the ET calendar day the session ran on.
    static let eastern = TimeZone(identifier: "America/New_York")!

    static var root: URL {
        if let stored = UserDefaults.standard.string(forKey: rootDefaultsKey),
           FileManager.default.fileExists(atPath: stored) {
            return URL(fileURLWithPath: stored, isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Trading", isDirectory: true)
    }

    static func setRoot(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: rootDefaultsKey)
    }

    static var planURL: URL { root.appendingPathComponent("skuld_trading_operation.json") }
    static var recordsDir: URL { root.appendingPathComponent("Records", isDirectory: true) }
    static var reportsDir: URL { root.appendingPathComponent("Reports", isDirectory: true) }
    static var databaseURL: URL { recordsDir.appendingPathComponent("skuld_journal.sqlite") }

    static func dayDir(_ date: String) -> URL {
        recordsDir.appendingPathComponent(date, isDirectory: true)
    }
    static func inboxDir(_ date: String) -> URL {
        dayDir(date).appendingPathComponent("inbox", isDirectory: true)
    }
    static func assetsDir(_ date: String) -> URL {
        dayDir(date).appendingPathComponent("assets", isDirectory: true)
    }

    /// Fixed TradingView screenshot folder (cmd+s target) — watched in
    /// addition to the per-day inbox. Overridable via UserDefaults "tvInboxDir".
    static var tvGrabsDir: URL? {
        if let stored = UserDefaults.standard.string(forKey: "tvInboxDir") {
            let url = URL(fileURLWithPath: (stored as NSString).expandingTildeInPath, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let fallback = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("ChartGrabsTradingView", isDirectory: true)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// Midnight ET of the current trading date — pending-queue cutoff for
    /// shots in the shared TradingView folder (old grabs stay out).
    static func startOfTodayET(now: Date = Date()) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        return cal.startOfDay(for: now)
    }

    /// YYYY-MM-DD for "today" in ET.
    static func todayString(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = eastern
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: now)
    }

    static func isoNow(now: Date = Date()) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: now)
    }

    /// Minutes past midnight ET for "now" — used for the lunch-blackout banner.
    static func minutesNowET(now: Date = Date()) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        let c = cal.dateComponents([.hour, .minute], from: now)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    @discardableResult
    static func ensureDayFolders(_ date: String) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: inboxDir(date), withIntermediateDirectories: true)
            try fm.createDirectory(at: assetsDir(date), withIntermediateDirectories: true)
            try fm.createDirectory(at: reportsDir, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("Workspace.ensureDayFolders failed: \(error)")
            return false
        }
    }

    /// Path of `url` relative to the workspace root (for DB storage + mentor prompts).
    static func relativePath(_ url: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(rootPath) ? String(p.dropFirst(rootPath.count)) : p
    }

    static func absoluteURL(relative: String) -> URL {
        relative.hasPrefix("/")
            ? URL(fileURLWithPath: relative)
            : root.appendingPathComponent(relative)
    }
}
