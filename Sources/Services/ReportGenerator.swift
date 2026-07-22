import Foundation

/// End-of-day markdown report writer (contract section 4).
///
/// Pure formatter: takes the already-loaded session snapshot and writes
/// `Reports/<date>_session_report.md` under the workspace root (overwrite).
/// Image links are emitted relative to the Reports folder — the stored
/// screenshot paths are workspace-root-relative (`Records/<date>/assets/…`),
/// and Reports/ sits one level below the root, so a single `../` hop resolves
/// them in any standard markdown viewer opened from disk.
enum ReportGenerator {

    static func generate(root: URL, session: SessionRecord, levels: [LevelRecord],
                         entries: [EntryRecord], trades: [TradeRecord],
                         chops: [ChopRecord], comments: [String: [CommentRecord]],
                         stats: SessionStats, plan: TradingPlan) throws -> URL {
        let reportsDir = root.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
        let url = reportsDir.appendingPathComponent("\(session.date)_session_report.md")

        let levelById = Dictionary(levels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tradesByEntry = Dictionary(grouping: trades, by: { $0.entryId })

        var md: [String] = []
        md += headerSection(session: session, stats: stats, plan: plan)
        md += statsSection(stats: stats)
        md += levelsSection(levels: levels)
        md += starSection(stats: stats)
        md += playSection(stats: stats)
        md += signalsSection(stats: stats)
        md += chopSection(chops: chops)
        md += timelineSection(entries: entries, tradesByEntry: tradesByEntry,
                              levelById: levelById, comments: comments)
        md.append("---")
        md.append("")
        md.append("_Generated \(Workspace.isoNow()) by Skuld's Ledger._")
        md.append("")

        try md.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Sections

    private static func headerSection(session: SessionRecord, stats: SessionStats,
                                      plan: TradingPlan) -> [String] {
        let ib: String
        switch (session.ibLow, session.ibHigh) {
        case let (lo?, hi?): ib = "\(price(lo)) – \(price(hi))"
        case let (lo?, nil): ib = "low \(price(lo)) / high not set"
        case let (nil, hi?): ib = "low not set / high \(price(hi))"
        default:             ib = "not set"
        }
        var lines = [
            "# Session Report — \(session.date)",
            "",
            "| | |",
            "|---|---|",
            "| Base instrument | \(cell(session.instrument)) |"
        ]
        // Distinct instruments actually traded (he switches NQ/ES mid-day).
        if !stats.instrumentRows.isEmpty {
            let traded = stats.instrumentRows.map(\.instrument).joined(separator: ", ")
            lines.append("| Instruments traded | \(cell(traded)) |")
        }
        lines += [
            "| IB range | \(ib) |",
            "| Status | \(cell(session.status.uppercased())) |",
            "| Plan | v\(cell(plan.version)) · pace baseline \(plan.maxTradesPerDay)/day · min rank \(plan.minRankToTrade) |",
            ""
        ]
        return lines
    }

    private static func statsSection(stats: SessionStats) -> [String] {
        let target = stats.dailyTargetUsd.map { "$" + String(format: "%.2f", $0) } ?? "—"
        let maxLoss = stats.dailyMaxLossUsd.map { "$" + String(format: "%.2f", abs($0)) }
            ?? "UNDEFINED — not enforced"
        var lines = [
            "## Stats",
            "",
            "| Metric | Value |",
            "|---|---|",
            "| Trades | \(stats.tradesTaken) (pace baseline \(stats.maxTrades)/day) |",
            "| W / L / Scratch | \(stats.wins) / \(stats.losses) / \(stats.scratches) |"
        ]
        if stats.openTrades > 0 {
            lines.append("| Open trades | \(stats.openTrades) |")
        }
        lines += [
            "| Net ticks | \(ticks(stats.netTicks)) |",
            "| Net USD | \(usd(stats.netUsd)) |",
            "| Daily target | \(target) |",
            "| Daily max loss | \(maxLoss) |",
            ""
        ]
        // P&L split by instrument — only worth a table when the day actually
        // crossed products.
        if stats.instrumentRows.count > 1 {
            lines += [
                "### By instrument",
                "",
                "| Instrument | Trades | Ticks | USD |",
                "|---|---|---|---|"
            ]
            for row in stats.instrumentRows {
                lines.append("| \(cell(row.instrument)) | \(row.trades) | \(ticks(row.netTicks)) | \(usd(row.netUsd)) |")
            }
            lines.append("")
        }
        return lines
    }

    private static func levelsSection(levels: [LevelRecord]) -> [String] {
        var lines = ["## Levels", ""]
        guard !levels.isEmpty else {
            lines += ["_No levels logged._", ""]
            return lines
        }
        lines += [
            "| Level | Price | Stars | Rank | Status |",
            "|---|---|---|---|---|"
        ]
        for level in levels {
            let status = level.broken ? "BROKE" : "HELD"
            lines.append("| \(cell(level.name)) | \(price(level.price)) | \(stars(level.stars)) | \(level.effectiveRank) | \(status) |")
        }
        lines.append("")
        return lines
    }

    private static func starSection(stats: SessionStats) -> [String] {
        var lines = ["## Star-rank hit rate", ""]
        guard !stats.starRows.isEmpty else {
            lines += ["_No trades tagged to ranked levels._", ""]
            return lines
        }
        lines += [
            "| Stars | Signals | W | L | Hit rate |",
            "|---|---|---|---|---|"
        ]
        for row in stats.starRows {
            lines.append("| \(stars(row.stars)) | \(row.signals) | \(row.wins) | \(row.losses) | \(pct(row.hitRate)) |")
        }
        lines.append("")
        return lines
    }

    private static func playSection(stats: SessionStats) -> [String] {
        var lines = ["## Plays", ""]
        guard !stats.playRows.isEmpty else {
            lines += ["_No trades taken._", ""]
            return lines
        }
        lines += [
            "| Play | Taken | W | L | Win rate |",
            "|---|---|---|---|---|"
        ]
        for row in stats.playRows {
            lines.append("| \(cell(row.play)) | \(row.taken) | \(row.wins) | \(row.losses) | \(pct(row.winRate)) |")
        }
        lines.append("")
        return lines
    }

    private static func signalsSection(stats: SessionStats) -> [String] {
        var lines = ["## Signals", ""]
        lines.append("- Offered: \(stats.signalsOffered) · Taken: \(stats.signalsTaken)")
        if !stats.actionCounts.isEmpty {
            let canonical = EntryAction.allCases.map(\.rawValue)
            let known = canonical.compactMap { key in
                stats.actionCounts[key].map { "\(key) \($0)" }
            }
            let extras = stats.actionCounts.keys
                .filter { !canonical.contains($0) }
                .sorted()
                .compactMap { key in stats.actionCounts[key].map { "\(key) \($0)" } }
            lines.append("- Actions: " + (known + extras).joined(separator: " · "))
        }
        lines.append("- Chop periods: \(stats.chopCount)")
        lines.append("- Levels held / broke: \(stats.levelsHeld) / \(stats.levelsBroken)")
        lines.append("")
        return lines
    }

    private static func chopSection(chops: [ChopRecord]) -> [String] {
        var lines = ["## Chop log", ""]
        guard !chops.isEmpty else {
            lines += ["_No chop periods logged._", ""]
            return lines
        }
        lines += [
            "| Time (ET) | High | Low | Crossings |",
            "|---|---|---|---|"
        ]
        for chop in chops.sorted(by: { $0.ts < $1.ts }) {
            let crossings = chop.crossings.map(String.init) ?? "—"
            lines.append("| \(etTime(chop.ts)) | \(price(chop.rangeHigh)) | \(price(chop.rangeLow)) | \(crossings) |")
        }
        lines.append("")
        return lines
    }

    private static func timelineSection(entries: [EntryRecord],
                                        tradesByEntry: [String: [TradeRecord]],
                                        levelById: [String: LevelRecord],
                                        comments: [String: [CommentRecord]]) -> [String] {
        var lines = ["## Timeline", ""]
        // Store hands entries newest-first; the report reads top-to-bottom
        // through the day, so re-sort oldest-first. ISO8601 UTC strings sort
        // lexicographically in time order.
        let ordered = entries.sorted { $0.ts < $1.ts }
        guard !ordered.isEmpty else {
            lines += ["_No entries logged._", ""]
            return lines
        }
        for (index, entry) in ordered.enumerated() {
            let action = (entry.action ?? "note").uppercased()
            lines.append("### #\(index + 1) · \(etTime(entry.ts)) ET · \(action)")
            lines.append("")

            if let link = imageLink(entry.screenshotPath) {
                lines.append(link)
                lines.append("")
            }

            var fields: [String] = []
            if let text = entry.comment, !text.isEmpty {
                fields.append("- **What I see:** \(inline(text))")
            }
            if let text = entry.lookingFor, !text.isEmpty {
                fields.append("- **Looking for:** \(inline(text))")
            }
            if let text = entry.wantToSee, !text.isEmpty {
                fields.append("- **Want to see:** \(inline(text))")
            }
            var tags: [String] = []
            if let play = entry.playType, !play.isEmpty {
                tags.append("Play `\(play)`")
            }
            if let levelId = entry.levelId, let level = levelById[levelId] {
                tags.append("Level \(inline(level.name)) \(stars(level.stars)) @ \(price(level.price)) (rank \(level.effectiveRank))")
            }
            if !tags.isEmpty {
                fields.append("- " + tags.joined(separator: " · "))
            }
            if !fields.isEmpty {
                lines += fields
                lines.append("")
            }

            if let trade = tradesByEntry[entry.id]?.first {
                lines.append(tradeLine(trade))
                lines.append("")
            }

            if let reply = entry.mentorReply,
               !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("> **Mentor:**")
                for row in reply.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("> \(row)")
                }
                lines.append("")
            }

            // Thread under the post (user <-> mentor back-and-forth), oldest
            // first — rendered as its own blockquote block after the review.
            if let thread = comments[entry.id], !thread.isEmpty {
                lines += threadLines(thread)
                lines.append("")
            }
        }
        return lines
    }

