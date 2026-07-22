import SwiftUI
import AppKit

// MARK: - File-private helpers

private let isoParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private let etTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.timeZone = Workspace.eastern
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

/// ISO8601 timestamp -> "HH:mm" in ET. Falls back to the raw string.
private func etTime(fromISO iso: String) -> String {
    guard let date = isoParser.date(from: iso) else { return iso }
    return etTimeFormatter.string(from: date)
}

/// X-style relative age: "now", "4m", "2h".
private func relativeAge(fromISO iso: String, now: Date) -> String {
    guard let date = isoParser.date(from: iso) else { return "" }
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h"
}

private func parseDouble(_ s: String) -> Double? {
    Double(s.trimmingCharacters(in: .whitespaces))
}

private func parseInt(_ s: String) -> Int? {
    Int(s.trimmingCharacters(in: .whitespaces))
}

/// "22910.25" / "8" — two decimals max, trailing zeros trimmed.
private func trimmedNumber(_ v: Double) -> String {
    var s = String(format: "%.2f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

private func usdString(_ v: Double) -> String {
    (v < 0 ? "-$" : "+$") + String(format: "%.2f", abs(v))
}

private func ticksString(_ v: Double) -> String {
    let sign = v > 0 ? "+" : (v < 0 ? "-" : "")
    return sign + trimmedNumber(abs(v)) + "t"
}

private func actionColor(_ action: String) -> Color {
    switch action {
    case "enter": return Theme.green
    case "exit": return Theme.purple
    case "skip": return Theme.blue
    case "chop": return Theme.amber
    default: return Theme.textDim   // wait
    }
}

// MARK: - Shared small views

/// NSImage loader; placeholder when the file is gone.
private struct AssetImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.inset)
                    Text("no image")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        .task(id: url) {
            image = NSImage(contentsOf: url)
        }
    }
}

private struct TagChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
    }
}

private struct LevelChip: View {
    let level: LevelRecord

    var body: some View {
        HStack(spacing: 4) {
            Text(level.name).foregroundStyle(Theme.text)
            Text(Theme.starText(level.stars))
                .foregroundStyle(Theme.starColor(level.stars))
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.inset))
        .overlay(Capsule().stroke(Theme.starColor(level.stars).opacity(0.5), lineWidth: 1))
    }
}

private struct PillButtonStyle: ButtonStyle {
    var color: Color
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.monoSmall)
            .foregroundStyle(filled ? Theme.bg : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(filled ? color : color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// One-tap toggle chip for the composer tag rows.
private struct SelectChip: View {
    let text: String
    let color: Color
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(selected ? Theme.bg : color)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? color : color.opacity(0.10)))
                .overlay(Capsule().stroke(color.opacity(selected ? 1 : 0.45), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct DarkField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.mono)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.inset))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.cardBorder, lineWidth: 1))
    }
}

private extension View {
    func darkField() -> some View { modifier(DarkField()) }
}

// MARK: - FeedView

