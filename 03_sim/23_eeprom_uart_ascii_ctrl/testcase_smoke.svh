initial begin : tc_smoke
  @(posedge tb_rst_n);

  log_info("EEPROM ASCII TB", "case: random read command decodes");
  send_text("R 00123\n");
  expect_cmd(ASCII_OP_READ, 1'b0, 17'h00123, 8'h00, 17'h00000, "random read");

  log_info("EEPROM ASCII TB", "case: byte write with 2 hex digits decodes");
  send_text("W 00123 7F\n");
  expect_cmd(ASCII_OP_WRITE, 1'b0, 17'h00123, 8'h7F, 17'h00000, "byte write 2 hex");

  log_info("EEPROM ASCII TB", "case: byte write with 8 hex digits uses low byte");
  send_text("W 00124 000000A5\n");
  expect_cmd(ASCII_OP_WRITE, 1'b0, 17'h00124, 8'hA5, 17'h00000, "byte write 8 hex");

  log_info("EEPROM ASCII TB", "case: bulk read uses byte count");
  send_text("BR 01000 00040\n");
  expect_cmd(ASCII_OP_BULK, 1'b1, 17'h01000, 8'h00, 17'h00040, "bulk read");

  log_info("EEPROM ASCII TB", "case: bulk write uses byte count");
  send_text("BW 01080 00080\n");
  expect_cmd(ASCII_OP_BULK, 1'b0, 17'h01080, 8'h00, 17'h00080, "bulk write");

  log_info("EEPROM ASCII TB", "case: out-of-range address is rejected");
  send_text("R 20000\n");
  expect_err(ERR_ADDR_RANGE, 32'h0002_0000, "addr range");

  log_info("EEPROM ASCII TB", "case: unsupported command is rejected");
  send_text("SR 00000\n");
  expect_err(ERR_BAD_ASCII_CMD, 32'h0000_0053, "bad command");

  log_info("EEPROM ASCII TB", "eeprom_uart_ascii_ctrl smoke test passed");
  $finish;
end