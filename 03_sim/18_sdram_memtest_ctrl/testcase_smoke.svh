initial begin : tc_smoke
  wait (tb_rst_n);
  wait (tb_test_pass);

  if (tb_dbg_fail_arg0 !== 32'h0000_0000) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-recovery address debug mismatch");
  end

  if (tb_dbg_fail_arg1 !== 32'h0000_0000) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-recovery expected-data debug mismatch");
  end

  if (tb_dbg_fail_arg2 !== 32'hFFFF_FFFF) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-recovery first readback mismatch");
  end

  if (tb_dbg_fail_ctx_arg1 !== 32'hFFFF_FFFF) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-recovery retry #1 mismatch");
  end

  if (tb_dbg_fail_ctx_arg0[14] !== 1'b1) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-recovery flag missing");
  end

  if (tb_dbg_fail_ctx_arg0[27:24] !== 4'h2) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-recovery count mismatch");
  end

  if (tb_dbg_fail_ctx_arg0[3:0] !== 4'h2) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-recovery reason mismatch");
  end

  log_info("MEMTEST CTRL TB", "retry-recovery run passed");

  r_run_index = 1;
  tb_rst_n    = 1'b0;
  tb_init_done= 1'b0;
  repeat (8) @(posedge tb_clk);
  tb_rst_n     = 1'b1;
  tb_init_done = 1'b1;

  wait (tb_test_fail);

  if (tb_dbg_fail_arg2 !== 32'hFFFF_FFFF) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-exhaust first readback mismatch");
  end

  if (tb_dbg_fail_ctx_arg1 !== 32'hFFFF_FFFF) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-exhaust retry #1 mismatch");
  end

  if (tb_dbg_fail_ctx_arg2 !== 32'hFFFF_FFFF) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-exhaust retry #2 mismatch");
  end

  if (tb_dbg_last_rd_data !== 32'hFFFF_FFFF) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-exhaust final readback mismatch");
  end

  if (tb_dbg_fail_ctx_arg0[13] !== 1'b1) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-exhaust flag missing");
  end

  if (tb_dbg_fail_ctx_arg0[27:24] !== 4'h3) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-exhaust count mismatch");
  end

  if (tb_dbg_fail_ctx_arg0[3:0] !== 4'h2) begin
    log_fatal(1, "MEMTEST CTRL TB", "retry-exhaust reason mismatch");
  end

  log_info("MEMTEST CTRL TB", "retry-exhaust run passed");
  $finish;
end
