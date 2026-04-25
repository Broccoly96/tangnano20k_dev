  initial begin : tc_smoke
    @(posedge tb_src_rst_n);
    @(posedge tb_dst_rst_n);
    wait_for_src_ready("after reset");

    log_info("CLI BYTE CDC TB", "case: realistic UART-spaced bytes cross domains in order");
    send_source_byte(8'h53, 64);
    expect_dst_byte(8'h53, "byte S");
    wait_for_src_ready("after byte S");

    send_source_byte(8'h52, 64);
    expect_dst_byte(8'h52, "byte R");
    wait_for_src_ready("after byte R");

    send_source_byte(8'h0A, 64);
    expect_dst_byte(8'h0A, "byte LF");
    wait_for_src_ready("after byte LF");

    log_info("CLI BYTE CDC TB", "case: destination backpressure holds the byte stable");
    tb_dst_ready = 1'b0;
    send_source_byte(8'h41, 64);
    wait_for_dst_valid("backpressure byte");
    if (tb_dst_data !== 8'h41) begin
      log_fatal(1, "CLI BYTE CDC TB", $sformatf("backpressure data mismatch got=0x%02h", tb_dst_data));
    end
    repeat (6) begin
      @(posedge tb_dst_clk);
      if (!tb_dst_valid || (tb_dst_data !== 8'h41)) begin
        log_fatal(1, "CLI BYTE CDC TB", "byte changed while destination not ready");
      end
    end
    if (tb_src_ready) begin
      log_fatal(1, "CLI BYTE CDC TB", "src_ready reasserted before destination accepted byte");
    end
    tb_dst_ready = 1'b1;
    @(posedge tb_dst_clk);
    @(posedge tb_dst_clk);
    if (tb_dst_valid) begin
      log_fatal(1, "CLI BYTE CDC TB", "dst_valid did not clear after backpressure release");
    end
    wait_for_src_ready("after backpressure release");

    log_info("CLI BYTE CDC TB", "case: sequential command bytes preserve order");
    send_source_byte(8'h42, 64);
    expect_dst_byte(8'h42, "byte B");
    wait_for_src_ready("after byte B");
    send_source_byte(8'h57, 64);
    expect_dst_byte(8'h57, "byte W");
    wait_for_src_ready("after byte W");
    send_source_byte(8'h20, 64);
    expect_dst_byte(8'h20, "byte space");
    wait_for_src_ready("after byte space");

    log_info("CLI BYTE CDC TB", "uart_log_cli_byte_async_bridge smoke test passed");
    $finish;
  end