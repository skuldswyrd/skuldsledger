# SKULD Unified — Phase 0 Inventory (2026-07-30, pre-v2.4)

**Main file chosen:** `indicator/skuld.pine` — title "Skuld Unified v2.3 — Levels · IB · MR · APP · Imbalance", 1,353 lines, Pine v6. This is the canonical repo copy (working copy `~/Desktop/Trading/skuld.pine` is a byte-identical sync of it). NOTE: the build spec said "~v9" — the repo is at v2.3; new work ships as **v2.4**.

## Version & mode switch
- Header changelog v1 → v2.3 (dated blocks). `htfMode = tfSec >= timeframe.in_seconds(inModeTf)`, input default "60": STRUCTURE at/above 1H (map only, no signals), EXECUTION below.

## Session engine
- Session strings (inputs, ET): RTH `0930-1600`, IB `0930-1030`, ON `1800-0930`, Asia `1800-0300`, London `0300-0930`, lunch `1130-1330`, prime `0800-1030`, cold `0000-0100,0700-0800,1100-1200,1500-1600`.
- Booleans per bar via `time(timeframe.period, sess, TZ)`: `inRTH/inIBw/inON/inA/inL/inLunch/inPrime/inCold`; `newRTH` edge. SESSION row derives `NY/LDN/ASIA/OFF` from `inRTH/inL/inA` (computed inline in the dashboard block — will be hoisted to a global for reuse).
- Per-session tracking: RTH day extremes `rHi/rLo` (reset on `newRTH`), overnight `onHi/onLo`, VWAP accumulators reset on `newRTH`. Session profile anchors `aT0/lT0/nT0` (+ `dT0/wT0` day/week).

## Cluster data structures
- `type Lvl {price, name, rank, scope}`; profiles are `type Prof` fine-bin volume arrays.
- Prior-period level arrays: `priorD` (pd\*), `priorW` (pw\*), `priorA/priorL/priorN` (session AS/LDN/NY \*), produced by `f_levels(profile, prefix, scope)` on confirmed rolls. Names include `pdPOC/pdVAH/pdVAL/pdH/pdL/pdHVN/pdLVN` etc.
- Clusters = parallel arrays rebuilt by `f_clusters(...)` when `needCl` (day/week/session roll): `clP` price (rank-weighted mean), `clR` summed rank, `clS` scope max, `clN` merged name, `clSt` BRT state (0 live/1 up/2 down/3 dead), `clEB` BRT escape bar. Merge width `clustW` auto = 25% of target. Stars via `f_stars` (≥10=5★ … ≥4=2★), exact score labels `[12]`.
- Developing levels: `devSPoc/devSVah/devSVal/devDPoc/devDVah/devDVal` recomputed each confirmed close from fine bins; **signals test the `[1]` last-confirmed snapshot** (anti-repaint pattern).
- Signals fire on `barstate.isconfirmed and not htfMode` only. MR touch test `f_mrTest`: touch may land on this bar OR prior (`loW/hiW` = 2-bar min/max), within `mrTol` (auto 2× cluster width), rejection close via `cPos >=/<= inWick` (0.55). Priority IB → MR → APP → BRT; `gate` = RTH/lunch/hard-cap/cooldown checks (all default permissive except 5-bar cooldown); `sigCnt`, `lastSigBar`. Plan lines E/S/T + outcome stamps; one signal label per fire.

## Info table
- `table.new(f_dashPos(), 2, 10)` — rows: 0 MODE, 1 TUNE, 2 SESSION, 3 IB, 4 NEAREST, 5 sPOC, 6 IMB, 7 CLOCK, 8 SIGNALS, 9 FILTER. `f_row(t,r,k,v,stateColor)` dark-card brand style. New rows = grow row count in `table.new` + insert `f_row` calls (single block, `barstate.islast`).

## Delta / LTF machinery (the IMB row engine)
- **Exactly one `request.*` call in the script:** `[ltfC, ltfV] = request.security_lower_tf(tickerid, ltfStr, [close, volume])` (line 638). `ltfStr` auto: ≥1H→"5", ≥1m→"1", else "1S".
- Per confirmed bar the zone engine walks the LTF arrays with `var float lastLtf` carry to split `upV/dnV` (uptick/downtick volume) — **currently computed only when `enImb`**; will be hoisted to always-on so Day Type / Approach / Stamp share it. Zones: parallel arrays `imbBx/imbHi/imbLo/imbDir/imbTch/imbBorn`, origin-third bodies, touch decay (dim at 1, retire at N=2), close-through kill, ±rank bonus via `f_inZone`.
- Budget after v2.4: still **1** request call — the existing tuple widens to `[close, volume, hl2]` for the stamp's volume-thirds bins. No new calls.

## Drawing budgets & cleanup
- `max_lines_count/labels/boxes = 500`. Dev lines/labels + cluster lines/labels: rebuilt each `barstate.islast` (delete-all-then-redraw arrays). Zones: FIFO cap per side + kill rules. Signal labels persist (500 cap). Plot-family calls: **9 plots** (VWAP, ±1σ, ±2σ, ONH/ONL, IBH/IBL) — ~18 of the ~64 output units; plotshapes removed in v2.2. Room for the 5 `alertcondition` stubs (5×2 = 10 units → 28 total, safe).

## Feature mapping decisions (deviations logged in CHANGES.md)
- D1/D3 prior-day value: read `pdVAH/pdVAL` prices out of `priorD` via a name-lookup helper; developing side uses `devDVah/devDVal`.
- D2: script has ONE IB (NY 0930–1030). AS/LDN sessions score D2 = 0.
- D4: exact 15m one-timeframing via `timeframe.change("15")` bucketing on-chart — zero requests.
- ADR(10): on-chart daily range tracking via `timeframe.change("D")` — zero requests.
- Eval clock: `timeframe.change("5")` on sub-5m charts; every confirmed bar on ≥5m charts.
- Stamp touch trigger: single-bar overlap within `mrTol` (MR's own test is directional/2-bar; stamp needs side-agnostic trigger) — side taken from approach direction.
- Gating matrix: spec's default mapping hardcoded; `dtGateMode` + trend-MR exception are the inputs (24 per-cell inputs rejected as settings bloat).
- Cluster-keyed stamp/touch state lives in new parallel arrays cleared on recluster → `touchNo` is per-day by construction (matches "reset daily").
