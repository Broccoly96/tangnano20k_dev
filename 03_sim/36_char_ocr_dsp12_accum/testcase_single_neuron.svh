// testcase_single_neuron.svh
//
// Purpose: Verify single-lane dot-product correctness.
//
// TC-3: Positive x positive weights. Feeds 4 pairs and checks final result.
// TC-4: Negative activations + positive weights (signed multiplication).
// TC-5: Positive acts + negative weights.
// TC-6: Boundary: maximum positive int8 inputs (127 * 127 * 2 pairs) — verify
//        accumulator does not overflow int32 for a moderate pair count.
// TC-7: Zero activation → accumulator must remain 0 regardless of weight.

task automatic tc_single_neuron();
  log_info("DSP12_TB", "=== tc_single_neuron START ===");

  // -----------------------------------------------------------------------
  // TC-3: Positive x positive, 4 pairs
  //   pair 0: a0=3,  b0=4,  a1=5,  b1=6   -> 3*4 + 5*6 = 12+30 = 42
  //   pair 1: a0=1,  b0=2,  a1=10, b1=3   -> 1*2 + 10*3 = 2+30  = 32
  //   pair 2: a0=7,  b0=8,  a1=9,  b1=10  -> 7*8 + 9*10 = 56+90 = 146
  //   pair 3: a0=2,  b0=3,  a1=4,  b1=5   -> 2*3 + 4*5  = 6+20  = 26
  //   total = 42 + 32 + 146 + 26 = 246
  // -----------------------------------------------------------------------
  log_info("DSP12_TB", "TC-3: positive x positive, 4 pairs");

  pulse_dsp_reset();
  @(posedge tb_clk);

  tb_weight_a = '0;
  tb_weight_b = '0;
  // Lane 0 only; all other lanes have weight=0
  set_wa(0, 8'sd4);  // will override each pair below

  // pair 0
  set_wa(0, 8'sd4);  set_wb(0, 8'sd6);   feed_pair(8'sd3,  8'sd5);
  // pair 1
  set_wa(0, 8'sd2);  set_wb(0, 8'sd3);   feed_pair(8'sd1,  8'sd10);
  // pair 2
  set_wa(0, 8'sd8);  set_wb(0, 8'sd10);  feed_pair(8'sd7,  8'sd9);
  // pair 3
  set_wa(0, 8'sd3);  set_wb(0, 8'sd5);   feed_pair(8'sd2,  8'sd4);

  flush_pipeline();
  check_accum32(0, 32'sd246, "TC-3 result");

  // -----------------------------------------------------------------------
  // TC-4: Negative activations + positive weights
  //   pair 0: a0=-2, b0=10, a1=-3, b1=5  -> -2*10 + -3*5 = -20-15 = -35
  //   pair 1: a0=-1, b0=7,  a1=-4, b1=2  -> -1*7  + -4*2 = -7-8   = -15
  //   total = -50
  // -----------------------------------------------------------------------
  log_info("DSP12_TB", "TC-4: negative acts x positive weights");

  pulse_dsp_reset();
  @(posedge tb_clk);

  set_wa(0, 8'sd10); set_wb(0, 8'sd5);  feed_pair(-8'sd2, -8'sd3);
  set_wa(0, 8'sd7);  set_wb(0, 8'sd2);  feed_pair(-8'sd1, -8'sd4);
  flush_pipeline();
  check_accum32(0, -32'sd50, "TC-4 result");

  // -----------------------------------------------------------------------
  // TC-5: Positive acts + negative weights
  //   pair 0: a0=5, b0=-3, a1=2, b1=-6  -> 5*(-3) + 2*(-6) = -15-12 = -27
  //   pair 1: a0=8, b0=-2, a1=4, b1=-1  -> 8*(-2) + 4*(-1) = -16-4  = -20
  //   total = -47
  // -----------------------------------------------------------------------
  log_info("DSP12_TB", "TC-5: positive acts x negative weights");

  pulse_dsp_reset();
  @(posedge tb_clk);

  set_wa(0, -8'sd3); set_wb(0, -8'sd6);  feed_pair(8'sd5, 8'sd2);
  set_wa(0, -8'sd2); set_wb(0, -8'sd1);  feed_pair(8'sd8, 8'sd4);
  flush_pipeline();
  check_accum32(0, -32'sd47, "TC-5 result");

  // -----------------------------------------------------------------------
  // TC-6: Maximum int8 inputs (127 * 127), 10 pairs, 2 products/pair
  //   Each pair: 127*127 + 127*127 = 16129 + 16129 = 32258
  //   10 pairs: 322580
  // -----------------------------------------------------------------------
  log_info("DSP12_TB", "TC-6: max int8 inputs, 10 pairs");

  pulse_dsp_reset();
  @(posedge tb_clk);

  set_wa(0, 8'sd127); set_wb(0, 8'sd127);
  repeat (10) feed_pair(8'sd127, 8'sd127);
  flush_pipeline();
  check_accum32(0, 32'sd322580, "TC-6 result");

  // -----------------------------------------------------------------------
  // TC-7: Zero activation → accumulator stays 0 regardless of weights
  // -----------------------------------------------------------------------
  log_info("DSP12_TB", "TC-7: zero act, any weight -> acc=0");

  pulse_dsp_reset();
  @(posedge tb_clk);

  set_wa(0, 8'sd99); set_wb(0, -8'sd77);
  repeat (8) feed_pair(8'sd0, 8'sd0);
  flush_pipeline();
  check_accum32(0, 32'sd0, "TC-7 result");

  log_info("DSP12_TB", "=== tc_single_neuron PASS ===");
endtask
