import Foundation

/// One mentor exchange: the reply text plus the claude session id (for --resume
/// continuity across entries in the same trading session).
struct MentorResult {
    let reply: String
    let claudeSessionId: String?
}

enum MentorError: Error, LocalizedError {
    case cliNotFound
    case timeout
    case processFailed(String)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "claude CLI not found — install it or add it to PATH."
        case .timeout:
            return "Mentor timed out after 60 seconds."
        case .processFailed(let detail):
            return "Mentor process failed: \(detail)"
        case .emptyReply:
            return "Mentor returned an empty reply."
        }
    }
}

/// Shells out to the local `claude` CLI for a live mentor read on each journal
/// entry. No Anthropic API key anywhere — the CLI owns auth. Every failure is
/// a `.failure` return; the caller saves the entry regardless.
final class MentorService {
    private let repoRoot: URL
    private static let timeoutSeconds: TimeInterval = 60

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    // MARK: - CLI discovery

    /// GUI apps don't inherit shell PATH, so probe well-known install spots
    /// first, then whatever PATH the app process does have.
    static func locateCLI() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent("bin/claude"),
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                candidates.append(
                    URL(fileURLWithPath: String(dir), isDirectory: true)
                        .appendingPathComponent("claude"))
            }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Review

    func review(entry: EntryRecord, session: SessionRecord, level: LevelRecord?,
                plan: TradingPlan, stats: SessionStats,
                resumeSessionId: String?) async -> Result<MentorResult, MentorError> {
        guard let cli = Self.locateCLI() else { return .failure(.cliNotFound) }

        let prompt = Self.buildPrompt(
            entry: entry, session: session, level: level, plan: plan, stats: stats)
        let baseArgs = ["-p", prompt, "--output-format", "json", "--allowedTools", "Read"]

        var args = baseArgs
        let resume = resumeSessionId?.trimmingCharacters(in: .whitespaces)
        if let resume, !resume.isEmpty {
            args += ["--resume", resume]
        }

        let first = await execute(cli: cli, arguments: args)
        switch first {
        case .failure(let err):
            return .failure(err)
        case .success(let output):
            if output.exitCode == 0 {
                return Self.parse(stdout: output.stdout)
            }
            // Session ids expire; a stale --resume is the most likely nonzero
            // exit. Retry exactly once as a fresh conversation.
            if let resume, !resume.isEmpty {
                let second = await execute(cli: cli, arguments: baseArgs)
                switch second {
                case .failure(let err):
                    return .failure(err)
                case .success(let retry):
                    if retry.exitCode == 0 {
                        return Self.parse(stdout: retry.stdout)
                    }
                    return .failure(.processFailed(Self.failureDetail(retry)))
                }
            }
            return .failure(.processFailed(Self.failureDetail(output)))
        }
    }

    // MARK: - Prompt

    private static func buildPrompt(entry: EntryRecord, session: SessionRecord,
                                    level: LevelRecord?, plan: TradingPlan,
                                    stats: SessionStats) -> String {
        var lines: [String] = []

        let shot = entry.screenshotPath.trimmingCharacters(in: .whitespaces)
        if shot.isEmpty {
            lines.append("You are skuld's live trading mentor. Read the plan at skuld_trading_operation.json using your Read tool.")
        } else {
            lines.append("You are skuld's live trading mentor. Read the plan at skuld_trading_operation.json and the screenshot at \(shot) using your Read tool.")
        }
        lines.append("")

        var sessionLine = "Session: \(session.instrument) \(session.date)"
        if let lo = session.ibLow, let hi = session.ibHigh {
            sessionLine += ", IB \(fmt(lo))-\(fmt(hi))"
        }
        sessionLine += ". Trades taken: \(stats.tradesTaken)/\(stats.maxTrades)."
        lines.append(sessionLine)

        // Stats were recomputed after this entry was saved, so the action
        // counts sum IS the entry count (floor 1 covers the retry-later path).
        let n = max(1, stats.actionCounts.values.reduce(0, +))
        lines.append("Entry #\(n) at \(entry.ts):")

        if let text = nonEmpty(entry.comment) { lines.append("- What I see: \(text)") }
        if let text = nonEmpty(entry.lookingFor) { lines.append("- Looking for: \(text)") }
        if let text = nonEmpty(entry.wantToSee) { lines.append("- Want to see: \(text)") }

        var tags: [String] = []
        if let action = nonEmpty(entry.action) { tags.append("Action: \(action)") }
        if let play = nonEmpty(entry.playType) { tags.append("Play: \(play)") }
        if let level {
            let stars = String(repeating: "★", count: max(1, min(5, level.stars)))
            tags.append("Level: \(level.name) \(stars) @ \(fmt(level.price)) (rank \(level.effectiveRank), min tradeable \(plan.minRankToTrade))")
        }
        if !tags.isEmpty { lines.append("- " + tags.joined(separator: "  ")) }

        lines.append("")
        lines.append("Give a short mentor read (max ~120 words): does this match the plan's play definitions, is the level rank sane, and one discipline reminder if trades taken is at or near the max. Direct, no fluff. Never use the word \"fade\" — say \"reversal\" or frame by direction.")

        return lines.joined(separator: "\n")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func fmt(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e12 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    // MARK: - Output parsing

    /// `--output-format json` yields an object with "result" and "session_id".
    /// Parse defensively: bad JSON or a missing result falls back to raw
    /// stdout, and the session id is regex-scavenged either way.
    private static func parse(stdout: String) -> Result<MentorResult, MentorError> {
        let raw = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failure(.emptyReply) }

        var jsonReply: String?
        var sessionId: String?
        var sawResultKey = false

        if let data = raw.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let r = obj["result"] as? String {
                sawResultKey = true
                let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
                jsonReply = t.isEmpty ? nil : t
            }
            sessionId = obj["session_id"] as? String
        }
        if sessionId == nil {
            sessionId = extractSessionId(from: raw)
        }

        if let jsonReply {
            return .success(MentorResult(reply: jsonReply, claudeSessionId: sessionId))
        }
        if sawResultKey {
            // Valid JSON whose result string was empty — that IS an empty reply;
            // echoing the JSON envelope back would be noise.
            return .failure(.emptyReply)
        }
        // Not valid JSON / no result key: the raw stdout is the reply.
        return .success(MentorResult(reply: raw, claudeSessionId: sessionId))
    }

    private static func extractSessionId(from text: String) -> String? {
        let pattern = #""session_id"\s*:\s*"([^"]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func failureDetail(_ output: ProcessOutput) -> String {
        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stderr.isEmpty ? stdout : stderr
        if detail.isEmpty {
            return "claude exited with code \(output.exitCode)."
        }
        return "exit \(output.exitCode): \(String(detail.prefix(400)))"
    }

    // MARK: - Process plumbing

    private struct ProcessOutput {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private final class LockedFlag {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class DataBox {
        private let lock = NSLock()
        private var data = Data()
        func store(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Hop to a dispatch queue so the blocking wait never parks a cooperative
    /// pool thread (this method is called from an async context).
    private func execute(cli: URL, arguments: [String]) async -> Result<ProcessOutput, MentorError> {
        let cwd = repoRoot
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: Self.runProcess(
                        cli: cli, arguments: arguments, cwd: cwd,
                        timeout: Self.timeoutSeconds))
            }
        }
    }

    private static func runProcess(cli: URL, arguments: [String], cwd: URL,
                                   timeout: TimeInterval) -> Result<ProcessOutput, MentorError> {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = mergedEnvironment()
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes concurrently — a fat reply must never deadlock on a
        // full 64KB pipe buffer while we wait for exit.
        let readers = DispatchGroup()
        let outBox = DataBox()
        let errBox = DataBox()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.store(outPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.store(errPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        do {
            try process.run()
        } catch {
            return .failure(.processFailed("could not launch claude CLI: \(error.localizedDescription)"))
        }

        let timedOut = LockedFlag()
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            // Escalate if SIGTERM is ignored.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        process.waitUntilExit()
        killer.cancel()
        // Readers end at pipe EOF (write ends close on exit). The bounded wait
        // guards against a grandchild process holding a pipe open.
        _ = readers.wait(timeout: .now() + 5)

        if timedOut.isSet {
            return .failure(.timeout)
        }
        return .success(ProcessOutput(
            exitCode: process.terminationStatus,
            stdout: String(data: outBox.value, encoding: .utf8) ?? "",
            stderr: String(data: errBox.value, encoding: .utf8) ?? ""))
    }

    /// The claude CLI shells out to its runtime (node etc.) — make sure the
    /// usual bin dirs are on PATH even when launched from Finder.
    private static func mergedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/.local/bin",
            home + "/bin",
        ]
        let current = env["PATH"] ?? "/usr/bin:/bin"
        let missing = extras.filter { !current.split(separator: ":").map(String.init).contains($0) }
        env["PATH"] = (missing + [current]).joined(separator: ":")
        return env
    }
}
