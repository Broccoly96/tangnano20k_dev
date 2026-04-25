initial begin : tc_smoke
  logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] wr_payload;
  logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] rd_expect;

  @(posedge tb_rst_n);

  log_info("EEPROM ACCESS TB", "case: single byte write completes after ACK polling");
  issue_request(1'b1, 1'b0, 17'h00123, 8'd1, 832'(8'h7F));
  expect_single_event(EVT_WRITE_ACK, 17'h00123, 32'h0000_007F, 32'h0000_0000, "single write");

  log_info("EEPROM ACCESS TB", "case: random read returns the written byte");
  issue_request(1'b0, 1'b0, 17'h00123, 8'd1, '0);
  expect_single_event(EVT_READ_RSP, 17'h00123, 32'h0000_007F, 32'h0000_0000, "single read");

  wr_payload = '0;
  wr_payload[0 +: 8] = 8'h11;
  wr_payload[8 +: 8] = 8'h22;
  wr_payload[16 +: 8] = 8'h33;
  wr_payload[24 +: 8] = 8'h44;
  wr_payload[32 +: 8] = 8'h55;
  wr_payload[40 +: 8] = 8'h66;

  log_info("EEPROM ACCESS TB", "case: page write chunk stores sequential bytes");
  issue_request(1'b1, 1'b1, 17'h01010, 8'd6, wr_payload);
  expect_raw_done("raw page write");

  rd_expect = '0;
  rd_expect[0 +: 8] = 8'h11;
  rd_expect[8 +: 8] = 8'h22;
  rd_expect[16 +: 8] = 8'h33;
  rd_expect[24 +: 8] = 8'h44;
  rd_expect[32 +: 8] = 8'h55;
  rd_expect[40 +: 8] = 8'h66;

  log_info("EEPROM ACCESS TB", "case: sequential read returns the written byte stream");
  issue_request(1'b0, 1'b1, 17'h01010, 8'd6, '0);
  expect_raw_done("raw sequential read");
  if (tb_raw_rd_data[47:0] != rd_expect[47:0]) begin
    log_fatal(
      1,
      "EEPROM ACCESS TB",
      $sformatf("raw read mismatch got=0x%012h exp=0x%012h", tb_raw_rd_data[47:0], rd_expect[47:0])
    );
  end

  log_info("EEPROM ACCESS TB", "case: raw page write rejects page crossing");
  issue_request(1'b1, 1'b1, 17'h0007E, 8'd4, wr_payload);
  expect_raw_err(ERR_ADDR_RANGE, "page cross reject");

  log_info("EEPROM ACCESS TB", "case: raw sequential read rejects block crossing");
  issue_request(1'b0, 1'b1, 17'h0FFFE, 8'd4, '0);
  expect_raw_err(ERR_ADDR_RANGE, "block cross reject");

  log_info("EEPROM ACCESS TB", "eeprom_i2c_access_engine smoke test passed");
  $finish;
end