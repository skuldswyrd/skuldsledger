# Skuld Unified — the chart side of the Ledger

One TradingView indicator, self-switching by timeframe. It IS the level engine the journal speaks: ranked clusters, developing session levels, and the three-plus-one plays — drawn, scored, and alerted.

## Install (2 minutes)

1. TradingView → Pine Editor → delete whatever's there → paste the entire contents of `Skuld_Unified.pine` → **Add to chart**.
2. Create **one** alert: right-click chart → Add alert → Condition: this indicator → **"Any alert() function call"** → save. That single alert covers every play with full entry/stop/target text.
3. Done. Re-paste the same way whenever the repo updates it.

## What it does

- **Structure mode** (1H and up): weekly + daily ranked level map. No signals — the map.
- **Execution mode** (under 1H): session VWAP ±1σ/±2σ, ONH/ONL, IB lines, ranked clusters, live developing levels (sPOC/sVAH/sVAL + day dPOC/dVAH/dVAL), and the plays:
  - **IB** — initial-balance acceptance break (the set play)
  - **MR** — reaction wick at a high-scored cluster
  - **APP** — approach: ride INTO a powerful level inside the 1.0–1.5× target window; target lands in front of it, never through it
  - **BRT** — break-retest continuation (off by default)

## The score system

Every level's label shows its **exact score** — `[12] pdH+NY H 29192.50` — uncapped, one math for all levels: scope (session 1 / day 3 / week 5) + kind (POC 5 / VA edge 3 / H-L 3 / HVN 2 / LVN 1); clusters SUM their members. Colors band by score, but the number is the truth. The journal app reads these labels straight off the chart when the TradingView bridge is up.

## Auto-tune

NQ/MNQ: 32t target / 48t stop / 2.0pt cluster width. ES/MES: 8t / 12t / 0.5pt. All overridable in inputs.

## Discipline toggles (Settings → "Discipline & trade plan")

Ships loose — signals always flow, counters display-only. Flip for strict plan mode:
- **Hard-stop signals at max** — indicator goes silent after N signals/day
- **Signals only in NY RTH** — no overnight fires
- **Lunch blackout** — 11:30–13:30 ET mute

## Journal integration

- Level labels sync into the app's level table (score → rank, exact).
- Alert text pastes into the app's trade sheet ("Paste SKULD alert" field) — play, direction, E/S/T fill themselves.

No repaint: signals evaluate on confirmed closes only. No lookahead. Not financial advice — it draws *your* plan, it doesn't have one of its own.
