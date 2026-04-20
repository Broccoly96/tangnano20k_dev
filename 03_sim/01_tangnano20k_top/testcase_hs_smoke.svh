//////////////////////////////////////////////////////////////////////////////////
// File         : testcase_hs_smoke.svh
// Description  : Single-scenario HS startup self-test and refresh smoke.
//////////////////////////////////////////////////////////////////////////////////

initial begin
  tb_log_pkg::log_info("TOP HS SMOKE", "start HS integration smoke");

  repeat (3000) begin
    @(posedge tb_clk);
    if (tb_test_pass || tb_test_fail) begin
      break;
    end
  end

  if (!tb_test_pass || tb_test_fail) begin
    tb_log_pkg::log_fatal(
      1,
      "TOP HS SMOKE",
      $sformatf(
        "self-test did not pass pass=%0b fail=%0b cmd_count=%0d reason=0x%02h exp=0x%08h act=0x%08h",
        tb_test_pass,
        tb_test_fail,
        s_cmd_count,
        u_sdram_emb_hostif_ctrl.l_memtest_fail_reason,
        u_sdram_emb_hostif_ctrl.l_memtest_fail_expected,
        u_sdram_emb_hostif_ctrl.l_memtest_fail_actual
      )
    );
  end

  tb_log_pkg::log_info(
    "TOP HS SMOKE",
    $sformatf("self-test passed after %0d HS commands", s_cmd_count)
  );

  repeat (900) @(posedge tb_clk);

  if (s_refresh_count == 0) begin
    tb_log_pkg::log_fatal(1, "TOP HS SMOKE", "AUTO_REFRESH was not observed");
  end

  tb_log_pkg::log_info(
    "TOP HS SMOKE",
    $sformatf("observed %0d AUTO_REFRESH command(s)", s_refresh_count)
  );
  tb_log_pkg::log_info("TOP HS SMOKE", "PASS");
  $finish;
end
