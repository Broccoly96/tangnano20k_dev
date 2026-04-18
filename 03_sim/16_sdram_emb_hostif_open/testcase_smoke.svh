initial begin : tc_smoke
  wait (tb_rst_n);

  log_info("HOSTIF OPEN TB", "checking host access is blocked before memtest pass");
  send_text("R 0\n");
  repeat (128) @(posedge tb_clk);
  if (tb_host_evt_valid || tb_host_busy) begin
    log_fatal(1, "HOSTIF OPEN TB", "host path responded before memtest completed");
  end

  wait (tb_test_pass || tb_test_fail);
  if (tb_test_fail) begin
    log_fatal(1, "HOSTIF OPEN TB", "boot memtest failed unexpectedly");
  end

  send_text("W 0 11223344\n");
  expect_host_event(EVT_WRITE_ACK, 32'h0000_0000, 32'h1122_3344, 32'h0000_0000, "write_low");
  send_text("R 0\n");
  expect_host_event(EVT_READ_RSP, 32'h0000_0000, 32'h1122_3344, 32'h0000_0000, "read_low");

  send_text("W 100 AABBCCDD\n");
  expect_host_event(EVT_WRITE_ACK, 32'h0000_0100, 32'hAABB_CCDD, 32'h0000_0000, "write_mid");
  send_text("R 100\n");
  expect_host_event(EVT_READ_RSP, 32'h0000_0100, 32'hAABB_CCDD, 32'h0000_0000, "read_mid");

  send_text("W 1F00 55667788\n");
  expect_host_event(EVT_WRITE_ACK, 32'h0000_1F00, 32'h5566_7788, 32'h0000_0000, "write_high");
  send_text("R 1F00\n");
  expect_host_event(EVT_READ_RSP, 32'h0000_1F00, 32'h5566_7788, 32'h0000_0000, "read_high");

  log_info("HOSTIF OPEN TB", "checking repeated overwrite/readback on one address");
  send_text("W 100 01020304\n");
  expect_host_event(EVT_WRITE_ACK, 32'h0000_0100, 32'h0102_0304, 32'h0000_0000, "rewrite_mid");
  send_text("R 100\n");
  expect_host_event(EVT_READ_RSP, 32'h0000_0100, 32'h0102_0304, 32'h0000_0000, "reread_mid");

  log_info("HOSTIF OPEN TB", "checking unsupported bulk commands");
  send_text("BR 0 4\n");
  expect_host_event(EVT_CMD_ERR, ERR_UNSUPPORTED, 32'h0000_0000, 32'h0000_0004, "bulk_read_unsupported");
  send_text("BW 20 8\n");
  expect_host_event(EVT_CMD_ERR, ERR_UNSUPPORTED, 32'h0000_0020, 32'h0000_0008, "bulk_write_unsupported");

  log_info("HOSTIF OPEN TB", "checking parser error path");
  send_text("X\n");
  expect_host_event(EVT_CMD_ERR, ERR_BAD_ASCII_CMD, 32'h0000_0058, 32'h0000_0000, "bad_ascii");

  log_info("HOSTIF OPEN TB", "checking busy rejection while a command is in flight");
  send_text("W 40 0A0B0C0D\n");
  repeat (4) @(posedge tb_clk);
  send_text("W 44 01010101\n");
  expect_host_event(EVT_CMD_ERR, ERR_BUSY, 32'h0000_0044, 32'h0000_0000, "busy_reject");
  expect_host_event(EVT_WRITE_ACK, 32'h0000_0040, 32'h0A0B_0C0D, 32'h0000_0000, "busy_primary_write");

  log_info("HOSTIF OPEN TB", "sdram_emb_hostif integrated host path test passed");
  $finish;
end
