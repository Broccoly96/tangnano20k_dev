// testcase_reset_mid_run.svh
//
// Purpose: Verify that asserting I_RESET during a running accumulation:
//   a) Clears the accumulator completely (verified by feeding more pairs
//      and checking only the post-reset contribution is present).
//   b) Clears pipeline in-flight data so the post-reset result does not
//      include any pre-reset products.
//
// TC-10: Run 5 pairs, then RESET, then run 3 pairs.
//        Expect final accumulator = only the 3-pair contribution.
//
// TC-11: Run until just before the last flush would appear (2 valid pairs,
//        RESET asserted 1 cycle before OUT_REG would capture it), then
//        verify accumulator is still 0 after one more clock.

task automatic tc_reset_mid_run();
  log_info("DSP12_TB", "=== tc_reset_mid_run START ===");

  // -----------------------------------------------------------------------
  // TC-10: 5 pairs → RESET → 3 pairs, verify only 3-pair result
  //   Phase-A: act0=7, act1=3, wa=2, wb=4
  //     per pair: 7*2 + 3*4 = 14+12 = 26; 5 pairs = 130 (discarded by RESET)
  //   Phase-B: act0=1, act1=2, wa=5, wb=6
  //     per pair: 1*5 + 2*6 = 5+12 = 17; 3 pairs = 51
  // -----------------------------------------------------------------------
  log_info("DSP12_TB", "TC-10: run 5 pairs, RESET, run 3 pairs");

  pulse_dsp_reset();
  @(posedge tb_clk);

  // Phase-A: 5 pairs
  set_wa(0, 8'sd2); set_wb(0, 8'sd4);
  for (int k = 1; k < LANE_COUNT; k++) begin
    set_wa(k, 8'sd0); set_wb(k, 8'sd0);
  end
  repeat (5) feed_pair(8'sd7, 8'sd3);

  // RESET (synchronous): clears accumulator and all pipeline stages
  pulse_dsp_reset();
  @(posedge tb_clk);

  // Phase-B: 3 pairs with different act/weight
  set_wa(0, 8'sd5); set_wb(0, 8'sd6);
  repeat (3) feed_pair(8'sd1, 8'sd2);

  flush_pipeline();
  // Expected: 3 * (1*5 + 2*6) = 3 * 17 = 51
  check_accum32(0, 32'sd51, "TC-10 post-reset");

  // All other lanes must be 0
  for (int k = 1; k < LANE_COUNT; k++)
    check_accum32(k, 32'sd0, $sformatf("TC-10 lane%0d zero", k));

  // -----------------------------------------------------------------------
  // TC-11: RESET asserted exactly 2 cycles after last valid pair
  //   (data in PIPE stage but not yet in OUT_REG)
  //   Verify OUT_REG = 0 after RESET + pipeline settle
  // -----------------------------------------------------------------------
  log_info("DSP12_TB", "TC-11: RESET 2 cycles after last valid input, result must be 0");

  pulse_dsp_reset();
  @(posedge tb_clk);

  set_wa(0, 8'sd20); set_wb(0, 8'sd30);
  // Feed one pair (data in stage-1 after this clock)
  feed_pair(8'sd2, 8'sd3);
  // 1 idle cycle (data in stage-2 — pipeline multiply), zero inputs
  tb_act0 = '0; tb_act1 = '0;
  @(posedge tb_clk);
  // Assert RESET here (data is between stage-2 and stage-3, not yet committed)
  tb_dsp_reset = 1'b1;
  tb_weight_a  = '0;
  tb_weight_b  = '0;
  @(posedge tb_clk);
  tb_dsp_reset = 1'b0;
  // Wait for pipeline settle
  repeat (PIPE_LAT + 1) @(posedge tb_clk);
  check_all_lanes_zero("TC-11 post-reset");

  log_info("DSP12_TB", "=== tc_reset_mid_run PASS ===");
endtask
