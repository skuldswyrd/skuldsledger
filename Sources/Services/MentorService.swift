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
        let prompt = Self.buildReviewPrompt(
            entry: entry, session: session, level: level, plan: plan, stats: stats)
        return await run(prompt: prompt, resumeSessionId: resumeSessionId)
    }

    // MARK: - Thread reply (comment back-and-forth under a post)

    /// Mentor's next turn in a post's comment thread. Same CLI plumbing as
    /// `review` — only the prompt differs.
    func threadReply(entry: EntryRecord, thread: [CommentRecord], newComment: String,
                     session: SessionRecord, level: LevelRecord?,
                     plan: TradingPlan, stats: SessionStats,
                     resumeSessionId: String?) async -> Result<MentorResult, MentorError> {
        let prompt = Self.buildThreadPrompt(
            entry: entry, thread: thread, newComment: newComment,
            session: session, level: level, plan: plan, stats: stats)
        return await run(prompt: prompt, resumeSessionId: resumeSessionId)
    }

    // MARK: - Pre-trade edge check (GO / WAIT / NO)

    /// Quick verdict against the one-edge checklist BEFORE the trade. Fresh
    /// conversation every time (no --resume) — the check must never inherit
    /// stale context.
    func preTradeCheck(instrument: String, adx: Double?, stretchSigma: Double?,
                       rsi: Double?, levelName: String?, levelScore: Double?,
                       side: String, plan: TradingPlan) async -> Result<MentorResult, MentorError> {
        let prompt = Self.buildPreTradePrompt(
            instrument: instrument, adx: adx, stretchSigma: stretchSigma,
            rsi: rsi, levelName: levelName, levelScore: levelScore,
            side: side, plan: plan)
        return await run(prompt: prompt, resumeSessionId: nil)
    }

    private static func buildPreTradePrompt(instrument: String, adx: Double?,
                                            stretchSigma: Double?, rsi: Double?,
                                            levelName: String?, levelScore: Double?,
                                            side: String, plan: TradingPlan) -> String {
        var lines: [String] = []
        lines.append("You are skuld's live trading mentor doing a PRE-TRADE edge check. His ONE edge is session VWAP mean reversion (SKULD 3.0). Checklist: regime ADX(14) < 25 full / 25-30 extreme-only (strict RSI 25/75) / > 30 no trade; stretch from session VWAP >= 1.5 sigma; trigger RSI(7) <= 30 long / >= 70 short; entry AT a SKULD key level with a rejection candle; stop beyond the stretch extreme; target session VWAP (or the first working level before it); risk 0.25-0.75% per trade.")
        lines.append("")
        var facts: [String] = ["Instrument: \(instrument)", "Side: \(side.uppercased())"]
        if let adx { facts.append("ADX(14): \(fmt(adx))") }
        if let stretchSigma { facts.append("Stretch from session VWAP: \(fmt(stretchSigma)) sigma") }
        if let rsi { facts.append("RSI(7): \(fmt(rsi))") }
        if let levelName, !levelName.isEmpty {
            var levelLine = "Level: \(levelName)"
            if let levelScore { levelLine += " (score \(fmt(levelScore)))" }
            facts.append(levelLine)
        } else if let levelScore {
            facts.append("Level score: \(fmt(levelScore))")
        }
        facts.append("Plan min rank to trade: \(plan.minRankToTrade)")
        lines.append(contentsOf: facts.map { "- \($0)" })
        lines.append("")
        lines.append("Reply with a verdict — GO, WAIT, or NO — as the FIRST word, then one line of reason against the checklist. Missing values count against GO. Max 60 words total. Never use the word \"fade\" — say \"reversal\" or frame by direction.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared run (resume retry + parse)

    private func run(prompt: String, resumeSessionId: String?) async -> Result<MentorResult, MentorError> {
        guard let cli = Self.locateCLI() else { return .failure(.cliNotFound) }

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

    // MARK: - Prompts

    /// ONE-EDGE doctrine (2026-08-18, SKULD 3.0): SESSION VWAP MEAN REVERSION
    /// is the only play. Injected into BOTH prompts so the first read and
    /// every thread reply hold the same line.
    private static func philosophyBlock(paceBaseline: Int) -> String {
        "He trades ONE edge: session VWAP mean reversion (SKULD 3.0). Trade count (baseline \(paceBaseline)/day), session choice, and the clock are CONTEXT ONLY — NEVER criticize a trade for count, lunch, overnight, or session choice. Grade ONLY: (a) regime — ADX(14) < 25 full trading, 25-30 extreme-only, > 30 no trade; (b) stretch — how far from session VWAP in sigma (needs >= 1.5 sigma or ATR-equivalent); (c) trigger — RSI(7) <= 30 for longs / >= 70 for shorts (strict 25/75 in extreme-only regime); (d) level — was the entry AT a SKULD key level, and what score; (e) rejection candle present at the level; (f) risk — stop beyond the stretch extreme, target session VWAP (or the first working level before it), risk 0.25-0.75% per trade; (g) discipline — did he trade outside the edge (trend day, no stretch, no level, chasing)? Reserve sharp flags for: any MR trade with ADX > 30, entry mid-air (no level), target through a working level, no stop, revenge or euphoria language. Otherwise constructive, specific, short."
    }

    private static func sessionLine(session: SessionRecord, stats: SessionStats) -> String {
        var line = "Session: \(session.instrument) \(session.date)"
        if let lo = session.ibLow, let hi = session.ibHigh {
            line += ", IB \(fmt(lo))-\(fmt(hi))"
        }
        line += ". Trades taken: \(stats.tradesTaken) (pace baseline \(stats.maxTrades)/day)."
        return line
    }

    /// The four post fields + tag line, empties omitted. Shared verbatim by
    /// the review prompt and the thread prompt's "original post" section.
    private static func entryFieldLines(entry: EntryRecord, level: LevelRecord?,
                                        plan: TradingPlan) -> [String] {
        var lines: [String] = []
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
        return lines
    }

    private static func buildReviewPrompt(entry: EntryRecord, session: SessionRecord,
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
        lines.append(sessionLine(session: session, stats: stats))

        // Stats were recomputed after this entry was saved, so the action
        // counts sum IS the entry count (floor 1 covers the retry-later path).
        let n = max(1, stats.actionCounts.values.reduce(0, +))
        lines.append("Entry #\(n) at \(entry.ts):")
        lines.append(contentsOf: entryFieldLines(entry: entry, level: level, plan: plan))

        lines.append("")
        lines.append(philosophyBlock(paceBaseline: stats.maxTrades))
        lines.append("")
        lines.append("Give a short mentor read (max ~120 words) graded against the one-edge checklist above: regime, stretch, trigger, level, rejection, risk, discipline. Direct, no fluff. Never use the word \"fade\" — say \"reversal\" or frame by direction.")

        return lines.joined(separator: "\n")
    }

    private static func buildThreadPrompt(entry: EntryRecord, thread: [CommentRecord],
                                          newComment: String, session: SessionRecord,
                                          level: LevelRecord?, plan: TradingPlan,
                                          stats: SessionStats) -> String {
        var lines: [String] = []

        let shot = entry.screenshotPath.trimmingCharacters(in: .whitespaces)
        if shot.isEmpty {
            lines.append("You are skuld's live trading mentor, continuing the comment thread under one of his journal posts. Read the plan at skuld_trading_operation.json using your Read tool if you need it.")
        } else {
            lines.append("You are skuld's live trading mentor, continuing the comment thread under one of his journal posts. Read the plan at skuld_trading_operation.json and the post's screenshot at \(shot) using your Read tool if you need them.")
        }
        lines.append("")
        lines.append(sessionLine(session: session, stats: stats))
        lines.append("Original post at \(entry.ts):")
        lines.append(contentsOf: entryFieldLines(entry: entry, level: level, plan: plan))

        // Chronological exchange: the original mentor read leads, then the
        // saved comments. The caller's thread already contains the just-saved
        // new comment — drop that trailing duplicate since it's called out
        // separately below.
        var prior = thread
        if let last = prior.last, last.author == "user",
           last.text.trimmingCharacters(in: .whitespacesAndNewlines)
               == newComment.trimmingCharacters(in: .whitespacesAndNewlines) {
            prior.removeLast()
        }
        var exchange: [String] = []
        if let read = nonEmpty(entry.mentorReply) {
            exchange.append("You said: \(read)")
        }
        for comment in prior {
            guard let text = nonEmpty(comment.text) else { continue }
            exchange.append(comment.author == "mentor"
                ? "You said: \(text)"
                : "Trader replied: \(text)")
        }
        if !exchange.isEmpty {
            lines.append("")
            lines.append("Thread so far:")
            lines.append(contentsOf: exchange)
        }

        lines.append("")
        lines.append("Trader's new comment: \(newComment)")
        lines.append("")
        lines.append(philosophyBlock(paceBaseline: stats.maxTrades))
        lines.append("")
        lines.append("Continue the conversation as the mentor: answer his new comment directly (max ~100 words), holding the one-edge line above — regime, stretch, trigger, level, rejection, risk, discipline. Direct, specific, no fluff. Never use the word \"fade\" — say \"reversal\" or frame by direction.")

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
