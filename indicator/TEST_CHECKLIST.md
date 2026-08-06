# SKULD Unified v2.4 — manual verification checklist

Paste v2.4 alongside v2.3 on the same NQ execution chart (5m) unless a step says otherwise. Compile check happens at paste time — report any error line for a same-day fix.

- [ ] **(a) Defaults parity.** Same signal labels at the same bars, same cluster lines/labels, same dev levels, same VP, same plan lines/outcome react scores as v2.3. New only: DAY TYPE row, APPR/REACT rows (— when idle), approach/react score labels, feed alerts. SIGNALS counter matches v2.3 bar-for-bar.
- [ ] **(b) Trend day replay** (e.g. a strong NY trend session): DAY TYPE reaches TREND with the range gate satisfied (no "thin" tag), holds through hysteresis, ≤ ~2 state changes for the session. T score visible and sane.
- [ ] **(c) Balance day replay**: BALANCE prints (value overlapping ≥ 50%), no flip-flopping between evaluations.
- [ ] **(d) Fast directional arrival into a 4★ cluster**: APPR shows DRIVE before the touch; REACT prints on the touch bar's CLOSE only — step bar-by-bar in replay and confirm nothing appears intrabar.
- [ ] **(e) Rotational arrival**: APPR shows GRIND.
- [ ] **(f) Replay vs live parity**: run bar replay across a session, then compare against the live chart — DAY TYPE / APPR / REACT histories identical (no repaint).
- [ ] **(g) `dtGateMode = ENFORCE`** on a trend session: counter-trend reversal marker absent; alert log shows `EVT=BENCHED|play=MR|…`. Set back to OFF after.
- [ ] **(h) STRUCTURE mode** (open a 1H+ chart): DAY TYPE row renders; APPR and REACT rows show — and produce no labels (engines skipped, not just hidden).
- [ ] **(i) Feed spot-check**: alert log contains well-formed one-line events — `EVT=TOUCH|NQ1!|…|touchNo=1|session=NY|daytype=…|appr=…`, `EVT=REACT|…|score=…|band=…`, one `EVT=DAYTYPE` per state change. Toggle `feedAlerts` off → events stop, signal alerts continue.
- [ ] **(j) Touch counter**: revisit a level twice in a session → NEAREST shows `·T2` when that cluster is nearest; counter resets next day.
- [ ] **(k) `react scoreGateMR` smoke test** (then back OFF): with it ON, a reversal at a cluster with a fresh ✓ react score still fires; one at an unreact scoreed cluster does not; a VWAP/dev-level reversal is unaffected.
