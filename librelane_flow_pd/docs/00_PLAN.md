# mac_pe Physical Design -- PLAN

Date: 2026-10-16 · Design dir: `designs/mac/librelane_flow_pd/` · Flow: LibreLane 3.0.16 (nix), `--flow Classic`

## 0. Brief and hard constraints

| | |
|---|---|
| **RTL** | `rtl/mac_pe.v` (157 lines) + `rtl/mult8x8_array.v` (project file, copied byte-identical from `designs/matrix_multiplication/rtl/` because `mac_pe` instantiates it at `DATA_W==8`). **No RTL changes.** |
| **Build** | `PIPELINE_MAC=1`, delivered as a Yosys `chparam` via `SYNTH_PARAMETERS` -- never by editing the file. Pipeline becomes `[hop regs] | [mult] | [add] | [acc]`. |
| **Goals (ordered)** | 1) **least clk period**, 2) **least area**, 3) **least power** |
| **Geometry** | square compute core, systolic-array tile: **inputs on left + top, outputs on right + bottom** (guide: `docs/01_FLOORPLAN_GUIDE.md`) |
| **Environment** | nix devshell only (`cd ~/workspace/librelane_project/difetto && nix develop`); Docker/`eda_env` are deleted (NIX_TRANSITION_REFERENCE.md) |

Period is *evidence-driven*: a synth-only sweep picks the number, signoff STA
judges the full PnR, and every fallback rung changes **one knob at a time**
(lesson: `RISCV_Efficient/00_START_HERE.md`).

## 1. Metrics and where they come from

| Goal | Metric | Source (per run tag) |
|---|---|---|
| Period | ABC delay at mapping | `runs/<tag>/06-yosys-synthesis/yosys-synthesis.log` ("Delay = ... ps") |
| Period | setup WNS / `clk period_min` / fmax per corner | `runs/<tag>/<nn>-openroad-staprepnr/summary.rpt`, `.../stapostpnr/<corner>/sta.log` |
| Area | cell area, instance count, die/core area | `final/metrics.json`, `<nn>-openroad-detailedplacement/or_metrics_out.json` (`design__die__area`) |
| Power | total / internal / switching / leakage (SS + TT) | `.../stapostpnr/<corner>/power.rpt` |
| QoR gates | DRT violations, antenna, DRC, hold | routing logs, `summary.rpt`, checker steps |

## 2. Phases

**Phase 0 -- inputs (done).** RTL present with the multiplier file; config /
SDCs / pin cfg written; PDK present (`~/.ciel/.../sky130` version dir exists,
so no volare fetch).

**Phase 1 -- synth-only mapping study (`--to Yosys.Synthesis`).**
~~sweep `CLOCK_PERIOD`~~ **CORRECTED 2026-10-16 by measurement:** in this
LibreLane build `CLOCK_PERIOD` does **not** change the ABC mapping. Evidence:
`s10` (10 ns) and `s2` (2 ns) produced **byte-identical netlists and identical
ABC delay 3968.66 ps** -- the generated `DELAY_0.abc` script contains no `-D`,
and `&nf` ignores the target passed by yosys's `abc -D`. (Same for the AREA
strategy: `a10` == `a02`.) Consequence: the period lever is **not** at
synthesis; it is (a) the ABC **strategy**, which does change the mapping, and
(b) PnR, where the SDC period drives `repair_design`/`repair_timing`.
* 1a: strategy study at one fixed period: **DELAY 0/1/2/3/4, AREA 0,
  DELAY 0+`SYNTH_ABC_BUFFERING`** (tags `d0…d4`, `a0`, `b0`), each read for
  ABC delay + cell count + area.
* 1b: pick the best **period/area** point (period-first brief: DELAY family
  wins if its delay is materially lower and the area premium is acceptable --
  measure both columns, do not assume).
* Synthesis is *target-blind*, so "will it meet 7 ns?" is **not** answerable at
  synth: ABC's 3969 ps is a wire-load-free, TT-only, combinational-boundary
  estimate. The real verdict comes from post-PnR STA (phase 4); synth only
  ranks mappings against each other.

**Phase 1 record (2026-10-16):** DELAY 0 = 625 cells / 6961.7 µm² / 3969 ps ·
AREA 0 = 476 cells / 5124.9 µm² / 5620 ps (interface model then `inv_2`+33 fF;
numbers after aligning to `buf_1`+10 fF are in `03_RESULTS.md`). Full table:
`docs/03_RESULTS.md` §1–2.

**Phase 2 -- floorplan freeze.** From the winning synth's cell area, compute a
square `DIE_AREA` at ~35-40 % utilization (guide section 4), switch
`FP_SIZING: absolute`, and keep the sweep's period in all three places
(checklist in `impl.sdc`).

