# RESULTS -- mac_pe (PIPELINE_MAC=1, sky130A / sky130_fd_sc_hd, LibreLane 3.0.16 nix)

Filled **in between phases** (plan §2, decision log in `00_PLAN.md` §4).
Rule: every number below is copied from a run artifact named in the row.

## 1. Phase 1a -- `CLOCK_PERIOD` is INERT at synthesis (measured 2026-10-16)

| Tag | CLOCK_PERIOD [ns] | ABC delay [ps] | cells | cell area [µm²] | netlist vs s10 |
|---|---|---|---|---|---|
| s10 | 10 | 3968.66 | 625 | 6961.68 | — (baseline) |
| s06 | 6 | 3968.66 | 625 | 6961.68 | **identical** |
| s05 | 5 | 3968.66 | 625 | 6961.68 | **identical** |
| s04 | 4 | 3968.66 | 625 | 6961.68 | **identical** |
| s03 | 3 | 3968.66 | 625 | 6961.68 | **identical** |
| s02 | 2 | 3968.66 | 625 | 6961.68 | **identical** |

`diff s10/…/mac_pe.nl.v s2/…/mac_pe.nl.v` → **no difference**. The generated
`DELAY_0.abc` script contains no `-D`; yosys passes `abc -D <period>` but `&nf`
ignores it. Same inertness under `AREA 0` (`a10` ≡ `a02`: 476 cells /
5124.92 µm² / 5620.43 ps both). **Conclusion: never sweep `CLOCK_PERIOD` at
synthesis -- it measures one mapping repeatedly.** The mapping is decided by
`SYNTH_STRATEGY`; the period by PnR (SDC-driven repair + STA).

Also recorded from s10: `PIPELINE_MAC=1` really applied — Yosys log line
`Generating RTLIL … $paramod\mac_pe\PIPELINE_MAC=…0001`, so the mapping is the
mandated `[hop] | [mult] | [add] | [acc]` build, not the default. Lint: 0
errors, 2 warnings (both `UNUSEDSIGNAL clk/clr` in the multiplier's PIPE=0
branch — structurally unavoidable while PIPE=1 is set at the *mac* level, and
a warning, not an error). 0 unmapped, 0 synth check errors, `lev = 20`.

Source: `runs/<tag>/06-yosys-synthesis/yosys-synthesis.log` (`Delay = … ps`),
`runs/<tag>/final/metrics.json`.

Calibration anchor: parent 4x4 `matrix_mult` @10 ns with `PIPE=0`
(mult+add in one cycle) = **ABC delay 9166 ps, 10156 cells, 120797 µm²**
(`designs/matrix_multiplication/runs/pre1`). PIPE=1 must beat 9166 ps.

## 2. Phase 1b -- the real synth lever: ABC strategy + buffering

Fixed period 7 ns for every row; **interface model aligned with the SDCs**
(`SYNTH_DRIVING_CELL sky130_fd_sc_hd__buf_1/X`, `OUTPUT_CAP_LOAD: 10` fF ==
`set_load 0.010 pF` with sky130 `capacitive_load_unit pf`) so synth and STA
model the same chip. Pre-alignment defaults (`inv_2/Y`, 33.442 fF) gave
DELAY 0 = 3968.66 ps and AREA 0 = 5620.43 ps.

| Tag | SYNTH_STRATEGY | extra | ABC delay [ps] | cells | cell area [µm²] | vs DELAY 0 |
|---|---|---|---|---|---|---|
| d0 | DELAY 0 | — | 4466.66 | 625 | 6961.68 | baseline |
| d1 | DELAY 1 | — | 3994.56 | 641 | 6850.32 | −11 % delay, **−1.6 % area** (dominates d0) |
| d2 | DELAY 2 | — | 4010.77 | 648 | 6901.62 | −10 % |
| d3 | DELAY 3 | — | 4272.34 | 636 | 7020.48 | −4 % |
| d4 | DELAY 4 | — | 4249.92 | 711 | 7286.99 | −5 % delay, +5 % area |
| a0 | AREA 0 | — | 5872.56 | 476 | 5124.92 | +31 % delay, **−26 % area** |
| **b0** | DELAY 0 | `SYNTH_ABC_BUFFERING=true` | **3393.04** | 667 | 7474.67 | **−24 % delay, +7 % area** |

