# SKULD 3.1.0 — SESSION PERSPECTIVE (2026-08-12)

Purely informational addition, his ask: "a way to understand RTH and ETH,
maintain perspective on a movement" — zero effect on gates, doctrine, or
the ticket.

- Thin dotted vertical line at every session open. NY (RTH) gets a small
  tagged label + a slightly brighter line; Asia/London (ETH) draw dimmer,
  unlabeled. Static once drawn — never repainted/redrawn. Toggle
  showSessLines (default on); off = zero chart marks. No background
  shading anywhere (standing no-decorative-chart-art rule).
- New HUD row, WAITING state only: "NY 47m · rng 63% ADR" — elapsed time
  in the live session + today's range so far vs the prior day's ATR(14)
  (the regime engine's own dATR — no new state added). Amber only past
  100% of a normal day's range — a heads-up, never a gate.

Considered and rejected for 3.1: LuxAlgo's Polynomial Regression
Extrapolation. Three reasons: CC BY-NC-SA license blocks embedding it in
this public repo; a curve-fit forward projection is exactly the "random
math target" doctrine 2.9.3 killed ("use key levels as targets"); and
polynomial extrapolation is inherently unstable at the fitted window's
edges (Runge's phenomenon) — not something serious desks forecast with.
Regime detection stays ADX's job.

# SKULD 3.0.0 — VWAP MEAN REVERSION, ONE EDGE (2026-08-12)

Rewritten from scratch around a single setup. The doctrine, one line:
price stretched from session VWAP (σ or range), landing ON a scored SKULD
level, RSI exhausted, rejection close confirmed, in a regime where mean
reversion is allowed → resting limit back to VWAP. Nothing else fires.

NEW — the edge (input group "3.0 · Mean Reversion Edge"):

- REGIME: ADX(14) on the chart TF. <25 FULL · 25-30 EXTREME-ONLY (needs
  stretch ≥ 2σ + strict RSI + level score ≥ trade floor +2) · ≥30 NO MR.
  Confirmed bars only.
- STRETCH: |close − VWAP| ≥ 1.5σ (the script's own session σ) OR ≥ 0.35 ×
  ATR(14) of the chart TF. Below VWAP = long candidate, above = short.
- TRIGGER: RSI(7) ≤30 long / ≥70 short (25/75 strict), 2-bar window — the
  rejection candle may be the bar after the RSI extreme.
- LEVEL: the stretch must land ON a pool level whose EffScore (arrival
  direction) ≥ the regime trade floor. ±2σ bands are pool levels, so a 2σ
  tag counts. VWAP stretch alone is never enough — this is the SKULD tie-in.
- CONFIRMATION: the 2.9 rejection test (close back on the VWAP side, close
  position ≥ 0.55) + the initiative and lower-TF delta standdowns.
- TICKET: E = level edge offset into the zone (resting limit) · S = beyond
  the far edge + regime buffer AND beyond the touch bar's extreme · T1 =
  SESSION VWAP, the primary target — a qualifying working level between
  entry and VWAP intercepts it (T1 = its front edge − standoff, T2 = VWAP,
  shown in HUD/alert; plan lines draw T1 only). VWAP farther than the
  100-tick believability cap (or the regime TP cap) = NO TRADE. Room gate
  tpDist ≥ max(minR × stop, tpFloor × dATR) or NOTRADE. R emitted.
- RISK row (advisory): 0.5% of account → contracts from stop ticks × tick
  value (futures); CFD/forex shows ticks only.
- HUD WAITING gains a GATES row — "ADX 18 FULL · STR 1.7σ · RSI 24 · LVL ✓",
  each token colored, so the missing condition is always visible. SIGNAL
  state: BUY/SELL MR block, E/S/T1/R grid, FROM, T2 (when applicable), RISK,
  VALID clock (bar-based, default 6 bars = 90m on the 15m chart of record).
- Alerts: two alertconditions (BUY MR / SELL MR); the alert() pipe now
  carries E/S/T1/T2/R/ADX/STRETCH/LVL/time. NOTRADE events opt-in
  (feedNoTrade, default off).
- Fix inherited from 2.9.x: the day-scope EffScore epoch (epDay) now
  actually bumps at the trade-day roll — day-scope reaction stats reset
  daily as documented instead of accreting forever.

KEPT (2.9.x machinery, verbatim): sessions NY/LDN/ASIA + trading day at the
Asia open · per-session VWAP ±1σ/±2σ (±3σ optional, default off) + TWAP ·
regime engine (daily ATR percentile + VIX tier → widths/floors/caps/buffer)
· profile→levels→clusters pipeline · unified level pool (VWAP 10 · sesH/L 8
· dPOC 8 · TWAP 6 · ±2σ 6 · ONH/L 6 · dVA 6 · sPOC 6 · sVA 4 · IBH/L 4 as
levels only) · EFFECTIVE SCORE reaction memory · STRUCTURE ≥1H map /
EXECUTION nearest-K render · fill-aware plan lifecycle (RAN-unfilled clears)
· deck-spec HUD.

DIED (deleted outright): IB play · BRT play · APP play/advisory · imbalance
zones + ◆ bonus · day-type engine (D1-D5, gate matrix, tint) · APPR grades ·
TOUCH REACT scoring + labels · ledger feed events except NOTRADE · the
14-row debug HUD (now 4 rows: REGIME/ADX/STRETCH/GATES) · legacy tick seeds
(width seed = 0.02×dATR until the tier engine writes) · CLOCK prime/cold
hours · lunch blackout · volume-multiple MR filter · VP histogram "Bars"
mode (developing POC lines only) · ONH/ONL + IB chart plots (both stay in
the pool and surface through the nearest-K render).

Chart = candles, VWAP+bands, TWAP, K levels/side with labels, developing
sPOC/dPOC lines, signal fire label, plan lines E/S/T1 + outcome stamp, HUD.
Nothing else. No bgcolor.

OUTPUT BUDGET: 8 plot() + 2 alertcondition() = 10 calls (×2 internal = 20,
cap 64). Everything else is line/label/table objects.

# SKULD 2.9.3 — TARGETS ARE LEVELS, PERIOD (2026-08-10)

His call: "use key levels as targets, not random math targets."

- Open-field TP fallback (entry +/- tpCap x dATR) removed: no qualifying
  opposing level in reach = NO TRADE. Every T1 is the front edge of a real
  level. Applies to MR, IB and BRT alike (shared construction).
- Believability cap: target level must sit within inTpMaxT ticks (input,
  default 100). Farther = no trade; never truncated to a mid-air price.
- HUD SIGNAL block adds a FROM row (source level, gold, tooltip = full
  text); ROOM row prints "no lvl" when a side has no reachable target.
