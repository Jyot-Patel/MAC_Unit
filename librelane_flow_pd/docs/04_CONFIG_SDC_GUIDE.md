# 04 -- THE INPUT FILES EXPLAINED: `config.yaml`, `impl.sdc`, `signoff.sdc`
### (+ pin config, + everything else a real PD project feeds the tools, + Cadence comparison, + debug tooling)

Audience: "I have never written these files from scratch and I need to know
what each one is *for*, how to write it, what the options are, what the
defaults are, and why this project needs *two* SDCs."

Every default below was read out of the actual tool source (LibreLane 3.0.16
in the nix devshell: `librelane/config/flow.py`, `librelane/steps/*.py`) or the
actual PDK (`~/.ciel/…/sky130A/libs.tech/openlane/config.tcl` +
`…/sky130_fd_sc_hd/config.tcl`) — not from memory. Every "our value" is the
live value in this design directory.

---

## 1. The 10,000 ft view -- what eats what

```
 rtl/*.v  ──┐
 config.yaml ├──> LibreLane (flow engine, 76 steps) ├──> runs/<tag>/
 impl.sdc  ──┤        │                               ├── final/gds/mac_pe.gds
 signoff.sdc ─┤       │ yosys → openroad → magic →    ├── final/{def,lef,lib,spef,sdf,odb,…}
 pin_order.cfg ┘      │ klayout → netgen → opensta    ├── metrics.json  (every number we quote)
 PDK (sky130A) ───────┘                               └── <NN-step>/{COMMANDS,logs,reports}
```

* **`config.yaml`** = the *flow* configuration: which design, which PDK,
  which knobs every tool step gets. It is LibreLane's own language (YAML),
  not any EDA vendor's.
* **`impl.sdc`** = the *timing constraints* the implementation tools
  (placement, CTS, resizer, routers, mid-flow STA) work against.
* **`signoff.sdc`** = the *timing constraints* the final STA judges the
  finished chip against — i.e. the numbers you would print in a datasheet.
* **`pin_order.cfg`** = where each IO pin goes on the die edge (this design:
  systolic left/top in, right/bottom out).

An SDC (Synopsys Design Constraints, `.sdc`) is a Tcl script with a standard
command set. It is *the* industry-portable input: the very same file is read
by OpenSTA (here), Cadence Tempus, Synopsys PrimeTime, Yosys' SDC frontend —
by essentially every tool in the business. `config.yaml` is the one piece
that is LibreLane-specific.

---

## 2. `config.yaml` -- the flow's project manager

### 2.1 YAML in 30 seconds

```yaml
KEY: value                       # scalar (string / number / bool)
LIST: [a, b, c]                  # inline list
LIST:                            # block list
  - item1
  - item2
KEY: dir::relative/path.sdc      # dir:: = path relative to this config file
# comment to end of line
```

Three YAML landmines (all hit in this project, all in the interview doc):

1. **Duplicate keys are legal YAML and LAST ONE WINS, silently.** We shipped
   a run (`sq1cts`) whose `CTS_CORNERS` change did nothing because the file
   already had that key lower down. After ANY config edit: scan for duplicate
   top-level keys (10-line Python) and check `runs/<tag>/resolved.json`.
2. Indentation is structure (lists under a key must be consistently indented).
3. `yes/no/on/off` are booleans in YAML 1.1 — write `true/false` explicitly.

CLI one-off overrides: `python3 -m librelane config.yaml --run-tag x -c "FP_CORE_UTIL=45"`.
Command line beats config file beats PDK/tool defaults (see §2.4).

### 2.2 The non-negotiable keys (every design needs these)

| Key | Our value | Meaning | Default |
|---|---|---|---|
| `DESIGN_NAME` | `mac_pe` | top module name | REQUIRED |
| `PDK` | `sky130A` | process design kit | REQUIRED |
| `STD_CELL_LIBRARY` | `sky130_fd_sc_hd` | which sky130 flavor (hd = high density) | REQUIRED |
| `VERILOG_FILES` | `dir::rtl/mult8x8_array.v`, `dir::rtl/mac_pe.v` | RTL sources, in dependency order | REQUIRED |
| `CLOCK_PORT` | `clk` | name of the clock port (drives generated SDC, CTS, STA) | REQUIRED |
| `meta: flow: Classic` | (bottom of file) | which flow DAG to run; `Classic` = the full PnR+signoff flow | REQUIRED |

