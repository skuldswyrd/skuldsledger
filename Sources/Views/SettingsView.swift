import SwiftUI

/// Settings sheet — the user's knobs overlaying the plan JSON. Doctrine stays
/// hand-edited in skuld_trading_operation.json; these overrides live at
/// Records/user_settings.json and win where set (TradingPlan.applying).
/// Every knob is optional: cleared = fall back to the plan / milestone auto.
struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    // Optional overrides — nil / empty text = plan default or auto.
    @State private var pace: Int?
    @State private var minRank: Int?
    @State private var targetText: String = ""
    @State private var maxLossText: String = ""
    @State private var defaultInstrument: Instrument?
    /// Raw plan (no settings overlay) — shows the true plan defaults beside
    /// each knob. store.plan is already overlaid, so it can't serve here.
    @State private var basePlan = TradingPlan()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.cardBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    paceRow
                    targetRow
                    maxLossRow
                    minRankRow
                    instrumentRow
                    environmentCard
                }
                .padding(16)
            }
            Divider().overlay(Theme.cardBorder)
            footer
        }
        .frame(width: 480, height: 640)
        .background(Theme.bg)
        .foregroundColor(Theme.text)
        .onAppear(perform: loadCurrent)
    }

    // MARK: - State load / save

    private func loadCurrent() {
        let s = store.settings
        pace = s.paceBaselinePerDay
        minRank = s.minRankToTrade
        targetText = s.dailyTargetUsd.map(Self.plainMoney) ?? ""
        maxLossText = s.dailyMaxLossUsd.map(Self.plainMoney) ?? ""
        defaultInstrument = s.defaultInstrument.flatMap(Instrument.init(rawValue:))
        basePlan = TradingPlan.load(from: Workspace.planURL)
    }

    private func save() {
        var s = UserSettings()
        s.paceBaselinePerDay = pace
        s.dailyTargetUsd = parsedMoney(targetText)
        s.dailyMaxLossUsd = parsedMoney(maxLossText)
        s.minRankToTrade = minRank
        s.defaultInstrument = defaultInstrument?.rawValue
        store.saveSettings(s)
        dismiss()
    }

    private func resetToPlanDefaults() {
        pace = nil
        minRank = nil
        targetText = ""
        maxLossText = ""
        defaultInstrument = nil
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundColor(Theme.purple)
            Text("SETTINGS")
                .font(Theme.mono)
                .foregroundColor(Theme.text)
                .kerning(1.5)
            Spacer()
            Text("overrides the plan · Records/user_settings.json")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.textDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: resetToPlanDefaults) {
                Text("Reset to plan defaults")
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.amber)
            }
            .buttonStyle(.plain)
            .help("Clears every override — the plan JSON drives everything again")

            Spacer()

            Button(action: { dismiss() }) {
                Text("Cancel")
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.textDim)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.cardBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button(action: save) {
                Text("Save")
                    .font(Theme.monoSmall.weight(.semibold))
                    .foregroundColor(Theme.green)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.green.opacity(0.12)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.green, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(moneyInvalid(targetText) || moneyInvalid(maxLossText))
            .opacity(moneyInvalid(targetText) || moneyInvalid(maxLossText) ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Knob rows

    private var paceRow: some View {
        settingRow(
            "PACE BASELINE",
            caption: "Trades/day pace — context for the sidebar and mentor, never a cap."
        ) {
            HStack(spacing: 10) {
                Text("\(pace ?? basePlan.maxTradesPerDay)/day")
                    .font(Theme.mono)
                    .foregroundColor(pace == nil ? Theme.textDim : Theme.text)
                    .frame(minWidth: 60, alignment: .leading)
                Stepper(
                    "Pace baseline",
                    onIncrement: { pace = min(20, (pace ?? basePlan.maxTradesPerDay) + 1) },
                    onDecrement: { pace = max(1, (pace ?? basePlan.maxTradesPerDay) - 1) }
                )
                .labelsHidden()
                Spacer()
                overrideState(
                    pace != nil,
                    planLabel: "plan \(basePlan.maxTradesPerDay)/day"
                ) { pace = nil }
            }
        }
    }

    private var targetRow: some View {
        settingRow(
            "DAILY TARGET USD",
            caption: "Empty = auto from the plan's milestone table for the current balance."
        ) {
            HStack(spacing: 10) {
                moneyField("auto", text: $targetText)
                Spacer()
                overrideState(
                    parsedMoney(targetText) != nil,
                    planLabel: "milestone auto"
                ) { targetText = "" }
            }
        }
    }

    private var maxLossRow: some View {
        settingRow(
            "DAILY MAX LOSS USD",
            caption: "Empty = UNDEFINED (plan open item). Display + red banner only — never auto-flattens a position or blocks a trade."
        ) {
            HStack(spacing: 10) {
                moneyField("undefined", text: $maxLossText)
                Spacer()
                overrideState(
                    parsedMoney(maxLossText) != nil,
                    planLabel: basePlan.dailyMaxLossUsd.map { "plan $\(Self.plainMoney($0))" } ?? "UNDEFINED",
                    fallbackColor: basePlan.dailyMaxLossUsd == nil ? Theme.amber : Theme.textDim
                ) { maxLossText = "" }
            }
        }
    }

    private var minRankRow: some View {
        settingRow(
            "MIN RANK TO TRADE",
            caption: "Quality gate — the trade sheet warns when a level's effective rank sits below this."
        ) {
            HStack(spacing: 10) {
                Text("\(minRank ?? basePlan.minRankToTrade)")
                    .font(Theme.mono)
                    .foregroundColor(minRank == nil ? Theme.textDim : Theme.text)
                    .frame(minWidth: 60, alignment: .leading)
                Stepper(
                    "Min rank",
                    onIncrement: { minRank = min(20, (minRank ?? basePlan.minRankToTrade) + 1) },
                    onDecrement: { minRank = max(1, (minRank ?? basePlan.minRankToTrade) - 1) }
                )
                .labelsHidden()
                Spacer()
                overrideState(
                    minRank != nil,
                    planLabel: "plan \(basePlan.minRankToTrade)"
                ) { minRank = nil }
            }
        }
    }

    private var instrumentRow: some View {
        settingRow(
            "DEFAULT INSTRUMENT",
            caption: "Seeds the pre-session picker. Auto = last session's instrument."
        ) {
            HStack(spacing: 10) {
                Menu {
                    Button("Auto (last used)") { defaultInstrument = nil }
                    Divider()
                    ForEach(Instrument.allCases) { inst in
                        Button(inst.rawValue) { defaultInstrument = inst }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(defaultInstrument?.rawValue ?? "auto")
                            .font(Theme.mono)
                            .foregroundColor(defaultInstrument == nil ? Theme.textDim : Theme.text)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(Theme.textDim)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.cardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                overrideState(
                    defaultInstrument != nil,
                    planLabel: "auto (last used)"
                ) { defaultInstrument = nil }
            }
        }
    }

    // MARK: - Read-only environment

    private var environmentCard: some View {
        settingRow(
            "ENVIRONMENT",
            caption: "Read-only. Data and plan stay local in the workspace."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                kvRow("Workspace", Workspace.root.path)
                kvRow("TV grabs", Workspace.tvGrabsDir?.path ?? "not found")
                kvRow("Plan", "v\(store.plan.version)")
            }
        }
    }

    private func kvRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textDim)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared bits

    private func settingRow<Content: View>(
        _ title: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.monoSmall)
                .foregroundColor(Theme.textDim)
                .kerning(1.2)
            content()
            Text(caption)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
    }

    /// Override indicator: a cyan "back to plan" chip when overridden,
    /// a dim label of the fallback when not.
    @ViewBuilder
    private func overrideState(
        _ overridden: Bool,
        planLabel: String,
        fallbackColor: Color = Theme.textDim,
        clear: @escaping () -> Void
    ) -> some View {
        if overridden {
            Button(action: clear) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 8, weight: .bold))
                    Text(planLabel)
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundColor(Theme.cyan)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Theme.cyan.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Clear the override — fall back to \(planLabel)")
        } else {
            Text(planLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(fallbackColor)
        }
    }

    private func moneyField(_ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text("$")
                .font(Theme.mono)
                .foregroundColor(Theme.textDim)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Theme.mono)
                .foregroundColor(Theme.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 150)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(moneyInvalid(text.wrappedValue) ? Theme.amber : Theme.cardBorder, lineWidth: 1)
        )
    }

    /// "$1,250.50" / "300" -> Double. Positive values only; junk = nil.
    private func parsedMoney(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    private func moneyInvalid(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && parsedMoney(text) == nil
    }

    private static func plainMoney(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.2f", value)
    }
}
