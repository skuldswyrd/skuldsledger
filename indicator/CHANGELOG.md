# SKULD 2.9.2 — BRT GROWS UP (2026-08-10)

Field report: BUY BRT fired on a wick through VWAP/dPOC — one close beyond
the level counted as a "break" and any shallow dip while holding above
counted as a "retest." Fixed with real break-retest anatomy:

- **Acceptance**: break = inAcc consecutive closes beyond the escape margin
  (IB's standard; signed per-cluster counter, reset on recluster/reclaim).
- **Separation**: retest cannot fire until N bars after the accepted break
  (input, default 3) — same-chop fires dead.
- **Depth**: retest low must reach within half a cluster width of the level
  (was 2x width tolerance — grazes counted).
- **Rejection**: retest bar must close at MR's wick standard (top/bottom
  0.55 of range).
- **EffScore gate**: retested cluster must score >= the regime trade floor
  from the approach side (was raw rank only).

