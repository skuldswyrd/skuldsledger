import SwiftUI

/// Pre-session screen (sop.pre_market). Shown while `store.session == nil`.
/// Instrument + optional IB range + ranked level drafts, then Start Session.
struct SetupView: View {
    @EnvironmentObject var store: SessionStore

    @State private var instrument: Instrument = .MNQ
    @State private var ibHighText: String = ""
    @State private var ibLowText: String = ""
    @State private var levelDrafts: [LevelDraft] = []
    @State private var pullingChart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                planSummaryStrip
                if !store.plan.warnings.isEmpty {
                    warningsCard
                }
                instrumentCard
                ibCard
                levelsCard
                startButton
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .foregroundColor(Theme.text)
        .onAppear {
            if let last = store.lastUsedInstrument { instrument = last }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Theme.purple).frame(width: 8, height: 8)
                Text("PRE-SESSION SETUP")
                    .font(Theme.mono)
                    .foregroundColor(Theme.text)
                    .kerning(1.5)
            }
            Text("\(store.todayDate) ET — no session started yet")
                .font(Theme.monoSmall)
                .foregroundColor(Theme.textDim)
        }
    }

    // MARK: - Plan summary strip

    private var planSummaryStrip: some View {
        let tune = store.plan.tune(for: instrument)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                planStat("PLAN", "v\(store.plan.version)")
                planStat("TARGET", "\(tune.targetTicks)t / \(fmt(tune.targetPoints))pt")
                planStat("STOP", "\(tune.stopTicks)t / \(fmt(tune.stopPoints))pt")
                planStat("MAX TRADES", "\(store.plan.maxTradesPerDay)/day")
                planStat("MIN RANK", "\(store.plan.minRankToTrade)")
                dailyMaxLossStat
            }
        }
    }

    @ViewBuilder
    private var dailyMaxLossStat: some View {
        if let maxLoss = store.plan.dailyMaxLossUsd {
            planStat("DAILY MAX LOSS", String(format: "$%.0f", maxLoss))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("DAILY MAX LOSS")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textDim)
                HStack(spacing: 6) {
                    Text("UNDEFINED")
                        .font(Theme.monoSmall)
                        .foregroundColor(Theme.amber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Theme.amber, lineWidth: 1)
                        )
                    Text("not enforced")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textDim)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
        }
    }

    private func planStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.textDim)
            Text(value)
                .font(Theme.monoSmall)
                .foregroundColor(Theme.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
    }

    // MARK: - Plan warnings

    private var warningsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(store.plan.warnings.enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Theme.amber)
                        .frame(width: 6, height: 6)
                        .padding(.top, 4)
                    Text(warning)
                        .font(Theme.monoSmall)
                        .foregroundColor(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.amber.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Instrument

    private var instrumentCard: some View {
        sectionCard("INSTRUMENT") {
            HStack(spacing: 8) {
                ForEach(Instrument.allCases) { inst in
                    instrumentButton(inst)
                }
            }
            Text("$\(fmt(instrument.tickValue))/tick — auto-tune \(instrument.autoTuneKey)")
                .font(Theme.monoSmall)
                .foregroundColor(Theme.textDim)
        }
    }

    private func instrumentButton(_ inst: Instrument) -> some View {
        let selected = instrument == inst
        return Button {
            instrument = inst
        } label: {
            Text(inst.rawValue)
                .font(Theme.mono)
                .foregroundColor(selected ? Theme.text : Theme.textDim)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Theme.purple.opacity(0.35) : Theme.inset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? Theme.purple : Theme.cardBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Initial balance

    private var ibCard: some View {
        sectionCard("INITIAL BALANCE — optional") {
            HStack(spacing: 12) {
                darkField("IB High", text: $ibHighText, invalid: fieldInvalid(ibHighText))
                darkField("IB Low", text: $ibLowText, invalid: fieldInvalid(ibLowText))
            }
            if let note = ibValidationNote {
                HStack(spacing: 6) {
                    Circle().fill(Theme.amber).frame(width: 6, height: 6)
                    Text(note)
                        .font(Theme.monoSmall)
                        .foregroundColor(Theme.amber)
                }
            }
            Text("Leave empty pre-9:30 — the IB may not exist yet. Values are locked into the session record.")
                .font(Theme.monoSmall)
                .foregroundColor(Theme.textDim)
        }
    }

    private var ibValidationNote: String? {
        if fieldInvalid(ibHighText) || fieldInvalid(ibLowText) {
            return "Non-numeric IB values are ignored on start."
        }
        if let high = parseDouble(ibHighText), let low = parseDouble(ibLowText), high <= low {
            return "IB High is at or below IB Low — double-check the range."
        }
        return nil
    }

    private func fieldInvalid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && Double(trimmed) == nil
    }

    // MARK: - Ranked levels

    private var levelsCard: some View {
        sectionCard("RANKED LEVELS") {
            if levelDrafts.isEmpty {
                Text("No levels yet — pull them off the live chart, or add by hand.")
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.textDim)
            }
            ForEach($levelDrafts) { $draft in
                levelRow($draft)
            }
            HStack(spacing: 8) {
                Button {
                    pullFromChart()
                } label: {
                    HStack(spacing: 6) {
                        if pullingChart {
                            ProgressView().controlSize(.small)
                            Text("Reading chart…")
                                .font(Theme.monoSmall)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 11, weight: .bold))
                            Text("Pull from chart")
                                .font(Theme.monoSmall)
                        }
                    }
                    .foregroundColor(Theme.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.cyan.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(pullingChart)
                .help("Read the ★ clusters straight off the live TradingView chart")

                Button {
                    levelDrafts.append(LevelDraft())
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Add level")
                            .font(Theme.monoSmall)
                    }
                    .foregroundColor(Theme.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.green.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            if !levelDrafts.isEmpty {
                Text("Rows without a name and numeric price are dropped on start.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textDim)
            }
        }
    }

    private func levelRow(_ draft: Binding<LevelDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                darkField("Name (pdPOC, VWAP…)", text: draft.name)
                    .frame(minWidth: 140)
                darkField("Price", text: draft.price, invalid: fieldInvalid(draft.price.wrappedValue))
                    .frame(width: 100)
                starPicker(draft.stars)
                darkField("Rank", text: draft.rankScore, invalid: rankInvalid(draft.rankScore.wrappedValue))
                    .frame(width: 64)
                effectiveRankTag(stars: draft.stars.wrappedValue, rankText: draft.rankScore.wrappedValue)
                Button {
                    levelDrafts.removeAll { $0.id == draft.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.red)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.inset))
                }
                .buttonStyle(.plain)
            }
            darkField("Notes", text: draft.notes)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
    }

    private func starPicker(_ stars: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Text("★")
                    .font(.system(size: 14))
                    .foregroundColor(
                        i <= stars.wrappedValue
                            ? Theme.starColor(stars.wrappedValue)
                            : Theme.cardBorder
                    )
                    .onTapGesture { stars.wrappedValue = i }
            }
        }
    }

    /// Preview of the min-rank check: mirrors LevelRecord.effectiveRank
    /// (raw rank when given, else the floor of the star band).
    private func effectiveRankTag(stars: Int, rankText: String) -> some View {
        let rank = parsedRank(rankText) ?? starFloorRank(stars)
        let tradeable = rank >= store.plan.minRankToTrade
        return HStack(spacing: 4) {
            Circle()
                .fill(tradeable ? Theme.green : Theme.amber)
                .frame(width: 6, height: 6)
            Text("eff \(rank)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(tradeable ? Theme.green : Theme.amber)
        }
        .frame(width: 58, alignment: .leading)
    }

    private func parsedRank(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces))
    }

    private func rankInvalid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && Int(trimmed) == nil
    }

    private func starFloorRank(_ stars: Int) -> Int {
        switch stars {
        case 5: return 10
        case 4: return 8
        case 3: return 6
        case 2: return 4
        default: return 1
        }
    }

    // MARK: - Start

    private var startButton: some View {
        Button(action: start) {
            HStack(spacing: 8) {
                Circle().fill(Theme.green).frame(width: 8, height: 8)
                Text("START SESSION")
                    .font(Theme.mono)
                    .kerning(1.5)
            }
            .foregroundColor(Theme.green)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.green.opacity(0.12)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.green, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    private func start() {
        store.startSession(
            instrument: instrument,
            ibHigh: parseDouble(ibHighText),
            ibLow: parseDouble(ibLowText),
            levelDrafts: levelDrafts)
    }

    /// Chart clusters merge into the drafts: same name updates price/stars,
    /// new names append. Hand-entered rows stay.
    private func pullFromChart() {
        pullingChart = true
        Task {
            let pulled = await store.fetchChartLevelDrafts()
            await MainActor.run {
                for draft in pulled {
                    if let idx = levelDrafts.firstIndex(where: {
                        $0.name.lowercased() == draft.name.lowercased() && !draft.name.isEmpty
                    }) {
                        levelDrafts[idx].price = draft.price
                        levelDrafts[idx].stars = draft.stars
                    } else {
                        levelDrafts.append(draft)
                    }
                }
                pullingChart = false
            }
        }
    }

    // MARK: - Shared bits

    private func sectionCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.monoSmall)
                .foregroundColor(Theme.textDim)
                .kerning(1.2)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
    }

    private func darkField(_ placeholder: String, text: Binding<String>, invalid: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Theme.mono)
            .foregroundColor(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(invalid ? Theme.amber : Theme.cardBorder, lineWidth: 1)
            )
    }

    private func parseDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.2f", value)
    }
}
