# SkuldJournal — module contracts

Core files already written (READ THEM before implementing anything):

- `Sources/Support/Theme.swift` — dark theme tokens. Use `Theme.*` for every color. Black bg, card `#0d0d10`, text `#d1d4dc`, green `#00FF00` (good/long), purple `#673ab7` (accent/short/stop), amber warnings, red blocked. `Theme.starText(_:)`/`starColor(_:)` for stars. NEVER default light chrome.
- `Sources/Support/WorkspaceLocator.swift` — `Workspace` paths + ET date helpers.
- `Sources/Models/PlanModels.swift` — `TradingPlan` (live-parsed plan JSON), `Instrument`.
- `Sources/Models/Records.swift` — GRDB records: `SessionRecord`, `LevelRecord` (has `effectiveRank`), `EntryRecord`, `TradeRecord`, `ChopRecord`; enums `EntryAction` (wait/enter/exit/skip/chop), `PlayType` (IB/MR/BRT).
- `Sources/Models/Stats.swift` — `SessionStats` (+ `StarRow`, `PlayRow`).
- `Sources/Database/AppDatabase.swift` — GRDB queue, migrations, CRUD.
- `Sources/Store/SessionStore.swift` — `@MainActor ObservableObject` hub. Views bind ONLY to this. Also defines `EntryDraft`, `TradeForm`, `LevelDraft`.
- `Sources/SkuldJournalApp.swift` — @main, injects `SessionStore` as `@EnvironmentObject`.

Target: macOS 14+, Swift 5.9, SwiftUI. GRDB via SPM (import GRDB only where needed).
Do NOT rename/move any existing symbol. Implement EXACTLY the signatures below — SessionStore already calls them.

## 1. Sources/Services/InboxWatcher.swift

```swift
final class InboxWatcher {
    init(directory: URL, onNewFiles: @escaping ([URL]) -> Void)
    func start()
    func stop()
    func rescan()
}
```

- FSEvents (`FSEventStreamCreate`, CoreServices) on `directory`, `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes`, latency ~0.5s. Schedule on a dispatch queue (`FSEventStreamSetDispatchQueue`).
- Create the directory if missing before starting.
- On events (and on `start()` and `rescan()`): scan directory non-recursively for `png/jpg/jpeg` (case-insensitive), skip hidden files, skip files smaller than 1KB (TradingView cmd+s may still be writing), sort by creation date ascending.
- Track a `seen` set of paths; invoke `onNewFiles` **on the main queue** with only never-before-reported URLs. Also drop from `seen` files that no longer exist (entry submission moves them out of inbox) so the set doesn't grow stale.
- `deinit` must stop/invalidate/release the stream safely. Handle `start()` called twice.
- Memory: callback context uses `Unmanaged<InboxWatcher>` — retain/release correctly, no leaks, no dangling pointer after `stop()`.

## 2. Sources/Services/MentorService.swift

```swift
struct MentorResult { let reply: String; let claudeSessionId: String? }

enum MentorError: Error, LocalizedError { case cliNotFound, timeout, processFailed(String), emptyReply }

final class MentorService {
    init(repoRoot: URL)
    static func locateCLI() -> URL?
    func review(entry: EntryRecord, session: SessionRecord, level: LevelRecord?,
                plan: TradingPlan, stats: SessionStats,
                resumeSessionId: String?) async -> Result<MentorResult, MentorError>
}
```