    /// One blockquote block for the whole thread; each comment starts with its
    /// author tag, continuation lines keep the `> ` prefix so multi-line
    /// replies stay inside the quote.
    private static func threadLines(_ thread: [CommentRecord]) -> [String] {
        var lines: [String] = []
        for comment in thread.sorted(by: { $0.ts < $1.ts }) {
            let author = comment.author == "user" ? "You" : "Mentor"
            let rows = comment.text.split(separator: "\n", omittingEmptySubsequences: false)
            guard let first = rows.first else { continue }
            lines.append("> **\(author):** \(first)")
            for row in rows.dropFirst() {
                lines.append("> \(row)")
            }
        }
        return lines
    }

    private static func tradeLine(_ trade: TradeRecord) -> String {
        var parts: [String] = ["**Trade:** \(trade.playType) · \(trade.contracts) ct"]
        parts.append("E \(price(trade.entryPrice)) / S \(price(trade.stopPrice)) / T \(price(trade.targetPrice))")
        if let exit = trade.exitPrice { parts.append("exit \(price(exit))") }
        if let tk = trade.ticksResult { parts.append(ticks(tk)) }
        if let us = trade.usdResult { parts.append(usd(us)) }
        parts.append((trade.result ?? "open").uppercased())
        return parts.joined(separator: " · ")
    }

