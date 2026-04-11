  initial begin : tc_smoke
    logic [20:0] wr_addr;
    logic [31:0] wr_data;

    wr_addr = 21'h00030;
    wr_data = 32'h89AB_CDEF;

    @(posedge tb_rst_n);
    repeat (4) @(posedge tb_clk);

    log_info("BRIDGE CTRL TB", "case: ascii write");
    send_text($sformatf("W %05X %08X\n", wr_addr, wr_data));
    expect_event(EVT_WRITE_ACK, {11'h0, wr_addr}, wr_data, 32'h0, "write ack");

    log_info("BRIDGE CTRL TB", "case: ascii read");
    send_text($sformatf("R %05X\n", wr_addr));
    expect_event(EVT_READ_RSP, {11'h0, wr_addr}, wr_data, 32'h0, "read rsp");

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
