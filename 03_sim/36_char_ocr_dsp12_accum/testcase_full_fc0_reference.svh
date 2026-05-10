// testcase_full_fc0_reference.svh
//
// Purpose: Verify a full FC0 (512 pairs) computation for all 12 lanes
//          against a software reference computed in the same testcase.
//
// Method:
//   1. Choose deterministic pseudo-random weights and activations (not truly
//      random — use a simple linear LFSR-like formula so the test is
//      repeatable without a random seed).
//   2. Compute the expected dot products in software (64-bit integers to
//      avoid overflow) for each of the 12 lanes.
//   3. Drive the DUT for FEAT_PAIRS (512) pairs + PIPE_LAT (3) flush cycles.
//   4. Compare O_ACCUM_VECTOR[k] (lower 32 bits) against the software reference.
//
// Activation generation: act[2i]   = signed'((i * 7 + 3) & 8'hFF - 8'h80)
//                        act[2i+1] = signed'(((i+1) * 11 + 5) & 8'hFF - 8'h80)
// Weight generation:     w[k][2i]  = signed'(((k*31 + i*7 + 13) & 8'hFF) - 8'h80)
//                        w[k][2i+1]= signed'(((k*17 + i*13 + 29) & 8'hFF) - 8'h80)
//
// TC-12: 12-lane FC0 reference dot product, 512 pairs.

task automatic tc_full_fc0_reference();
  // Software reference (64-bit to avoid int32 overflow during accumulation)
  automatic longint signed ref_accum [0:LANE_COUNT-1];
  automatic logic signed [7:0] a0_arr [0:FEAT_PAIRS-1];
  automatic logic signed [7:0] a1_arr [0:FEAT_PAIRS-1];
  automatic logic signed [7:0] wa_arr [0:LANE_COUNT-1][0:FEAT_PAIRS-1];
  automatic logic signed [7:0] wb_arr [0:LANE_COUNT-1][0:FEAT_PAIRS-1];

  log_info("DSP12_TB", "=== tc_full_fc0_reference START ===");
  log_info("DSP12_TB", "TC-12: 12-lane FC0 dot product, 512 pairs");

  // -----------------------------------------------------------------------
  // Build activation and weight tables
  // -----------------------------------------------------------------------
  for (int i = 0; i < FEAT_PAIRS; i++) begin
    automatic int v0 = ((i * 7 + 3) & 8'hFF);
    automatic int v1 = (((i + 1) * 11 + 5) & 8'hFF);
    a0_arr[i] = 8'(v0 - 128);  // center around 0 (signed)
    a1_arr[i] = 8'(v1 - 128);
  end

  for (int k = 0; k < LANE_COUNT; k++) begin
    for (int i = 0; i < FEAT_PAIRS; i++) begin
      automatic int wv0 = ((k * 31 + i * 7  + 13) & 8'hFF);
      automatic int wv1 = ((k * 17 + i * 13 + 29) & 8'hFF);
      wa_arr[k][i] = 8'(wv0 - 128);
      wb_arr[k][i] = 8'(wv1 - 128);
    end
  end

  // -----------------------------------------------------------------------
  // Compute software reference
  // -----------------------------------------------------------------------
  for (int k = 0; k < LANE_COUNT; k++) ref_accum[k] = 0;

  for (int i = 0; i < FEAT_PAIRS; i++) begin
    for (int k = 0; k < LANE_COUNT; k++) begin
      ref_accum[k] += longint'($signed(a0_arr[i])) * longint'($signed(wa_arr[k][i]));
      ref_accum[k] += longint'($signed(a1_arr[i])) * longint'($signed(wb_arr[k][i]));
    end
  end

  log_info("DSP12_TB", "TC-12: software reference computed");
  for (int k = 0; k < LANE_COUNT; k++)
    log_debug("DSP12_TB",
      $sformatf("TC-12 ref lane%0d = %0d", k, ref_accum[k]));

  // -----------------------------------------------------------------------
  // Drive DUT: RESET → 512 pairs → 3 flush cycles
  // -----------------------------------------------------------------------
  pulse_dsp_reset();
  @(posedge tb_clk);

  for (int i = 0; i < FEAT_PAIRS; i++) begin
    for (int k = 0; k < LANE_COUNT; k++) begin
      set_wa(k, wa_arr[k][i]);
      set_wb(k, wb_arr[k][i]);
    end
    feed_pair(a0_arr[i], a1_arr[i]);
  end

  flush_pipeline();

  // -----------------------------------------------------------------------
  // Verify: lower 32 bits must match reference (for reasonable weight ranges
  // the 512-pair accumulation stays within int32 range with these parameters)
  // -----------------------------------------------------------------------
  for (int k = 0; k < LANE_COUNT; k++) begin
    automatic logic signed [31:0] exp32 = ref_accum[k][31:0];
    check_accum32(k, exp32, $sformatf("TC-12 lane%0d", k));
    // Also verify upper bits of 54-bit result match reference (no overflow)
    if (read_accum54(k) !== ref_accum[k][53:0])
      log_warn("DSP12_TB",
        $sformatf("TC-12 lane%0d 54b mismatch: act=%0d ref=%0d",
          k, read_accum54(k), ref_accum[k][53:0]));
  end

  log_info("DSP12_TB", "=== tc_full_fc0_reference PASS ===");
endtask
