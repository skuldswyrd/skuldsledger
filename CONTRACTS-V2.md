# Skuld's Ledger v2 — module contracts (2026-07-22 all-day update)

Read CONTRACTS.md first (v1 architecture). This file covers the v2 delta. Core is ALREADY WRITTEN — read the current sources before implementing:

- `Records.swift`: NEW `CommentRecord` (id, entryId, ts, author "user"/"mentor", text); `EntryRecord.instrument: String?`; `TradeRecord.instrument: String?`.
- `PlanModels.swift`: `Instrument.detect(fromFilename:)`; `UserSettings` (paceBaselinePerDay, dailyTargetUsd, dailyMaxLossUsd, minRankToTrade, defaultInstrument; load/save at Records/user_settings.json); `TradingPlan.applying(_:)`, `plan.dailyTargetOverrideUsd`.
- `AppDatabase.swift`: migration v2 (comments table, instrument columns + backfill); `comments(sessionId:) -> [String: [CommentRecord]]`; `save(_ comment:)`; `deleteEntry(id:)` (cascades comments+trades); `deleteTrade(id:)`.
- `SessionStore.swift` NEW API (already implemented — bind to it exactly):
  - `comments: [String: [CommentRecord]]` (entryId -> thread asc), `settings: UserSettings`
  - `addUserComment(entryId:text:)` — saves user comment, kicks mentor thread reply (mentorBusy covers the entry while thinking)
  - `deleteEntry(entryId:)`, `deleteTrade(tradeId:)`, `updateEntry(_ entry:)` (pass a mutated EntryRecord)
  - `saveSettings(_:)`
  - `EntryDraft.instrument: Instrument?`, `TradeForm.instrument: Instrument?`
  - `tradeWarning(for:)` now ONLY warns on level rank (count check REMOVED)
  - `tradesRemaining` still exists but must NOT drive any red/blocking UI anymore

## PHILOSOPHY SHIFT (drives every module)

He trades ALL DAY, ALL SESSIONS now. 3 trades/day = pace BASELINE, not a cap. Lunch = informational. The mentor and UI must never scold about count, clock, or session. Quality bar unchanged: ranked levels, orderflow/footprint context, market structure, defined risk, fixed-target exits.

## Module A — Sources/Services/MentorService.swift (EDIT existing)

1. REWRITE the review prompt's discipline framing. New philosophy block (verbatim spirit):
   "He trades all sessions, all day. Trade count (baseline 3/day) and time of day are CONTEXT ONLY — NEVER criticize a trade for count, lunch, overnight, or session choice. Grade ONLY: setup quality (level score, orderflow/footprint context, market structure), direction logic vs the plays (IB/MR/BRT/APP), defined risk (entry/stop/target stated), exit discipline (fixed target; never hold through a destination level). Reserve sharp flags for: no level AND no structure basis, undefined risk, holding through target/level, revenge or euphoria language. Otherwise constructive, specific, short."
   Keep: reads plan JSON + screenshot via Read tool, ~120 word cap, banned word "fade".
2. ADD `func threadReply(entry:thread:newComment:session:level:plan:stats:resumeSessionId:) async -> Result<MentorResult, MentorError>` — same Process/timeout/parse plumbing as review() (share private helpers). Prompt: original post fields + screenshot path + the thread so far ("You said: … / Trader replied: …" chronological) + the new user comment; instruct: continue the conversation as the mentor, direct reply, max ~100 words, same philosophy block. thread: `[CommentRecord]`, newComment: String.

## Module B — Sources/Views/FeedView.swift (EDIT existing)