/// Main live screen — an X-style feed. Composer pinned on top, posts
/// (screenshot + quick caption) stream below, newest first.
struct FeedView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if store.entries.isEmpty {
                        emptyFeed
                    } else {
                        ForEach(store.entries) { entry in
                            EntryCardView(entry: entry)
                            Rectangle()
                                .fill(Theme.cardBorder)
                                .frame(height: 1)
                        }
                    }
                } header: {
                    ComposerView()
                        .background(Theme.bg)
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
    }

    private var emptyFeed: some View {
        VStack(spacing: 8) {
            Circle().fill(Theme.textDim).frame(width: 6, height: 6)
            Text("No posts yet")
                .font(Theme.mono)
                .foregroundStyle(Theme.textDim)
            Text("cmd+s in TradingView, caption it, post. Waits and skips count as reps too.")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ComposerView

/// X-style compose box: latest screenshot auto-attaches, one caption field,
/// one-tap tag chips. Everything else optional behind "more".
struct ComposerView: View {
    @EnvironmentObject private var store: SessionStore

    @State private var selectedShot: URL?
    @State private var comment = ""
    @State private var lookingFor = ""
    @State private var wantToSee = ""
    @State private var action: EntryAction = .wait
    @State private var playType: PlayType?
    @State private var levelId: String?
    @State private var showMore = false
    @State private var chopHighText = ""
    @State private var chopLowText = ""
    @State private var chopCrossingsText = ""
    @FocusState private var captionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("What are you seeing?", text: $comment, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .focused($captionFocused)
                .padding(.top, 10)

            attachedPreview
            spareShotStrip

            if action == .chop { chopRow }
            if showMore { moreFields }

            HStack(spacing: 6) {
                ForEach(EntryAction.allCases) { a in
                    SelectChip(
                        text: a.rawValue.uppercased(),
                        color: actionColor(a.rawValue),
                        selected: action == a
                    ) { action = a }
                }

                playMenu
                levelMenu

                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { showMore.toggle() }
                } label: {
                    Image(systemName: showMore ? "chevron.up" : "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.inset))
                }
                .buttonStyle(.plain)
                .help("Looking for / want to see")

                Spacer()

                Button("Post") { submit() }
                    .buttonStyle(PillButtonStyle(color: Theme.green, filled: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.4)
                    .help("⌘↩")
            }
            .padding(.bottom, 10)

            Rectangle()
                .fill(Theme.cardBorder)
                .frame(height: 1)
        }
        .padding(.horizontal, 14)
        .onAppear { autoAttach(store.pendingScreenshots) }
        .onChange(of: store.pendingScreenshots) { _, shots in
            if let sel = selectedShot, !shots.contains(sel) {
                selectedShot = nil
            }
            autoAttach(shots)
        }
    }

    /// Newest inbox screenshot lands attached, ready to caption.
    private func autoAttach(_ shots: [URL]) {
        if selectedShot == nil { selectedShot = shots.last }
    }

    // MARK: attached image

    @ViewBuilder
    private var attachedPreview: some View {
        if let shot = selectedShot {
            ZStack(alignment: .topTrailing) {
                AssetImage(url: shot)
                    .frame(maxHeight: 220)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder, lineWidth: 1))

                Button {
                    store.discardPendingScreenshot(shot)
                    selectedShot = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.text)
                        .background(Circle().fill(Theme.bg.opacity(0.8)))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Discard screenshot")
            }
        } else {
            HStack(spacing: 6) {
                Circle().fill(Theme.textDim).frame(width: 5, height: 5)
                Text("cmd+s in TradingView — screenshot attaches here")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    /// Other pending shots (if several stacked up between posts) — tap to swap.
    @ViewBuilder
    private var spareShotStrip: some View {
        let spares = store.pendingScreenshots.filter { $0 != selectedShot }
        if !spares.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(spares, id: \.self) { url in
                        AssetImage(url: url)
                            .frame(width: 72, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.cardBorder, lineWidth: 1))
                            .onTapGesture { selectedShot = url }
                            .help("Use this screenshot")
                    }
                }
                .padding(2)
            }
            .frame(height: 48)
        }
    }

    // MARK: tag menus

    private var playMenu: some View {
        Menu {
            Button("no play") { playType = nil }
            ForEach(PlayType.allCases) { p in
                Button(p.rawValue) { playType = p }
            }
        } label: {
            Text(playType?.rawValue ?? "play")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(playType == nil ? Theme.textDim : Theme.teal)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var levelMenu: some View {
        Menu {
            Button("no level") { levelId = nil }
            ForEach(store.levels) { level in
                Button("\(level.name) \(Theme.starText(level.stars)) @ \(trimmedNumber(level.price))") {
                    levelId = level.id
                }
            }
        } label: {
            Text(store.level(id: levelId).map { "\($0.name) \(Theme.starText($0.stars))" } ?? "level")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(levelId == nil ? Theme.textDim : Theme.amber)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: optional extras

    private var moreFields: some View {
        VStack(spacing: 6) {
            TextField("Looking for", text: $lookingFor, axis: .vertical)
                .lineLimit(1...3)
                .darkField()
            TextField("Want to see for a trade", text: $wantToSee, axis: .vertical)
                .lineLimit(1...3)
                .darkField()
        }
    }

    private var chopRow: some View {
        HStack(spacing: 8) {
            Text("CHOP")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.amber)
            TextField("high", text: $chopHighText)
                .darkField()
                .frame(width: 90)
            TextField("low", text: $chopLowText)
                .darkField()
                .frame(width: 90)
            TextField("crossings", text: $chopCrossingsText)
                .darkField()
                .frame(width: 90)
            Spacer()
        }
    }

    // MARK: submit

    private var canSubmit: Bool {
        selectedShot != nil
            || !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        var draft = EntryDraft()
        draft.screenshot = selectedShot
        draft.comment = comment
        draft.lookingFor = lookingFor
        draft.wantToSee = wantToSee
        draft.action = action
        draft.playType = playType
        draft.levelId = levelId
        if action == .chop {
            draft.chopHigh = parseDouble(chopHighText)
            draft.chopLow = parseDouble(chopLowText)
            draft.chopCrossings = parseInt(chopCrossingsText)
        }
        store.submitEntry(draft)
        clear()
    }

    private func clear() {
        selectedShot = nil
        comment = ""
        lookingFor = ""
        wantToSee = ""
        action = .wait
        playType = nil
        levelId = nil
        showMore = false
        chopHighText = ""
        chopLowText = ""
        chopCrossingsText = ""
        // Next queued screenshot slides straight into the composer.
        autoAttach(store.pendingScreenshots)
        captionFocused = true
    }
}

// MARK: - EntryCardView

/// One post: caption, big image, tags, mentor as a threaded reply, trade line.
struct EntryCardView: View {
    @EnvironmentObject private var store: SessionStore
    let entry: EntryRecord

    @State private var showTradeSheet = false
    @State private var exitPriceText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let comment = entry.comment, !comment.isEmpty {
                Text(comment)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            secondaryFields

            if !entry.screenshotPath.isEmpty {
                let url = Workspace.absoluteURL(relative: entry.screenshotPath)
                AssetImage(url: url)
                    .frame(maxHeight: 420)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardBorder, lineWidth: 1))
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .help("Open in Preview")
            }

            mentorBlock
            tradeBlock
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showTradeSheet) {
            TradeLogSheet(entry: entry)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 6) {
            if let action = entry.action, !action.isEmpty {
                TagChip(text: action.uppercased(), color: actionColor(action))
            }
            if let play = entry.playType, !play.isEmpty {
                TagChip(text: play, color: Theme.teal)
            }
            if let level = store.level(id: entry.levelId) {
                LevelChip(level: level)
            }

            Spacer()

            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("\(etTime(fromISO: entry.ts)) ET · \(relativeAge(fromISO: entry.ts, now: context.date))")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    // MARK: secondary fields

    @ViewBuilder
    private var secondaryFields: some View {
        if let lf = entry.lookingFor, !lf.isEmpty {
            secondaryRow("LOOKING FOR", lf)
        }
        if let wts = entry.wantToSee, !wts.isEmpty {
            secondaryRow("WANT TO SEE", wts)
        }
    }

    private func secondaryRow(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: mentor (threaded reply)

    @ViewBuilder
    private var mentorBlock: some View {
        if store.mentorBusy.contains(entry.id) {
            mentorThread {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("mentor thinking…")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
            }
        } else if let reply = entry.mentorReply, !reply.isEmpty {
            mentorThread {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MENTOR")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.purple)
                    Text(reply)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if store.mentorAvailable {
            Button("Retry mentor") {
                store.retryMentor(entryId: entry.id)
            }
            .buttonStyle(PillButtonStyle(color: Theme.amber))
        } else {
            Text("claude CLI not found — mentor offline")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
        }
    }

    /// Reply-style indent: purple thread bar on the left.
    private func mentorThread<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.purple.opacity(0.6))
                .frame(width: 2)
            content()
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.vertical, 2)
    }

    // MARK: trade

    @ViewBuilder
    private var tradeBlock: some View {
        if let trade = store.trade(forEntry: entry.id) {
            if trade.result == "open" {
                openTradeView(trade)
            } else {
                closedTradeView(trade)
            }
        } else if entry.action == "enter" {
            Button("Log trade") { showTradeSheet = true }
                .buttonStyle(PillButtonStyle(color: Theme.green))
        } else {
            Button("Log trade") { showTradeSheet = true }
                .buttonStyle(PillButtonStyle(color: Theme.textDim))
        }
    }

    private func openTradeView(_ trade: TradeRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Theme.amber).frame(width: 6, height: 6)
                Text(bracketLine(trade))
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.text)
            }
            HStack(spacing: 8) {
                TextField("exit price", text: $exitPriceText)
                    .darkField()
                    .frame(width: 110)
                Button("Close") {
                    if let px = parseDouble(exitPriceText) {
                        store.closeTrade(tradeId: trade.id, exitPrice: px)
                        exitPriceText = ""
                    }
                }
                .buttonStyle(PillButtonStyle(color: Theme.purple, filled: true))
                .disabled(parseDouble(exitPriceText) == nil)
                .opacity(parseDouble(exitPriceText) == nil ? 0.4 : 1)
            }
        }
    }

    private func closedTradeView(_ trade: TradeRecord) -> some View {
        HStack(spacing: 8) {
            TagChip(text: (trade.result ?? "?").uppercased(), color: resultColor(trade.result))
            if let ticks = trade.ticksResult {
                Text(ticksString(ticks))
                    .font(Theme.monoSmall)
                    .foregroundStyle(ticks > 0 ? Theme.green : (ticks < 0 ? Theme.red : Theme.textDim))
            }
            if let usd = trade.usdResult {
                Text(usdString(usd))
                    .font(Theme.monoSmall)
                    .foregroundStyle(usd > 0 ? Theme.green : (usd < 0 ? Theme.red : Theme.textDim))
            }
            Text("\(trade.contracts)x \(trade.playType)")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
        }
    }

    private func bracketLine(_ trade: TradeRecord) -> String {
        func p(_ v: Double?) -> String { v.map(trimmedNumber) ?? "—" }
        return "E \(p(trade.entryPrice))  S \(p(trade.stopPrice))  T \(p(trade.targetPrice))  ·  \(trade.contracts)x \(trade.playType)"
    }

    private func resultColor(_ result: String?) -> Color {
        switch result {
        case "win": return Theme.green
        case "loss": return Theme.red
        default: return Theme.textDim
        }
    }
}

