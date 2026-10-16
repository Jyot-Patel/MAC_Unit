# FLOORPLAN GUIDE -- mac_pe as a square systolic-array compute core

Applies to: `designs/mac/librelane_flow_pd/` · enforced by `config.yaml` + `pin_order.cfg`

## 1. Why the shape is a square

The PE is the **unit cell of a 2-D systolic array**: it will be tiled
edge-to-edge in an N×N grid, not shaped like a slab SoC. Two consequences,
both mandatory here:

1. **Square core** -- `FP_ASPECT_RATIO: 1` (and, once frozen, a square
   `DIE_AREA`). A square tile abuts into a square array with no leftover
   gutter, and the horizontal hop length equals the vertical hop length, so
   the `a`-path and `b`-path see similar wire delay.
2. **Pin sides follow the dataflow**, not the tool's arrival order. This is
   the whole reason `IO_PIN_ORDER_CFG` is set: the stock `place_pins` would
   scatter ports by DB order and destroy tiling.

## 2. Dataflow → pin sides (the rule)

```
              b_in[7:0]  (+ clk, rst_n, clear, acc_en -- global controls)
                   │  NORTH: inputs
                   ▼
   ┌───────────────┬───────────────┐
   │               │               │
   │   a_in ──▶  [ mac_pe ] ──▶ a_out      WEST (left)  : inputs
   │               │               │        EAST (right): outputs
   │               ▼               │
   │        b_out, psum_out        │
   └───────────────┴───────────────┘
                   SOUTH: outputs
```

| Side | Ports | Direction | Rationale |
|---|---|---|---|
| **WEST (left)** | `a_in[7:0]` | input | activations enter from the left neighbour / array edge -- the a-hop source |
| **NORTH (top)** | `b_in[7:0]` | input | weights enter from the row above -- the b-hop source |
| **NORTH (top)** | `clk`, `rst_n`, `clear`, `acc_en` | input | controls are *inputs*, so they belong to an input edge; they take the north band so the **west/east a-hop edges stay 8-vs-8 symmetric** |
| **EAST (right)** | `a_out[7:0]` | output | registered hop to the PE on the right (`a_out = a_reg`) |
| **SOUTH (bottom)** | `b_out[7:0]` | output | registered hop to the PE below (`b_out = b_reg`) |
| **SOUTH (bottom)** | `psum_out[17:0]` | output | accumulator readout; results flow downward with `b`, out of the array |

Rules this buys us:

* **Every input is on left or top; every output is on right or bottom** --
  exactly the brief, and it means an array can be wired by abutment with no
  wire ever doubling back across the tile.
* **W and E carry the same 8 pins in the same order** (see section 5), so
  `a_in[k]` and `a_out[k]` land at the same y and the horizontal hop between
  abutted tiles is one straight wire, no jogs.
* **N carries 12 pins, S carries 26** -- vertical alignment of `b_in[k]` with
  `b_out[k]` is monotonic but not exact; if exact b-alignment ever matters,
  the lever is moving `psum_out` off the south edge, which the brief forbids
  (outputs must be right/bottom). Documented as an accepted imperfection.

## 3. The mechanism (LibreLane 3.0.16)

* `config.yaml: IO_PIN_ORDER_CFG: dir::pin_order.cfg` (alias `FP_PIN_ORDER_CFG`)
  routes pin placement to `Odb.CustomIOPlacement` → `odbpy/io_place.py`, and
  **skips the stock ioplacer step** (`steps/openroad.py: IO_PIN_ORDER_CFG is
  set. Skipping …`).
* `ERRORS_ON_UNMATCHED_IO: both`: a design port absent from the cfg, or a cfg
  line matching no port, aborts the flow instead of silently picking a random
  side.
* Sides and ordering inside `pin_order.cfg`: `#N/#S` run left→right,
  `#W/#E` run bottom→top (low→high coordinates); each line is anchored `^…$`.
* Pin layers are the defaults (horizontal edges → met3, vertical edges → met2
  in sky130A: odd metals horizontal, even vertical). Do not move them without
  a routing reason.

There is **no other pin control in this build**: no GUI dragging, no DEF
template (`RISCV_Efficient/docs/doc7_gui_floorplan.md`, `doc16`), and no
fenced/guide regions (`doc26` -- this OpenROAD build has no region verbs).
Pin declaration + side assignment in one file is the whole mechanism.

## 4. Fixed footprint (for array assembly)

Bring-up sizes the die relatively (`FP_CORE_UTIL: 30`, `FP_ASPECT_RATIO: 1`).
For tiling, the footprint must be **frozen and square**, because N tiles are
placed at a fixed pitch. Procedure, run after the winning synthesis:

