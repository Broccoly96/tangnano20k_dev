  initial begin : tc_smoke
    int restart_count_before;

    @(posedge tb_rst_n);
    repeat (4) @(posedge tb_clk);

    log_info("BRIDGE CTRL TB", "case: aligned status read");
    send_text("R 00000\n");
    expect_event(EVT_READ_RSP, 32'h0000_0000, 32'h0300_0008, 32'h0, "summary read rsp");

    log_info("BRIDGE CTRL TB", "case: second status word read");
    send_text("R 00004\n");
    expect_event(EVT_READ_RSP, 32'h0000_0004, 32'hABCD_1234, 32'h0, "summary2 read rsp");

    log_info("BRIDGE CTRL TB", "case: unaligned read is rejected");
    send_text("R 00002\n");
    expect_event(EVT_CMD_ERR, ERR_ADDR_RANGE, 32'h0000_0002, 32'h0000_0040, "unaligned read");

    log_info("BRIDGE CTRL TB", "case: out-of-range read is rejected");
    send_text("R 00040\n");
    expect_event(EVT_CMD_ERR, ERR_ADDR_RANGE, 32'h0000_0040, 32'h0000_0040, "range read");

    log_info("BRIDGE CTRL TB", "case: control write restarts selftest");
    restart_count_before = tb_restart_count;
    send_text("W 0003C 00000001\n");
    expect_event(EVT_WRITE_ACK, 32'h0000_003C, 32'h0000_0001, 32'h0, "restart write ack");
    expect_restart_count_changed(restart_count_before, "restart write");

    log_info("BRIDGE CTRL TB", "case: ascii write is unsupported");
    send_text("W 00010 12345678\n");
    expect_event(EVT_CMD_ERR, ERR_UNSUPPORTED, 32'h0000_0010, 32'h1234_5678, "write unsupported");

    log_info("BRIDGE CTRL TB", "case: invalid command");
    send_text("X\n");
    expect_event(EVT_CMD_ERR, ERR_BAD_ASCII_CMD, 32'h0000_0058, 32'h0, "bad command");

    log_info("BRIDGE CTRL TB", "case: unsupported bulk");
    send_text("BR 00040 00001\n");
    expect_event(
      EVT_CMD_ERR,
      ERR_UNSUPPORTED,
      32'h0000_0040,
      32'h0000_0001,
      "unsupported bulk"
    );

    log_info("BRIDGE CTRL TB", "sdram_uart_bridge_ctrl smoke test passed");
    $finish;
  end