    // MARK: - Paths & time

    /// Stored screenshot paths are workspace-root-relative; the report lives
    /// in Reports/ one level below the root, so prefix a single `../`.
    /// Absolute paths (outside-root edge case) pass through untouched.
    private static func imageLink(_ storedPath: String) -> String? {
        let trimmed = storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let target = trimmed.hasPrefix("/") ? trimmed : "../\(trimmed)"
        // Angle brackets keep the link valid if a path segment carries spaces.
        return target.contains(" ") ? "![](<\(target)>)" : "![](\(target))"
    }

    private static let isoPlain: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static let etClock: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.timeZone = Workspace.eastern
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    private static func etTime(_ iso: String) -> String {
        if let date = isoPlain.date(from: iso) ?? isoFractional.date(from: iso) {
            return etClock.string(from: date)
        }
        return iso // unparseable — surface the raw stamp rather than guess
    }

    // MARK: - Formatting helpers

    private static func price(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func price(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "—"
    }

    private static func ticks(_ value: Double) -> String {
        let body = trimNumber(String(format: "%.2f", abs(value)))
        let sign = value > 0 ? "+" : (value < 0 ? "-" : "")
        return "\(sign)\(body)t"
    }

    private static func usd(_ value: Double) -> String {
        let body = String(format: "%.2f", abs(value))
        if value > 0 { return "+$\(body)" }
        if value < 0 { return "-$\(body)" }
        return "$\(body)"
    }

    private static func pct(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    private static func trimNumber(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    private static func stars(_ count: Int) -> String {
        String(repeating: "★", count: max(1, min(5, count)))
    }

    /// Table-cell text: escape pipes, collapse newlines so rows stay intact.
    private static func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Bullet-line text: collapse newlines so the list item stays one item.
    private static func inline(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
