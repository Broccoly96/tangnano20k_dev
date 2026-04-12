  initial begin : tc_smoke
    logic [20:0] wr_addr;
    logic [31:0] wr_data;
    logic [20:0] zero_addr;

    wr_addr = 21'h00012;
    wr_data = 32'h0012_A55A;
    zero_addr = 21'h000A0;

    @(posedge tb_rst_n);
    log_info("HOSTIF CTRL TB", "waiting for self-test completion");
    wait (tb_test_pass || tb_test_fail);
    if (tb_test_fail) begin
      log_fatal(1, "HOSTIF CTRL TB", "self-test finished with FAIL");
    end

    log_info("HOSTIF CTRL TB", "case: untouched location is zero after clear");
    send_text($sformatf("R %05X\n", zero_addr));
    expect_host_event(EVT_READ_RSP, {11'h0, zero_addr}, 32'h0000_0000, 32'h0, "zero-cleared read rsp");

    log_info("HOSTIF CTRL TB", "case: host single write after memtest");
    send_text($sformatf("W %05X %08X\n", wr_addr, wr_data));
    expect_host_event(EVT_WRITE_ACK, {11'h0, wr_addr}, wr_data, 32'h0, "write ack");

    log_info("HOSTIF CTRL TB", "case: host single read after memtest");
    send_text($sformatf("R %05X\n", wr_addr));
    expect_host_event(EVT_READ_RSP, {11'h0, wr_addr}, wr_data, 32'h0, "read rsp");

    log_info("HOSTIF CTRL TB", "case: unsupported bulk");
    send_text("BR 00040 00001\n");
    expect_host_event(
      EVT_CMD_ERR,
      ERR_UNSUPPORTED,
      32'h0000_0040,
      32'h0000_0001,
      "unsupported bulk"
    );

    log_info("HOSTIF CTRL TB", "sdram_emb_hostif_ctrl smoke test passed");
    $finish;
  end
