//======================================================================
// mult8x8_array.v -- Structural unsigned 8x8 array multiplier
//----------------------------------------------------------------------
// WHY THIS STRUCTURE (see docs/THEORY.md + Phase 1 documentation):
//   * Array multiplier = partial-product AND plane + carry-save (3:2)
//     compressor rows + one final ripple-carry adder.
//   * Fully REGULAR geometry: a sea of identical full-adder cells in
//     rows/columns -- ideal for the symmetric, tiled layout this
//     project targets (contrast: Wallace/Dadda trees are faster but
//     irregular; Booth encoding saves rows only for signed/wider data).
//   * Unsigned 8x8 -> 64 partial products, rows 0..7, 16-bit columns.
//   * Proven sufficient: max product 255*255 = 65,025 < 2^16.
//
// Timing: 7 CSA levels (serial dependency chain, one fast hop per row)
// + one 16-bit CPA. PIPE=0 puts both in a single cycle (that is the
// critical path of a PIPELINE_MAC=0 MAC); PIPE=1 registers them
// separately (see the PIPE parameter below).
//
// Verified EXHAUSTIVELY (all 65,536 input combinations, PIPE=0 mode) by
// tb_mac_pe.v; the PIPE=1 mode is verified end-to-end by the SoC
// lockstep campaign (suite `soc2`, 274,992 checks vs a PIPELINE_MAC=0
// reference DUT).
//======================================================================
`default_nettype none

module mult8x8_array #(
    // PIPE: 0 = fully combinational (default, the canonical structure);
    //       1 = TWO internal pipeline stages: register after the CSA rows
    //           AND after the final CPA. Operands at cycle X -> product
    //           valid at cycle X+2, split into segments
    //           [AND plane + 7 CSA rows] | [16-bit CPA] -- mac_pe adds
    //           the 18-bit ADD as a third cycle when PIPELINE_MAC=2.
    //       The stages are flushed by `clr` (transaction start); the
    //       controller's acc_en window can never sample them before that
    //       flush, so their power-up X is unreachable downstream --
    //       proven by the X-scans + Q2/Q5/Q9 campaigns under suite soc2.
    parameter PIPE = 0
) (
    input  wire        clk,   // used only when PIPE = 1
    input  wire        clr,   // sync flush of the internal pipe (PIPE = 1)
    input  wire [7:0]  a,
    input  wire [7:0]  b,
    output wire [15:0] y
);

    // ---------------------------------------------------------------
    // Partial products: pp[i] = a masked by b[i], shifted to bit pos i
    //   pp[i] = (b[i] ? a : 0) << i        (i = 0..7)
    // Constant shifts are pure wire routing (free in layout).
    // ---------------------------------------------------------------
    wire [15:0] pp [0:7];
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_pp
            assign pp[i] = {8'h00, (a & {8{b[i]}})} << i;
        end
    endgenerate

    // ---------------------------------------------------------------
    // Carry-save rows: each row compresses 3 vectors -> 2 vectors
    //   sum[i]   = pp[i] ^ sum[i-1] ^ carry[i-1]        (bitwise XOR)
    //   carry[i] = majority(pp[i], sum[i-1], carry[i-1]) << 1
    // No carry ripples between rows (that happens only ONCE, at the end)
    // ---------------------------------------------------------------
    wire [15:0] sum   [0:7];
    wire [15:0] carry [0:7];

    assign sum[0]   = pp[0];          // row 0: just the first partial product
    assign carry[0] = 16'h0000;

    generate
        for (i = 1; i < 8; i = i + 1) begin : g_csa
            assign sum[i]   = pp[i] ^ sum[i-1] ^ carry[i-1];
            assign carry[i] = ((pp[i]   & sum[i-1]) |
                               (pp[i]   & carry[i-1]) |
                               (sum[i-1] & carry[i-1])) << 1;
        end
    endgenerate

    // ---------------------------------------------------------------
    // Final 16-bit ripple-carry add: product = sum[7] + carry[7]
    // (Yosys builds the CPA here; kept behavioral for readability)
    //
    // PIPE = 0: combinational -- result out in the same cycle.
    // PIPE = 1: two registered stages inside the multiplier:
    //     cycle X   : AND plane + 7 CSA rows captured (r_sum/r_carry)
    //     cycle X+1 : CPA on the captured pair, captured (prod_r)
    //     => operands at X, product valid at X+2
    // Elaboration builds exactly one of the two branches.
    // ---------------------------------------------------------------
    generate
        if (PIPE != 0) begin : g_pipe2
            reg [15:0] r_sum, r_carry;   // stage A: after the CSA rows
            reg [15:0] prod_r;           // stage B: after the CPA
            always @(posedge clk) begin
                if (clr) begin
                    r_sum   <= 16'h0000;
                    r_carry <= 16'h0000;
                    prod_r  <= 16'h0000;
                end else begin
                    r_sum   <= sum[7];
                    r_carry <= carry[7];
                    prod_r  <= r_sum + r_carry;
                end
            end
            assign y = prod_r;
        end else begin : g_comb
            assign y = sum[7] + carry[7];
        end
    endgenerate

endmodule

`default_nettype wire
