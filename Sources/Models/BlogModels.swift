import Foundation
import GRDB

/// One blog post — Skuldswyrd Online Edition drafts written inside the
/// ledger while trading. Markdown body, optional link to the session it
/// was written during (that's where "pull session notes" reads from).
struct BlogPostRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "blog_posts"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var title: String
    var body: String                 // markdown
    var sessionId: String?
    var status: String               // "draft" / "final"
    var createdAt: String            // ISO8601
    var updatedAt: String            // ISO8601

    var isFinal: Bool { status == "final" }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }
}

/// Writes a post out as a clean markdown file — no app branding, no footer:
/// the exported file is exactly what gets pasted to social.
enum BlogExporter {

    /// Blog/exports/<yyyy-MM-dd>-<slug>.md under the workspace root (overwrite).
    static func write(post: BlogPostRecord, root: URL) throws -> URL {
        let dir = root.appendingPathComponent("Blog/exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(datePrefix(post.createdAt))-\(slug(post.title)).md")
        try composed(post).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Title as an H1 over the body — unless there is no title.
    static func composed(_ post: BlogPostRecord) -> String {
        let t = post.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = post.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return b + "\n" }
        return "# \(t)\n\n\(b)\n"
    }

    static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        var lastDash = true
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "untitled" : String(out.prefix(60))
    }

    private static func datePrefix(_ iso: String) -> String {
        // ISO8601 leads with yyyy-MM-dd; fall back to today if malformed.
        let prefix = String(iso.prefix(10))
        return prefix.count == 10 ? prefix : Workspace.todayString()
    }
}

/// Pure formatter: the on-screen session condensed to blog raw material.
/// Pasted into a draft so the post gets written FROM the day's record, not
/// from memory after the close.
enum SessionDigest {

    static func markdown(session: SessionRecord, stats: SessionStats,
                         levels: [LevelRecord], entries: [EntryRecord],
                         trades: [TradeRecord]) -> String {
        var lines: [String] = []
        let label = session.name.map { "\($0) · \(session.instrument)" }
            ?? session.instrument
        lines.append("## Session notes — \(session.date) · \(label)")
        lines.append("")
        lines.append("- Net: \(usd(stats.netUsd)) (\(ticks(stats.netTicks))) · \(stats.tradesTaken) trades · \(stats.wins)W \(stats.losses)L \(stats.scratches)S")
        if let lo = session.ibLow, let hi = session.ibHigh {
            lines.append("- IB: \(price(lo)) – \(price(hi))")
        }
        if !levels.isEmpty {
            let tops = levels.sorted { $0.stars > $1.stars }.prefix(6).map {
                "\($0.name) \(stars($0.stars)) @ \(price($0.price)) \($0.broken ? "BROKE" : "HELD")"
            }
            lines.append("- Levels: " + tops.joined(separator: " · "))
        }
        lines.append("")

        let ordered = entries.sorted { $0.ts < $1.ts }
        if !ordered.isEmpty {
            lines.append("### Timeline")
            lines.append("")
            let tradesByEntry = Dictionary(grouping: trades, by: \.entryId)
            for entry in ordered {
                let action = (entry.action ?? "note").uppercased()
                var head = "- **\(etTime(entry.ts)) ET · \(action)**"
                if let text = entry.comment, !text.isEmpty {
                    head += " — \(inline(text))"
                }
                lines.append(head)
                var context: [String] = []
                if let text = entry.lookingFor, !text.isEmpty {
                    context.append("Looking for: \(inline(text))")
                }
                if let text = entry.wantToSee, !text.isEmpty {
                    context.append("Want to see: \(inline(text))")
                }
                if !context.isEmpty {
                    lines.append("  - \(context.joined(separator: " · "))")
                }
                if let trade = tradesByEntry[entry.id]?.first {
                    var parts = ["Trade: \(trade.playType)"]
                    if let side = trade.side { parts.append(side.uppercased()) }
                    if let tk = trade.ticksResult { parts.append(ticks(tk)) }
                    if let us = trade.usdResult { parts.append(usd(us)) }
                    parts.append((trade.result ?? "open").uppercased())
                    lines.append("  - \(parts.joined(separator: " · "))")
                }
                if let reply = entry.mentorReply?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !reply.isEmpty {
                    lines.append("  - Mentor: \"\(inline(String(reply.prefix(220))))\(reply.count > 220 ? "…" : "")\"")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting (mirrors the report's tone, kept private here)

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
        return iso
    }

    private static func price(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func ticks(_ value: Double) -> String {
        let sign = value > 0 ? "+" : (value < 0 ? "-" : "")
        var body = String(format: "%.2f", abs(value))
        while body.hasSuffix("0") { body.removeLast() }
        if body.hasSuffix(".") { body.removeLast() }
        return "\(sign)\(body)t"
    }

    private static func usd(_ value: Double) -> String {
        let body = String(format: "%.2f", abs(value))
        if value > 0 { return "+$\(body)" }
        if value < 0 { return "-$\(body)" }
        return "$\(body)"
    }

    private static func stars(_ count: Int) -> String {
        String(repeating: "★", count: max(1, min(5, count)))
    }

    private static func inline(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
