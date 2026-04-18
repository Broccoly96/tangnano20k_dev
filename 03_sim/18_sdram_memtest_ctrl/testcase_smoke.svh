  initial begin : tc_smoke
    reset_case(SC_PASS);
    wait_done("pass case");
    if (!tb_test_pass || tb_test_fail) begin
      log_fatal(1, "MEMTEST TB", "pass case did not end in PASS");
    end
    if (tb_dbg_retry_summary !== 32'h0300_0000) begin
      log_fatal(1, "MEMTEST TB", $sformatf("unexpected retry summary for PASS: 0x%08h", tb_dbg_retry_summary));
    end

    reset_case(SC_RECOVER);
    wait_done("recover case");
    if (!tb_test_pass || tb_test_fail) begin
      log_fatal(1, "MEMTEST TB", "recover case did not end in PASS");
    end
    if (tb_dbg_retry_summary !== 32'h0301_02A3) begin
      log_fatal(1, "MEMTEST TB", $sformatf("unexpected retry summary for RECOVER: 0x%08h", tb_dbg_retry_summary));
    end
    if (tb_dbg_fail_actual !== CORRUPT_DATA) begin
      log_fatal(1, "MEMTEST TB", "recover case did not latch first failing data");
    end
    if (tb_dbg_retry_data1 !== 32'h0000_0000) begin
      log_fatal(1, "MEMTEST TB", "recover case did not record retry#1 readback");
    end

    reset_case(SC_EXHAUST);
    wait_done("exhaust case");
    if (!tb_test_fail || tb_test_pass) begin
      log_fatal(1, "MEMTEST TB", "exhaust case did not end in FAIL");
    end
    if (tb_dbg_retry_summary !== 32'h0303_0463) begin
      log_fatal(1, "MEMTEST TB", $sformatf("unexpected retry summary for EXHAUST: 0x%08h", tb_dbg_retry_summary));
    end
    if (tb_dbg_retry_data1 !== CORRUPT_DATA || tb_dbg_retry_data2 !== CORRUPT_DATA) begin
      log_fatal(1, "MEMTEST TB", "exhaust case did not capture retry readbacks");
    end

    reset_case(SC_TIMEOUT);
    wait_done("timeout case");
    if (!tb_test_fail || tb_test_pass) begin
      log_fatal(1, "MEMTEST TB", "timeout case did not end in FAIL");
    end
    if (tb_dbg_fail_reason !== 8'h01) begin
      log_fatal(1, "MEMTEST TB", $sformatf("unexpected fail reason for TIMEOUT: 0x%02h", tb_dbg_fail_reason));
    end

    log_info("MEMTEST TB", "sdram_memtest_ctrl retry/debug smoke test passed");
    $finish;
  end
