# RUNBOOK -- mac_pe, nix LibreLane 3.0.16

Everything here was taken from `NIX_TRANSITION_REFERENCE.md` (the single
source of truth for this project) and `designs/RISCV_Efficient/docs/9.COMMANDS.md`.

> **FINAL STATE (frozen):** run tag **`sq1s740`** -- signoff claim **7.40 ns =
> 135.14 MHz**, square die **144.16 x 144.16** (20782 um^2, row-aligned), square
> core (aspect 1.003), all 9 corners setup+hold MET (binding max_ss **+0.0433**,
> worst hold +0.231), errors 0, magic/klayout DRC 0, XOR 0, LVS clean,
> antenna 0/0, power 2.030 mW. Period-optimal non-square variant: **`a41s735`**
> (7.35 ns = 136.05 MHz). Metrics: `runs/<tag>/final/metrics.json`; verdicts:
> `03_RESULTS.md` §5. Re-run: the command in §1 with `--run-tag sq1s740`.

## 0. Environment

```bash
cd ~/workspace/librelane_project/difetto && nix develop   # ALWAYS cd difetto first (wrong flake otherwise)
cd ~/workspace/librelane_project                          # still inside the shell
C=./designs/mac/librelane_flow_pd/config.yaml
```

* `nix develop` spawns a **fresh subshell**: nothing you `export`ed survives.
  Put env vars on the run command line itself, never in the shell.
* No `--dockerized`, no `eda_env` (deleted 2026-10-14).
* PDK: `sky130A` / `sky130_fd_sc_hd`, resolved from the ciel store
  (`~/.ciel/ciel/sky130/versions/8afc…`) -- already present, no volare fetch.
* **Never `nix-collect-garbage`** (the devshell has no GC root).

## 1. Synthesis study (phase 1) -- synth only, cheap

**Measured 2026-10-16: `CLOCK_PERIOD` does NOT change the ABC mapping in this
build** (`s10` vs `s2` netlists byte-identical, ABC delay identical at
3968.66 ps; same for AREA strategy). Yosys does pass `abc -D <period>`, but the
generated `DELAY_0.abc` script has no `-D` and `&nf` ignores it. So do **not**
sweep `CLOCK_PERIOD` at synth -- it measures the same mapping N times.

What *does* change the mapping is `SYNTH_STRATEGY` (and the ABC toggles):

```bash
for S in "DELAY 0" "DELAY 1" "DELAY 2" "DELAY 3" "DELAY 4" "AREA 0"; do
  python3 -m librelane $C --run-tag st${S// /} --flow Classic --to Yosys.Synthesis \
      --overwrite -c CLOCK_PERIOD=7 -c "SYNTH_STRATEGY=$S"
done
# plus the buffering variant:
python3 -m librelane $C --run-tag b0 --flow Classic --to Yosys.Synthesis --overwrite \
    -c CLOCK_PERIOD=7 -c "SYNTH_STRATEGY=DELAY 0" -c SYNTH_ABC_BUFFERING=true
```

Read the answer:

```bash
grep -E "ABC: WireLoad|delay =" runs/d0/06-yosys-synthesis/yosys-synthesis.log | tail -3
cat  runs/d0/final/metrics.json     # instance count + area + lint/synth errors
```

**Verdict rule:** rank by ABC delay (period-first), tie-break on cell area;
require `design__instance_unmapped__count == 0`, `synthesis__check_error__count == 0`.
ABC delay is TT / wire-load-free / boundary-model-dependent (now aligned with
the SDC: `SYNTH_DRIVING_CELL` buf_1, `OUTPUT_CAP_LOAD: 10` fF = `set_load 0.010 pF`),
so it ranks mappings -- **it does not predict signoff**. The period is decided
by post-PnR STA (runbook §5).

## 2. Strategy A/B (phase 1b) -- DONE 2026-10-16, results in `03_RESULTS.md`

