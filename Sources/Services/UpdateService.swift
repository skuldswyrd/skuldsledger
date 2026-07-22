import Foundation
import AppKit

/// Self-update from the GitHub repo — code moves, data never does.
/// install.sh stamps the clone path into UserDefaults ("repoPath");
/// check() counts commits behind origin/main; runUpdate() hands off to
/// scripts/update.sh (pull, rebuild, repackage, relaunch) and quits.
enum UpdateService {
    enum Status: Equatable {
        case upToDate
        case behind(Int)
        case unavailable(String)
    }

    static var repoPath: String? {
        guard let path = UserDefaults.standard.string(forKey: "repoPath"),
              FileManager.default.fileExists(atPath: path + "/scripts/update.sh") else {
            return nil
        }
        return path
    }

    static func check() async -> Status {
        guard let repo = repoPath else {
            return .unavailable("repo clone not registered — run scripts/install.sh once")
        }
        // fetch quietly; failure (offline, auth) is non-fatal
        let fetch = await runGit(["-C", repo, "fetch", "--quiet", "origin", "main"], timeout: 20)
        guard fetch.ok else {
            return .unavailable("fetch failed: \(fetch.output.prefix(120))")
        }
        let count = await runGit(["-C", repo, "rev-list", "--count", "HEAD..origin/main"], timeout: 10)
        guard count.ok, let n = Int(count.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .unavailable("rev-list failed")
        }
        return n > 0 ? .behind(n) : .upToDate
    }

    /// Detached update: script survives the app quitting, rebuilds, relaunches.
    static func runUpdate() {
        guard let repo = repoPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c",
            "nohup /bin/bash '\(repo)/scripts/update.sh' > /tmp/skuldsledger-update.log 2>&1 &"]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    private static func runGit(_ args: [String], timeout: TimeInterval) async -> (ok: Bool, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"   // never hang on a credential prompt
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (false, error.localizedDescription))
                    return
                }
                var timedOut = false
                let killer = DispatchWorkItem { timedOut = true; process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                let out = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (!timedOut && process.terminationStatus == 0, out))
            }
        }
    }
}
