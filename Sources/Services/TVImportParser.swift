import Foundation

/// One broker round trip reconstructed from a TradingView account-history
/// paste. Entry facts come from the "Commission for: Enter position" line
/// (timestamp + fee); price truth comes from the Close line's AVG price.
struct TVRoundTrip: Identifiable {
    let id = UUID()
    var symbol: String               // "CME_MINI:NQ1!"
    var instrument: Instrument?      // nil = unknown product (still importable)
    var side: String                 // "long" / "short"
    var units: Int
    var entryTime: Date?
    var exitTime: Date
    var entryPrice: Double           // position AVG from the close line
    var exitPrice: Double
    var grossUsd: Double             // cash on the close line (pre-commission)
    var commissionUsd: Double        // entry + exit fees, positive number
    var pointValue: Double

    var netUsd: Double { grossUsd - commissionUsd }
    /// Signed ticks; nil when the product's tick math is unknown.
    var ticks: Double? {
        guard let instrument else { return nil }
        let dir: Double = side == "long" ? 1 : -1
        return (exitPrice - entryPrice) / instrument.tickSize * dir
    }
}

struct TVImportParse {
    var trips: [TVRoundTrip] = []
    var warnings: [String] = []
    var totalGross: Double { trips.reduce(0) { $0 + $1.grossUsd } }
    var totalCommission: Double { trips.reduce(0) { $0 + $1.commissionUsd } }
    var totalNet: Double { trips.reduce(0) { $0 + $1.netUsd } }
}

/// Parses the text a user copies out of TradingView's paper/broker account
/// history panel. Line shape (verified against a real 2026-07-22 paste):
///
///   2026-07-22 14:50:34 <tab> 101,011.45 <tab> 101,010.60 <tab>
///   −0.85                       <- amount, minus is U+2212 OR ascii
///   USD
///   Commission for: Close short position for symbol CME_MINI:NQ1! at price
///   29226.50 for 1 units. Position AVG Price was 29241.750000, ... point value: 20.000000
///
/// Events are re-sorted ascending and paired per symbol (FIFO): an
/// Enter-commission opens a pending position, the matching Close line closes
/// it, the Close-commission attaches its fee.
enum TVImportParser {

    // MARK: - Event model

    private struct Event {
        enum Kind {
            case enterCommission(symbol: String, price: Double, units: Int, fee: Double)
            case closeCommission(symbol: String, fee: Double)
            case close(symbol: String, side: String, exitPrice: Double, units: Int,
                       avgEntry: Double, pointValue: Double, cash: Double)
        }
        var time: Date
        var order: Int          // original text position — stabilizes same-second sorting
        var kind: Kind
    }

    /// Broker timestamps read in ET (matches the chart clock in use).
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = Workspace.eastern
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Public

    static func parse(_ text: String) -> TVImportParse {
        var result = TVImportParse()
        let events = extractEvents(from: text, warnings: &result.warnings)
        guard !events.isEmpty else {
            if result.warnings.isEmpty {
                result.warnings.append("Nothing recognizable — copy the account history rows straight out of TradingView.")
            }
            return result
        }

        // Oldest first; same-second ties keep reverse text order (paste is
        // newest-first, so a larger text position = earlier event).
        let sorted = events.sorted {
            $0.time != $1.time ? $0.time < $1.time : $0.order > $1.order
        }

        struct Pending { var time: Date; var price: Double; var units: Int; var fee: Double }
        var pendingBySymbol: [String: [Pending]] = [:]
        var trips: [TVRoundTrip] = []
        var closeFees: [(symbol: String, time: Date, fee: Double)] = []

        for event in sorted {
            switch event.kind {
            case .enterCommission(let symbol, let price, let units, let fee):
                pendingBySymbol[symbol, default: []].append(
                    Pending(time: event.time, price: price, units: units, fee: fee))

            case .close(let symbol, let side, let exitPrice, let units,
                        let avgEntry, let pointValue, let cash):
                var entryTime: Date?
                var entryFee = 0.0
                if var queue = pendingBySymbol[symbol], !queue.isEmpty {
                    let pending = queue.removeFirst()
                    pendingBySymbol[symbol] = queue
                    entryTime = pending.time
                    entryFee = pending.fee
                } else {
                    result.warnings.append("No matching entry found for \(symbol) close at \(exitPrice) — imported without entry time.")
                }
                trips.append(TVRoundTrip(
                    symbol: symbol,
                    instrument: detectInstrument(symbol: symbol, pointValue: pointValue),
                    side: side,
                    units: units,
                    entryTime: entryTime,
                    exitTime: event.time,
                    entryPrice: avgEntry,
                    exitPrice: exitPrice,
                    grossUsd: cash,
                    commissionUsd: entryFee,
                    pointValue: pointValue))

            case .closeCommission(let symbol, let fee):
                closeFees.append((symbol, event.time, fee))
            }
        }

        // Exit fees attach in a second pass: TradingView's same-second block
        // order is inconsistent (sometimes cash first, sometimes commission),
        // so timestamp-exact matching after ALL closes exist is the only
        // stable rule. Ties go to the trip with the least fees so far.
        for cf in closeFees {
            let exact = trips.indices.filter {
                trips[$0].symbol == cf.symbol && trips[$0].exitTime == cf.time
            }
            if let idx = exact.min(by: { trips[$0].commissionUsd < trips[$1].commissionUsd }) {
                trips[idx].commissionUsd += cf.fee
            } else if let idx = trips.lastIndex(where: {
                $0.symbol == cf.symbol && $0.exitTime <= cf.time
            }) {
                trips[idx].commissionUsd += cf.fee
            }
        }

        for leftover in pendingBySymbol.values.flatMap({ $0 }) {
            result.warnings.append("Open position entered \(timestampFormatter.string(from: leftover.time)) @ \(leftover.price) has no close in this paste — still open? Not imported.")
        }

        result.trips = trips.sorted { $0.exitTime < $1.exitTime }
        return result
    }

