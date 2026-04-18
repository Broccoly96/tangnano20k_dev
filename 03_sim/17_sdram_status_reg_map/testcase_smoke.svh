initial begin : tc_smoke
  #1;

  if (tb_rd_data !== 32'h0200_0000) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("reset map mismatch 0x%08h", tb_rd_data));
  end

  tb_init_done              = 1'b1;
  tb_test_active            = 1'b1;
  tb_test_fail              = 1'b1;
  tb_host_busy              = 1'b1;
  tb_memtest_summary        = 32'h6789_ABCD;
  tb_memtest_curr_word_addr = 32'h0000_0123;
  tb_memtest_expected_word  = 32'h1122_3344;
  tb_memtest_last_rd_data   = 32'h5566_7788;
  tb_memtest_last_rsp_status= 32'h0000_0003;
  tb_memtest_fail_arg0      = 32'h0000_0123;
  tb_memtest_fail_arg1      = 32'h1122_3344;
  tb_memtest_fail_arg2      = 32'h5566_7788;
  tb_memtest_fail_ctx_arg0  = 32'h3213_0002;
  tb_memtest_fail_ctx_arg1  = 32'hA5A5_A5A5;
  tb_memtest_fail_ctx_arg2  = 32'h5A5A_5A5A;
  tb_word_ctrl_summary      = 32'h9234_5678;
  tb_word_ctrl_data         = 32'hCAFE_BABE;
  tb_byte_ctrl_summary      = 32'hA765_4321;
  tb_byte_ctrl_detail       = 32'h0011_2233;
  #1;

  if (tb_rd_data !== 32'h0263_A85D) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("summary word mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0003;
  #1;
  if (tb_rd_data !== 32'h0263_A85D) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("byte-lane alias mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0004;
  #1;
  if (tb_rd_data !== 32'h6789_ABCD) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("memtest summary mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0008;
  #1;
  if (tb_rd_data !== 32'h0000_0123) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("current address mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h000C;
  #1;
  if (tb_rd_data !== 32'h1122_3344) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("expected word mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0010;
  #1;
  if (tb_rd_data !== 32'h5566_7788) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("last read data mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0014;
  #1;
  if (tb_rd_data !== 32'h0000_0003) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("last response status mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0018;
  #1;
  if (tb_rd_data !== 32'h0000_0123) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("fail arg0 mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h001C;
  #1;
  if (tb_rd_data !== 32'h1122_3344) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("fail arg1 mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0020;
  #1;
  if (tb_rd_data !== 32'h5566_7788) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("fail arg2 mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0024;
  #1;
  if (tb_rd_data !== 32'h3213_0002) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("fail ctx arg0 mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0028;
  #1;
  if (tb_rd_data !== 32'hA5A5_A5A5) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("fail ctx arg1 mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h002C;
  #1;
  if (tb_rd_data !== 32'h5A5A_5A5A) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("fail ctx arg2 mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0030;
  #1;
  if (tb_rd_data !== 32'h9234_5678) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("word summary mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0034;
  #1;
  if (tb_rd_data !== 32'hCAFE_BABE) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("word data mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0038;
  #1;
  if (tb_rd_data !== 32'hA765_4321) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("byte summary mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h003C;
  #1;
  if (tb_rd_data !== 32'h0011_2233) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("byte detail mismatch 0x%08h", tb_rd_data));
  end

  tb_addr = 16'h0040;
  #1;
  if (tb_rd_data !== 32'h0000_0000) begin
    log_fatal(1, "STATUS REG MAP TB", $sformatf("range clamp mismatch 0x%08h", tb_rd_data));
  end

  log_info("STATUS REG MAP TB", "status register map smoke test passed");
  $finish;
end
