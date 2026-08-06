# SKULD Unified v2.4 — CHANGES (2026-07-30)

Three additive features + ledger feed. **At every default: signals, levels, existing table rows, plan lines and existing drawings behave exactly as v2.3.** New at defaults: the DAY TYPE / APPR / STAMP rows, approach + stamp labels (their features' display defaults per spec), and the feed alerts. Enforcement (`dtGateMode`, `stampGateMR`) ships OFF.

## Features
- **A · DAY TYPE** — BALANCE / TREND▲ / TREND▼ / TRANSITION per session. T = D1 open vs prior value (±2) + D2 IB break holding ½-range beyond (±2) + D3 value migration with <25% overlap (±2, ≥50% overlap sets the balance flag) + D4 15m one-timeframing streak (±2) + D5 session delta slope with ≥65% same-sign share (±1). TREND needs |T| ≥ 5 AND session range ≥ frac × ADR(10) (NY .60 / LDN .45 / AS .30). BALANCE needs |T| ≤ 2 AND overlapping value. 2-evaluation hysteresis. Row under SESSION; optional faint tint (OFF).
- **A gate** — `dtGateMode` OFF (default) / ADVISORY (benched signal prints dim + BENCH tag) / ENFORCE (marker suppressed, BENCHED feed event fires, signal counter untouched). Matrix per spec; with-trend reversal exception at rank ≥ 8 + fresh stamp ≥ 70 (`dtTrendMrException` ON).
- **B · APPR** — active in execution mode when the nearest qualifying cluster in the travel direction sits in (touch tolerance, 1.5× target]. DRIVE (eff ≥ .55, speed ≥ .35 × ATR14/bar, pullback ≤ 40%), DRIFT (speed ≤ .12, delta alignment 35–65%), else GRIND. Row `▼ DRIVE → ★★★★ 29402 · 21t`, playbook hint in tooltip, optional target label (FIFO 10). `apReplaceNearest` OFF.
- **C · STAMP** — on armed touch of a rank ≥ min cluster: S1 delta flip vs arrival scaled by size (30) + S2 extreme-third LTF volume share, 30→45% ramp (25) + S3 rejection structure on the close, reusing MR's close-position read (25) + S4 new price extreme without delta confirmation (20). ✓ ≥70 / – 40–69 / ✗ <40. Label at touch (FIFO 20) + STAMP row. Re-arm: 20 bars or 2× cluster width away. `stampGateMR` OFF; when ON applies to cluster-based reversals only (+10 under DRIVE with `stampDriveStrict`).
- **LEDGER FEED** — `alert()` events on confirmed bars: `EVT=TOUCH|…|touchNo|session|daytype|appr`, `EVT=STAMP`, `EVT=DAYTYPE old->new`, `EVT=APPR`, `EVT=BENCHED`. Master + per-event toggles (ON). 5 `alertcondition` stubs. Per-cluster touch counter shown as `·T2+` on NEAREST.

## Inputs (name · default · group)
Day Type: dtOn true · dtTrendThresh 5 (3–9) · dtBalThresh 2 (0–4) · dtHysteresis 2 (1–5) · dtOneTfStreak 4 (2–10) · dtRangeNY .60 / dtRangeLDN .45 / dtRangeAS .30 · dtGateMode "OFF" · dtTrendMrException true · dtTint false.
Approach: apOn true · apWindow 10 (5–40) · apMaxDist 1.5 · apEffMin .55 · apSpeedMin .35 · apPullMax 40 · apSpeedDrift .12 · apAlignLo 35 / apAlignHi 65 · apReplaceNearest false · apChartLabel true.
Touch Stamp: stOn true · stW1 30 / stW2 25 / stW3 25 / stW4 20 · stBotShare 45 · stampRearm 20 · stampGateMR false · stampMinMR 60 · stampDriveStrict false.
Ledger Feed: feedAlerts true · feedTouch/feedStamp/feedDayType/feedAppr/feedBench true.

## Budgets
- `request.*`: **1 before → 1 after** (existing lower-TF tuple widened to `[close, volume, hl2]`).
- Output calls: 9 plots + 5 alertcondition + 1 bgcolor = 15 calls (≈30 units of ~64) — safe.
- New drawings: approach labels FIFO 10, stamp labels FIFO 20.

## Deviations from the spec (spec said prefer repo reality + log)
1. Repo is **v2.3**, not "~v9" → version bumped to v2.4.
2. Play matrix cells are the spec's default mapping **hardcoded**; per-cell inputs (24 booleans) rejected as settings-panel bloat. `dtGateMode` + `dtTrendMrException` are the knobs.
3. D2 uses the script's ONE IB (NY 0930–1030). AS/LDN sessions score D2 = 0.
4. D4 one-timeframing: exact 15m buckets via `timeframe.change("15")` on-chart (no request). On charts ≥ 15m the chart bars stand in.
5. ADR(10): on-chart daily-range tracking via `timeframe.change("D")` (no request). Warms up over the first 10 loaded days.
6. Eval clock: sub-5m charts evaluate on 5m boundaries; ≥5m charts every confirmed bar (spacing = chart TF).
7. Approach deactivation ">2× target" is subsumed: activation window already ends at 1.5× target.
8. Stamp touch trigger = single-bar range overlap within MR tolerance (MR's own test is directional/2-bar; the stamp needs one side-agnostic trigger). Arrival side = approach direction (fallback: 5-bar travel).
9. S4 "cumulative window delta fails a new extreme" implemented as: new price extreme + touch-bar delta flip → full; + touch-bar |delta| ≤ 25% of window average → half; else 0 (per-bar proxy for the cum-delta test).
10. `touchNo` counts armed touches (one per touch sequence, same re-arm as the stamp) and resets when clusters rebuild (daily) — matches "reset daily" by construction.
11. TOUCH/STAMP events fire for rank ≥ min-rank clusters (the tradeable map), not every drawn level.
12. ENFORCE-benched APP still consumes its one-shot-per-level slot (level marked fired before the gate runs).
13. Committed as one code commit + one docs commit (single interleaved file; per-feature commits would have been artificial splits).
14. Three pre-existing vocabulary violations fixed (BRT input label "Escape margin"→"Break margin", two comments) — text only, zero behavior.
15. New rows/labels at defaults: the spec's own display defaults make DAY TYPE/APPR/STAMP visible; "bit-identical" is honored for every EXISTING element.

## Graduation criteria (do not flip early)
Run 20 sessions with everything advisory-only. Flip `stampGateMR` ON only if reversal winners' median stamp beats reversal losers' median by ≥ 15 points over the sample (the ledger's STAMP feed makes this a query). Flip `dtGateMode=ENFORCE` only if benched signals' hypothetical outcomes net negative over the sample. Until then the trader's eyes stay the gate.