- `locateCLI()`: first hit among `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.local/bin/claude`, `~/bin/claude`, then `env PATH` scan. (GUI apps don't inherit shell PATH.)
- Verified CLI surface (claude 2.1.214): `claude -p "<prompt>" --output-format json --allowedTools Read` and `--resume <sessionId>` to continue. Output JSON object contains `"result"` (string reply) and `"session_id"`. Parse defensively: if stdout isn't valid JSON or lacks `result`, fall back to raw stdout trimmed; still try to regex out `"session_id"\s*:\s*"([^"]+)"`.
- Build args: `["-p", prompt, "--output-format", "json", "--allowedTools", "Read"]`, plus `["--resume", resumeSessionId]` when non-nil. If resume fails (nonzero exit + resume was set), RETRY ONCE without `--resume` (session ids can expire).
- `Process` with `currentDirectoryURL = repoRoot`, pipes for stdout/stderr. Run off the main thread (wrap in `withCheckedContinuation` or run in a detached task — the func is already async). Timeout **60s**: terminate the process, return `.failure(.timeout)`.
- Prompt template (single string):

```
You are skuld's live trading mentor. Read the plan at skuld_trading_operation.json and the screenshot at <relativeScreenshotPath> (if path non-empty) using your Read tool.

Session: <instrument> <date>, IB <ibLow>-<ibHigh>. Trades taken: <tradesTaken>/<maxTrades>.
Entry #<n> at <ts>:
- What I see: <comment>
- Looking for: <lookingFor>
- Want to see: <wantToSee>
- Action: <action>  Play: <playType>  Level: <levelName> <stars> @ <price> (rank <effectiveRank>, min tradeable <minRankToTrade>)

Give a short mentor read (max ~120 words): does this match the plan's play definitions, is the level rank sane, and one discipline reminder if trades taken is at or near the max. Direct, no fluff. Never use the word "fade" — say "reversal" or frame by direction.
```

  Omit lines whose field is empty. `<n>` = entry count. Use relative paths only (cwd is repo root).
- No Anthropic API key anywhere. Never block the journal: any failure -> `.failure`, caller saves entry regardless.

## 3. Sources/Database/StatsQueries.swift

```swift
enum StatsQueries {
    static func compute(db: AppDatabase, session: SessionRecord,
                        levels: [LevelRecord], plan: TradingPlan) throws -> SessionStats
}
```

- Fill every `SessionStats` field. Use `db.trades(sessionId:)`, `db.entries(sessionId:)`, `db.chops(sessionId:)` or direct SQL via `db.dbQueue.read`.
- `tradesTaken` = session.tradesTaken; `maxTrades` = plan.maxTradesPerDay.
- net ticks/usd = sums over trades with non-nil results; wins/losses/scratches/openTrades from `result`.
- `starRows`: for stars 5→1, trades joined to their level (via `levelId` -> levels array), bucketed by level `stars`; only include rows with signals > 0.
- `playRows`: group trades by playType (include only plays present).
- `actionCounts`: entry count per `action` string.
- `chopCount`, `levelsHeld` (= levels where !broken), `levelsBroken`.
- `dailyTargetUsd`: `plan.milestone(forBalance: plan.startingCapital + <net usd across ALL sessions in DB>)?.dailyTargetUsd` — running balance = starting capital + lifetime net USD (all days), that's the milestone position.
- `dailyMaxLossUsd` = plan.dailyMaxLossUsd (stays nil — UNDEFINED, display only).

## 4. Sources/Services/ReportGenerator.swift

```swift
enum ReportGenerator {
    static func generate(root: URL, session: SessionRecord, levels: [LevelRecord],
                         entries: [EntryRecord], trades: [TradeRecord],
                         chops: [ChopRecord], stats: SessionStats,
                         plan: TradingPlan) throws -> URL
}
```

- Writes `Reports/<date>_session_report.md` (overwrite). Return the URL.
- Sections: header (date, instrument, IB range, status); Stats table (trades X/max, W/L/scratch, net ticks, net USD, daily target, daily max loss "UNDEFINED — not enforced" if nil); Levels table (name, price, stars, rank, HELD/BROKE); star-rank hit-rate table; play-type table; signals offered vs taken; chop log; then full entry timeline (oldest first): timestamp (ET, HH:mm), image link `![](../Records/<date>/assets/<file>)` when screenshotPath non-empty (compute the relative path from Reports/ to the asset from the stored relative path — do not hardcode beyond the `../` prefix), the four fields, action/play/level tags, trade line if attached (E/S/T, exit, ticks, USD, result), mentor reply as a blockquote.
- Markdown must render in standard viewers. ET times: convert entry `ts` ISO8601 -> `America/New_York` HH:mm.

## 5. Sources/Views/SetupView.swift

Pre-session screen (`sop.pre_market`). Shown when `store.session == nil`.
- Instrument picker (`Instrument.allCases`), IB high/low optional text fields (Double), ranked-levels editor: list of `LevelDraft` rows (name, price, stars 1-5 stepper/picker, optional rank score, notes) with add/remove.
- "Start Session" button -> `store.startSession(instrument:ibHigh:ibLow:levelDrafts:)`; disabled until instrument picked (always is) — IB and levels may be empty (IB may not exist pre-9:30, levels addable later).
- Show plan summary strip: plan version, target/stop ticks for chosen instrument (`plan.tune(for:)`), max trades, min rank, daily max loss "UNDEFINED" badge in amber if nil.
- Show `plan.warnings` if any. Dark theme via Theme tokens.

## 6. Sources/Views/FeedView.swift  (may also contain ComposerView + EntryCardView + TradeSheet as separate structs in this one file)

Main live screen.
- Composer at top: horizontal thumbnail strip of `store.pendingScreenshots` (click to select for this entry, selected = purple border; X button to `discardPendingScreenshot`), four multiline text fields (What I see / Looking for / Want to see — TextEditor or TextField(axis:.vertical)), action segmented picker (`EntryAction`), play type picker (optional, IB/MR/BRT/–), level picker from `store.levels` (name + stars, optional). When action == .chop reveal chop fields (high/low/crossings). Submit button -> `store.submitEntry(_:)`, then clear the form. Cmd+Return submits.
- Feed below: `ScrollView` of entry cards, **newest on top** (`store.entries` already sorted desc). Card: thumbnail (load NSImage from `Workspace.absoluteURL(relative:)`, fit ~180pt wide, click = open in Preview via NSWorkspace), ET time, the four fields (label + text, skip empties), tag chips (action; play; level name + stars colored via Theme.starColor), mentor block: reply text (dim italic under a "MENTOR" caption) OR "thinking…" with ProgressView when `store.mentorBusy.contains(entry.id)` OR a Retry button when reply nil and not busy (`store.retryMentor(entryId:)`; hide Retry if `!store.mentorAvailable`, show "claude CLI not found" instead).
- Trade attach: if `store.trade(forEntry:)` nil, "Log trade" button opens sheet (TradeForm fields: play, level, contracts, entry/stop/target prices, prefill target/stop distance display from `plan.tune(for:)` as hint text). On save: if `store.tradeWarning(for:)` non-nil show warning alert with "Record anyway" (override) / Cancel. Call `store.recordTrade(entryId:form:)`. If a trade exists and `result == "open"`, show E/S/T line + exit-price field + "Close" -> `store.closeTrade(tradeId:exitPrice:)`. Closed: show result chip (win green / loss red / scratch dim) + ticks + USD.
- Empty states for no entries / no pending screenshots ("cmd+s in TradingView drops screenshots here").

## 7. Sources/Views/StatsSidebarView.swift AND Sources/Views/ContentView.swift

ContentView (root):
- If `store.fatalError != nil`: blocking error panel.
- Else if `store.session == nil`: SetupView.
- Else: HStack: FeedView (min 640, flexible) + Divider + StatsSidebarView (fixed ~300).
- Top banner area (always over feed): amber lunch banner when `store.isLunchBlackout` ("LUNCH 11:30–13:30 ET — no new signals per plan"); red-ish banner when `store.tradesRemaining == 0` ("3/3 DONE — plan says stop"); `store.errorMessage` toast/alert (`.alert` bound to it). Toolbar: session label (instrument + date), Rescan Inbox, Generate Report, End Session (confirm dialog).

StatsSidebarView ("poker stats", live from `store.stats`):
- Discipline: big "TRADES X/N" with green/amber/red light (dot circle) — green <max-1, amber = last trade, red = at/over max.
- P&L: net ticks + net USD (green positive / red negative), W-L-S line, daily target from stats.dailyTargetUsd, daily max loss row: value or "UNDEFINED" amber badge with "not enforced" caption.
- Star-rank hit rate table (★s colored, signals, win rate %). Play-type table. Signals offered vs taken. Chop count. Levels held vs broke (green/red counts) + tap-to-toggle list of levels (name, price, stars, broken strikethrough; toggle calls `store.setLevelBroken`).
- Everything monospaced-ish (`Theme.mono`/`monoSmall`), status as colored dots not text walls.

## Style rules (all agents)

- Dark theme ONLY through Theme tokens. No `Color.white` backgrounds, no default List chrome (use plain ScrollView/LazyVStack or `.scrollContentBackground(.hidden)`).
- Status = green/red/amber lights (small circles), not text walls.
- The word "fade" is BANNED anywhere in UI text or prompts — use "reversal".
- No Edgeful branding anywhere.
- Compile-clean Swift 5.9 (macOS 14 APIs OK). No third-party deps beyond GRDB. No force-unwraps of runtime data. Keep files self-contained; do not edit other modules' files.
