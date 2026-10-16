# PNR (implementation) SDC for mac_pe -- systolic unit cell, PIPELINE_MAC=1,
# square compute core. Read by every LibreLane OpenROAD step as PNR_SDC_FILE.
#
# Modelled on designs/matrix_multiplication/impl.sdc and
# designs/RISCV_Efficient/impl.sdc (same toolchain); cut down to what THIS
# design can justify:
#   * ONE clock domain, std-cell only (no macros) -> no generated clocks.
#   * NO MULTICYCLE PATHS, none, ever: with PIPE=1 the contract in the
#     rtl/mac_pe.v header is cycle-accurate -- a product is accumulated
#     exactly one clock after its operands are registered. Every path here is
#     a real one-cycle path; an exception would hide a bug, not fix timing
#     (ref docs/doc1_multicycle_exceptions.md).
#   * no debug ports -> no debug false paths.
#   The only exception is rst_n (async assert / sync release): a reset
#   release is not a data path.
#
# !! PERIOD CHANGE CHECKLIST (all three must stay equal) !!
#   1. config.yaml  CLOCK_PERIOD
#   2. this file    create_clock -period
#   3. signoff.sdc  create_clock -period
# CLOCK_PERIOD drives the PnR repair/optimization steps and the flow's timing
# checks; these two files drive STA. (It does NOT steer ABC's mapping --
# measured 2026-10-16: 10 ns and 2 ns produce byte-identical netlists, see
# docs/03_RESULTS.md §1.) A mismatch between the three still means optimizing
# against one period and reporting another.
#
# Expected critical path with PIPE=1 (the path to watch):
#   [WORST] a_reg -> 8x8 array multiplier (AND plane + 7 CSA rows + 16-bit
#           CPA) -> prod_r        -- internal, no IO budget involved
#   [next ] prod_r + acc -> acc   -- 18-bit add + clear/acc_en muxes
#   [easy ] a_in -> a_reg, acc -> psum_out, and the hop outputs (all one
#           gate or none, plus the IO budget below)

# PnR-side clock: OVER-constrained to 6.0 ns on purpose (repair drives SS req
# 7.5215); signoff.sdc reports the real claim at 7.6 ns. See docs/03_RESULTS.md §4.3.
# sq1cts: PnR side back at sq1 baseline 6.0 (sq1p55's 5.5 was rejected)
create_clock -name clk -period 6.0 [get_ports clk]

# PnR uncertainties: ref values -- 0.45 setup is deliberately pessimistic
# while placement/routing are still moving; signoff.sdc tightens to 0.10.
set_clock_uncertainty -setup 0.45 [get_clocks clk]
set_clock_uncertainty -hold  0.10 [get_clocks clk]

set_clock_transition 0.1 [get_clocks clk]

# Async assert / sync release reset: never a data path.
set_false_path -from [get_ports rst_n]

# IO budget (ref-proven 2.0 max / 0.5 min). Note what this does and does not
# do: it taxes the boundary paths (a_in -> a_reg, acc -> psum_out), all of
# which are trivially short, and leaves the multiplier segment untouched --
# so a tightened IO budget could never buy the period that matters here.
set_input_delay  -max 2.0 -clock clk \
    [get_ports -filter "name != clk" [all_inputs]]
set_input_delay  -min 0.5 -clock clk \
    [get_ports -filter "name != clk" [all_inputs]]

set_output_delay -max 2.0 -clock clk [all_outputs]
set_output_delay -min 0.5 -clock clk [all_outputs]

# Drive strength / load (sky130_fd_sc_hd) -- ref values, so results are
# comparable with the reference runs.
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_1    -pin X [all_inputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__clkbuf_4 -pin X [get_ports clk]

set_load 0.010 [all_outputs]

# Design-rule guardrails for PnR ONLY -- signoff.sdc drops them so signoff
# STA reports true violations instead of the router re-optimizing them away.
#   max_fanout 10  = MAX_FANOUT_CONSTRAINT (config/PDK default) -- equal here,
#   max_transition 0.75 ns = MAX_TRANSITION_CONSTRAINT (resolved PDK default
#     0.75, used by synth + CTS + repair_design). The reference SDCs said 2.5,
#     which is LOOSER than what the router itself enforces -- STA would have
#     signed off slews that repair_design considers violations. One number,
#     used everywhere (config default), instead of two.
set_max_fanout 10 [current_design]
set_max_transition 0.75 [current_design]