Recorded mapping (locked into `config.yaml`): **`SYNTH_STRATEGY: DELAY 1` +
`SYNTH_ABC_BUFFERING: true` → ABC 2970.83 ps / 678 cells / 7392.09 µm²**.
Measured table: `docs/03_RESULTS.md` §2–3. To reproduce the study:

```bash
for S in "DELAY 0" "DELAY 1" "AREA 0"; do
  python3 -m librelane $C --run-tag st${S// /} --flow Classic --to Yosys.Synthesis --overwrite \
      -c CLOCK_PERIOD=7 -c "SYNTH_STRATEGY=$S"
done
python3 -m librelane $C --run-tag b0 --flow Classic --to Yosys.Synthesis --overwrite \
    -c CLOCK_PERIOD=7 -c "SYNTH_STRATEGY=DELAY 0" -c SYNTH_ABC_BUFFERING=true
```

Rules learned the hard way (do not relitigate):
* `SYNTH_STRATEGY=…` **must be double-quoted in the shell** so the space
  survives; when this whole command lives inside `bash -c '…'`, the inner
  double quotes are what `9.COMMANDS.md` §3 warns about -- keep exactly one
  quoting layer.
* `SYNTH_ABC_USE_MFS3: true` **crashes ABC** on DELAY 0 (`utilTruth.h`
  assertion, exit 134, `runs/m0/error.log`) and loses to plain buffering on
  DELAY 1 (`runs/m1` 3124.66 ps > `runs/c1` 2970.83 ps, and bigger). Leave it
  off.
* `SYNTH_ABC_DFF` (ABC `-dff` / retiming) stays off permanently: retiming
  would change the PIPE=1 in-PE latency contract = an RTL change by stealth.

## 3. Full flow (phases 3–5)

```bash
python3 -m librelane $C --run-tag f1 --flow Classic --overwrite     # fresh
python3 -m librelane $C --run-tag f1 --flow Classic                 # resume (NO --overwrite)
```

* `--overwrite` **deletes that tag's folder** -- tags are cheap, use a new one
  for every experiment (`f2-dens35`, `f3-p12`, …) and keep the winner.
* Never `--skip` an STA step. `-j N` (default 8) caps parallelism.
* `Ctrl-C` between steps is safe: `state_out.json` of finished steps is kept.

## 4. PERIOD CHANGE CHECKLIST (3 places, always together)

1. `config.yaml` → `CLOCK_PERIOD:` (PnR repair/optimization target)
2. `impl.sdc` → `create_clock -period` (PnR STA)
3. `signoff.sdc` → `create_clock -period` (signoff STA = the claim)

Miss one and you optimize against one period and report another.

**Two legal shapes (both documented in `03_RESULTS.md` §4.3/§5):**
- **Equal periods** (simple): all three identical — use the helper below.
- **Over-constrained PnR + honest claim** (the winning pattern):
  `config` = `impl.sdc` = **repair target** (e.g. 6.0), `signoff.sdc` =
  **claim** (e.g. 7.35) with `PNR ≤ SIGNOFF`, commented in all three files.
  Asymmetric runs are edited **by hand** (the helper forces equality), e.g.
  `f6s76`, `a41s735`.

**Use the helper for equal-period sweeps -- it edits all three, derives the
tag, and cannot forget a place** (note: it does NOT re-append the
`CLOCK_PERIOD` trailing comment):

```bash
# inside the nix shell, from ~/workspace/librelane_project:
./designs/mac/librelane_flow_pd/scripts/sweep_period.sh 7.0 7.5   # -> tags f70 f75
# resume an interrupted run of the SAME period (server died, etc.) -- no --overwrite:
python3 -m librelane $C --run-tag f65 --flow Classic
# single-knob overrides without touching the config (used for a45):
python3 -m librelane $C --run-tag a45 --flow Classic --overwrite \
  -c "FP_CORE_UTIL=45" -c "PL_TARGET_DENSITY_PCT=55"
```

`CLOCK_PERIOD` = PnR repair target only; it does **not** steer ABC (§1).
Verify the period a run actually used: `grep create_clock <tag>/final/sdc/*`
and the signoff `sta.log` header.