`SYNTH_ABC_BUFFERING` adds ABC's `buffer -N <fanout 10> -S <tran 0.75 ns>;
upsize;dnsize` to the script -- the one toggle that beat every strategy.
`SYNTH_ABC_DFF` (ABC `-dff`, retiming across registers) is **deliberately
never tried**: retiming would move pipeline registers and change the in-PE
latency the PIPE=1 contract specifies (rtl header: the product lands one clock
after its operands are registered) -- that would be an implicit RTL change.

## 3. Batch 2 -- buffering × DELAY 1/2/3 × MFS3 → **WINNER: c1**

| Tag | strategy | extra | ABC delay [ps] | cells | cell area [µm²] |
|---|---|---|---|---|---|
| **c1** | **DELAY 1** | **buffering** | **2970.83** | **678** | **7392.09** |
| c2 | DELAY 2 | buffering | 3069.38 | 686 | 7300.75 |
| c3 | DELAY 3 | buffering | 3274.88 | 673 | 7524.72 |
| m1 | DELAY 1 | buffering + mfs3 | 3124.66 | 699 | 7509.70 |
| m0 | DELAY 0 | buffering + mfs3 | **CRASH (exit 134)** | — | — |

* **Selected mapping: `c1`** = `SYNTH_STRATEGY: DELAY 1` +
  `SYNTH_ABC_BUFFERING: true` → **2970.83 ps**, 678 cells, 7392.09 µm²:
  −33 % delay vs the default DELAY 0 at +6 % area (and −26 % delay vs plain
  DELAY 1).
* `m0` crashed ABC — `utilTruth.h:2257 … Assertion 'pCut[i] == pCut0[k]'
  failed` → `yosys-abc: Aborted (core dumped)` (`runs/m0/error.log`).
  `SYNTH_ABC_USE_MFS3` is rejected: unreliable on DELAY 0, and on DELAY 1 it
  is slower *and* bigger than plain buffering (m1 vs c1).
* Delay ranking: **c1 2971 < c2 3069 < c3 3275 < b0 3393 < d1 3995 < d2 4011
  < d4 4250 < d3 4272 < d0 4467 < a0 5873 ps**.
* Area ranking (for the later area pass): **a0 5124.92 < d1 6850.32 <
  d2 6901.62 < d0 6961.68 < d3 7020.48 < d4 7286.99 < c2 7300.75 <
  c1 7392.09 < b0 7474.67 < m1 7509.70 < c3 7524.72 µm²**.
* Config after the study: `SYNTH_STRATEGY: DELAY 1`,
  `SYNTH_ABC_BUFFERING: true`, `SYNTH_ABC_USE_MFS3` unset (false).

## 4. Phase 3 -- full PnR, 6 ns baseline (tag f6)

Synthesis predicts **2971 ps** (TT, wire-load-free, buf_1 + 10 fF boundary
model). The 6 ns baseline covers wire + SS overhead that synth cannot see;
post-PnR STA then tightens or loosens ONE period at a time (plan §4 ladder).

| Tag | period [ns] | die side (square) | util | DRT viol | setup WNS TT | setup WNS SS | hold WNS | max-slew/max-cap | verdict |
|---|---|---|---|---|---|---|---|---|---|
| f6 | 6 | 168.01 × 178.73 (30028 µm², *not* exact square) | 40.03 % (core 24320 µm²) | **0** | **0.00 (WS +2.104)** | **−1.5215 (TNS −11.23, 33 paths)** | **0.00 (WS +0.263)** | **0 / 0 / 0** | **FAIL SS setup only** |

f6 receipts (2026-10-16, runtime 4m37s, `flow__errors__count: 0`):

* **Signoff clean except SS setup**: magic DRC 0, klayout DRC 0, XOR 0, LVS
  0 (device/net/pin/property all 0), antenna 0, DRT 0 (234→35→26→**0** in 4
  iters), PDN violations 0, IR drop worst 0.00225 V = **0.125 %**, 0
  disconnected pins, 0 max-slew / max-cap / max-fanout violations at **all 9
  corners**.
* **Period bounds (the number that matters)**: `nom_tt_025C_1v80`
  `period_min = 3.90 ns` (**256.69 MHz**) · `max_ss_100C_1v60`
  `period_min = 7.52 ns` (**132.95 MHz**) — SS is the binding corner, as
  predicted by the plan's ladder. Hold met everywhere (worst hold WS +0.204).
* Failing SS path: `_1293_ → _1281_`, ~20 logic levels through the array
  multiplier cone (matches ABC's `lev = 20`), 11 violating paths per SS corner
  (−1.5215 / −1.488 / −1.481 … −0.822 ns) — i.e. **the `mult` segment of the
  PIPE=1 pipeline, exactly the path `impl.sdc` predicted**, not an IO path
  (the worst IO path, `a_in[5] → a_reg`, was +3.91 ns MET).
* IO pin placement **matches the floorplan guide exactly**: N 12, E 8, W 8,
  S 26 (54 = port count), and **W/E are perfectly symmetric** (both start at
  track 9, 16 tracks/pin, 113 used tracks) → the a-hop lands as a straight
  wire. N starts at track 17, S at track 7 — the documented, accepted
  north/south asymmetry (12 vs 26 pins).
* Area: die 168.01 × 178.73 µm = 30028.4 µm², core 24319.6 µm²,
  std-cells 1166 / 9735.59 µm² (synth 678 + 119 timing-repair buffers + 15
  clock buffers + 45 setup buffers), fill 4188 cells, tap 354, rows 57,
  utilization 40.03 % (= `PL_TARGET_DENSITY_PCT`, i.e. **the die is already
  as small as density 40 allows** — the area lever is density, not util).
* Power (LibreLane vectorless default activity, `nom_tt_025C_1v80`):
  **2.132 mW total** (1.229 internal / 0.904 switching / 0.015 leakage);
  flow-level `power__total` 2.479 mW. IR-drop analysis ran without
  `VSRC_LOC_FILES` (accuracy warning, acceptable for a block).
* CTS: 50 sinks, 15 clock buffers (270.26 µm²), skew worst setup 0.1275 ns /
  worst hold −0.1135 ns at SS.
* **Open question closed — the 2 "floating nets" (RSZ-0020) are `VGND` and
  `VPWR`**, not signal nets: `runs/f6/32-openroad-repairdesignpostgpl/
  openroad-repairdesignpostgpl.log` prints them by name immediately after the
  warning (the resizer counts the power nets as driverless at that stage).
  Confirmed harmless by the downstream receipts: netgen **"Circuits match
  uniquely"**, 0 disconnected pins, 0 PDN violations, IR drop 0.125 %, and an
  empty `error.log`. No action taken — and the `STA-1140` "library already
  exists" lines are the same benign message the reference runs logged.

Sources: `runs/f6/final/metrics.json`,
`…/55-openroad-stapostpnr/{summary.rpt,max_ss_100C_1v60/{max.rpt,sta.log},nom_tt_025C_1v80/{power.rpt,sta.log}}`,
`…/26-odb-customioplacement/odb-customioplacement.log`,
`…/openroad-floorplan.log`.

Sources: `…-openroad-floorplan/openroad-floorplan.log`,
`…-detailedrouting/`, `…-stapostpnr/summary.rpt`,
`…-stapostpnr/<corner>/sta.log` (`period_min`, `fmax`).

### 4.1 Period ladder — rung 1 (loosen period, one rung per run)

Tags `f65` / `f70` / `f75` produced by `scripts/sweep_period.sh` (period updated
in all 3 places per run); every run `flow__errors__count: 0`, DRT 0, antenna 0,
hold 0, max-slew/cap/fanout 0 at **all 9 corners**, TT/FF setup 0 — **only
`max_ss`/`nom_ss` setup still failing.**

| Tag | target [ns] | max_ss WNS | nom_ss WNS | min_ss WNS | hold WS | logic cells | stdcell area [µm²] | util | power total [mW] | SS req = target+|WNS| |
|---|---|---|---|---|---|---|---|---|---|---|
| f6 | 6.0 | −1.5215 | −1.3821 | −1.2359 | 0 | 812 | 9735.59 | 40.03 % | 2.479 | **7.5215** |
| f65 | 6.5 | −1.0357 | −0.8903 | −0.7455 | 0 | — | — | — | 2.258 | **7.5357** |
| f70 | 7.0 | −0.5537 | −0.4125 | −0.2673 | 0 | — | — | — | 2.081 | **7.5537** |
| f75 | 7.5 | **−0.2044** | −0.0749 | **0 ✓** | 0 | 774 | 9001.13 | 37.01 % | 1.880 | **7.7044** |
| f775 | 7.75 | −0.2087 | −0.0799 | 0 ✓ | 0 | 786 | — | — | 1.797 | **7.9587** |
| f775ss | 7.75 + `SYNTH_CORNER=ss` | −0.2557 | −0.1430 | −0.0242 | 0 | — | 5679† | — | 1.923 | **8.0057** ← rejected (§4.2) |
| **f6s76** | **6.0 repair / 7.6 signoff** | **+0.0785 ✓** | **+0.2179 ✓** | **+0.3641 ✓** | +0.204 | 3.97 | 5354 | — | 1.957 | **7.5215 (achieved)** ← **ALL 9 CORNERS GREEN, §4.3** |

**f775 exposed the plateau**: raising the target by 0.25 ns moved the SS
requirement by +0.254 ns — the gap stopped shrinking and locked at ~0.205 ns
(gap vs target: 1.52 → 1.04 → 0.55 → 0.204 → **0.209**). Diagnosed from the
worst-path reports (`55-openroad-stapostpnr/max_ss_100C_1v60/max.rpt`):

* same cone both times (`_1293_→_1281_` at f6, `_1291_→_1279_` at f775, the
  multiplier), but **different cells**: f6's hard target made the resizer
  upsize the critical gates (`o21ai_4`, `o22ai_4`, `a21oi_2`, `buf_4`; path
  cell-delay sum **8.65**), f775's loose target left weak drives (`nand2_2` ×10,
  `nand4_2` ×6, `o211ai_1`; sum **8.96**).
* so the requirement tracks the target because **repair upsizing stops above
  ~7.5 ns**: `repair_timing` only edits what it sees as a violation, and the
  residual violation is the same ~0.2 ns either way.

What the ladder proved:

1. **The binding corner is `max_ss_100C_1v60`** (slow lib + Cmax RC); `min_ss`
   already closed at 7.5, `nom_ss` was −0.075, TT/FF never failed. TT bound
   stayed ~3.90–3.94 ns (256→254 MHz) and FF ~2.45–2.60 ns (393–408 MHz) the
   whole way — SS/TT ≈ 1.93×, a normal sky130 `hd` SS(1.6 V, 100 °C) vs
   TT(1.8 V, 25 °C) ratio, not a modeling artifact.
2. **`repair_timing` gains ~nothing on this cone**: improving the target by
   1.5 ns moved the SS requirement by only **+0.18 ns** the wrong way
   (7.5215 → 7.7044).
3. **Repair pressure is real but double-edged**: the hard 6 ns target made the
   resizer insert the *most* logic (812 cells / 9735.6 µm²) and that run had
   the *fastest* SS requirement (7.5215); the relaxed 7.5 ns target inserted
   fewer buffers (774 cells / 9001.1 µm² — smaller area, −7.5 %) but left SS
   0.18 ns slower. Period and area therefore pull in the same direction here:
   a tighter target ⇒ more repair ⇒ faster SS, larger area.
4. Power tracks the period target as expected (clock + cell-count driven):
   2.479 → 2.258 → 2.081 → 1.880 mW from 6.0 → 7.5 ns — so *slack costs
   power* in this design too.

**Rung 1b executed:** `f775` (period 7.5 → 7.75, one knob) — failed as shown
above, proving the gap cannot be closed by *loosening alone* (the requirement
chases the target once repair stops up-sizing).

### 4.2 Lever 2 — map against the binding corner (`SYNTH_CORNER`)

Evidence chain:

1. Synthesis was mapping against **TT only**: the merged `tmp/*.lib` had
   `default_operating_conditions : "tt_025C_1v80"`, `nom_voltage 1.80`,
   `nom_temperature 25.0` — while the corner that decides signoff is SS
   (`max_ss_100C_1v60`, 1.6 V / 100 °C + Cmax RC). ABC optimizes cell choice
   for the *fast* corner, so its output is under-driven at SS (§4.1 cell mix).
2. The supported knob is `SYNTH_CORNER` (librelane `steps/pyosys.py:224`:
   *"A fully qualified IPVT corner to use during synthesis; if unspecified the
   PDK's `DEFAULT_CORNER` is used"*) — synthesis filters the `LIB` corner dict
   (`tools.box.filter_views`) through it.
3. **Gotcha (run `sc1`, recorded):** the value must be RC-qualified to match
   the `LIB` keys — `ss_100C_1v60` matched **nothing** → empty lib list →
   `DFFLIBMAP ERROR: Missing '-liberty liberty_file' option!` (flow aborts at
   step 06). Correct form = `max_ss_100C_1v60` (`LIB` keys are
   `*_tt_025C_1v80`, `*_ss_100C_1v60`, `*_ff_n40C_1v95`; `DEFAULT_CORNER` is
   `nom_tt_025C_1v80`, i.e. `<RC>_<PVT>`, and `max`/`nom`/`min` select the
   same SS liberty file).
4. Verified in run `sc2` (synth only): merged lib now
   `default_operating_conditions "ss_100C_1v60"`, 100 °C, 1.600 V;
   **709 cells / 7577.27 µm²** (TT mapping was 678 cells / 7392.09 µm² —
   +2.5 % area for SS-directed sizing), 0 unmapped, 0 check errors.
5. Full-flow test: tag **`f775ss`** = one knob from `f775` (`SYNTH_CORNER=max_ss_100C_1v60`,
   period unchanged at 7.75 in all 3 places). Judged by `max_ss` WNS vs f775's
   −0.2087.

**Verdict — REJECTED (measured, full flow):**

| run | mapping | max_ss WNS | SS req | nom_ss | min_ss | TT period_min | FF | logic cells | power [mW] |
|---|---|---|---|---|---|---|---|---|---|
| f775 | `DEFAULT_CORNER` (TT) | −0.2087 | 7.9587 | −0.0799 | 0 ✓ | 3.97–4.09 | 2.54–2.62 | 5560* | 1.797 |
| f775ss | `max_ss_100C_1v60` | **−0.2557** | **8.0057** | −0.1430 | −0.0242 | **4.17–4.28** | 2.72–2.79 | 5679* | 1.923 |

\* `design__instance__count` from `final/metrics.json` (incl. fillers).

Mapping for the slow corner made the design **worse at every corner**: SS
requirement +0.047 ns, TT +0.2 ns, min_ss now failing too, +119 instances,
+7 % power. The hypothesized "ABC optimizes for TT, so map for SS" did not
survive contact with the full flow — ABC's SS-directed cell choice *widened*
the cone (more/slower cells on the critical path) instead of speeding it.
**Keep `DEFAULT_CORNER` (TT mapping); reject `SYNTH_CORNER=ss` for this design.**
(A second `SYNTH_CORNER` try on a different design could behave differently —
the method here is "measure, don't assume".)

### 4.3 Lever 3 — deliberate over-constrained PnR SDC (tag f6s76)

Observation from the ladder: the SS *requirement* is nearly flat when repair
is tight (7.5215 @ 6.0 target) and then **chases the target upward** once
repair stops up-sizing (7.7044 @ 7.5, 7.9587 @ 7.75) — i.e. the tight rung is
the one that produced the fastest silicon model. So split the constraint set:

| file | value | role |
|---|---|---|
| `config.yaml` `CLOCK_PERIOD` | **6.0** | drives `repair_timing` / PnR optimization (over-constrained on purpose) |
| `impl.sdc` `create_clock` | **6.0** | PnR STA steps see the same target (intermediate STA warnings are expected and documented) |
| `signoff.sdc` `create_clock` | **7.6** | what **signoff STA reports** — the actual claim |

Expected: signoff reproduces f6's design (identical inputs except signoff
period) → max_ss WNS ≈ 7.6 − 7.5215 = **+0.078** at `max_ss_100C_1v60`,
hold/TT/FF clean as in f6, `flow__errors__count: 0`.

**Result — RUN COMPLETE, FIRST FULLY-GREEN SIGNOFF:**

| corner (signoff @ 7.6 ns) | setup WS [ns] | hold WS [ns] |
|---|---|---|
| **max_ss_100C_1v60** (binding) | **+0.07851** | +0.2041 |
| nom_ss_100C_1v60 | +0.2179 | +0.2244 |
| min_ss_100C_1v60 | +0.3641 | +0.2390 |
| max/nom/min_tt_025C_1v80 | +3.63 / +3.70 / +3.78 | +0.250 / +0.263 / +0.272 |
| max/nom/min_ff_n40C_1v95 | +4.54 / +4.55 / +4.57 | +0.231 / +0.229 / +0.227 |

* `flow__errors__count: 0`; TNS = 0 and WNS = 0 (no negatives) at **all 9
  corners** for setup *and* hold; DRT/antenna/DRC/LVS/XOR/PDN/IR identical to
  f6 (same physical design, same inputs).
* Prediction **exact**: 7.6 − 7.5215 = +0.0785 vs measured +0.07851 → the
  requirement is deterministic for fixed inputs.
* period_min: max_ss **7.52 ns (132.95 MHz)**, nom_ss 7.38, min_ss 7.24;
  TT 3.82–3.97 (251–262 MHz); FF 2.45–2.54 (393–408 MHz).
* power 1.957 mW (int 1.089 / sw 0.868 / leak 0.00002), 5354 instances,
  die 30028 µm², core 24319.6 µm².
* **Claim for this design: 7.6 ns signoff period (131.6 MHz), binding corner
  `max_ss_100C_1v60`, +0.079 ns (0.010 %) margin — zero violations anywhere.**
* Caveats stated honestly: the margin is thin (by construction — the claim was
  set to be just above the measured requirement), and the PnR-side SDC is 6.0 ns
  (documented over-constraint, §4.3 table).

This **revises the 3-place rule**: period must still be set in all 3 places,
but the invariant is now `PNR_SDC (≤) SIGNOFF_SDC`, and the asymmetry must be
commented in all three files (done) + recorded here. Judge by signoff WNS;
`Checker.SetupViolations` reads signoff results, so with a passing signoff
period the checker stays clean (f6's STA-1139/Checker setup warning disappears).

## 5. Phase 5 -- area / power passes

| Tag | change (one knob) | period [ns] | die area [µm²] | cell area [µm²] | power total / int / sw / leak [mW] | note |
|---|---|---|---|---|---|---|
| f6s76 | (period winner: 6.0 repair / 7.6 signoff) | 6.0 / 7.6 | 30028.4 (core 24319.6) | core incl. fill 24319.6; util 40.03 % | 1.957 / 1.089 / 0.868 / 0.000025 | first all-green signoff, max_ss **+0.0785** |
| a41 | `FP_CORE_UTIL 30→41` + `PL_TARGET_DENSITY_PCT 40→50` (planned pair, computed §4.1 lever note) | 6.0 / **7.35 claim pending** | **22674.2 (core 17840.9, −24.5 %)** | core incl. fill 17840.9; GPL util 48.09 %, min feasible density 0.49 | 1.965 / — / — / — | **errors 0, all 9 corners green, DRC/DRT/antenna 0 — and FASTER: max_ss +0.3207 (req 7.2793, −0.242 vs f6s76)** — shorter wires beat congestion penalty |

Power from `…-stapostpnr/<corner>/power.rpt`. Power is an *output*: the only
levers are die size (wire cap) and synthesis strategy (cell sizing) -- no RTL
clock gating allowed (no RTL changes). **Measured so far:** a41's die shrink
did **not** move power (1.957 → 1.965 mW — fewer wires but denser placement /
more fillers interaction), confirming §4.1 point 4 that period target (repair
buffer count + clock activity) dominates power here, not die size.

**a41 follow-up:** signoff claim tightened 7.6 → **7.35 ns** (single knob,
tag `a41s735`): expected max_ss WS = 7.35 − 7.2793 = **+0.0707** — the
requirement is deterministic for fixed inputs (proven by f6s76's exact
+0.0785 vs predicted +0.0785).

| Tag | change (one knob) | claim [ns] | max_ss setup WS | die [µm²] | errors | power [mW] | note |
|---|---|---|---|---|---|---|---|
| f6s76 | 6.0 repair / 7.6 signoff | 7.60 | **+0.07851** (= 7.6−7.5215, exact) | 30028.4 | 0 | 1.957 | first all-green |
| a41 | util 41 / density 50 | 7.60 | **+0.3207** (req 7.2793) | **22674.2 (−24.5 %)** | 0 | 1.965 | shrink = faster |
| **a41s735** | signoff claim 7.6 → 7.35 | **7.35** | **+0.0707** (= 7.35−7.2793, exact) | 22674.2 | 0 | 2.032 | **new claim: 136.05 MHz**, SS fmax 137.38, TT 258–264, FF 404–414; hold ≥ +0.225 |

Power rose 1.965 → 2.032 mW **with an identical layout** because the vectorless
power model's switching activity scales with the *assumed* clock frequency —
shorter claimed period ⇒ higher assumed toggle rate ⇒ more mW. So "power" in
these tables is always relative to the reporting period; compare like-for-like.

Next rung taken: `a45` (util 45 / density 55 via `-c` overrides) to see if
further shrink still improves the SS requirement (a41 gave −0.242 ns) — result
recorded immediately below (rejected: shrink limit reached).

**a45 result — the shrink limit (recorded, not adopted):**

| Tag | util/density | die [µm²] | max_ss WS @7.35 claim | SS req | verdict |
|---|---|---|---|---|---|
| a41 | 41 / 50 | 22674.2 | +0.0707 | **7.2793** | **winner** (best period, −24.5 % die) |
| a45 | 45 / 55 | **20870.3 (−30.8 % vs f6s76)** | **+0.0010** | 7.349 | green but margin ~0; **SS got 0.07 ns slower** than a41 despite *shorter* wires (21480 vs 22130 µm) |

a45: errors 0, all 9 corners MET, DRC 0, DRT converged (0 final violations after
iterations: 25→5→0 — congestion pressure visible), GPL util 52.48 %,
min feasible density 0.53. **Conclusion: the density penalty (coupling/slew/
detour at 52–55 %) outweighs the wire-shortening benefit beyond util 41 — the
area lever is exhausted at `FP_CORE_UTIL 41 / PL_TARGET_DENSITY_PCT 50`.**
Config file kept at the winner (41/50); a45 was run via `-c` overrides only.

**Phase-2 footprint freeze (`sq1`/`sq2`/`sq1p55`/`sq1cts`, guide §4 recipe):**

| Tag | DIE_AREA / change | die [µm²] | core [µm²] (aspect) | max_ss WS @7.35 claim | errors | verdict |
|---|---|---|---|---|---|---|
| sq1 | 144.16² (2.72×53 rows, **square**) | 20782 (−8.3 % vs a41) | 17718 (132.94×133.28, aspect **1.003**) | **−0.0067** (req 7.3567) | 0 | geometry ✓ DRC/DRT/antenna 0, but **6.7 ps short** of claim |
| sq2 | 146.88² (2.72×54 rows, square) | 21574 (−4.9 % vs a41) | 18455 (135.7×136.0, aspect 1.002) | **−0.0401** (req 7.3901) | 0 | rejected: bigger core = longer wires, slower than sq1 |
| sq1p55 | sq1 + PnR repair 5.5 (one knob) | 20782 | same as sq1 | **−0.0153** (req 7.3653) | 0 | **rejected**: 155 upsizes + 75 buffers inserted yet SS got *worse* — repair pressure exhausted here too |
| sq1cts | sq1 + `CTS_CORNERS [tt, max_ss]` (one knob) | = sq1 exactly | = sq1 | **−0.0067 (bit-identical to sq1)** | 0 | **no-op run**: duplicate `CTS_CORNERS` key in config (last-wins) silently kept TT-only — knob never applied; detected via identical hashes + `resolved.json`. Lesson = Q269 of the interview doc |
| sq1cts2 | same change, single key (applied) | = sq1 exactly | = sq1 | **−0.0067 (bit-identical, same netlist hash)** | 0 | knob **applied** (`resolved.json` TT+SS, log reads both libs) yet zero change → **CTS corner-balance lever measured & closed: clock tree is not the SS bottleneck** (15-buffer tree, hold ≥ +0.23) — distinct from sq1cts's config-shadowing no-op (Q269) |
| sq1s740 | sq1 geometry + claim **7.40** | **+0.0433** (= 7.40 − 7.3567, exact) | **ALL GREEN ✅** | **FINAL SQUARE DELIVERABLE**: die 144.16² (20782 µm², −8.3 % vs a41), core aspect 1.003, errors 0, setup+hold MET @ all 9 corners (worst hold +0.231), no negative WNS/TNS, magic 0 / klayout 0 / DRT 0 / antenna 0 / LVS "Circuits match uniquely", period_min max_ss **7.36 (135.93 MHz)**, TT 258–264, FF 403–412, power 2.030 mW → **claim 7.40 ns = 135.14 MHz** |

**FINAL VERDICT (period × area × square-freeze):**

| | **sq1s740 (FINAL)** | a41s735 (period-optimal variant) |
|---|---|---|
| signoff claim | **7.40 ns → 135.14 MHz** | 7.35 ns → 136.05 MHz |
| binding corner margin | **+0.0433** (max_ss, deterministic) | +0.0707 (max_ss) |
| die | **144.16 × 144.16 square (20782 µm²)**, core aspect 1.003 | 145.3 × 156.0 (22674 µm²), core 133.9 × 133.3 |
| all 9 corners setup+hold | **MET**, errors 0 | MET, errors 0 |
| why not better on the other axis | 7.35 on square geometry exhausted: repair 5.5 ✗, CTS corners ✗ (×2), grow ✗ | die not square → violates the tiling requirement (guide §4) |

Square-geometry period floor measured: **req 7.3567** (sq1); every recovery
lever tried and recorded (sq1p55, sq1cts, sq1cts2, sq2). Final config in
`config.yaml` = sq1s740 state: `FP_SIZING absolute`, `DIE_AREA [0,0,144.16,144.16]`,
margins L/R 12 sites + T/B 2 rows, `PL_TARGET_DENSITY_PCT 52`, PnR period 6.0,
signoff 7.40, `CTS_CORNERS [tt, ss]` (proven neutral — kept with comment).

Margins used for all square attempts: L/R 12 sites (5.52 µm default),
**T/B halved 4→2 rows** (10.88→5.44) so gutters match across axes. sq1
evidence: `flow__errors__count 0`, checker warning only on `max_ss`, GPL util
48.44 % / feasible 0.49, DRT 0, antenna 0, DRC 0 — the 0.077 ns regression vs
a41 (7.2793 → 7.3567) came from the tighter core/gutter, not from any rule
violation.

Fallback if sq1cts misses: square-tile claim settles at **7.40 ns**
(sq1 req 7.3567 + 0.043 margin = **135.14 MHz**, all-green expected), while
the period-optimal non-square configuration stands as **a41s735 @ 7.35**
(136.05 MHz) — both documented; requirement order decides which is "final".

## 6. Fallback ladder usage (plan §4) -- record every rung taken

| date | rung | tag | evidence that forced it |
|---|---|---|---|
| 2026-10-16 | 1 — period 6.0 → 6.5 | f65 | f6 max_ss WNS −1.5215 (only failing check in an otherwise green run) |
| 2026-10-16 | 1 — period 6.5 → 7.0 | f70 | f65 max_ss WNS −1.0357 |
| 2026-10-16 | 1 — period 7.0 → 7.5 | f75 | f70 max_ss WNS −0.5537 |
| 2026-10-16 | 1 — period 7.5 → 7.75 | f775 | f75 max_ss WNS −0.2044, SS requirement now 7.7044 |
| 2026-10-16 | 2 — map synth at SS corner | f775ss | plateau at 7.75 (−0.2087); hypothesized TT-mapping bias. **Rejected**: made SS/TT/power all worse (§4.2) |
| 2026-10-16 | 3 — over-constrained PnR + signoff claim 7.6 | f6s76 | req vs target plateaus: repair at 6.0 achieved the best SS req ever measured (**7.5215**) while looser targets chase the gap; so repair at 6.0, report at 7.6 (margin +0.078) — config/impl = 6.0, signoff = 7.6. **RESULT: all 9 corners green, errors 0, max_ss WS +0.0785 (prediction exact)** |
| 2026-10-16 | 5 — area rung util 41 / density 50 | a41 | period phase closed; planned area lever. **RESULT: die −24.5 % AND SS req 7.5215→7.2793 (faster)** |
| 2026-10-16 | 5 — claim tighten 7.6 → 7.35 | a41s735 | a41 req 7.2793 leaves +0.32 at 7.6 (wasted margin) → tighten. **RESULT: green, +0.0707 exact, claim 136.05 MHz** |
| 2026-10-16 | 5 — shrink limit probe util 45 / density 55 | a45 | does shrink keep helping? **RESULT: −8 % die but SS req → 7.349 (worse)** → lever exhausted at 41/50 |
| 2026-10-16 | 2 — square DIE_AREA 144.16² | sq1 | requirement: row-aligned square tile (guide §4). **RESULT: geometry exact, −8.3 % die, SS 6.7 ps short (req 7.3567)** |
| 2026-10-16 | 2 — square side 146.88² | sq2 | recover 6.7 ps with one more row pair. **RESULT: req 7.3901 — bigger core = longer wires = slower, rejected** |
| 2026-10-16 | 4 — repair pressure 6.0 → 5.5 on sq1 | sq1p55 | last cheap period lever on square geometry. **RESULT: 155 upsizes + 75 buffers, req *worse* (7.3653) → rejected, plateau reproduced** |
| 2026-10-16 | CTS — TT+SS balanced tree | sq1cts → sq1cts2 | only untried SS lever: `CTS_CORNERS` TT-only while binding corner is SS. **sq1cts = NO-OP** (duplicate YAML key shadowed the edit, last-wins; caught by identical hashes + `resolved.json`) → single key rerun as **sq1cts2: knob applied but netlist/WS byte-identical** → lever *measured and closed*: clock tree is not the SS bottleneck. All 7.35 recovery attempts on square geometry exhausted → claim settles at 7.40 (sq1s740) |
| 2026-10-16 | FINAL — square claim 7.40 | **sq1s740** | locked the square deliverable at req 7.3567 + 0.0433. **RESULT: ALL GREEN** — errors 0, setup+hold MET all 9 corners (max_ss **+0.0433 exact**, 4th successful prediction), magic/klayout DRC 0, antenna 0, LVS "Circuits match uniquely", die exactly 144.16², power 2.030 mW → **FINAL: 7.40 ns = 135.14 MHz square tile**; `a41s735` kept as period-optimal (7.35 / 136.05 MHz, non-square) |
