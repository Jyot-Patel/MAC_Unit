//======================================================================
// mac_pe.v -- MAC Processing Element (the "unit cell" of the 4x4 array)
//----------------------------------------------------------------------
// One PE computes:  acc <= acc + (a_reg * b_reg)     [UINT8 x UINT8 -> 18b]
// and forwards its operands to its neighbours (the SYSTOLIC HOP):
//   a hops RIGHT  (activations),  b hops DOWN (weights).
//
// Structure (4 registered stages, see docs/THEORY.md section 3):
//   [1] hop input regs  a_reg/b_reg  -- operand available a full cycle;
//       doubles as the systolic pipeline register (1 PE hop = 1 cycle)
//   [2] multiplier      structural 8x8 array mult when DATA_W==8
//                       (see rtl/mult8x8_array.v; generic '*' otherwise)
//   [3] optional pipe   PIPELINE_MAC build-study knob (matrix stays 4x4,
//                       SPEC Sec.5) -- cuts the mult+add path into
//                         0 = mult + add in ONE cycle  (longest path)
//                         1 = register after the mult   [mult] | [add]
//                         2 = pipelined multiplier      [CSA] | [CPA]
//                             + the adder's own cycle       | [add]
//                       Each cut = shorter segments -> higher Fmax
//                       potential, at the cost of registers and of +1/+2
//                       cycles of in-PE accumulate latency. The controller
//                       widens its acc_en window to match, so transaction
//                       latency is IDENTICAL for all variants (proven by
//                       lockstep simulation -- docs/TIMING.md).
//   [4] accumulator     18-bit acc with synchronous clear / enable
//
// TIMING CONTRACT (critical for Phase 2/3 controller design):
//   At every posedge:  a_reg <= a_in          (hop)
//                      acc   <= clear ? 0 : acc + prod   (prod = value
//                             BEFORE this edge, gated by acc_en)
//   => the product of a pair is accumulated ONE clock after the pair is
//      registered (TWO clocks if PIPELINE_MAC=1, THREE if =2).
//   => clear has highest priority over acc_en (and flushes the pipe).
//   => To absorb the last products, the controller keeps acc_en high for
//      PIPELINE_MAC extra clocks past the compute window (FLUSH plus
//      DRAIN cycles cnt < PIPELINE_MAC) while a_in/b_in zero-fill
//      outside the feeder emission window (0 products, harmless).
//
// WIDTH PROOF (SPEC F5/F7): 255*255 = 65,025 < 2^16;
//   4 * 65,025 = 260,100 < 2^18 = 262,144  => ACC_W = 18 for N = 4.
//======================================================================
`default_nettype none

module mac_pe #(
    parameter DATA_W        = 8,   // operand width  (UINT8 in this project)
    parameter ACC_W         = 18,  // accumulator width (16 + clog2(4) = 18)
    parameter PIPELINE_MAC  = 0    // 0 = one cycle | 1 = mult|add | 2 = CSA|CPA|add
) (
    input  wire                 clk,
    input  wire                 rst_n,     // async assert, sync release, active low
    input  wire                 clear,     // synchronous acc clear (highest priority)
    input  wire                 acc_en,    // accumulate enable for THIS edge
    input  wire [DATA_W-1:0]    a_in,      // activation from left neighbour / edge
    input  wire [DATA_W-1:0]    b_in,      // weight from top neighbour / edge
    output wire [DATA_W-1:0]    a_out,     // hop -> PE on the right
    output wire [DATA_W-1:0]    b_out,     // hop -> PE below
    output wire [ACC_W-1:0]     psum_out   // live view of acc (= one C element)
);

    localparam PROD_W = 2 * DATA_W;   // 16 bits for DATA_W = 8

    // Stage 1 -- systolic hop registers (a flows right, b flows down)
    reg [DATA_W-1:0] a_reg, b_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_reg <= {DATA_W{1'b0}};
            b_reg <= {DATA_W{1'b0}};
        end else begin
            a_reg <= a_in;
            b_reg <= b_in;
        end
    end
    assign a_out = a_reg;
    assign b_out = b_reg;

    // Stage 2 -- unsigned multiplier
    //   Canonical project width (DATA_W==8): explicit structural array
    //   multiplier for regular, symmetric layout (prompt.txt goal).
    //   Any other width: portable behavioral multiply (synthesis still
    //   maps it to an array/Wallace structure).
    // The structural multiplier owns the first TWO stages of
    // PIPELINE_MAC=2 itself (its internal PIPE=1 cut: [CSA] | [CPA]);
    // every other configuration keeps it combinational and stages the
    // product with mac-level registers (stage 3 below).
    localparam MULT_PIPE = (DATA_W == 8 && PIPELINE_MAC == 2) ? 1 : 0;

    wire [PROD_W-1:0] prod_c;
    generate
        if (DATA_W == 8) begin : g_struct_mult
            mult8x8_array #(.PIPE (MULT_PIPE)) u_mult (
                .clk (clk),
                .clr (clear),
                .a   (a_reg),
                .b   (b_reg),
                .y   (prod_c)
            );
        end else begin : g_generic_mult
            assign prod_c = a_reg * b_reg;   // portable '*' for other widths
        end
    endgenerate

    // Stage 3 -- product staging toward the adder (one cycle per stage)
    //   `clear` FLUSHES the mac-level stages so an in-flight product can
    //   never pollute the freshly cleared accumulator; for PIPELINE_MAC=2
    //   with the structural multiplier that flush lives inside u_mult.
    wire [PROD_W-1:0] prod;
    generate
        if (MULT_PIPE != 0) begin : g_mult_pipe
            // PIPELINE_MAC=2, structural: u_mult already delays the
            // product by two cycles (its stages carry the clear flush).
            assign prod = prod_c;
        end else if (PIPELINE_MAC == 1) begin : g_pipe1
            reg [PROD_W-1:0] prod_r;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)      prod_r <= {PROD_W{1'b0}};
                else if (clear)  prod_r <= {PROD_W{1'b0}};   // flush
                else             prod_r <= prod_c;
            end
            assign prod = prod_r;
        end else if (PIPELINE_MAC == 2) begin : g_pipe2
            // PIPELINE_MAC=2, generic multiplier: two mac-level stages
            reg [PROD_W-1:0] prod_r1, prod_r2;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    prod_r1 <= {PROD_W{1'b0}};
                    prod_r2 <= {PROD_W{1'b0}};
                end else if (clear) begin
                    prod_r1 <= {PROD_W{1'b0}};              // flush
                    prod_r2 <= {PROD_W{1'b0}};
                end else begin
                    prod_r1 <= prod_c;
                    prod_r2 <= prod_r1;
                end
            end
            assign prod = prod_r2;
        end else begin : g_nopipe 
            assign prod = prod_c;
        end
    endgenerate

    // Stage 4 -- 18-bit accumulator
    //   Zero-extend the 16-bit product; the carry OUT of the 18-bit adder
    //   is discarded BY CONSTRUCTION (impossible to need it, see header).
    wire [ACC_W-1:0] prod_ext = {{(ACC_W - PROD_W){1'b0}}, prod};

    reg [ACC_W-1:0] acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      acc <= {ACC_W{1'b0}};
        else if (clear)  acc <= {ACC_W{1'b0}};       // clear > acc_en
        else if (acc_en) acc <= acc + prod_ext;      // THE MAC operation
    end

    assign psum_out = acc;

endmodule

`default_nettype wire
