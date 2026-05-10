`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_multaddalu18x18_wrapper.sv
// Description  : Wrapper around one gowin_multaddalu_18x18 (MULTADDALU18X18)
//                DSP instance for the character OCR accumulator array.
//
// Operation (Mode 1, ACCLOAD = 0 in the generated IP):
//   Every clock: DOUT += A0*B0 + A1*B1   (internal accumulation)
//   RESET (sync): clears the accumulator and all pipeline stages.
//
// Mapping for OCR dot product:
//   I_A0 = activation feature[2i]       (broadcast to all lanes)
//   I_B0 = weight for neuron k at [2i]   (unique per DSP)
//   I_A1 = activation feature[2i+1]     (broadcast to all lanes)
//   I_B1 = weight for neuron k at [2i+1] (unique per DSP)
//   After FEAT_COUNT/2 = 512 cycles:
//     O_DOUT = sum_j(act[j]*w[k][j]) = dot(act, w[k])
//
// Pipeline latency (3 cycles):
//   Stage 1 (I_A/I_B reg)  -> Stage 2 (PIPE_REG multiply) -> Stage 3 (OUT_REG accum)
//   Feed PIPE_LATENCY = 3 zero cycles after last valid input to flush.
//
// Synthesis:
//   Define CHAR_OCR_USE_GOWIN_DSP to enable gowin_multaddalu_18x18 instantiation.
//   The CASO cascade output carries the full 54-bit accumulated result.
//   Without the define, a cycle-accurate 3-stage behavioral model is used.
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_multaddalu18x18_wrapper (
  input  logic                I_CLK,
  input  logic                I_CE,
  input  logic                I_RESET,    // synchronous reset, clears accumulator + pipeline
  input  logic signed [7:0]   I_A0,       // int8 activation for feature[2i]
  input  logic signed [7:0]   I_B0,       // int8 weight for neuron k at feature[2i]
  input  logic signed [7:0]   I_A1,       // int8 activation for feature[2i+1]
  input  logic signed [7:0]   I_B1,       // int8 weight for neuron k at feature[2i+1]
  output logic signed [53:0]  O_DOUT      // 54-bit accumulated dot product
);

`ifdef CHAR_OCR_USE_GOWIN_DSP
  // ------------------------------------------------------------------
  // Synthesis path: use the generated Gowin IP.
  // gowin_multaddalu_18x18 sign-extends the 8-bit inputs to 18 bits
  // internally, uses Mode=1 (ACC/0 + A0*B0 + A1*B1) with ACCLOAD=0
  // and all pipeline registers enabled (3-cycle latency).
  // The full 54-bit accumulated result is read from caso[53:0].
  // ------------------------------------------------------------------
  wire [16:0] w_dout_low;
  wire [54:0] w_caso;

  gowin_multaddalu_18x18 u_gowin_dsp (
    .clk   (I_CLK),
    .ce    (I_CE),
    .reset (I_RESET),
    .a0    (I_A0),
    .b0    (I_B0),
    .a1    (I_A1),
    .b1    (I_B1),
    .dout  (w_dout_low),
    .caso  (w_caso)
  );

  // CASO[53:0] carries the same full 54-bit accumulated result as DOUT[53:0].
  assign O_DOUT = $signed(w_caso[53:0]);

`else
  // ------------------------------------------------------------------
  // Simulation path: cycle-accurate 3-stage pipeline behavioral model.
  //
  // Matches gowin_multaddalu_18x18 pipeline:
  //   Stage 1 (s_ab)  : input A/B registers (A0REG=1, B0REG=1, A1REG=1, B1REG=1)
  //   Stage 2 (s_prod): multiply pipe registers (PIPE0_REG=1, PIPE1_REG=1)
  //   Stage 3 (s_acc) : output/accumulator register (OUT_REG=1, Mode=1)
  //
  // Accumulation: s_acc[n] = s_acc[n-1] + s_prod_p0[n-1] + s_prod_p1[n-1]
  // RESET clears all three stages synchronously.
  // ------------------------------------------------------------------
  logic signed [7:0]  s_ab_a0, s_ab_b0, s_ab_a1, s_ab_b1;
  logic signed [17:0] s_prod_p0, s_prod_p1;
  logic signed [53:0] s_acc;

  // Stage-1: input registers (A0REG, B0REG, A1REG, B1REG = 1)
  // Stage-2: multiply pipeline (PIPE0_REG, PIPE1_REG = 1)
  // Stage-3: accumulate to OUT_REG (Mode=1, ACCLOAD=0 always)
  always_ff @(posedge I_CLK) begin
    if (I_RESET) begin
      s_ab_a0   <= '0;
      s_ab_b0   <= '0;
      s_ab_a1   <= '0;
      s_ab_b1   <= '0;
      s_prod_p0 <= '0;
      s_prod_p1 <= '0;
      s_acc     <= '0;
    end else if (I_CE) begin
      // Stage 1: latch inputs
      s_ab_a0   <= I_A0;
      s_ab_b0   <= I_B0;
      s_ab_a1   <= I_A1;
      s_ab_b1   <= I_B1;
      // Stage 2: compute products from stage-1 values
      s_prod_p0 <= 18'($signed(s_ab_a0) * $signed(s_ab_b0));
      s_prod_p1 <= 18'($signed(s_ab_a1) * $signed(s_ab_b1));
      // Stage 3: accumulate products from stage-2
      s_acc     <= s_acc + 54'($signed(s_prod_p0)) + 54'($signed(s_prod_p1));
    end
  end

  assign O_DOUT = s_acc;
`endif

endmodule