    // MARK: - Line scanning

    private static func extractEvents(from text: String, warnings: inout [String]) -> [Event] {
        // Normalize U+2212 minus and split into lines.
        let lines = text
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .components(separatedBy: .newlines)

        // Group into blocks that start at a timestamp line.
        var blocks: [(time: Date, order: Int, lines: [String])] = []
        var current: (time: Date, order: Int, lines: [String])?
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let ts = leadingTimestamp(line) {
                if let done = current { blocks.append(done) }
                current = (ts, i, [line])
            } else if current != nil, !line.isEmpty {
                current?.lines.append(line)
            }
        }
        if let done = current { blocks.append(done) }

        var events: [Event] = []
        for block in blocks {
            let body = block.lines.joined(separator: " ")
            guard let kind = classify(body: body, warnings: &warnings) else { continue }
            events.append(Event(time: block.time, order: block.order, kind: kind))
        }
        return events
    }

    private static func leadingTimestamp(_ line: String) -> Date? {
        guard line.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#,
                         options: .regularExpression) != nil else { return nil }
        return timestampFormatter.date(from: String(line.prefix(19)))
    }

    private static func classify(body: String, warnings: inout [String]) -> Event.Kind? {
        guard body.contains("position for symbol") else { return nil }
        let isCommission = body.contains("Commission for:")
        guard let symbol = firstMatch(#"symbol\s+(\S+?)\s+at price"#, in: body) else {
            warnings.append("Skipped a row — no symbol found: \(String(body.prefix(80)))…")
            return nil
        }
        let amount = signedAmount(in: body)

        if isCommission {
            let fee = abs(amount ?? 0)
            if body.contains("Enter position") {
                guard let price = firstDouble(#"at price\s+([0-9.,]+)"#, in: body) else {
                    warnings.append("Skipped an entry row — no price: \(String(body.prefix(80)))…")
                    return nil
                }
                let units = firstInt(#"for\s+(\d+)\s+units"#, in: body) ?? 1
                return .enterCommission(symbol: symbol, price: price, units: units, fee: fee)
            }
            return .closeCommission(symbol: symbol, fee: fee)
        }

        // Cash-bearing close line.
        guard body.contains("Close long position") || body.contains("Close short position") else {
            return nil   // plain "Enter position" rows carry no cash — entry facts ride the commission row
        }
        guard let exitPrice = firstDouble(#"at price\s+([0-9.,]+)"#, in: body),
              let avgEntry = firstDouble(#"AVG Price was\s+([0-9.,]+)"#, in: body),
              let cash = amount else {
            warnings.append("Skipped a close row — price/amount unreadable: \(String(body.prefix(80)))…")
            return nil
        }
        let side = body.contains("Close long position") ? "long" : "short"
        let units = firstInt(#"for\s+(\d+)\s+units"#, in: body) ?? 1
        let pointValue = firstDouble(#"point value:\s+([0-9.,]+)"#, in: body) ?? 0
        return .close(symbol: symbol, side: side, exitPrice: exitPrice, units: units,
                      avgEntry: avgEntry, pointValue: pointValue, cash: cash)
    }

    /// First signed money amount in the block ("+305.00", "-0.85"); balance
    /// columns are unsigned so they never match.
    private static func signedAmount(in body: String) -> Double? {
        guard let raw = firstMatch(#"(?:^|\s)([+-][0-9][0-9,]*\.\d{2})(?:\s|$)"#, in: body) else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: ""))
    }

    /// "CME_MINI:NQ1!" -> Instrument. Symbol root is definitive; point value
    /// is the cross-check when the root is missing/odd.
    static func detectInstrument(symbol: String, pointValue: Double) -> Instrument? {
        let root = (symbol.split(separator: ":").last.map(String.init) ?? symbol).uppercased()
        for inst in [Instrument.MNQ, .MES, .NQ, .ES] where root.hasPrefix(inst.rawValue) {
            return inst
        }
        switch pointValue {
        case 20: return .NQ
        case 2: return .MNQ
        case 50: return .ES
        case 5: return .MES
        default: return nil
        }
    }

    // MARK: - Regex helpers

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func firstDouble(_ pattern: String, in text: String) -> Double? {
        firstMatch(pattern, in: text).flatMap {
            Double($0.replacingOccurrences(of: ",", with: ""))
        }
    }

    private static func firstInt(_ pattern: String, in text: String) -> Int? {
        firstMatch(pattern, in: text).flatMap(Int.init)
    }
}
