  initial begin : tc_probe
    logic [31:0] exp_words [0:25];
    logic [20:0] req_addr;
    logic [31:0] start_data;

    tb_log_pkg::log_info(
      "SDRAM UI PROBE 24_96 TB",
      "waiting for SDRAM initialization to complete"
    );
    sdrc_wait_init(tb_clk_24m, tb_sdrc_init_done, 32);

    tb_log_pkg::log_info(
      "SDRAM UI PROBE 24_96 TB",
      "scenario 1: single write/read at 0x00030"
    );
    req_addr = 21'h00030;
    start_data = 32'h6200_0030;
    exp_words[0] = start_data;

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
      8'd0,
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
      8'd0
    );

    sdrc_expect_read_words(
      tb_clk_24m,
      tb_sdrc_rd_valid,
      tb_sdrc_rd_data,
      exp_words,
      1,
      200,
      "scenario1 single readback"
    );
    sdrc_wait_idle(tb_clk_24m, tb_sdrc_busy_n);

    tb_log_pkg::log_info(
      "SDRAM UI PROBE 24_96 TB",
      "scenario 2: 26-word burst at aligned address 0x00040"
    );
    req_addr = 21'h00040;
    start_data = 32'h6300_0040;
    for (int idx = 0; idx < 26; idx++) begin
      exp_words[idx] = start_data + idx;
    end

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
      8'd25,
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
      8'd25
    );

    sdrc_expect_read_words(
      tb_clk_24m,
      tb_sdrc_rd_valid,
      tb_sdrc_rd_data,
      exp_words,
      26,
      300,
      "scenario2 aligned burst"
    );

    tb_log_pkg::log_info(
      "SDRAM UI PROBE 24_96 TB",
      "probe scenarios completed"
    );
    $finish;
  end
