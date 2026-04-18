initial begin : tc_smoke
  wait (tb_rst_n);

  log_info("HOSTIF OPEN TB", "checking status map is visible before init completes");
  send_text("R 0\n");
    expect_host_event(
      EVT_READ_RSP,
      32'h0000_0000,
      32'h0210_00A0,
      32'h0000_0000,
      "status_before_init"
    );

  wait (tb_test_pass || tb_test_fail);
  send_text("R 0\n");
  if (tb_test_pass) begin
    expect_host_event(
      EVT_READ_RSP,
      32'h0000_0000,
      32'h0280_0803,
      32'h0000_0000,
      "status_pass"
    );
    send_text("R 4\n");
    expect_host_event(
      EVT_READ_RSP,
      32'h0000_0004,
      32'h8A00_001F,
      32'h0000_0000,
      "memtest_summary_pass"
    );
    send_text("R 8\n");
    expect_host_event(
      EVT_READ_RSP,
      32'h0000_0008,
      32'h0000_00FF,
      32'h0000_0000,
      "final_word_index"
    );
    send_text("R 10\n");
    expect_host_event(
      EVT_READ_RSP,
      32'h0000_0010,
      32'h0000_0000,
      32'h0000_0000,
      "last_read_data_pass"
    );
    send_text("R 14\n");
    expect_host_event(
      EVT_READ_RSP,
      32'h0000_0014,
      32'h0000_0000,
      32'h0000_0000,
      "last_rsp_status_pass"
    );
    send_text("R 24\n");
    expect_host_event(
      EVT_READ_RSP,
      32'h0000_0024,
      32'h3000_0000,
      32'h0000_0000,
      "retry_summary_pass"
    );
  end else begin
    expect_host_event(
      EVT_READ_RSP,
      32'h0000_0000,
      32'h0200_0005,
      32'h0000_0000,
      "status_fail"
    );
  end

  log_info("HOSTIF OPEN TB", "checking unmapped register read range handling");
  send_text("R 40\n");
  expect_host_event(EVT_CMD_ERR, ERR_ADDR_RANGE, 32'h0000_0040, 32'h0000_0000, "addr_range");

  log_info("HOSTIF OPEN TB", "checking status map write rejection");
  send_text("W 0 11223344\n");
  expect_host_event(EVT_CMD_ERR, ERR_UNSUPPORTED, 32'h0000_0000, 32'h1122_3344, "write_rejected");

  log_info("HOSTIF OPEN TB", "checking unsupported bulk commands");
  send_text("BR 0 4\n");
  expect_host_event(EVT_CMD_ERR, ERR_UNSUPPORTED, 32'h0000_0000, 32'h0000_0004, "bulk_read_unsupported");
  send_text("BW 20 8\n");
  expect_host_event(EVT_CMD_ERR, ERR_UNSUPPORTED, 32'h0000_0020, 32'h0000_0008, "bulk_write_unsupported");

  log_info("HOSTIF OPEN TB", "checking parser error path");
  send_text("X\n");
  expect_host_event(EVT_CMD_ERR, ERR_BAD_ASCII_CMD, 32'h0000_0058, 32'h0000_0000, "bad_ascii");

  log_info("HOSTIF OPEN TB", "status-map-only host path test passed");
  $finish;
end
