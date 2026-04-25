  initial begin : tc_sweep
    int unsigned burst_lengths [0:14];
    logic [20:0] req_addr;
    logic [31:0] start_data;

    burst_lengths[0]  = 1;
    burst_lengths[1]  = 2;
    burst_lengths[2]  = 4;
    burst_lengths[3]  = 8;
    burst_lengths[4]  = 16;
    burst_lengths[5]  = 24;
    burst_lengths[6]  = 26;
    burst_lengths[7]  = 32;
    burst_lengths[8]  = 48;
    burst_lengths[9]  = 64;
    burst_lengths[10] = 96;
    burst_lengths[11] = 128;
    burst_lengths[12] = 192;
    burst_lengths[13] = 255;
    burst_lengths[14] = 256;

    tb_log_pkg::log_info(
      "SDRAM BURST SWEEP TB",
      "waiting for SDRAM initialization to complete"
    );
    sdrc_wait_init(tb_clk_24m, tb_sdrc_init_done, 32);

    for (int sweep_idx = 0; sweep_idx <= 14; sweep_idx++) begin
      req_addr = 21'(sweep_idx * 21'h00100);
      start_data = 32'h7100_0000 + (sweep_idx * 32'h0001_0000);

      for (int word_idx = 0; word_idx < burst_lengths[sweep_idx]; word_idx++) begin
        exp_words[word_idx] = start_data + word_idx;
      end

      tb_log_pkg::log_info(
        "SDRAM BURST SWEEP TB",
        $sformatf(
          "sweep burst_words=%0d addr=0x%05h start=0x%08h",
          burst_lengths[sweep_idx],
          req_addr,
          start_data
        )
      );

      sdrc_issue_write_burst(
        tb_clk_24m,
        tb_sdrc_busy_n,
        tb_sdrc_wr_n,
        tb_sdrc_rd_n,
        tb_sdrc_addr,
        tb_sdrc_data_len,
        tb_sdrc_dqm,
        tb_sdrc_wr_data,
        req_addr,
        burst_lengths[sweep_idx] - 1,
        start_data
      );

      sdrc_issue_read_burst(
        tb_clk_24m,
        tb_sdrc_busy_n,
        tb_sdrc_wr_n,
        tb_sdrc_rd_n,
        tb_sdrc_addr,
        tb_sdrc_data_len,
        tb_sdrc_dqm,
        req_addr,
        burst_lengths[sweep_idx] - 1
      );

      sdrc_expect_read_words(
        tb_clk_24m,
        tb_sdrc_rd_valid,
        tb_sdrc_rd_data,
        exp_words,
        burst_lengths[sweep_idx],
        burst_lengths[sweep_idx] + 400,
        $sformatf("burst sweep len=%0d", burst_lengths[sweep_idx])
      );

      sdrc_wait_idle(tb_clk_24m, tb_sdrc_busy_n);
    end

    tb_log_pkg::log_info(
      "SDRAM BURST SWEEP TB",
      "all burst length sweep scenarios passed"
    );
    $finish;
  end
