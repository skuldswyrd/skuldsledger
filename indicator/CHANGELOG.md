# SKULD 2.9.3 — TARGETS ARE LEVELS, PERIOD (2026-08-10)

His call: "use key levels as targets, not random math targets."

- Open-field TP fallback (entry +/- tpCap x dATR) removed: no qualifying
  opposing level in reach = NO TRADE. Every T1 is the front edge of a real
  level. Applies to MR, IB and BRT alike (shared construction).
- Believability cap: target level must sit within inTpMaxT ticks (input,
  default 100). Farther = no trade; never truncated to a mid-air price.
- HUD SIGNAL block adds a FROM row (source level, gold, tooltip = full
  text); ROOM row prints "no lvl" when a side has no reachable target.

