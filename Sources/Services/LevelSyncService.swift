import Foundation
import AppKit
import Vision

/// A ranked cluster read off the live TradingView chart (Skuld Unified
/// labels — v2 score format "[12] pdH+NY H  29192.50 · 3.50", v1 star
/// format "★★★★★ pdH+NY H  29192.50 · 3.50").
struct ChartLevel: Equatable {
    let name: String
    let price: Double
    let stars: Int
    /// Exact summed rank from the v2 score labels; nil on legacy ★ labels.
    let rank: Int?
}

enum LevelSyncError: Error, LocalizedError {
    case cliNotFound
    case timeout
    case failed(String)
    case noLevels

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "tv CLI not found — install the TradingView bridge."
        case .timeout: return "TradingView read timed out — is TV running with CDP? (tv launch)"
        case .failed(let msg): return "TradingView read failed: \(msg)"
        case .noLevels: return "No ★ cluster labels on the chart — is the Skuld indicator visible?"
        }
    }
}

/// Reads ranked levels straight off the live chart by shelling out to the
/// `tv` CLI (CDP bridge on localhost:9222). Same no-API-key pattern as the
/// mentor: subprocess, timeout, never blocks the journal.
final class LevelSyncService {

    static func locateCLI() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/tv",
            "/usr/local/bin/tv",
            NSHomeDirectory() + "/.local/bin/tv",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let p = String(dir) + "/tv"
                if FileManager.default.isExecutableFile(atPath: p) {
                    return URL(fileURLWithPath: p)
                }
            }
        }
        return nil
    }

    /// True when the CDP bridge answers — cheap TV-connection health check.
    static func cdpAlive() async -> Bool {
        guard let url = URL(string: "http://localhost:9222/json/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func fetchLevels() async -> Result<[ChartLevel], LevelSyncError> {
        guard let cli = Self.locateCLI() else { return .failure(.cliNotFound) }

        let output: String
        switch await runProcess(cli: cli, args: ["data", "labels", "-f", "Skuld", "-n", "60"], timeout: 20) {
        case .success(let out): output = out
        case .failure(let err): return .failure(err)
        }

        guard let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let studies = obj["studies"] as? [[String: Any]] else {
            return .failure(.failed("unreadable tv output"))
        }

        var levels: [ChartLevel] = []
        for study in studies {
            for label in (study["labels"] as? [[String: Any]] ?? []) {
                guard let text = label["text"] as? String else { continue }
                if let level = Self.parseClusterLabel(text, fallbackPrice: label["price"] as? Double) {
                    levels.append(level)
                }
            }
        }
        // Chart may briefly show duplicate labels during redraw — dedupe by name.
        var seen = Set<String>()
        levels = levels.filter { seen.insert($0.name.lowercased()).inserted }

        return levels.isEmpty ? .failure(.noLevels) : .success(levels)
    }

    /// "[12] AS VAH+AS H  29154.75 · 34.25" -> (rank 12, stars band 5, price 29154.75).
    /// Legacy "★★★★ name  price · dist" still parses (rank nil). Other labels
    /// (trade plans, TP/SL stamps) are skipped. Price comes from the label TEXT
    /// (exact level); the label's y-price drifts and is only a fallback.
    static func parseClusterLabel(_ text: String, fallbackPrice: Double?) -> ChartLevel? {
        var stars = 0
        var rank: Int?
        var rest: String
        if text.hasPrefix("[") {
            guard let closeBracket = text.firstIndex(of: "]"),
                  let parsed = Int(text[text.index(after: text.startIndex)..<closeBracket]) else {
                return nil
            }
            rank = parsed
            stars = starBand(parsed)
            rest = String(text[text.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
        } else if text.hasPrefix("★") {
            stars = text.prefix(while: { $0 == "★" }).count
            rest = String(text.dropFirst(stars)).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }
        // Trailing "· <distance>" segment is live distance-to-price — drop it.
        if let dot = rest.range(of: "·", options: .backwards) {
            rest = String(rest[..<dot.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        // Last whitespace-separated numeric token = the level price.
        var name = rest
        var price: Double?
        if let lastSpace = rest.range(of: " ", options: .backwards) {
            let tail = rest[lastSpace.upperBound...].replacingOccurrences(of: ",", with: "")
            if let p = Double(tail) {
                price = p
                name = String(rest[..<lastSpace.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let finalPrice = price ?? fallbackPrice, !name.isEmpty else { return nil }
        return ChartLevel(name: name, price: finalPrice, stars: max(1, min(5, stars)), rank: rank)
    }

    /// Same banding the indicator uses for colors: ≥10 → 5★ … <4 → 1★.
    static func starBand(_ rank: Int) -> Int {
        rank >= 10 ? 5 : rank >= 8 ? 4 : rank >= 6 ? 3 : rank >= 4 ? 2 : 1
    }

    // MARK: - Screenshot fallback (no bridge needed)

    /// Native Vision OCR over the posted screenshot — the chart prints its own
    /// "[12] pdH+NY H  29192.50 · 3.50" labels, and OCR reads them in ~2s.
    /// Fully local, no bridge, no subprocess.
    func extractLevels(fromScreenshot relPath: String, repoRoot: URL) async -> Result<[ChartLevel], LevelSyncError> {
        let url = relPath.hasPrefix("/")
            ? URL(fileURLWithPath: relPath)
            : repoRoot.appendingPathComponent(relPath)
        let lines: [String]
        switch Self.recognizeTextLines(imageURL: url) {
        case .failure(let err): return .failure(err)
        case .success(let recognized): lines = recognized
        }

        var levels: [ChartLevel] = []
        for line in lines {
            if let level = Self.parseOCRLevelLine(line) {
                levels.append(level)
            }
        }
        var seen = Set<String>()
        levels = levels.filter { seen.insert($0.name.lowercased()).inserted }
        return levels.isEmpty ? .failure(.noLevels) : .success(levels)
    }

    static func recognizeTextLines(imageURL: URL) -> Result<[String], LevelSyncError> {
        guard let image = NSImage(contentsOf: imageURL),
              var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .failure(.failed("could not load screenshot image"))
        }
        // Chart labels are small — a 2x upscale materially improves Vision's
        // read of the bracket scores. Cap at ~6k px so memory stays sane.
        if max(cg.width, cg.height) < 3000, let scaled = upscale2x(cg) {
            cg = scaled
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.customWords = [
            "pdPOC", "pwPOC", "pdVAH", "pdVAL", "pwVAH", "pwVAL", "pdLVN", "pwLVN",
            "pdHVN", "pwHVN", "pdH", "pdL", "pwH", "pwL", "VWAP", "sPOC", "sVAH",
            "sVAL", "dPOC", "dVAH", "dVAL", "ONH", "ONL", "IBH", "IBL",
            "NY POC", "NY VAH", "NY VAL", "AS POC", "AS VAH", "AS VAL",
            "LDN POC", "LDN VAH", "LDN VAL", "NY H", "NY L", "AS H", "AS L",
        ]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .failure(.failed("OCR failed: \(error.localizedDescription)"))
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return .success(lines)
    }

    private static func upscale2x(_ cg: CGImage) -> CGImage? {
        let w = cg.width * 2
        let h = cg.height * 2
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// "[12] pdH+NY H  29192.50 · 3.50" -> ChartLevel, tolerant of real OCR
    /// mangling seen in the field: leading line artifacts ("- [8] PWVAL…"),
    /// brackets as parens/pipes ("(6)", "|2"), "·" read as "-", comma
    /// thousands, split/garbled prices ("29245./5" is dropped, not guessed).
    static func parseOCRLevelLine(_ raw: String) -> ChartLevel? {
        var line = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
        // Level lines start after the drawn line's OCR artifacts.
        while let f = line.first, "-—–|•·~_ ".contains(f) { line.removeFirst() }

        var rank: Int?
        var rest: String

        if let m = line.range(of: #"^[\[\(](\d{1,2})[\]\)]"#, options: .regularExpression) {
            rank = Int(line[m].dropFirst().dropLast())
            rest = String(line[m.upperBound...])
        } else if line.hasPrefix("★") {
            let stars = line.prefix(while: { $0 == "★" }).count
            rank = [1: 1, 2: 4, 3: 6, 4: 8, 5: 10][min(5, max(1, stars))]
            rest = String(line.dropFirst(stars))
        } else {
            return nil
        }
        rest = rest.trimmingCharacters(in: .whitespaces)

        // Price = first futures-price-shaped token (>=3 integer digits, two
        // decimals). Distances like "48.75" (2 digits) never match — a line
        // whose price got OCR-garbled is skipped, not guessed.
        guard let pm = rest.range(of: #"\d{3,6}\.\d{2}"#, options: .regularExpression),
              let price = Double(rest[pm]), price > 0 else {
            return nil
        }
        let name = String(rest[..<pm.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " -—–·•|:"))
        guard name.count >= 2, name.count <= 30,
              name.rangeOfCharacter(from: .letters) != nil else {
            return nil
        }
        let upper = name.uppercased()
        for banned in ["TP", "SL", "E", "S", "T", "SIGNAL", "SIGNALS", "TUNE", "MODE", "IB", "FILTER", "NEAREST", "SESSION", "SPOC"] where upper == banned {
            return nil
        }
        return ChartLevel(name: name, price: price, stars: starBand(rank ?? 1), rank: rank)
    }

    // MARK: - Process plumbing

    private func runProcess(cli: URL, args: [String], timeout: TimeInterval, cwd: URL? = nil) async -> Result<String, LevelSyncError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = cli
                process.arguments = args
                if let cwd { process.currentDirectoryURL = cwd }
                var env = ProcessInfo.processInfo.environment
                let extras = ["/opt/homebrew/bin", "/usr/local/bin"]
                let currentPath = env["PATH"] ?? ""
                let missing = extras.filter { !currentPath.contains($0) }
                if !missing.isEmpty {
                    env["PATH"] = (missing + [currentPath]).joined(separator: ":")
                }
                process.environment = env

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(.failed(error.localizedDescription)))
                    return
                }

                var timedOut = false
                let killer = DispatchWorkItem {
                    timedOut = true
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                _ = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()

                if timedOut {
                    continuation.resume(returning: .failure(.timeout))
                } else if process.terminationStatus != 0 {
                    let msg = String(data: outData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
                    continuation.resume(returning: .failure(.failed(String(msg.prefix(200)))))
                } else {
                    continuation.resume(returning: .success(String(data: outData, encoding: .utf8) ?? ""))
                }
            }
        }
    }
}
