initial begin : tc_smoke
  wait (tb_rst_n);
  wait (tb_init_done);
  log_info("OPEN WORD TB", "controller init completed");

  issue_word_request(1'b1, 21'h00010, 32'h1122_3344, 4'hF);
  expect_response(32'h0000_0000, 32'h0000_0000, "write_full_0");
  issue_word_request(1'b0, 21'h00010, 32'h0000_0000, 4'h0);
  expect_response(32'h0000_0000, 32'h1122_3344, "read_full_0");

  issue_word_request(1'b1, 21'h00010, 32'hAA00_0000, 4'b1000);
  expect_response(32'h0000_0000, 32'h0000_0000, "write_partial_lane3");
  issue_word_request(1'b0, 21'h00010, 32'h0000_0000, 4'h0);
  expect_response(32'h0000_0000, 32'hAA22_3344, "read_partial_lane3");

  issue_word_request(1'b1, 21'h00040, 32'h5566_7788, 4'hF);
  expect_response(32'h0000_0000, 32'h0000_0000, "write_full_1");
  issue_word_request(1'b0, 21'h00040, 32'h0000_0000, 4'h0);
  expect_response(32'h0000_0000, 32'h5566_7788, "read_full_1");

  log_info("OPEN WORD TB", "checking back-to-back request ordering");
  issue_word_request(1'b1, 21'h00080, 32'h0102_0304, 4'hF);
  expect_response(32'h0000_0000, 32'h0000_0000, "write_order_0");
  issue_word_request(1'b1, 21'h00081, 32'hA0B0_C0D0, 4'hF);
  expect_response(32'h0000_0000, 32'h0000_0000, "write_order_1");
  issue_word_request(1'b0, 21'h00080, 32'h0000_0000, 4'h0);
  expect_response(32'h0000_0000, 32'h0102_0304, "read_order_0");
  issue_word_request(1'b0, 21'h00081, 32'h0000_0000, 4'h0);
  expect_response(32'h0000_0000, 32'hA0B0_C0D0, "read_order_1");

  log_info("OPEN WORD TB", "forcing byte-response error propagation");
  fork
    begin
      wait (tb_byte_rsp_valid);
      force tb_byte_rsp_status = ERR_SDRAM_RD_TO;
      @(posedge tb_clk);
      release tb_byte_rsp_status;
    end
  join_none
  issue_word_request(1'b0, 21'h00090, 32'h0000_0000, 4'h0);
  expect_response(ERR_SDRAM_RD_TO, 32'h0000_0000, "read_error_prop");

  log_info("OPEN WORD TB", "sdram_open_word_ctrl smoke test passed");
  $finish;
end
