`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : 03_sim/36_char_ocr_dsp12_accum/testbench.sv
// Description  : Comprehensive unit testbench for char_ocr_dsp12_accum and
//                char_ocr_multaddalu18x18_wrapper.
//
// Test coverage (run sequentially from one master initial block):
//   tc_pipeline_latency   : pipeline depth = 3 cycles; RESET clears all stages
//   tc_single_neuron      : single-lane dot product correctness and sign handling
//   tc_multi_lane         : all 12 lanes independent and correct simultaneously
//   tc_reset_mid_run      : mid-computation RESET clears accumulator properly
//   tc_full_fc0_reference : software-equivalent FC0 dot-product reference check
//////////////////////////////////////////////////////////////////////////////////

module testbench;

  import tb_log_pkg::*;

  localparam time CLK_HALF_PERIOD = 10ns;  // 50 MHz

  // Derived constants matching char_ocr_pkg
  localparam int unsigned LANE_COUNT   = 12;
  localparam int unsigned PIPE_LAT     = 3;    // pipeline stages in wrapper
  localparam int unsigned FEAT_PAIRS   = 512;  // 1024 features / 2
  localparam int unsigned HIDDEN_PAIRS = 32;   // 64 hidden / 2

  // -------------------------------------------------------------------------
  // DUT I/O
  // -------------------------------------------------------------------------
  logic                         tb_clk;
  logic                         tb_ce;
  logic                         tb_dsp_reset;
  logic signed [7:0]            tb_act0;
  logic signed [7:0]            tb_act1;
  logic signed [(12*8)-1:0]     tb_weight_a;
  logic signed [(12*8)-1:0]     tb_weight_b;
  logic signed [(12*54)-1:0]    tb_accum_vector;

  // -------------------------------------------------------------------------
  // Clock generation
  // -------------------------------------------------------------------------
  initial begin
    tb_clk = 1'b0;
    forever #CLK_HALF_PERIOD tb_clk = ~tb_clk;
  end

  // -------------------------------------------------------------------------
  // DUT instantiation
  // -------------------------------------------------------------------------
  char_ocr_dsp12_accum u_dut (
    .I_CLK         (tb_clk),
    .I_CE          (tb_ce),
    .I_RESET       (tb_dsp_reset),
    .I_ACT0        (tb_act0),
    .I_ACT1        (tb_act1),
    .I_WEIGHT_A    (tb_weight_a),
    .I_WEIGHT_B    (tb_weight_b),
    .O_ACCUM_VECTOR(tb_accum_vector)
  );

  // -------------------------------------------------------------------------
  // Helper functions
  // -------------------------------------------------------------------------

  function automatic logic signed [31:0] read_accum32(int k);
    return $signed(tb_accum_vector[(k*54) +: 32]);
  endfunction

  function automatic logic signed [53:0] read_accum54(int k);
    return $signed(tb_accum_vector[(k*54) +: 54]);
  endfunction

  // -------------------------------------------------------------------------
  // Helper tasks
  // -------------------------------------------------------------------------

  task automatic set_wa(int k, logic signed [7:0] val);
    tb_weight_a[(k*8) +: 8] = val;
  endtask

  task automatic set_wb(int k, logic signed [7:0] val);
    tb_weight_b[(k*8) +: 8] = val;
  endtask

  // Pulse DSP RESET for one cycle (synchronous).
  // Also zeros act/weight inputs to match real RTL behavior: the FSM
  // always_comb block drives zeros in ST_L0_RESET / ST_L1_RESET.
  task automatic pulse_dsp_reset();
    tb_dsp_reset = 1'b1;
    tb_act0     = '0;
    tb_act1     = '0;
    tb_weight_a = '0;
    tb_weight_b = '0;
    @(posedge tb_clk);
    tb_dsp_reset = 1'b0;
  endtask

  // Feed one pair into DUT then advance one clock
  task automatic feed_pair(
    input logic signed [7:0] act0,
    input logic signed [7:0] act1
  );
    tb_act0 = act0;
    tb_act1 = act1;
    @(posedge tb_clk);
  endtask

  // Feed PIPE_LAT zero pairs to flush the pipeline
  task automatic flush_pipeline();
    tb_act0     = '0;
    tb_act1     = '0;
    tb_weight_a = '0;
    tb_weight_b = '0;
    repeat (PIPE_LAT) @(posedge tb_clk);
  endtask

  // Verify lane k 32-bit accumulator result
  task automatic check_accum32(
    int k, logic signed [31:0] expected, string label
  );
    automatic logic signed [31:0] actual = read_accum32(k);
    if (actual !== expected)
      log_error("DSP12_TB",
        $sformatf("lane%0d [%s] act=%0d exp=%0d", k, label, actual, expected));
    else
      log_debug("DSP12_TB",
        $sformatf("lane%0d [%s] = %0d OK", k, label, actual));
  endtask

  task automatic check_all_lanes_zero(string label);
    for (int k = 0; k < LANE_COUNT; k++)
      check_accum32(k, 32'sd0, {label, $sformatf("_L%0d", k)});
  endtask

  // -------------------------------------------------------------------------
  // Testcase task includes (each file defines one task)
  // -------------------------------------------------------------------------
  `include "testcase_pipeline_latency.svh"
  `include "testcase_single_neuron.svh"
  `include "testcase_multi_lane.svh"
  `include "testcase_reset_mid_run.svh"
  `include "testcase_full_fc0_reference.svh"

  // -------------------------------------------------------------------------
  // Master test runner
  // -------------------------------------------------------------------------
  initial begin
    configure_logging(LOG_INFO);
    tb_ce       = 1'b1;
    tb_dsp_reset = 1'b0;
    tb_act0     = '0;
    tb_act1     = '0;
    tb_weight_a = '0;
    tb_weight_b = '0;

    // Wait a few clocks for stable initial state
    repeat (4) @(posedge tb_clk);

    tc_pipeline_latency();
    tc_single_neuron();
    tc_multi_lane();
    tc_reset_mid_run();
    tc_full_fc0_reference();

    log_info("DSP12_TB", "=== ALL DSP12 UNIT TESTS PASSED ===");
    $finish;
  end

endmodule