**Phase 3 -- full PnR (`--flow Classic`, no `--to`).** Bring-up at the chosen
period; expected artifacts: floorplan receipt (die = square), pin-placement
receipt (sides per guide section 5), DRT 0 violations.

**Phase 4 -- signoff STA.** Judge at SS (the corner that always votes):
* setup WNS >= 0 at SS **and** TT, hold >= 0 everywhere, no max-slew/max-cap
  explosions -> period accepted, write `docs/03_RESULTS.md`.
* else **fallback ladder** (one rung per run, evidence each time):
  1. re-run PnR one period step looser (`-c CLOCK_PERIOD=`), all three places updated;
  2. `SYNTH_STRATEGY: AREA 0` if DELAY 0's area was the problem, or the reverse if timing was;
  3. density/util rung: `PL_TARGET_DENSITY_PCT` 40 -> 35 -> 30 (shorter wires, easier route) or `FP_CORE_UTIL` 30 -> 25;
  4. last rung, still no RTL change: tighten the IO budget *only if* the failing path is a boundary path (it should not be -- see `impl.sdc` header);
  5. report the achieved period honestly. **RTL `PIPELINE_MAC=2` is out of scope** for this build (the brief fixes PIPE=1).

**Phase 5 -- area and power passes.** With the period locked:
* shrink the square `DIE_AREA` toward the measured cell area (util 40 -> 45 %), one notch per run, watching GRT overflow;
* re-read power from signoff `power.rpt` (power is an output, never a config knob; on a fixed 1.8 V PDK the levers are wire length = die size, and cell sizing = strategy);
* record all three metrics per run tag so the period/area/power trade is visible.

**Phase 6 -- documentation.** `03_RESULTS.md` holds the metric table per tag
(period, WNS, die area, cell area, cells, power, DRT), plus the decision log.
Secondary deliverable: **`10_PD_INTERVIEW_QA.md`** — 269-question PD interview
guide built from this flow's real incidents (every war story cites its run tag
and file evidence).

**Doc set (complete index):**

| Doc | What it answers |
|---|---|
| `00_PLAN.md` | goals, phases, decision log (this file) |
| `01_FLOORPLAN_GUIDE.md` | square-tile recipe: DIE_AREA lattice, margins, pin sides + post-run receipts |
| `02_RUNBOOK.md` | exact commands, environment rules, period-change checklist, resume/overwrite |
| `03_RESULTS.md` | every measured number per run tag + freeze/final verdict tables |
| `04_CONFIG_SDC_GUIDE.md` | **what `config.yaml` / `impl.sdc` / `signoff.sdc` / `pin_order.cfg` are, how to write them, all real defaults, why two SDCs, what a complex/Cadence project adds, debug tooling here vs commercial** |
| `10_PD_INTERVIEW_QA.md` | 269-Q interview prep built from this flow's war stories |

## 3. Risks carried from the reference runs (do not rediscover)

1. **OOM**: 9 parallel SPEF-STA runs crashed a 7 GB machine -> `STA_THREADS: 4` stays.
2. **Antenna diodes** maze-route crash (GRT-0183) -> `GRT_ANTENNA_REPAIR_JUMPER_ONLY: true`.
3. **GRT overflow**: single-digit clears in DRT, structural does not -> `GRT_ALLOW_CONGESTION: true` + `GRT_OVERFLOW_ITERS: 15`, and never "fix" congestion by ignoring it.
4. **CTS**: TT-only corners for bring-up (ref stance); `nix develop` starts a fresh subshell, so env vars must be prefixed on the run command line, never `export`ed.
5. **`--overwrite` wipes a tag's folder**; resume = same command minus `--overwrite`; never `--skip` an STA step.
6. **Signoff SDC must not lag the PnR SDC** (the reference shipped a stale port pattern and got STA-0366 warnings on every run) -- checklist in `impl.sdc`.
7. `nix-collect-garbage` would delete the live shell (no GC root) -- never run it.

## 4. Decision log (filled in between phases)