1. Read `design__instance__area` from `runs/<tag>/06-yosys-synthesis/reports/stat.rpt` (or `final/metrics.json`).
2. `side = ceil(sqrt(cell_area / 0.40) / 5) * 5` -- 40 % target utilization, rounded up to a 5 µm grid (nice numbers in the DEF, easy array pitch arithmetic).
3. Sanity-check `side` against the pin count: south has 26 pins; met3 pin pitch ≳1.3 µm ⇒ ≳34 µm of edge needed on a ~200 µm side -- fine.
4. Switch config: `FP_SIZING: absolute` + `DIE_AREA: [0, 0, side, side]`, keep `FP_CORE_UTIL` as the fallback for the relative run only.
5. Re-check: row height in sky130 `unithd` is 2.72 µm, so prefer a side that
   is a multiple of 2.72 (e.g. 5 µm grid is *not* row-aligned -- pick the
   nearest multiple of 5.44 = 2 rows instead: 175 → 177.76 etc.). Row-aligned
   top/bottom edges are what makes left/right edge abutment legal.
6. Keep both tags (relative `f1`, absolute `f2`) so the area delta is on
   record.

## 5. Verification checklist (after `OpenROAD.IOPplacement`)

Do not trust the intent -- read the receipts:

```bash
# 1) every port present, and on the expected side
grep -E '^\s*- (clk|rst_n|clear|acc_en|a_in|b_in|a_out|b_out|psum_out)' \
    runs/<tag>/<nn>-openroad-ioplacement/*.def   # or the DEF written to the run dir

# 2) sides: x ≈ 0 (W), x ≈ die_w (E), y ≈ 0 (S), y ≈ die_h (N)
python3 - <<'EOF'
import re,sys,glob
f=sorted(glob.glob('runs/<tag>*/**/*.def',recursive=True))[-1]
txt=open(f).read()
for m in re.finditer(r'-\s+(\S+)\s+\+ NET.*?\+ FIXED\s*\( (-?[\d.]+) (-?[\d.]+) \)', txt, re.S):
    pass  # names/coords vary by DEF writer; fall back to: grep -A3 'PIN a_in\[7\]'
EOF
```

Practical, tool-supported receipt: `io_place.log` in the IOP placement step
prints pins-per-section (`Number of available slots`, `Slots per section`) --
with `ERRORS_ON_UNMATCHED_IO: both` a clean log means *all 50 ports matched a
regex*, and the DEF confirms which edge each landed on.

Expected: **W = 8 (`a_in`), N = 12, E = 8 (`a_out`), S = 26**.

### 5.1 Receipts from run `f6` (2026-10-16) -- PASSED

`runs/f6/26-odb-customioplacement/odb-customioplacement.log`:

| side | actual pins | tracks | tracks/pin | used | start index |
|---|---|---|---|---|---|
| N | **12** | 365 | 30 | 331 | 17 |
| E | **8** | 132 | 16 | 113 | **9** |
| W | **8** | 132 | 16 | 113 | **9** |
| S | **26** | 365 | 14 | 351 | 7 |

* 12+8+8+26 = **54 = the exact port count**, and `ERRORS_ON_UNMATCHED_IO: both`
  passed → every port matched its intended side, no random assignments.
* **W and E are numerically identical** (same start track, same pitch, same
  used-track count) → the a-hop symmetry goal (section 2) is real, not just
  intent: `a_in[k]` and `a_out[k]` sit on the same track rows.
* N starts at track 17, S at track 7 → the documented north/south asymmetry
  (12 vs 26 pins) is present exactly as predicted and accepted in section 2.
* Die came out **168.01 × 178.73 µm** with `FP_ASPECT_RATIO 1.0`: requested
  square, *near*-square actual. Cause: `initialize_floorplan` snaps the core
  to whole rows (57 × 2.72 = 155.04 µm height) and whole sites (0.46 µm
  width), so equal area ≠ equal sides. A **true** square requires the frozen
  absolute `DIE_AREA` of section 4 (row-aligned sides), which is phase 2 of
  the plan and still open.

## 6. Power grid, obstructions, antennas

* Default sky130A PDN (met4 vertical / met5 horizontal straps + corner rings)
  is kept: at a ~175–200 µm side and the default ~54 µm pitch, every std-cell
  row is crossed by 3–4 straps -- ample for one PE (µA–mA scale), and met4/5
  stay available for signal routing, which matters in a tiny block.
* Pins live on met2/met3 (section 3); PDN on met4/met5; no macros ⇒ no
  macro-placement, no halo, no PDN_MACRO_CONNECTIONS, no macro obstructions.
* No `FP_OBSTRUCTIONS`: nothing may be reserved -- the core is all logic.
* Antennas: jumpers only (`GRT_ANTENNA_REPAIR_JUMPER_ONLY: true`), because
  diode insertion crashed the router on a clock leaf in the reference design
  (GRT-0183).

## 7. What "done" looks like for this guide

* die is square (`design__die__area` reported once, side = sqrt);
* all 50 ports on the four intended sides, 8/12/8/26;
* `a_in`/`a_out` y-symmetric (spot-check first/last bit of each bus);
* HPWL sane (io_place prints `I/O nets HPWL`) -- a huge HPWL means a pin
  landed on the wrong edge;
* DRT closes at 0 violations with the pins as placed.
