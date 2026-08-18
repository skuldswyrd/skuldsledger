# SKULD 3.1 — VWAP Mean Reversion (one edge)

One TradingView indicator, one setup. It IS the level engine the journal speaks — ranked clusters, developing levels, a live effective score — but since 3.0 it fires exactly one play: **session-VWAP mean reversion at structure**.

## Install (2 minutes)

1. TradingView → Pine Editor → delete whatever's there → paste the entire contents of `skuld.pine` → **Add to chart**.
2. Create **one** alert: right-click chart → Add alert → Condition: this indicator → **"Any alert() function call"** → save. That covers both directions with full E/S/T1/T2/R text.
3. Chart of record for signals: **15m**. Re-paste the same way whenever the repo updates it.

## The edge (all gates must pass, confirmed closes only)

1. **REGIME** — ADX(14): <25 FULL · 25–30 EXTREME-ONLY (2σ + strict RSI + higher level floor) · ≥30 NO MR. Don't reverse a trending tape.
2. **STRETCH** — price ≥1.5σ from session VWAP (or ≥0.35×ATR14). Below VWAP = long candidate, above = short.
3. **TRIGGER** — RSI(7) ≤30 / ≥70 (25/75 strict), 2-bar window.
4. **LEVEL** — the stretch lands ON a pool level with EffScore ≥ the regime trade floor. ±2σ bands are pool levels. Stretch alone is never enough.
5. **CONFIRMATION** — rejection close at the level + initiative/delta standdowns (don't step in front of a train).
6. **TICKET** — E = level edge (resting limit) · S = structure + regime buffer, beyond the touch extreme · **T1 = session VWAP**, standing off any working level in between (T2 = VWAP then) · 100-tick believability cap · room gate or NOTRADE.

## Modes

- **Structure** (1H and up): weekly + daily ranked level map. No signals.
- **Execution** (under 1H): VWAP ±σ bands, TWAP, the nearest K qualifying levels per side (effective-score gated), developing sPOC/dPOC lines, the signal + plan lines, the HUD.

## The score system

Every label shows the level's **effective score** — base rank (scope + kind, clusters sum members) × directional reaction memory (EWMA hold rate) × freshness decay per touch today — plus its H/B record for the approach side. Broken levels decay off the chart; defended levels earn weight.

## HUD

- **WAITING**: nearest qualifying level each side, ROOM check, and the GATES row — `ADX 18 FULL · STR 1.7σ · RSI 24 · LVL ✓` — so the missing condition is always obvious.
- **SIGNAL**: BUY/SELL MR block, E/S/T1/R, FROM level, T2 (when T1 stood off an intermediate level), advisory RISK sizing (% of account → contracts), VALID countdown (bar-based, default 6).

## Journal integration

- Level labels sync into the app's level table (score → rank, exact).
- Alert pipe pastes into the app's trade sheet: `SKULD|BUY MR|ticker|E:|S:|T1:|T2:|R:|ADX:|STRETCH:|LVL:|time`.
- Optional `EVT=NOTRADE` feed (off by default) reports room-gate / believability kills.

No repaint: everything evaluates on confirmed closes, level snapshots test where the chart drew them, daily pulls are prior-day completed values. Not financial advice — it draws *your* plan, it doesn't have one of its own.
