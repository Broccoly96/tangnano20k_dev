// testcase_multi_lane.svh
//
// Purpose: Verify all 12 lanes operate independently with different weights.
//
// TC-8: Assign each lane k a distinct weight pair (wa=k+1, wb=k+2).
//       Feed act0=10, act1=20 for 3 pairs; verify each lane accumulates its
//       own correct sum:
//         lane k: sum = 3 * (10*(k+1) + 20*(k+2))
//
// TC-9: Lanes with negative and positive weights mixed.
//       wa[k] = (-1)^k * (k+1), wb[k] = (k+1)
//       act0=5, act1=3, 2 pairs
//       lane k: sum = 2 * (5 * ((-1)^k*(k+1)) + 3*(k+1))

task automatic tc_multi_lane();
  log_info("DSP12_TB", "=== tc_multi_lane START ===");

  // -----------------------------------------------------------------------
  // TC-8: Distinct positive weights per lane, 3 pairs
  // -----------------------------------------------------------------------
  log_info("DSP12_TB", "TC-8: all lanes, distinct positive weights, 3 pairs");

  pulse_dsp_reset();
  @(posedge tb_clk);

  for (int k = 0; k < LANE_COUNT; k++) begin
    set_wa(k, 8'(k + 1));
    set_wb(k, 8'(k + 2));
  end

  repeat (3) feed_pair(8'sd10, 8'sd20);
  flush_pipeline();

  for (int k = 0; k < LANE_COUNT; k++) begin
    automatic logic signed [31:0] exp;
    exp = 3 * (10 * (k + 1) + 20 * (k + 2));
    check_accum32(k, exp, $sformatf("TC-8 lane%0d", k));
  end

  // -----------------------------------------------------------------------
  // TC-9: Mixed sign weights per lane, 2 pairs
  //   wa[k] = (k even) ? (k+1) : -(k+1)
  //   wb[k] = (k+1)
  //   act0=5, act1=3
  //   lane k: 2 * (5*wa[k] + 3*wb[k])
  // -----------------------------------------------------------------------
  log_info("DSP12_TB", "TC-9: mixed sign weights, all lanes, 2 pairs");

  pulse_dsp_reset();
  @(posedge tb_clk);

  for (int k = 0; k < LANE_COUNT; k++) begin
    automatic logic signed [7:0] wa;
    wa = (k % 2 == 0) ? 8'(k + 1) : -8'(k + 1);
    set_wa(k, wa);
    set_wb(k, 8'(k + 1));
  end

  repeat (2) feed_pair(8'sd5, 8'sd3);
  flush_pipeline();

  for (int k = 0; k < LANE_COUNT; k++) begin
    automatic int signed wa_int;
    automatic int signed wb_int;
    automatic logic signed [31:0] exp;
    wa_int = (k % 2 == 0) ? (k + 1) : -(k + 1);
    wb_int = (k + 1);
    exp = 2 * (5 * wa_int + 3 * wb_int);
    check_accum32(k, exp, $sformatf("TC-9 lane%0d", k));
  end

  log_info("DSP12_TB", "=== tc_multi_lane PASS ===");
endtask