### 2.3 Every knob this design sets: what it does, the real default, why we set it

Source legends: **[LL]** = LibreLane source default (3.0.16),
**[PDK]** = sky130A `config.tcl` value, **[—]** = no default (must come from
PDK or user). "Default" is what you would get by *omitting* the line.

#### Synthesis

| Key | Default | Ours | Why / what it does |
|---|---|---|---|
| `SYNTH_PARAMETERS` | none | `["PIPELINE_MAC=1"]` | build-time parameter: passed to Yosys as `chparam -set PIPELINE_MAC 1 mac_pe`. This is how you change a design parameter **without touching RTL** — the mandated pipeline build of this project |
| `SYNTH_STRATEGY` | `'AREA 0'` **[LL]** | `DELAY 1` | ABC effort/optimization mode; legal: `AREA 0..4`, `DELAY 0..4`. Measured here: DELAY 1 = 2971 ps ABC delay vs 4467 ps (AREA 0) at +6 % area. There is no analytic answer which one wins — the tool's own doc says "no way to know before trying" |
| `SYNTH_ABC_BUFFERING` | `false` **[LL]** | `true` | runs ABC's `buffer -N 10 -S 0.75ns; upsize; dnsize` after mapping. Bought −24 % delay on AREA 0 and stacks with DELAY strategies |
| `SYNTH_ABC_USE_MFS3` | `false` **[LL]** | *(unset)* | experimental SAT remapper. Tried, rejected: crashes ABC on AREA 0 (exit 134), slower+bigger on DELAY 1 |
| `SYNTH_DRIVING_CELL` | `sky130_fd_sc_hd__inv_2` pin `Y` **[PDK]** | `sky130_fd_sc_hd__buf_1/X` | what drives every input port during synthesis **and** STA. Must match `set_driving_cell` in the SDCs or synthesis and STA model different chips |
| `OUTPUT_CAP_LOAD` | `33.442` fF **[PDK]** (= inv_16 pin A cap) | `10` (fF) | load on every output during synthesis+STA; = SDC `set_load 0.010` (pF). Consistency again |
| `ERROR_ON_SYNTH_CHECKS` | `true` **[LL]** | `false` | **deliberate deviation**: warn-don't-stop on synthesis advisories during bring-up. Risk noted: a real unmapped-cell problem still fails hard at `07-checker-yosysunmappedcells` |
| `ERROR_ON_LINTER_ERRORS` | `true` **[LL]** | `true` | verilator *errors* stop the flow (kept) |
| `ERROR_ON_LINTER_WARNINGS` | `false` **[LL]** | `false` | warn only (kept) |

#### Floorplan (this is where "square tile" is expressed)

| Key | Default | Ours | Why / what it does |
|---|---|---|---|
| `FP_CORE_UTIL` | `50` **[LL]** | `41` | core area = synth cell area / util. Evaluated against *synth* area: 7392 µm² / 0.41 ≈ 18,030 µm² core. Lower = bigger die = easier routing/faster wires |
| `FP_SIZING` | `'relative'` **[LL]** | `absolute` | relative = compute DIE_AREA from util; absolute = you give `DIE_AREA` explicitly (needed for a fixed square tile) |
| `DIE_AREA` | REQUIRED if absolute | `[0, 0, 144.16, 144.16]` | die rectangle in µm. 144.16 = 2.72 µm × 53 rows — chosen so die *and* core come out square on the site/row lattice (guide §4) |
| `FP_ASPECT_RATIO` | `1` **[LL]** | `1` | core height/width when sizing relatively |
| `TOP/BOTTOM_MARGIN_MULT` | `4` **[LL]** | `2` | vertical core margins in ROWS (default 4 rows = 10.88 µm each). Halved so the four gutters ≈ equal ⇒ square core inside square die |
| `LEFT/RIGHT_MARGIN_MULT` | `12` **[LL]** | *(default)* | horizontal margins in SITES (12 sites = 5.52 µm) |
| `IO_PIN_ORDER_CFG` | unset (= stock ioplacer) | `dir::pin_order.cfg` | hands pin placement to `Odb.CustomIOPlacement` (step 26) with our file instead of the stock ioplacer (step 25) |
| `ERRORS_ON_UNMATCHED_IO` | `'unmatched_design'` **[LL]** | `both` | the tool's own doc recommends `both`: a design port missing from the cfg OR a cfg line matching no port = fatal error, not a silent wrong-side pin |

