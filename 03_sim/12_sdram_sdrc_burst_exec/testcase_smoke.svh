  initial begin : tc_smoke
    int unsigned lengths [0:6];
    logic [31:0] pattern_base;

    lengths[0] = 1;
    lengths[1] = 2;
    lengths[2] = 3;
    lengths[3] = 4;
    lengths[4] = 8;
    lengths[5] = 26;
    lengths[6] = 256;

    @(posedge tb_rst_n);
    repeat (4) @(posedge tb_clk);

    for (int idx = 0; idx < 7; idx++) begin
      pattern_base = 32'hA500_0000 + (idx << 8);
      log_info(
        "SDRC EXEC TB",
        $sformatf("case: write/read length=%0d", lengths[idx])
      );
      issue_write(21'(idx * 16), lengths[idx], pattern_base);
      expect_rsp_status(32'h0000_0000, $sformatf("write_len_%0d", lengths[idx]));
      issue_read(21'(idx * 16), lengths[idx]);
      expect_read_stream(21'(idx * 16), lengths[idx], pattern_base, $sformatf("read_len_%0d", lengths[idx]));
    end

    log_info("SDRC EXEC TB", "case: write timeout");
    inject_next_wr_timeout = 1'b1;
    issue_write(21'h00100, 8, 32'hA5FF_0000);
    expect_rsp_status(ERR_SDRAM_WR_TO, "write_timeout");

    log_info("SDRC EXEC TB", "case: read timeout");
    inject_next_rd_timeout = 1'b1;
    issue_read(21'h00120, 8);
    expect_rsp_status(ERR_SDRAM_RD_TO, "read_timeout");

    log_info("SDRC EXEC TB", "sdram_sdrc_burst_exec smoke test passed");
    $finish;
  end
