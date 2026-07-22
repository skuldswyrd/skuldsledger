import Foundation
import AppKit

/// TradingView connection state, three rungs. The screenshot/mentor pipeline
/// is pure filesystem and works in every state — this only describes the
/// optional CDP level-pull channel.
enum TVStatus: Equatable {
    /// CDP bridge answering — live chart reads available.
    case bridge
    /// TradingView running but launched without the debug flag — screenshots
    /// fine, bridge impossible until the USER restarts TV (we never do).
    case filesOnly
    /// TradingView not running.
    case closed
}

/// Launches TradingView Desktop WITH the CDP bridge flag — but ONLY when it
/// is not already running. HARD RULE: never quit, relaunch, or otherwise
/// touch a running TradingView; a live chart mid-session is sacred.
enum TVLauncher {
    static let bundleId = "com.tradingview.tradingviewapp.desktop"

    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    static func appURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            ?? (FileManager.default.fileExists(atPath: "/Applications/TradingView.app")
                ? URL(fileURLWithPath: "/Applications/TradingView.app") : nil)
    }

    /// Current three-rung status. CDP probe first (cheap, 2s timeout).
    static func status() async -> TVStatus {
        if await LevelSyncService.cdpAlive() { return .bridge }
        return isRunning() ? .filesOnly : .closed
    }

    /// Opens TradingView with the bridge flag if (and only if) it isn't
    /// running. Returns false when it was already running (untouched) or the
    /// app couldn't be found.
    @discardableResult
    static func launchWithBridgeIfClosed() -> Bool {
        guard !isRunning(), let url = appURL() else { return false }
        let config = NSWorkspace.OpenConfiguration()
        // Same flag `tv launch` uses — arguments only apply on a cold start,
        // which is exactly the only case we ever launch.
        config.arguments = ["--remote-debugging-port=9222"]
        config.activates = false   // Ledger keeps focus; chart boots behind it
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { NSLog("TVLauncher: open failed: \(error)") }
        }
        return true
    }
}