#### Placement / CTS / routing

| Key | Default | Ours | Why / what it does |
|---|---|---|---|
| `PL_TARGET_DENSITY_PCT` | `FP_CORE_UTIL + 5*GPL_CELL_PADDING + 10` (≈ 61 at our util) **[LL formula]** | `52` | where global placement aims cell density. Placement *legalization* can exceed it, so it must sit above real utilization (41 %) but below the congestion cliff — measured best pair here: util 41 / density 50–52 |
| `CTS_CORNERS` | unset (= step's PNR corners) **[LL]** | `[nom_tt_025C_1v80, max_ss_100C_1v60]` | corners whose library the clock tree builder characterizes against. Applied (`resolved.json` + log prove it) but measured **byte-identical** result: the clock tree is not the bottleneck on this 15-buffer design |
| `GRT_OVERFLOW_ITERS` | `50` **[LL]** | `15` | how long global route chases congestion before giving up |
| `GRT_ALLOW_CONGESTION` | `false` **[LL]** | `true` | let the flow proceed on residual global overflow — detail route usually clears single-digit overflow (verified here); inherited crash-workaround from the reference design |
| `GRT_ANTENNA_REPAIR_JUMPER_ONLY` | `false` **[LL]** | `true` | antenna fix via jumpers only; full diode insertion maze-routes and crashed (GRT-0183 heap underflow) on this toolchain |
| `GRT_ANTENNA_REPAIR_ITERS` | `3` **[LL]** | `3` | kept at default |
| `DRT_OPT_ITERS` | `64` **[LL]** | `16` | detail-route optimization iterations; reference design's proven value |
| `DRT_THREADS` | machine thread count **[LL]** | `8` | detail routing threads |
| `STA_THREADS` | machine thread count **[LL]** | `4` | parallel post-PnR STA corner runs; **measured**: 9 parallel SPEF-STA runs OOM a 7 GB machine — this is a *memory* knob, not a speed knob |
| `KLAYOUT_DRC/XOR_THREADS` | — | `8` | klayout deck parallelism |

#### The period knobs and the two SDC hooks (the heart of this doc)

| Key | Default | Ours | Why |
|---|---|---|---|
| `CLOCK_PERIOD` | `10.0` ns **[LL]** | `6.0` | the number LibreLane feeds its *generated* base SDC, `repair_timing`, flow checkers… Here it is the **over-constrained PnR target** (§6). Measured: it does NOT change ABC mapping (10 ns and 2 ns netlists are bit-identical) |
| `PNR_SDC_FILE` | unset (flow generates one from the above) **[LL]** | `dir::impl.sdc` | replaces the generated SDC for every implementation step |
| `SIGNOFF_SDC_FILE` | unset (generated) **[LL]** | `dir::signoff.sdc` | replaces the generated SDC for the 9-corner signoff STA (step 55) |

### 2.4 Where a value actually comes from (resolution order)

```
CLI -c override   >   config.yaml   >   PDK config.tcl   >   LibreLane built-in default
```

* `runs/<tag>/resolved.json` = the final resolved configuration for that run.
  **It is the ground truth, not what you believe you typed** (Q269 war story:
  a duplicate YAML key silently reverted a knob; `resolved.json` exposed it).
* Every step also dumps its own `config.json` — check the *step* if you doubt
  whether a knob reached the tool.
* Type errors fail early: a Variable declared `int` rejects `"fast"`; declared
  `Literal['a','b']` rejects `c`.

---

## 3. SDC in 30 seconds (the language our two constraint files speak)

| Command | Meaning | Used here? |
|---|---|---|
| `create_clock -name clk -period P [get_ports clk]` | define clock P ns, port-target | ✔ (both files) |
| `set_clock_uncertainty -setup X [get_clocks clk]` | pessimism margin (jitter+skew budget) around the clock | ✔ |
| `set_clock_uncertainty -hold X` | same for hold | ✔ |
| `set_clock_transition X` | expected clock slew at the source | ✔ |
| `set_input_delay -max/-min D -clock clk {ports}` | how long after the clock edge inputs arrive/hold (board/ upstream-chip budget) | ✔ |
| `set_output_delay -max/-min D -clock clk` | how long before the next edge outputs must be valid (downstream budget) | ✔ |
| `set_driving_cell -lib_cell C -pin P {ports}` | model the driver of each input port | ✔ |
| `set_load C {ports}` | model the load on each output port (pF) | ✔ |
| `set_false_path -from {pins/ports}` | remove paths from analysis (async reset here) | ✔ |
| `set_multicycle_path -setup/-hold N ...` | paths that legitimately take N cycles | ✘ (deliberately none — see impl.sdc header) |
| `set_clock_groups -asynchronous {...}` | independent clock domains | ✘ (single domain) |
| `create_generated_clock ...` | derived clocks (PLL/÷N) | ✘ (none in this design) |
| `set_max_fanout / set_max_transition / set_max_capacitance` | design-rule *guardrails* as constraints | ✔ in impl.sdc only |
| `set_timing_derate` | OCV/AOCV pessimism scaling | ✘ (no derate inputs; see §8) |
| `set_case_analysis 0/1` | constant pin in analysis (test modes) | ✘ |

Everything else you will ever need is in `help` inside any OpenSTA shell, and
every command used in this project is in the two SDCs verbatim.

---

## 4. `impl.sdc` -- constraints the *implementation* works against

Read by steps 12, 31, 36, 38, 43 (all the mid-PnR STAs) as `PNR_SDC_FILE`,
and its philosophy is: *be pessimistic and make the router fight*.

Line-by-line (the file is heavily commented — read it alongside this):

1. `create_clock -name clk -period 6.0 [get_ports clk]`
   The PnR period. **Deliberately tighter (6.0 ns) than the real claim
   (7.40 ns)** — see §6 for the measured why.
2. `set_clock_uncertainty -setup 0.45 …` / `-hold 0.10 …`
   PnR-stage pessimism: while placement/routing are still moving, assume the
   clock is worse than it will be. Signoff tightens setup to 0.10.
3. `set_clock_transition 0.1` — expected clock slew.
4. `set_false_path -from [get_ports rst_n]`
   The one exception in the whole design: async-assert/sync-release reset is
   not a data path. (No multicycle paths, ever: with PIPELINE_MAC=1 the RTL
   contract is cycle-accurate, so every path is a real one-cycle path; an
   exception would hide a bug.)
5. `set_input_delay -max 2.0 / -min 0.5` (same for outputs)
   The IO timing budget (external world's promise). These tax the boundary
   paths only (a_in→a_reg, acc→psum_out — trivially short here); the critical
   multiplier path is internal and never sees IO budget.
6. `set_driving_cell sky130_fd_sc_hd__buf_1/X` (+ `clkbuf_4` for clk),
   `set_load 0.010` — must equal `SYNTH_DRIVING_CELL`/`OUTPUT_CAP_LOAD` in the
   config, else synthesis and STA simulate different chips.
7. `set_max_fanout 10` + `set_max_transition 0.75`
   **Guardrails for PnR ONLY.** 10 and 0.75 ns are exactly the PDK's
   `MAX_FANOUT_CONSTRAINT`/`MAX_TRANSITION_CONSTRAINT` that `repair_design`
   enforces — one number used everywhere instead of two disagreeing numbers
   (an earlier reference SDC had 2.5 ns here, looser than what the router
   itself would fix — STA would have signed off slews the router considered
   violations).

## 5. `signoff.sdc` -- constraints the *signoff STA judges* against

Read by step 55's 9 corner runs (min/nom/max × ss/tt/ff) as
`SIGNOFF_SDC_FILE`. Philosophy: *report the truth, change nothing.*

It differs from `impl.sdc` in **exactly three lines**:

| Line | impl.sdc | signoff.sdc | Why the difference |
|---|---|---|---|
| `create_clock … -period` | **6.0** (repair target) | **7.40** (the claim) | the claim you report must be the claim you verified on the final layout (§6) |
| `set_clock_uncertainty -setup` | 0.45 (pessimism while moving) | **0.10** | PnR pessimism is an implementation crutch; signoff reports real margin |
| `set_max_fanout` / `set_max_transition` | present (guardrails) | **absent** | guardrails make tools *fix*; signoff must **print residual violations**, not trigger re-optimization (flow checkers 74/75 then judge them) |

Everything else is deliberately **byte-identical** between the two files: an
exception (false path, multicycle, IO delay) that exists in one and not the
other is a hidden bug that ships a wrong datasheet. That rule caught nothing
in this project precisely because we enforce it.

## 6. Why two SDCs at all -- and why the period lives in THREE places

**The mechanism:** `repair_timing` only up-sizes/buffers what it *sees* as a
violation. A tighter implementation period = more repair pressure = a
genuinely faster layout — at the cost of area/power.

**Measured in this design** (same everything else, only repair target moved):

| PnR repair target | achieved max_ss requirement |
|---|---|
| 7.75 ns | 7.9587 ns |
| 6.0 ns | **7.5215 ns** (best measured) |
| 5.5 ns (sq1 geometry) | 7.3653 ns — *worse* than 6.0 on that geometry: repair pressure is exhausted past a point |

So the strategy is *over-constrained implementation + honest reporting*:
build against 6.0, claim 7.40, and the gap (+0.0433 ns at max_ss, verified
green on all 9 corners) is measured margin, not hope.

**The 3-place rule** (config `CLOCK_PERIOD`, `impl.sdc` period,
`signoff.sdc` period): all three must be *edited together* and must satisfy

```
PNR_SDC period  ≤  SIGNOFF_SDC period        (here: 6.0 ≤ 7.40)
```

A looser PnR than signoff would mean optimizing against one promise and
reporting another. This invariant, the checklist, and the sweep script
(`scripts/sweep_period.sh`, equal-period edits only) live in
`02_RUNBOOK.md §4`.

---

## 7. `pin_order.cfg` -- the fourth input (and the systolic contract)

Read by step 26 (`Odb.CustomIOPlacement` → `librelane/scripts/odbpy/io_place.py`).

Format: side headers `#N #S #E #W`, then one regex per line (anchored
`^line$`, must match exactly one port; `ERRORS_ON_UNMATCHED_IO: both` makes
misses fatal). Order within a side = order along the edge
(N/S left→right, W/E bottom→ top):

```
#N   b_in.* clk rst_n clear acc_en      # inputs enter from the north
#S   b_out.* psum_out.*                 # results exit south
#W   a_in.*                             # a-hop enters west
#E   a_out.*                            # a-hop exits east
```

Why it matters here: the stock ioplacer scatters ports by arrival order;
a systolic tile needs *abutment symmetry* — W and E carry the same 8 pins in
the same order so `a_in[k]` and `a_out[k]` land at the same y and the hop
between abutted tiles is a straight wire. Verified post-placement by grepping
the DEF (guide §5).

---

## 8. What a *complex* PD project feeds the flow that this one doesn't need

This is a single-voltage-domain, single-clock, macro-less, std-cell-only
block — the simplest possible PD contract. A real SoC block/cluster adds:

| Input | What it is | Why we don't need it | Where it would slot in |
|---|---|---|---|
| **UPF/CPF power intent** | power domains, isolation, retention, level shifters | one voltage domain, always-on | LibreLane: minimal support (mostly manual ODB); Innovus/Voltus: first-class |
| **MMMC corner matrix** (lib sets × RC corners × delay corners × constraint modes × analysis views) | the full PVT grid | LibreLane derives it from `STA_CORNERS` (PDK's 9) + OpenRCX min/nom/max RC | auto (steps 12/31/55); in Cadence you write it explicitly (§9) |
| **Macro hardening inputs**: per-macro LEF + `.lib` per corner + optional `.spef`, plus a macro placement DEF / `FP_PDN_MACROS` | pre-built blocks (SRAM, PLL, IP) | no macros (`11-openroad-checkmacroinstances` confirms empty) | `MANUAL_MACRO_PLACEMENT` cfg, `MACROS` variable, PDN macro hooks |
| **Generated clocks / clock groups** | PLL outputs, dividers, async domains | one clock, straight from the port | `create_generated_clock`, `set_clock_groups` in both SDCs |
| **DFT constraints** | scan shift/launch clocks, test-mode false paths, `set_case_analysis` on test pins | no DFT insertion in this build | SDC test-mode sections + synthesis DFT |
| **OCV/AOCV derates** (`set_timing_derate`) | systematic per-depth/on-path pessimism | not derivable from open PDK data; 9-corner + uncertainty covers it here | signoff.sdc, applied only at signoff views |
| **SI/crosstalk**: coupled-Net extraction + aggressor analysis, noise checks | high-speed adjacency effects | no signoff-grade crosstalk in OpenSTA | Cadence Tempus SI / PrimeTime SI |
| **Foundry-certified DRC/LVS decks** | the legal signoff | open Magic/KLayout/Netgen decks (good, not certified) | steps 64–71 swap decks |
| **IR/EM signoff**: power hookup (`VSRC_LOC_FILES`), current budgets, EM rules | step 56 runs but warns: no top-level power source defined | block-level only | `VSRC_LOC_FILES` + `FP_PDN_*` tuning; Voltus in Cadence |
| **Vector-based power**: SAIF/VCD activity from a testbench (or FSDB from gate sim) | real workload power | flow uses the vectorless default (and we documented its frequency-scaling artifact) | feed activity via OpenROAD `read_power_activities`, or Joules/Voltus |
| **Chip-level assembly**: padframe, ESD, GDS merge list, seal ring, top-level SDC | becoming a chip | hardened macro, not a top | separate top flow |
| **Gate-level sim w/ SDF** | functional proof of the netlist | possible manually (see §10) but not in-flow | `final/sdf` + `final/nl/mac_pe.nl.v` + iverilog/verilator |
| **EMC/antenna foundry rules, density/fill** | metal density, fill insertion | klayout/magic decks cover rule checks; fill not inserted here | post-streamout fill step |

---

## 9. Same job, Cadence tools: what maps where, what would change

### 9.1 Tool mapping (this project → a Cadence flow)

| Role | Here (open, all in the nix shell) | Cadence equivalent | Same input? |
|---|---|---|---|
| Lint | Verilator (step 01–04) | Jasper/Verisium lint or in-tool lint | RTL yes |
| Synthesis | Yosys + ABC (06) | **Genus** | RTL + SDC yes; Genus adds its own `synthesize` strategy tcl |
| Floorplan/place/CTS/route | OpenROAD (13–44) | **Innovus** | DEF/LEF/SDC concept-for-concept; knob names differ |
| Mid & signoff STA | OpenSTA (12/31/…/55) | **Tempus** | **SDC ports as-is** |
| RC extraction | OpenRCX (54) → SPEF | **StarRC / QRC** | needs a QRC/StarRC tech file (see 9.2) |
| DRC | Magic (64) + KLayout (65) | **Pegasus / Assura** (or Calibre, Synopsys) | needs foundry decks |
| LVS | Netgen (70) | **Pegasus LVS / Conformal LVS** | same extracted netlist concept |
| GDS XOR | KLayout (62) | Calibre XOR | yes |
| Streamout | Magic (57) + KLayout (58) | Innovus streamout | yes |
| Power/IR | OpenROAD power + `analyze_power_grid` (56) | **Voltus** (vector + EM) | Voltus wants activity + power hookup |
| Power estimation | vectorless only | **Joules** (pre-layout, ML-based) | — |
| LEC | (Yosys `equiv`, manual) | **Conformal LEC** | netlists + constraints |
| Waveform debug | iverilog/verilator + VCD (manual) | **Verdi** (FSDB, schematic, transaction) | — |
| ECO | re-run / resume / odbpy scripting | **Innovus ECO** (pre/post-route, formally checked) | — |

### 9.2 What a Cadence flow would require *in addition* for this design

1. **MMMC setup tcl** — the five object families:
   `create_library_set / create_rc_corner / create_delay_corner /
   create_constraint_mode / create_analysis_view`. LibreLane derives all of
   this from `STA_CORNERS` + the PDK; in Innovus it is your explicit script.
   Our two SDCs map 1:1 onto two constraint modes (or one mode swapped at
   signoff) — *the impl/signoff split is a normal Innovus practice too*.
2. **QRC/StarRC technology file** — sky130 ships OpenRCX rules
   (`rules.openrcx.sky130A.*.{max,magic,nom}`); a foundry QRC tech file does
   not exist publicly for sky130. This is a *hard* external input a Cadence
   flow would demand and we don't have.
3. **Foundry-certified DRC/LVS decks** (Pegasus/Assura/Calibre format).
   Community sky130 decks exist but are not certified.
4. **Innovus init set**: tech LEF + cell LEF + all-corner `.lib` (we have all
   three from the PDK — they are the same artifacts LibreLane consumes), plus
   power hookup (`vsupply`/stripe tcl instead of `FP_PDN_*`).
5. **Pin placement tcl/GUI** — our `pin_order.cfg` is LibreLane syntax but the
   *content* (side + order + symmetry) ports directly into an Innovus
   `pin` script or the GUI.
6. Everything else (RTL, SDC semantics, floorplan numbers, density strategy,
   the whole optimization methodology of this project) transfers unchanged —
   the methodology is tool-agnostic; only knob spellings differ.

### 9.3 What LibreLane gives that a Cadence flow typically doesn't

* **Hermetic environment**: the entire toolchain is one `nix develop` — no
  module files, no license server, no "works on my install".
* **Declarative, diffable config** + `resolved.json` + one-command rerun of
  any historical run tag (`--run-tag`, `--overwrite`/resume). Cadence flows
  are tcl-scripted; reproducibility is whatever discipline the team enforces.
* **Per-step metrics and hard checkers** (steps 30, 63, 66–76: power-grid,
  XOR, DRC, LVS, setup/hold/slew/cap violation checkers) — the flow *fails
  itself*; you cannot "forget" a signoff corner.
* **Cost**: $0 vs per-seat licenses (the reason this 20-run exploration
  campaign with ~5 min/run was even possible).

What Cadence still wins: signoff authority (certified decks), SI/crosstalk,
vector-based power/EM, ECO infrastructure, integrated GUIs, and foundry
acceptance.

---

## 10. Debugging: what we have here vs. what Cadence gives you

### 10.1 Available in this flow (and actually used in this project)

| Tool / artifact | How | Used for |
|---|---|---|
| **OpenROAD GUI** | `openroad -gui -db runs/<tag>/NN-step/mac_pe.odb` (GUI is compiled in — `-gui` in usage) | interactive layout/placement inspection, schematic view, runtime metrics |
| **`COMMANDS` replay** | every step dir has a `COMMANDS` file — rerun that exact tool invocation by hand | surgical debugging: re-run DRT with one flag changed, poke the ODB |
| **OpenSTA (full Tcl)** | `openroad` + `read_liberty/read_verilog/read_spef/read_sdc; report_checks -path_delay max -group_count 10; report_clock_min_period; check_setup; report_tns; report_worst_slack` | everything timing; the flow's own sta.log is this tool's output |
| **`metrics.json`** | python one-liner per corner (what we quote in `03_RESULTS.md`) | regression tables, WNS/TNS per corner, area/power |
| **`resolved.json` / step `config.json`** | cat | "did the tool see my input?" — first question for any no-op run (Q269) |
| **Checker steps as alarms** | 72-setup, 73-hold, 74-maxslew, 75-maxcap, 66/67 DRC, 71 LVS, 63 XOR | the flow prints exactly which corner/what failed |
| **KLayout** | open `final/gds/mac_pe.gds`, run decks interactively, measure | layout eyeballing, DRC iteration |
| **Magic** | interactive DRC + extraction (step 64/68 run this engine) | DRC debugging with per-rule coordinates |
| **Verilator lint** | step 01 reports; `verilator --lint-only` manually | RTL problems before they become netlist problems |
| **Yosys** | inspect `6-yosys-synthesis/` scripts (`DELAY_0.abc` etc.), `stat`, hierarchy | how the netlist was actually built |
| **iverilog / verilator** | both in the shell: `iverilog mac_pe.nl.v tb.v` + `$sdf_annotate("final/sdf/…", …)` | manual gate-level sim w/ SDF back-annotation (not in-flow, but possible) |
| **IR drop report** | step 56 (needs `VSRC_LOC_FILES` to be meaningful — warned, documented) | block-level sanity only |

### 10.2 NOT available here (Cadence/Commercial equivalents + workarounds)

| Missing | Cadence equivalent | Workaround here |
|---|---|---|
| Interactive timing GUI (slack heatmap over layout, Tempus UI) | **Tempus** GUI | OpenSTA Tcl + OpenROAD GUI + scripted slack extraction |
| Vector power / dynamic IR / **EM signoff** | **Voltus** | vectorless power (documented artifact) + `analyze_power_grid`; no EM signoff-grade check |
| Waveform/schematic debug of gate-level with transactions | **Verdi** (FSDB) | iverilog/verilator → VCD (+gtkwave if installed); no FSDB ecosystem |
| Formal LEC as signoff | **Conformal LEC** | Yosys equivalence scripts (manual, not certified) |
| Formal CDC/RDC | **JasperGold** | none in-flow (single clock domain here ⇒ not needed) |
| Signoff-grade SI/crosstalk (delay + noise) | Tempus SI | none — accepted limitation, documented |
| Foundry-certified decks | Pegasus/Assura/Calibre | Magic/KLayout/Netgen open decks (0/0 clean, not certified) |
| Automated ECO (fix-only-the-bad-paths netlist edit, formally checked) | **Innovus ECO** | re-run flow (cheap here: ~5 min) or odbpy manual edits |
| Unified DB + GUI across all tools | Virtuoso/Innovus ecosystem | per-tool viewers (OpenROAD GUI, KLayout, Magic) |
| Massive-design capacity (multi-GB netlists, distributed route) | Innovus distributed | single machine; fine for a block this size |

---

## 11. Recipe: changing an input safely (the checklist this project uses)

1. **One knob per run**, run tag named after it (`a41s735`, `sq1cts2`…).
2. Edit the file; **scan `config.yaml` for duplicate top-level keys** (YAML
   last-wins bite); comment the *why* next to the knob.
3. If it is a period change: the **3-place checklist** (config `CLOCK_PERIOD`,
   `impl.sdc`, `signoff.sdc`) + invariant `PNR ≤ SIGNOFF`; equal-period
   sweeps via `scripts/sweep_period.sh`, asymmetric edits by hand.
4. If it must affect synthesis: remember `CLOCK_PERIOD` is inert there
   (measured) — use `SYNTH_STRATEGY`/knobs that reach ABC.
5. Run with a fresh `--run-tag`; **verify the knob in `resolved.json`** (and
   the step's `config.json`) before believing any result.
6. Score from `final/metrics.json` + the sta.log `period_min` per corner;
   record the result — **including rejections** — in `03_RESULTS.md`.

---

*Companion docs: `00_PLAN.md` (decision log), `01_FLOORPLAN_GUIDE.md` (the
DIE_AREA/margins recipe and pin receipts), `02_RUNBOOK.md` (commands,
period checklist), `03_RESULTS.md` (every measured number), and
`10_PD_INTERVIEW_QA.md` — Q269 for the duplicate-key incident, Q190+ for SDC
rationale, Appendix C for the run-tag index.*
