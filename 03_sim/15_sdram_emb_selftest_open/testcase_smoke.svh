initial begin : tc_smoke
  wait (tb_rst_n);
  wait (tb_test_pass);
  log_info("SELFTEST OPEN TB", "first run passed and covered refresh-stress sweep");

  tb_run_index = 1;
  tb_rst_n <= 1'b0;
  repeat (32) @(posedge tb_clk);
  tb_rst_n <= 1'b1;

  wait (tb_test_active);
  wait (!u_dut.l_mem_req_is_write);
  wait (u_dut.l_byte_rsp_valid);
  force u_dut.l_byte_rsp_status = 32'h0000_0003;
  @(posedge tb_clk);
  release u_dut.l_byte_rsp_status;

  wait (tb_test_fail);
  wait (tb_evt_fail_count >= 2);
  wait (tb_evt_fail_ctx_count >= 2);

  log_info("SELFTEST OPEN TB", "forced fail path and fail replay verified");
  $finish;
end
