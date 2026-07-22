import Foundation
import SwiftUI
import AppKit

/// In-app notes -> Records/skuld_upgrade_log.md (the same file the Claude
/// patch loop already uses). Type a note while trading, copy the whole file,
/// paste it into a Claude chat for the next upgrade round.
enum UpgradeLog {
    static var url: URL {
        Workspace.recordsDir.appendingPathComponent("skuld_upgrade_log.md")
    }

    static let types = ["BUG", "IDEA", "TUNE", "WIN", "NOTE"]

    private static let template = """
    # Skuld upgrade / error log

    Type notes here while trading. Paste the whole file (or new lines) to Claude for patches.
    Format per line: `- [date time] TYPE: note` — TYPE = BUG / IDEA / TUNE / WIN / NOTE. Loose format fine too, just write.

    ## Open

    ## Shipped (Claude fills this on each patch)

    """

    static func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? template
    }

    /// Appends "- [ts] TYPE: note" at the top of the "## Open" section.
    static func append(note: String, type: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.timeZone = Workspace.eastern
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let line = "- [\(fmt.string(from: Date()))] \(type): \(trimmed)"

        var content = read()
        if let range = content.range(of: "## Open") {
            let insertAt = content.range(of: "\n", range: range.upperBound..<content.endIndex)?.upperBound
                ?? content.endIndex
            content.insert(contentsOf: "\n" + line + "\n", at: insertAt)
        } else {
            content += "\n## Open\n\n\(line)\n"
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("UpgradeLog.append failed: \(error)")
        }
    }

    static func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(read(), forType: .string)
    }
}

// MARK: - UpgradeLogView

/// Sheet: quick note in, whole log out. Copy All -> paste to Claude.
struct UpgradeLogView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var noteText = ""
    @State private var noteType = "BUG"
    @State private var content = UpgradeLog.read()
    @State private var copied = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("UPGRADE / ERROR LOG")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text)
                    .kerning(1.2)
                Spacer()
                Button(copied ? "Copied ✓" : "Copy all") {
                    UpgradeLog.copyAll()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.plain)
                .font(Theme.monoSmall)
                .foregroundStyle(copied ? Theme.green : Theme.cyan)
                .help("Copy the whole log — paste it to Claude for the next patch round")
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 6) {
                ForEach(UpgradeLog.types, id: \.self) { t in
                    Button {
                        noteType = t
                    } label: {
                        Text(t)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(noteType == t ? Theme.bg : Theme.textDim)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(noteType == t ? typeColor(t) : Theme.inset))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField("What broke / what you want changed…", text: $noteText, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text)
                    .focused($noteFocused)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardBorder, lineWidth: 1))
                    .onSubmit(addNote)
                Button("Add") { addNote() }
                    .buttonStyle(.plain)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.green))
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }

            ScrollView {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardBorder, lineWidth: 1))
        }
        .padding(16)
        .frame(width: 620, height: 520)
        .background(Theme.bg)
        .onAppear { noteFocused = true }
    }

    private func addNote() {
        UpgradeLog.append(note: noteText, type: noteType)
        noteText = ""
        content = UpgradeLog.read()
        noteFocused = true
    }

    private func typeColor(_ t: String) -> Color {
        switch t {
        case "BUG": return Theme.red
        case "IDEA": return Theme.cyan
        case "TUNE": return Theme.amber
        case "WIN": return Theme.green
        default: return Theme.textDim
        }
    }
}
