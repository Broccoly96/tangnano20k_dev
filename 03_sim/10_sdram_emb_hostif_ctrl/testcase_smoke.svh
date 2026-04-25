  initial begin : tc_smoke
    logic [31:0] summary_word;
    logic [MAX_BULK_PAYLOAD_BYTES*8-1:0] bulk_payload;

    @(posedge tb_rst_n);
    log_info("HOSTIF CTRL TB", "case: summary read is available before init");
    send_text("SR 00000\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_0000, 32'h0501_00c8, 32'h0, "pre-init summary");

    log_info("HOSTIF CTRL TB", "case: host SDRAM read is blocked before PASS");
    send_text("R 00010\n");
    expect_host_event(EVT_CMD_ERR, ERR_BUSY, 32'h0000_0010, 32'h0, "pre-pass host read busy");

    log_info("HOSTIF CTRL TB", "waiting for self-test completion");
    wait (tb_test_pass || tb_test_fail);
    if (tb_test_fail) begin
      log_fatal(1, "HOSTIF CTRL TB", "self-test finished with FAIL");
    end

    summary_word = 32'h0515_00A8;
    log_info("HOSTIF CTRL TB", "case: final summary reflects PASS");
    send_text("SR 00000\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_0000, summary_word, 32'h0, "final summary");

    log_info("HOSTIF CTRL TB", "case: linear host SDRAM write after PASS");
    send_text("W 00010 12345678\n");
    expect_host_event(EVT_WRITE_ACK, 32'h0000_0010, 32'h1234_5678, 32'h0, "linear write");

    log_info("HOSTIF CTRL TB", "case: linear host SDRAM readback after PASS");
    send_text("R 00010\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_0010, 32'h1234_5678, 32'h0, "linear readback");

    log_info("HOSTIF CTRL TB", "case: control write resets SDRC and reruns self-test");
    send_text("SW 0003C 00000001\n");
    expect_host_event(EVT_WRITE_ACK, 32'h0000_003C, 32'h0000_0001, 32'h0, "restart write ack");
    repeat (2) @(posedge tb_clk);
    if (!tb_test_active || tb_test_pass || tb_test_fail) begin
      log_fatal(
        1,
        "HOSTIF CTRL TB",
        "manual restart did not force active=1/pass=0/fail=0"
      );
    end
    wait (!tb_sdrc_rst_n);
    wait (tb_sdrc_rst_n);
    wait (tb_test_active);
    wait (tb_test_pass || tb_test_fail);
    if (tb_test_fail) begin
      log_fatal(1, "HOSTIF CTRL TB", "manual restart self-test finished with FAIL");
    end

    log_info("HOSTIF CTRL TB", "case: final summary reflects PASS after manual restart");
    send_text("SR 00000\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_0000, summary_word, 32'h0, "post-restart summary");

    log_info("HOSTIF CTRL TB", "case: retry summary stays zero on PASS");
    send_text("SR 00024\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_0024, 32'h0300_0000, 32'h0, "retry summary");

    log_info("HOSTIF CTRL TB", "case: retry data #1 stays zero on PASS");
    send_text("SR 00028\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_0028, 32'h0000_0000, 32'h0, "retry data1");

    log_info("HOSTIF CTRL TB", "case: retry data #2 stays zero on PASS");
    send_text("SR 0002C\n");
    expect_host_event(EVT_READ_RSP, 32'h0000_002C, 32'h0000_0000, 32'h0, "retry data2");

    log_info("HOSTIF CTRL TB", "case: bulk write/read round-trip after PASS");
    bulk_payload = '0;
    bulk_payload[0 +: 32] = 32'h1234_5678;
    bulk_payload[32 +: 32] = 32'h3F14_1006;
    send_text("BW 00040 00002\n");
    expect_host_event(EVT_BULK_OK, 32'h0000_0040, 32'h0000_0002, 32'h0000_0000, "bulk write ok");
    send_bulk_data_words(8'h00, bulk_payload, 2);
    expect_host_event(EVT_BULK_PROG, 32'h0000_0040, 32'h0000_0002, 32'h0000_0000, "bulk write progress");
    send_bulk_end(8'h01);
    expect_host_event(EVT_BULK_DONE, 32'h0000_0040, 32'h0000_0002, 32'h0000_0002, "bulk write done");

    send_text("BR 00040 00002\n");
    expect_host_event(EVT_BULK_OK, 32'h0000_0040, 32'h0000_0002, 32'h0000_0001, "bulk read ok");
    expect_host_event(EVT_BULK_PROG, 32'h0040_0040, 32'h1234_5678, 32'h3F14_1006, "bulk read data");
    expect_host_event(EVT_BULK_DONE, 32'h0000_0040, 32'h0000_0002, 32'h0000_0002, "bulk read done");

    log_info("HOSTIF CTRL TB", "sdram_emb_hostif_ctrl smoke test passed");
    $finish;
  end
