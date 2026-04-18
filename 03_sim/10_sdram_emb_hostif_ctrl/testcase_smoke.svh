  initial begin : tc_smoke
    logic [31:0] summary_word;

    @(posedge tb_rst_n);
    log_info("HOSTIF CTRL TB", "case: summary read is available before init");
    send_text("R 00000\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_0000, 32'h0300_0080, 32'h0, "pre-init summary");

    log_info("HOSTIF CTRL TB", "waiting for self-test completion");
    wait (tb_test_pass || tb_test_fail);
    if (tb_test_fail) begin
      log_fatal(1, "HOSTIF CTRL TB", "self-test finished with FAIL");
    end

    summary_word = 32'h030D_00A8;
    log_info("HOSTIF CTRL TB", "case: final summary reflects PASS");
    send_text("R 00000\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_0000, summary_word, 32'h0, "final summary");

    log_info("HOSTIF CTRL TB", "case: retry summary stays zero on PASS");
    send_text("R 00024\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_0024, 32'h0300_0000, 32'h0, "retry summary");

    log_info("HOSTIF CTRL TB", "case: retry data #1 stays zero on PASS");
    send_text("R 00028\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_0028, 32'h0000_0000, 32'h0, "retry data1");

    log_info("HOSTIF CTRL TB", "case: retry data #2 stays zero on PASS");
    send_text("R 0002C\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_002C, 32'h0000_0000, 32'h0, "retry data2");

    log_info("HOSTIF CTRL TB", "case: host write is unsupported");
    send_text("W 00010 12345678\n");
    expect_host_event(EVT_CMD_ERR, ERR_UNSUPPORTED, 32'h0000_0010, 32'h1234_5678, "write unsupported");

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
