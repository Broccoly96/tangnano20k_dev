  initial begin : tc_smoke
    int restart_count_before;

    @(posedge tb_rst_n);
    repeat (4) @(posedge tb_clk);

    log_info("BRIDGE CTRL TB", "case: aligned status read");
    send_text("SR 00000\n");
    expect_event(EVT_READ_RSP, 32'h0000_0000, 32'h0300_0008, 32'h0, "summary read rsp");

    log_info("BRIDGE CTRL TB", "case: second status word read");
    send_text("SR 00004\n");
    expect_event(EVT_READ_RSP, 32'h0000_0004, 32'hABCD_1234, 32'h0, "summary2 read rsp");

    log_info("BRIDGE CTRL TB", "case: unaligned read is rejected");
    send_text("SR 00002\n");
    expect_event(EVT_CMD_ERR, ERR_ADDR_RANGE, 32'h0000_0002, 32'h0000_004C, "unaligned read");

    log_info("BRIDGE CTRL TB", "case: out-of-range read is rejected");
    send_text("SR 000B4\n");
    expect_event(EVT_CMD_ERR, ERR_ADDR_RANGE, 32'h0000_00B4, 32'h0000_004C, "range read");

    log_info("BRIDGE CTRL TB", "case: control write restarts selftest");
    restart_count_before = tb_restart_count;
    send_text("SW 0003C 00000001\n");
    expect_event(EVT_WRITE_ACK, 32'h0000_003C, 32'h0000_0001, 32'h0, "restart write ack");
    expect_restart_count_changed(restart_count_before, "restart write");

    log_info("BRIDGE CTRL TB", "case: unsupported status write");
    send_text("SW 00040 DEADBEEF\n");
    expect_event(EVT_CMD_ERR, ERR_UNSUPPORTED, 32'h0000_0040, 32'hDEAD_BEEF, "unsupported status write");

    log_info("BRIDGE CTRL TB", "case: event FIFO preserves order under backpressure");
    send_text("SR 00000\n");
    repeat (6) @(posedge tb_clk);
    send_text("SR 00004\n");
    expect_event(EVT_READ_RSP, 32'h0000_0000, 32'h0300_0008, 32'h0, "backpressure read 0");
    expect_event(EVT_READ_RSP, 32'h0000_0004, 32'hABCD_1234, 32'h0, "backpressure read 1");

    log_info("BRIDGE CTRL TB", "case: linear SDRAM read");
    send_text("R 00010\n");
    expect_event(EVT_READ_RSP, 32'h0000_0010, 32'h2000_0010, 32'h0, "linear read");

    log_info("BRIDGE CTRL TB", "case: linear SDRAM write");
    send_text("W 00010 12345678\n");
    expect_event(EVT_WRITE_ACK, 32'h0000_0010, 32'h1234_5678, 32'h0, "linear write ack");

    log_info("BRIDGE CTRL TB", "case: linear SDRAM readback after write");
    send_text("R 00010\n");
    expect_event(EVT_READ_RSP, 32'h0000_0010, 32'h1234_5678, 32'h0, "linear readback");

    log_info("BRIDGE CTRL TB", "case: host access disabled returns busy");
    tb_host_access_enable = 1'b0;
    send_text("R 00010\n");
    expect_event(EVT_CMD_ERR, ERR_BUSY, 32'h0000_0010, 32'h0, "read busy");
    tb_host_access_enable = 1'b1;

    log_info("BRIDGE CTRL TB", "case: invalid command");
    send_text("X\n");
    expect_event(EVT_CMD_ERR, ERR_BAD_ASCII_CMD, 32'h0000_0058, 32'h0, "bad command");

    log_info("BRIDGE CTRL TB", "case: unsupported bulk");
    send_text("BR 00040 00001\n");
    expect_event(
      EVT_CMD_ERR,
      ERR_UNSUPPORTED,
      32'h0000_0000,
      32'h0000_0000,
      "unsupported bulk"
    );

    log_info("BRIDGE CTRL TB", "case: unsupported bulk write");
    send_text("BW 00040 00001\n");
    expect_event(
      EVT_CMD_ERR,
      ERR_UNSUPPORTED,
      32'h0000_0000,
      32'h0000_0000,
      "unsupported bulk write"
    );

    log_info("BRIDGE CTRL TB", "case: burst zero length is rejected");
    send_text("BRT 00100 00000\n");
    expect_event(EVT_BULK_ERR, ERR_WORD_COUNT, 32'h0000_0100, 32'h8000_0000, "burst zero length");

    log_info("BRIDGE CTRL TB", "case: burst length 257 is rejected");
    send_text("BWT 00100 00101\n");
    expect_event(EVT_BULK_ERR, ERR_WORD_COUNT, 32'h0000_0100, 32'h0000_0101, "burst length 257");

    log_info("BRIDGE CTRL TB", "case: burst write test");
    send_text("BWT 00100 00004\n");
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_0004, 32'h0000_0000, "burst write done");

    log_info("BRIDGE CTRL TB", "case: burst read test");
    send_text("BRT 00100 00004\n");
    expect_event(EVT_BURST_DATA, 32'h0002_0002, 32'h0000_0000, 32'h0000_0001, "burst data 0");
    expect_event(EVT_BURST_DATA, 32'h0102_0202, 32'h0000_0002, 32'h0000_0003, "burst data 1");
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_0004, 32'h8000_0002, "burst read done");

    log_info("BRIDGE CTRL TB", "case: burst page crossing error");
    send_text("BRT 000F8 00010\n");
    expect_event(EVT_BULK_ERR, ERR_ADDR_RANGE, 32'h0000_00F8, 32'h8000_0010, "burst page cross");

    log_info("BRIDGE CTRL TB", "sdram_uart_bridge_ctrl smoke test passed");
    $finish;
  end