## 5. What to read out of a full run

| Question | File |
|---|---|
| Did it map cleanly? | `runs/<t>/final/metrics.json` (0 unmapped, 0 lint errors) |
| Floorplan square? util? | `runs/<t>/<nn>-openroad-floorplan/openroad-floorplan.log` (`Die BBox`, `Effective utilization`) |
| Pin sides right? | `runs/<t>/<nn>-openroad-ioplacement/io_place.log` + the DEF (guide §5) |
| Congestion | `runs/<t>/<nn>-openroad-globalroute/…` overflow, `GRT` log |
| Route closed? | detail-route log → `violations` must end at **0** |
| Pre-PnR timing | `runs/<t>/<nn>-openroad-staprepnr/summary.rpt` (per-corner WNS) |
| Signoff timing | `runs/<t>/<nn>-openroad-stapostpnr/summary.rpt` + `<corner>/sta.log` (`period_min`, `fmax`) |
| Area | `runs/<t>/final/metrics.json`, `…-detailedplacement/or_metrics_out.json` (`design__die__area`) |
| Power | `runs/<t>/<nn>-openroad-stapostpnr/<corner>/power.rpt` (Total/internal/switching/leakage) |

The signoff summary is the scoreboard: **setup WNS ≥ 0 at `nom_ss_100C_1v60`
and `nom_tt_025C_1v80`, hold ≥ 0 everywhere, 0 max-slew/max-cap, DRT 0.**

## 6. Fallback ladder (one rung per run, evidence each time)

1. one period step looser (`-c CLOCK_PERIOD=` + both SDCs, new tag);
2. flip `SYNTH_STRATEGY` (DELAY ↔ AREA) at the same period;
3. density/util rung (`PL_TARGET_DENSITY_PCT` 40 → 35 → 30, or `FP_CORE_UTIL` 30 → 25);
4. IO budget only if a *boundary* path is the violator (it should not be -- see `impl.sdc`);
5. report the achieved period honestly. `PIPELINE_MAC=2` is **out of scope** (brief fixes PIPE=1).

## 7. Machine limits (from the reference runs)

`STA_THREADS: 4` (9 parallel SPEF-STA runs OOM'd 7 GB), `DRT_THREADS: 8`,
`KLAYOUT_*_THREADS: 8`. Close browsers before a full run if swap starts.

## 8. Known-benign warnings (do not chase them)

| Warning | Verdict |
|---|---|
| `[RSZ-0020] found 2 floating nets` → next two lines are `VGND` / `VPWR` | the power nets, not signals — harmless. Proof in a passing run: LVS "Circuits match uniquely", 0 disconnected pins, 0 PDN violations, empty `error.log` |
| `[STA-1140] … library sky130_fd_sc_hd__*.lib already exists` | repeated library load across the 9 corners; identical in the reference runs |
| `[DRT-0349] LEF58_ENCLOSURE with no CUTCLASS … layer mcon` | OpenROAD skipping an unsupported sky130 LEF58 rule; the reference runs logged it and still reached DRT 0 |
| `Checker.WireLength … Threshold is not set` | `WIRE_LENGTH_THRESHOLD` unset → checker skipped by design |
| `IRDropReport 'VSRC_LOC_FILES' not given` | expected for a block (not a top-level chip); IR numbers still usable relatively |
| `[Checker.LintWarnings] 2 Lint warnings` | `UNUSEDSIGNAL clk/clr` of `mult8x8_array` while `PIPELINE_MAC=1` makes its PIPE=0 branch unused — a warning, never an error |
| `DFFLIBMAP ERROR: Missing '-liberty liberty_file' option!` (run `sc1`) | `SYNTH_CORNER` matched no `LIB` key → empty synthesis lib list. Use the RC-qualified form: **`SYNTH_CORNER: max_ss_100C_1v60`** (`*_<PVT>` keys, `DEFAULT_CORNER` is `nom_tt_025C_1v80`) |
