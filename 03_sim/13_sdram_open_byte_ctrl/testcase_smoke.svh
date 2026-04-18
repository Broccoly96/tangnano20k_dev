initial begin : tc_smoke
  wait (tb_rst_n);
  wait (tb_init_done);
  log_info("OPEN BYTE TB", "controller init completed");

  issue_write_byte(23'h000010, 8'h11);
  issue_write_byte(23'h000011, 8'h22);
  issue_write_byte(23'h000012, 8'h33);
  issue_write_byte(23'h000013, 8'h44);
  issue_read_byte(23'h000010, 8'h11);
  issue_read_byte(23'h000011, 8'h22);
  issue_read_byte(23'h000012, 8'h33);
  issue_read_byte(23'h000013, 8'h44);

  log_info("OPEN BYTE TB", "verifying single-byte overwrite preserves neighbors");
  issue_write_byte(23'h000020, 8'hA1);
  issue_write_byte(23'h000021, 8'hB2);
  issue_write_byte(23'h000022, 8'hC3);
  issue_write_byte(23'h000023, 8'hD4);
  issue_write_byte(23'h000021, 8'h5A);
  issue_read_byte(23'h000020, 8'hA1);
  issue_read_byte(23'h000021, 8'h5A);
  issue_read_byte(23'h000022, 8'hC3);
  issue_read_byte(23'h000023, 8'hD4);

  log_info("OPEN BYTE TB", "forcing reset during in-flight request");
  while (!tb_req_ready) @(posedge tb_clk);
  @(posedge tb_clk);
  tb_req_valid    <= 1'b1;
  tb_req_is_write <= 1'b0;
  tb_req_addr     <= 23'h000030;
  @(posedge tb_clk);
  tb_req_valid    <= 1'b0;
  tb_req_is_write <= 1'b0;
  tb_req_addr     <= '0;
  repeat (2) @(posedge tb_clk);
  tb_rst_n <= 1'b0;
  repeat (16) @(posedge tb_clk);
  tb_rst_n <= 1'b1;
  wait (tb_init_done);

  issue_write_byte(23'h000030, 8'h9C);
  issue_read_byte(23'h000030, 8'h9C);

  repeat (1000) @(posedge tb_clk);
  if (tb_refresh_count == 0) begin
    log_fatal(1, "OPEN BYTE TB", "refresh scheduler never issued a refresh");
  end

  log_info("OPEN BYTE TB", "sdram_open_byte_ctrl smoke test passed");
  $finish;
end