// MARK: - TradeLogSheet

struct TradeLogSheet: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let entry: EntryRecord

    @State private var playType: PlayType = .MR
    @State private var levelId: String?
    @State private var contracts = 1
    @State private var entryPriceText = ""
    @State private var stopPriceText = ""
    @State private var targetPriceText = ""
    @State private var warningText = ""
    @State private var showWarning = false
    @State private var isLong = true
    @State private var signalPaste = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LOG TRADE")
                .font(Theme.mono)
                .foregroundStyle(Theme.text)

            Text(tuneHint)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)

            // Paste the indicator's alert text -> play + E/S/T fill themselves.
            HStack(spacing: 8) {
                TextField("Paste SKULD alert text…", text: $signalPaste)
                    .darkField()
                Button("Parse") { parseSignal() }
                    .buttonStyle(PillButtonStyle(color: Theme.cyan))
                    .disabled(signalPaste.isEmpty)
            }

            Picker("Play", selection: $playType) {
                ForEach(PlayType.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Level", selection: $levelId) {
                Text("no level").tag(String?.none)
                ForEach(store.levels) { level in
                    Text("\(level.name) \(Theme.starText(level.stars))")
                        .tag(String?.some(level.id))
                }
            }
            .labelsHidden()

            HStack(spacing: 8) {
                Text("Contracts")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                Stepper(value: $contracts, in: 1...50) {
                    Text("\(contracts)")
                        .font(Theme.mono)
                        .foregroundStyle(Theme.text)
                        .frame(minWidth: 24)
                }
            }

            HStack(spacing: 8) {
                SelectChip(text: "LONG", color: Theme.green, selected: isLong) { isLong = true }
                SelectChip(text: "SHORT", color: Theme.purple, selected: !isLong) { isLong = false }
                Spacer()
                Button("Fill S/T from plan") { fillBracket() }
                    .buttonStyle(PillButtonStyle(color: Theme.amber))
                    .disabled(parseDouble(entryPriceText) == nil)
                    .help("Stop and target at the plan's fixed tick distances from entry")
            }

            HStack(spacing: 8) {
                priceField("entry", text: $entryPriceText)
                priceField("stop", text: $stopPriceText)
                priceField("target", text: $targetPriceText)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButtonStyle(color: Theme.textDim))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save trade") { save() }
                    .buttonStyle(PillButtonStyle(color: Theme.green, filled: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(Theme.bg)
        .onAppear { prefill() }
        .alert("Discipline check", isPresented: $showWarning) {
            Button("Record anyway", role: .destructive) { record() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(warningText)
        }
    }

    private func priceField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
            TextField(label, text: text)
                .darkField()
        }
    }

    private var tuneHint: String {
        let instrument = Instrument(rawValue: store.session?.instrument ?? "") ?? .MNQ
        let t = store.plan.tune(for: instrument)
        return "plan \(instrument.rawValue): target \(t.targetTicks)t (\(trimmedNumber(t.targetPoints))pt) / stop \(t.stopTicks)t (\(trimmedNumber(t.stopPoints))pt)"
    }

    private var form: TradeForm {
        TradeForm(
            playType: playType,
            levelId: levelId,
            contracts: contracts,
            entryPrice: parseDouble(entryPriceText),
            stopPrice: parseDouble(stopPriceText),
            targetPrice: parseDouble(targetPriceText))
    }

    private func prefill() {
        if let raw = entry.playType, let p = PlayType(rawValue: raw) {
            playType = p
        }
        levelId = entry.levelId
    }

    /// Stop/target at the plan's fixed tick distances from the typed entry.
    private func fillBracket() {
        guard let e = parseDouble(entryPriceText) else { return }
        let instrument = Instrument(rawValue: store.session?.instrument ?? "") ?? .MNQ
        let t = store.plan.tune(for: instrument)
        let dir: Double = isLong ? 1 : -1
        let stop = e - dir * Double(t.stopTicks) * instrument.tickSize
        let target = e + dir * Double(t.targetTicks) * instrument.tickSize
        stopPriceText = trimmedNumber(stop)
        targetPriceText = trimmedNumber(target)
    }

    /// "SKULD NQ1! 5 — MR ▲ · [12] pwVAL @ 29253.00 · E 29251.00 · S 29239.00 · T 29259.00 (32t) · signal 1/3"
    private func parseSignal() {
        let text = signalPaste
        for p in PlayType.allCases where text.contains(p.rawValue + " ▲") || text.contains(p.rawValue + " ▼") {
            playType = p
            isLong = text.contains(p.rawValue + " ▲")
            break
        }
        func grab(_ tag: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: tag + #"\s+([0-9]+(?:\.[0-9]+)?)"#),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        if let e = grab("E") { entryPriceText = e }
        if let s = grab("S") { stopPriceText = s }
        if let t = grab("T") { targetPriceText = t }
    }

    private func save() {
        if let warning = store.tradeWarning(for: form) {
            warningText = warning
            showWarning = true
        } else {
            record()
        }
    }

    private func record() {
        store.recordTrade(entryId: entry.id, form: form)
        dismiss()
    }
}