| Date | Phase | Decision | Evidence |
|---|---|---|---|
| 2026-10-16 | 0 | design dir `librelane_flow_pd/`, `mult8x8_array.v` copied byte-identical (elaboration dependency, not an RTL edit) | `diff` clean vs matrix source |
| 2026-10-16 | 0 | pin sides: N = `b_in` + controls, S = `b_out` + `psum_out`, W = `a_in`, E = `a_out` (W/E symmetric so the a-hop is a straight wire) | guide `01_FLOORPLAN_GUIDE.md` |
| 2026-10-16 | 1a | **Phase-1 methodology corrected**: `CLOCK_PERIOD` does not steer ABC mapping in this build — the period sweep is meaningless at synth and was replaced by a strategy study | `s10` ≡ `s2` ≡ … ≡ `s02` byte-identical netlists, 3968.66 ps everywhere; `a10` ≡ `a02` |
| 2026-10-16 | 1 | interface model unified: `SYNTH_DRIVING_CELL buf_1/X` + `OUTPUT_CAP_LOAD: 10` fF == SDC `set_driving_cell buf_1` / `set_load 0.010 pF` (sky130 liberty is pF; `flow.py` declares fF) | `flow.py` units, liberty `capacitive_load_unit pf`, `runs/m0` log "Setting output load to be 10.000000" |
| 2026-10-16 | 1 | `set_max_transition` in `impl.sdc` **2.5 → 0.75 ns** to equal `MAX_TRANSITION_CONSTRAINT` (resolved PDK default 0.75) — the reference SDCs were looser than what `repair_design` itself enforces | `resolved.json` |
| 2026-10-16 | 1b | **mapping locked: `DELAY 1` + `SYNTH_ABC_BUFFERING: true`** = 2970.83 ps / 678 cells / 7392.09 µm² (−33 % delay vs default DELAY 0, +6 % area) | `docs/03_RESULTS.md` §2–3 |
| 2026-10-16 | 1b | `SYNTH_ABC_USE_MFS3` rejected: crashes ABC on DELAY 0 (assertion, exit 134), slower+bigger on DELAY 1 | `runs/m0/error.log`, `runs/m1` vs `runs/c1` |
| 2026-10-16 | 1b | `SYNTH_ABC_DFF` never tried on purpose: ABC retiming across registers would alter the PIPE=1 in-PE latency contract = implicit RTL change | rtl/mac_pe.v header "TIMING CONTRACT" |
| 2026-10-16 | 3 | full-PnR baseline set to **6 ns** (all 3 places: config + impl.sdc + signoff.sdc), chosen as the midpoint between synth's 2.97 ns TT wire-load-free and SS/wire overhead | synth 2971 ps; ladder tightens/loosens with evidence |
| 2026-10-16 | 3 | **f6 ran end-to-end and passed everything except SS setup** (DRT/DRC/LVS/XOR/antenna/IR all 0; TT setup/hold 0; SS WNS −1.5215) → ladder rung 1 (loosen period, one rung at a time) started: 6.5 / 7.0 / 7.5 via `scripts/sweep_period.sh` | `docs/03_RESULTS.md` §4 |
| 2026-10-16 | 3 | period-change mechanics hardened into `scripts/sweep_period.sh` (sed on all 3 places per period, tag = `f<period>`), so the 3-place checklist cannot be half-done | runbook §4 |
| 2026-10-16 | 3 | floorplan verification PASSED per guide §5: pins N 12 / E 8 / W 8 / S 26, W-E symmetric (both start track 9, 16 tracks/pin); die 168.01×178.73 is *near*-square only (row/site snapping) → exact square needs the phase-2 absolute `DIE_AREA` freeze | `runs/f6/26-odb-customioplacement/odb-customioplacement.log` |
| 2026-10-16 | 4 | ladder rung 1 executed 6.0→6.5→7.0→7.5: **`max_ss_100C_1v60` is the binding corner** (TT/FF never failed; TT ≈ 3.90 ns, FF ≈ 2.45 ns), and `repair_timing` moved the SS requirement the *wrong* way 7.5215→7.7044 as its pressure fell | `03_RESULTS.md` §4.1 table |
| 2026-10-16 | 4 | power/period coupling measured: 2.479 → 1.880 mW from 6.0 → 7.5 ns target (fewer repair buffers + less clock activity pressure) → period slack costs power here as well | `final/metrics.json` per tag |
| 2026-10-16 | 4 | area lever identified for phase 5: die is sized by `FP_CORE_UTIL` against **synth** area (7392 µm²/0.30 = 24320 core) while final stdcell area is only 9001–9736 µm² (37–40 % of core) → `FP_CORE_UTIL 41` + `PL_TARGET_DENSITY_PCT 50` gives core ≈ 18000 µm² (−26 % die) at 50 % effective util, computed from f75's measured 9001.13 µm² | `or_metrics_out.json` f6/f75 |
| 2026-10-16 | 4 | rung 1b `f775` **failed to close** (max_ss −0.2087) and revealed the plateau: gap-vs-target 1.52→1.04→0.55→0.204→**0.209** — `repair_timing` stops up-sizing above ~7.5 ns, so loosening further cannot close (requirement chases target). Loose-target runs are also *smaller* (774 vs 812 logic cells) but *slower at SS* | `03_RESULTS.md` §4.1, worst-path cell mix 8.65 vs 8.96 |
| 2026-10-16 | 4 | lever 2 selected: **map for the binding corner** — synthesis used TT only (`default_operating_conditions tt_025C_1v80`) while signoff binds at `max_ss_100C_1v60`; set `SYNTH_CORNER=max_ss_100C_1v60` (value must be RC-qualified or the lib list comes back empty — run `sc1` aborts in `dfflibmap`) → sc2 verifies SS lib, 709 cells / 7577 µm² | `steps/pyosys.py:224`, `runs/sc2/tmp/*.lib` |
| 2026-10-16 | 4 | fallback kept on file: if `f775ss` + period ladder still cannot close SS, run **over-constrained PnR SDC vs signoff SDC** (PNR_SDC 6.0 ns where the design achieved req 7.5215, SIGNOFF_SDC ≥7.55) — deliberate pessimism during optimization, honest reporting at signoff; this revises the 3-place rule to "PNR ≤ SIGNOFF, documented" | f6 measured req 7.5215 |
| 2026-10-16 | 4 | **`f775ss` REJECTED**: SS mapping hurt every corner (max_ss −0.2087 → −0.2557, req 7.9587 → 8.0057, TT +0.2 ns, +119 cells, +7 % power) — ABC's SS-directed sizing widened the cone instead of speeding it → keep TT `DEFAULT_CORNER` | `03_RESULTS.md` §4.2 verdict table |
| 2026-10-16 | 4 | lever 3 executed: **over-constrained PnR (6.0) + signoff claim 7.6**, asymmetric periods commented in all 3 files, tag `f6s76` — expected max_ss WNS +0.078 from f6's measured req 7.5215 | `03_RESULTS.md` §4.3 |
| 2026-10-16 | 4 | **`f6s76` PASSED — first fully-green signoff**: all 9 corners setup+hold MET (max_ss WS **+0.07851**, prediction 7.6−7.5215=+0.0785 exact), errors 0, TNS 0, power 1.957 mW → **period phase closed at 7.6 ns signoff (131.6 MHz)**; move to phase 5 (area) keeping this period | `03_RESULTS.md` §4.3 result table |
| 2026-10-16 | 5 | **area rung `a41` PASSED and also sped the design up**: `FP_CORE_UTIL 41` + `PL_TARGET_DENSITY_PCT 50` → die 30028 → **22674 µm² (−24.5 %)**, errors 0, all 9 corners green, DRC/DRT/antenna 0, GPL util 48.09 % (feasible 0.49), and max_ss improved +0.0785 → **+0.3207** (req 7.5215 → **7.2793**) — smaller die = shorter wires; power unchanged 1.957 → 1.965 mW | `03_RESULTS.md` §5 |
| 2026-10-16 | 5 | signoff claim tightened 7.6 → **7.35 ns** on top of a41 (single knob, tag `a41s735`, expected +0.0707) → new period claim **136.1 MHz** if green | `signoff.sdc` comment, §5 follow-up |
| 2026-10-16 | 5 | **`a41s735` PASSED**: max_ss +0.0707 exact, errors 0, all 9 corners green → **claim 7.35 ns = 136.05 MHz** (power 2.032 mW — rises with claimed f under the vectorless model on an identical layout) | `03_RESULTS.md` §5 |
| 2026-10-16 | 5 | `a45` (util 45/density 55, `-c` overrides): die −30.8 % but SS req **worse** (7.2793 → 7.349, margin only +0.001) → **area lever exhausted at 41/50** — density penalty > wire benefit beyond a41 | `03_RESULTS.md` §5 a45 table |
| 2026-10-16 | 2 | square-tile freeze: `DIE_AREA 144.16²` (2.72×53 rows) + T/B margins 4→2 rows → **square die AND square core (aspect 1.003), −8.3 % die** — but SS 6.7 ps short of claim (sq1 req 7.3567); sq2 (146.88²) worse (7.3901); sq1p55 (repair 5.5) worse (7.3653, 155 upsizes no help); sq1cts = no-op (duplicate YAML key, Q269 of interview doc); sq1cts2 = knob applied but byte-identical (CTS corners not the SS bottleneck, lever closed) | `03_RESULTS.md` §5 freeze table |
| 2026-10-16 | 2 | **FINAL: `sq1s740` all-green** (claim = req 7.3567 + 0.0433): errors 0, setup+hold MET @ all 9 corners (max_ws +0.04329, hold +0.23143, no negative WNS/TNS anywhere), magic/klayout DRC 0, DRT 0, antenna 0/0, LVS "Circuits match uniquely", die exactly 144.16² row-aligned, power 2.030 mW → **FINAL DELIVERABLE: 7.40 ns = 135.14 MHz square systolic tile**; period-optimal non-square variant `a41s735` (7.35 / 136.05 MHz) documented alongside; 4/4 signoff predictions matched measurements | `03_RESULTS.md` §5 verdict table |
