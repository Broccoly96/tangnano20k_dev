initial begin
  wait (tb_rst_n === 1'b1);
  repeat (4) @(posedge tb_clk);

  reset_capture();
  issue_req(DISP_OP_INIT, 24'h000000);
  wait_done(DISP_OP_INIT);
  expected_bytes[0] = 8'hAE; expected_dcs[0] = 1'b0;
  expected_bytes[1] = 8'hA0; expected_dcs[1] = 1'b0;
  expected_bytes[2] = 8'h72; expected_dcs[2] = 1'b1;
  expected_bytes[3] = 8'hA1; expected_dcs[3] = 1'b0;
  expected_bytes[4] = 8'h00; expected_dcs[4] = 1'b1;
  expected_bytes[5] = 8'hA2; expected_dcs[5] = 1'b0;
  expected_bytes[6] = 8'h00; expected_dcs[6] = 1'b1;
  expected_bytes[7] = 8'hA4; expected_dcs[7] = 1'b0;
  expected_bytes[8] = 8'hA8; expected_dcs[8] = 1'b0;
  expected_bytes[9] = 8'h3F; expected_dcs[9] = 1'b1;
  expected_bytes[10] = 8'hAD; expected_dcs[10] = 1'b0;
  expected_bytes[11] = 8'h8E; expected_dcs[11] = 1'b1;
  expected_bytes[12] = 8'hB0; expected_dcs[12] = 1'b0;
  expected_bytes[13] = 8'h0B; expected_dcs[13] = 1'b1;
  expected_bytes[14] = 8'hB1; expected_dcs[14] = 1'b0;
  expected_bytes[15] = 8'h31; expected_dcs[15] = 1'b1;
  expected_bytes[16] = 8'hB3; expected_dcs[16] = 1'b0;
  expected_bytes[17] = 8'hF0; expected_dcs[17] = 1'b1;
  expected_bytes[18] = 8'h8A; expected_dcs[18] = 1'b0;
  expected_bytes[19] = 8'h64; expected_dcs[19] = 1'b1;
  expected_bytes[20] = 8'h8B; expected_dcs[20] = 1'b0;
  expected_bytes[21] = 8'h78; expected_dcs[21] = 1'b1;
  expected_bytes[22] = 8'h8C; expected_dcs[22] = 1'b0;
  expected_bytes[23] = 8'h64; expected_dcs[23] = 1'b1;
  expected_bytes[24] = 8'hBB; expected_dcs[24] = 1'b0;
  expected_bytes[25] = 8'h3A; expected_dcs[25] = 1'b1;
  expected_bytes[26] = 8'hBE; expected_dcs[26] = 1'b0;
  expected_bytes[27] = 8'h3E; expected_dcs[27] = 1'b1;
  expected_bytes[28] = 8'h87; expected_dcs[28] = 1'b0;
  expected_bytes[29] = 8'h06; expected_dcs[29] = 1'b1;
  expected_bytes[30] = 8'h81; expected_dcs[30] = 1'b0;
  expected_bytes[31] = 8'h91; expected_dcs[31] = 1'b1;
  expected_bytes[32] = 8'h82; expected_dcs[32] = 1'b0;
  expected_bytes[33] = 8'h50; expected_dcs[33] = 1'b1;
  expected_bytes[34] = 8'h83; expected_dcs[34] = 1'b0;
  expected_bytes[35] = 8'h7D; expected_dcs[35] = 1'b1;
  expected_bytes[36] = 8'hAF; expected_dcs[36] = 1'b0;
  expect_capture(37);
  if (!cap_res_low_seen || tb_res_n != 1'b1) begin
    log_fatal(1, "SSD1331 CTRL TB", "init did not pulse RES# as expected");
  end

  reset_capture();
  issue_req(DISP_OP_CLEAR, 24'h000000);
  wait_done(DISP_OP_CLEAR);
  expected_bytes[0] = 8'h25; expected_dcs[0] = 1'b0;
  expected_bytes[1] = 8'h00; expected_dcs[1] = 1'b1;
  expected_bytes[2] = 8'h00; expected_dcs[2] = 1'b1;
  expected_bytes[3] = 8'h5F; expected_dcs[3] = 1'b1;
  expected_bytes[4] = 8'h3F; expected_dcs[4] = 1'b1;
  expect_capture(5);

  reset_capture();
  issue_req(DISP_OP_FILL, 24'hFF0000);
  wait_done(DISP_OP_FILL);
  expected_bytes[0] = 8'h26; expected_dcs[0] = 1'b0;
  expected_bytes[1] = 8'h01; expected_dcs[1] = 1'b1;
  expected_bytes[2] = 8'h22; expected_dcs[2] = 1'b0;
  expected_bytes[3] = 8'h00; expected_dcs[3] = 1'b1;
  expected_bytes[4] = 8'h00; expected_dcs[4] = 1'b1;
  expected_bytes[5] = 8'h5F; expected_dcs[5] = 1'b1;
  expected_bytes[6] = 8'h3F; expected_dcs[6] = 1'b1;
  expected_bytes[7] = 8'h3E; expected_dcs[7] = 1'b1;
  expected_bytes[8] = 8'h00; expected_dcs[8] = 1'b1;
  expected_bytes[9] = 8'h00; expected_dcs[9] = 1'b1;
  expected_bytes[10] = 8'h3E; expected_dcs[10] = 1'b1;
  expected_bytes[11] = 8'h00; expected_dcs[11] = 1'b1;
  expected_bytes[12] = 8'h00; expected_dcs[12] = 1'b1;
  expect_capture(13);

  reset_capture();
  issue_req(DISP_OP_OFF, 24'h000000);
  wait_done(DISP_OP_OFF);
  expected_bytes[0] = 8'hAE; expected_dcs[0] = 1'b0;
  expect_capture(1);

  reset_capture();
  issue_req(DISP_OP_ON, 24'h000000);
  wait_done(DISP_OP_ON);
  expected_bytes[0] = 8'hAF; expected_dcs[0] = 1'b0;
  expect_capture(1);

  reset_capture();
  issue_req(DISP_OP_PATTERN, 24'h000000);
  wait_done(DISP_OP_PATTERN);
  if (cap_byte_count != 35) begin
    log_fatal(1, "SSD1331 CTRL TB", $sformatf("pattern count mismatch got=%0d", cap_byte_count));
  end
  if (cap_bytes[0] != 8'h26 || cap_bytes[1] != 8'h01 || cap_bytes[2] != 8'h22) begin
    log_fatal(1, "SSD1331 CTRL TB", "pattern prefix mismatch");
  end
  if (
    cap_bytes[7] != 8'h3E ||
    cap_bytes[10] != 8'h3E ||
    cap_bytes[19] != 8'h3F ||
    cap_bytes[22] != 8'h3F ||
    cap_bytes[31] != 8'h3E ||
    cap_bytes[34] != 8'h3E
  ) begin
    log_fatal(1, "SSD1331 CTRL TB", "pattern color bytes mismatch");
  end

  if (tb_busy != 1'b0 || tb_cs_n != 1'b1 || tb_sclk != 1'b0 || tb_res_n != 1'b1) begin
    log_fatal(
      1,
      "SSD1331 CTRL TB",
      $sformatf("unexpected idle outputs busy=%0b cs_n=%0b sclk=%0b res_n=%0b", tb_busy, tb_cs_n, tb_sclk, tb_res_n)
    );
  end

  $display("ssd1331_display_ctrl smoke test passed");
  $finish;
end