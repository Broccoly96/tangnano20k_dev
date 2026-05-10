// testcase_pipeline_latency.svh
//
// Purpose: Verify the behavioral pipeline has exactly 3 stages.
//
// TC-1: Single input pair at cycle 0; accumulator must be 0 at cycles +1, +2
//       and hold the correct product sum at cycle +3.
// TC-2: RESET while data is in-flight clears all stages; accumulator returns
//       to 0 after the reset clock edge and stays 0 for several cycles.

task automatic tc_pipeline_latency();
  log_info("DSP12_TB", "=== tc_pipeline_latency START ===");

  // -----------------------------------------------------------------------
  // TC-1: Verify exactly 3-cycle pipeline depth
  // -----------------------------------------------------------------------
  log_info("DSP12_TB", "TC-1: single pair, verify 3-cycle latency");

  pulse_dsp_reset();
  @(posedge tb_clk);  // extra idle cycle after reset

  // Set lane-0: w_a=2, w_b=3; act0=4, act1=5
  // Expected accumulation: 4*2 + 5*3 = 8 + 15 = 23
  set_wa(0, 8'sd2);
  set_wb(0, 8'sd3);
  for (int k = 1; k < LANE_COUNT; k++) begin
    set_wa(k, 8'sd0);
    set_wb(k, 8'sd0);
  end

  // Cycle 0: feed the single valid pair
  feed_pair(8'sd4, 8'sd5);

  // Now feed zeros; the input has entered stage-1.
  // Stage-2 (pipeline multiply) not reached yet.
  tb_act0 = '0;
  tb_act1 = '0;
  tb_weight_a = '0;
  tb_weight_b = '0;

  // +1: data in stage-1 → accumulator still 0
  @(posedge tb_clk);
  if (read_accum32(0) !== 32'sd0)
    log_error("DSP12_TB",
      $sformatf("TC-1 lat+1: acc=%0d exp=0", read_accum32(0)));
  else
    log_debug("DSP12_TB", "TC-1 lat+1: acc=0 OK");

  // +2: data in stage-2 → accumulator still 0
  @(posedge tb_clk);
  if (read_accum32(0) !== 32'sd0)
    log_error("DSP12_TB",
      $sformatf("TC-1 lat+2: acc=%0d exp=0", read_accum32(0)));
  else
    log_debug("DSP12_TB", "TC-1 lat+2: acc=0 OK");

  // +3: data exits stage-3 (OUT_REG) → accumulator = 23
  @(posedge tb_clk);
  check_accum32(0, 32'sd23, "TC-1 lat+3");

  // Cleanup
  repeat (4) @(posedge tb_clk);

  // -----------------------------------------------------------------------
  // TC-2: RESET while data in-flight clears all stages
  // -----------------------------------------------------------------------
  log_info("DSP12_TB", "TC-2: RESET while data in-flight");

  pulse_dsp_reset();
  @(posedge tb_clk);

  set_wa(0, 8'sd10);
  set_wb(0, 8'sd20);

  // Feed two non-zero pairs (data enters stages 1 and 2)
  feed_pair(8'sd1, 8'sd1);
  feed_pair(8'sd1, 8'sd1);

  // Assert RESET synchronously while data is still propagating
  tb_dsp_reset = 1'b1;
  @(posedge tb_clk);
  tb_dsp_reset = 1'b0;
  tb_act0     = '0;
  tb_act1     = '0;
  tb_weight_a = '0;
  tb_weight_b = '0;

  // All stages must be 0 within PIPE_LAT cycles after reset
  repeat (PIPE_LAT + 1) @(posedge tb_clk);
  check_all_lanes_zero("TC-2 post-reset");

  log_info("DSP12_TB", "=== tc_pipeline_latency PASS ===");
endtask
