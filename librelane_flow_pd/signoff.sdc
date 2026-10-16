# Signoff SDC for mac_pe -- PIPELINE_MAC=1, square compute core.
# Read by the post-PnR STA corners as SIGNOFF_SDC_FILE.
#
# Same clocks / IO / exceptions as impl.sdc, with exactly the two signoff
# differences the reference uses:
#   1. setup uncertainty 0.45 -> 0.10 (PnR was pessimistic; report truth)
#   2. no set_max_fanout / set_max_transition guardrails (signoff STA must
#      PRINT residual violations, not trigger re-optimization)
# Everything else is byte-for-byte the same constraint set -- an exception
# that exists in one file and not the other is a hidden bug
# (ref docs/doc1_multicycle_exceptions.md).
#
# !! PERIOD CHANGE CHECKLIST: this create_clock -period, impl.sdc, and
#    config.yaml CLOCK_PERIOD move together (see impl.sdc header).

# Signoff-reported period: 7.40 ns (claim) -- square-tile final (tag sq1s740).
# sq1 geometry req = 7.3567 (measured, deterministic) -> 7.40 - 7.3567 = +0.0433
# expected margin. 7.35 was chased to exhaustion on this geometry: repair 5.5
# (worse, 7.3653), TT+SS CTS corners (byte-identical netlist -- tree is not the
# SS bottleneck; two runs: sq1cts no-op via duplicate key, sq1cts2 applied),
# sq2 growth (7.3901, longer wires). PnR side stays 6.0 (impl.sdc).
create_clock -name clk -period 7.40 [get_ports clk]

set_clock_uncertainty -setup 0.10 [get_clocks clk]
set_clock_uncertainty -hold  0.10 [get_clocks clk]

set_clock_transition 0.1 [get_clocks clk]

# Async assert / sync release reset: never a data path (same as impl.sdc).
set_false_path -from [get_ports rst_n]

set_input_delay  -max 2.0 -clock clk \
    [get_ports -filter "name != clk" [all_inputs]]
set_input_delay  -min 0.5 -clock clk \
    [get_ports -filter "name != clk" [all_inputs]]

set_output_delay -max 2.0 -clock clk [all_outputs]
set_output_delay -min 0.5 -clock clk [all_outputs]

set_driving_cell -lib_cell sky130_fd_sc_hd__buf_1    -pin X [all_inputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__clkbuf_4 -pin X [get_ports clk]

set_load 0.010 [all_outputs]