1. THREADS: under the mentor block in EntryCardView render `store.comments[entry.id]` — each comment a compact row inside the existing purple thread bar style: author chip (YOU dim / MENTOR purple) + text. Below: reply TextField ("Reply to mentor…") + send button -> `store.addUserComment(entryId:text:)`, clears on send; show small ProgressView when `store.mentorBusy.contains(entry.id)`. Collapse: if thread > 3, show last 2 + "show N earlier" toggle.
2. POST CRUD: card gets an ellipsis menu (top-right of header, Menu with `Image(systemName: "ellipsis")`): "Edit post", "Delete post" (destructive, confirmationDialog -> `store.deleteEntry(entryId:)`), and when a trade exists "Delete trade" (confirm -> `store.deleteTrade(tradeId:)`), plus "Retry mentor" when reply nil.
3. EDIT SHEET: `EditPostSheet(entry:)` — edit caption/lookingFor/wantToSee (text fields), action chips, play menu, level menu, instrument menu (Instrument.allCases + "session default"); Save -> mutate copy of EntryRecord fields (nilIfEmpty semantics: empty string -> nil) -> `store.updateEntry(_:)`.
4. COMPOSER INSTRUMENT CHIP: next to play/level menus, an instrument menu chip showing detected instrument: when a screenshot attaches, set `draft.instrument = Instrument.detect(fromFilename: shot.lastPathComponent)`; display chip cyan when auto-detected, dim "inst" when nil; user can override via menu. Pass through submit. Card header: show instrument TagChip when entry.instrument differs from session instrument.

## Module C — Sources/Views/SettingsView.swift (NEW) + ContentView.swift (EDIT)

1. SettingsView sheet (~480pt wide, dark theme): fields with current values from `store.settings` / effective `store.plan`:
   - Pace baseline (int stepper 1–20, nil = plan default 3)
   - Daily target USD (text, nil = milestone auto)
   - Daily max loss USD (text, nil = UNDEFINED; caption explains: display + banner only, never auto-flattens)
   - Min rank to trade (stepper 1–20, nil = plan)
   - Default instrument (menu of Instrument.allCases)
   - Read-only rows: workspace root path, TV grabs dir, plan version
   Save -> build UserSettings -> `store.saveSettings(_:)` -> dismiss. "Reset to plan defaults" clears all optionals.
2. ContentView: gear toolbar button (`gearshape`) opens the sheet. BANNER REWORK: delete the red "DONE — plan says stop" banner entirely; lunch banner becomes dim/neutral (Theme.textDim, tiny): "lunch 11:30–13:30 ET — thinner liquidity"; ADD red banner only when `store.plan.dailyMaxLossUsd != nil && store.stats.netUsd <= -maxLoss`: "MAX LOSS HIT — $X down. Plan says flat."
3. Keep TV dot, Sync, Rescan, Report, End Session, Log, Update button wiring untouched.

## Module D — Sources/Database/StatsQueries.swift (EDIT)

- `tradesTaken` = trades.count (truth from rows, not the session counter).
- `maxTrades` = plan.maxTradesPerDay (pace baseline semantics).
- `instrumentRows`: group trades by `trade.instrument ?? session.instrument`; per group: count, net ticks, net USD (non-nil results). Sorted by |netUsd| desc.
- `dailyTargetUsd` = plan.dailyTargetOverrideUsd ?? (existing milestone lookup).
- `dailyMaxLossUsd` = plan.dailyMaxLossUsd (may now be defined via settings).
- Everything else unchanged.

## Module E — Sources/Views/StatsSidebarView.swift (EDIT)

- DISCIPLINE block -> PACE block: "TRADES n" big + "pace \(maxTrades)/day" caption dim. Dot: green always when n>0 or 0 — NO red/amber at/over baseline (over pace is fine now). Only red state in sidebar: max-loss breach (below).
- P&L: add per-instrument rows from stats.instrumentRows when >1 instrument (e.g. "NQ +$420 · 84t", "ES −$60 · −12t").
- DAILY MAX LOSS row: if defined show "-$X" (red when stats.netUsd <= -X, dim otherwise); if nil keep UNDEFINED amber badge.
- Everything else unchanged.

## Module F — Sources/Services/ReportGenerator.swift (EDIT)

- Accept `comments: [String: [CommentRecord]]` (ADD parameter — update the one call site in SessionStore.generateReport to pass `comments`).
- Timeline: after the mentor blockquote render the thread chronologically: `> **You:** …` / `> **Mentor:** …` (nested blockquote lines).
- Stats section: per-instrument table when >1 instrument (instrument, trades, ticks, USD).
- Header table: keep session instrument as "Base instrument"; list distinct instruments traded.
- Pace line replaces "Trades X/max": "Trades: N (pace baseline M/day)".

## Rules (unchanged)

Theme tokens only; "fade" banned; no Edgeful; compile-clean Swift 5.9; `xcrun swiftc -parse` your file(s); don't touch modules outside your assignment; return file paths + 3-5 decision bullets.
