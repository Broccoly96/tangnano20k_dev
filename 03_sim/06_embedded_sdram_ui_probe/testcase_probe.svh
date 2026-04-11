  initial begin : tc_probe
    logic [31:0] exp_words [0:25];
    logic [20:0] req_addr;
    logic [31:0] start_data;
    int unsigned seen_beats;
    int unsigned timeout_cycles;
    int unsigned first_seen_cycle;
    bit          saw_first;

    timeout_cycles = 200;

    tb_log_pkg::log_info(
      "SDRAM UI PROBE TB",
      "waiting for SDRAM initialization to complete"
    );
    sdrc_wait_init(tb_clk_100m, tb_sdrc_init_done, 32);
    tb_log_pkg::log_info(
      "SDRAM UI PROBE TB",
      "scenario 1: vendor-style 26-word burst write/read reference"
    );

    req_addr = make_sdrc_addr(2'd2, 11'd2, 8'd8);
    start_data = 32'h5100_0000;
    for (int idx = 0; idx < 26; idx++) begin
      exp_words[idx] = start_data + idx;
    end

    sdrc_issue_write_burst(
      tb_clk_100m,
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
      tb_clk_100m,
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
      tb_clk_100m,
      tb_sdrc_rd_valid,
      tb_sdrc_rd_data,
      exp_words,
      26,
      120,
      "scenario1 vendor-style burst"
    );
    sdrc_wait_idle(tb_clk_100m, tb_sdrc_busy_n);

    tb_log_pkg::log_info(
      "SDRAM UI PROBE TB",
      "scenario 2: host-style single-word write/read at 0x00030"
    );
    req_addr = 21'h00030;
    start_data = 32'h5200_0030;

    sdrc_issue_write_burst(
      tb_clk_100m,
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
      tb_clk_100m,
      tb_sdrc_busy_n,
      tb_sdrc_wr_n,
      tb_sdrc_rd_n,
      tb_sdrc_addr,
      tb_sdrc_data_len,
      tb_sdrc_dqm,
      req_addr,
      8'd0
    );

    seen_beats = 0;
    saw_first = 1'b0;
    first_seen_cycle = 0;
    repeat (timeout_cycles) begin
      @(posedge tb_clk_100m);
      if (tb_sdrc_rd_valid) begin
        if (!saw_first) begin
          saw_first = 1'b1;
          first_seen_cycle = seen_beats;
        end
        tb_log_pkg::log_debug(
          "SDRAM UI PROBE TB",
          $sformatf(
            "scenario2 beat=%0d data=0x%08h",
            seen_beats,
            tb_sdrc_rd_data
          )
        );
        seen_beats += 1;
      end
    end
    tb_log_pkg::log_info(
      "SDRAM UI PROBE TB",
      $sformatf(
        "scenario2 result beats=%0d expected_first=0x%08h",
        seen_beats,
        start_data
      )
    );
    sdrc_wait_idle(tb_clk_100m, tb_sdrc_busy_n);

    tb_log_pkg::log_info(
      "SDRAM UI PROBE TB",
      "scenario 3: host-style 26-word burst write/read starting at 0x00030"
    );
    req_addr = 21'h00030;
    start_data = 32'h5300_0030;

    sdrc_issue_write_burst(
      tb_clk_100m,
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
      tb_clk_100m,
      tb_sdrc_busy_n,
      tb_sdrc_wr_n,
      tb_sdrc_rd_n,
      tb_sdrc_addr,
      tb_sdrc_data_len,
      tb_sdrc_dqm,
      req_addr,
      8'd25
    );

    seen_beats = 0;
    repeat (timeout_cycles) begin
      @(posedge tb_clk_100m);
      if (tb_sdrc_rd_valid) begin
        tb_log_pkg::log_debug(
          "SDRAM UI PROBE TB",
          $sformatf(
            "scenario3 beat=%0d data=0x%08h",
            seen_beats,
            tb_sdrc_rd_data
          )
        );
        seen_beats += 1;
      end
    end
    tb_log_pkg::log_info(
      "SDRAM UI PROBE TB",
      $sformatf(
        "scenario3 result beats=%0d expected_first=0x%08h expected_last=0x%08h",
        seen_beats,
        start_data,
        start_data + 25
      )
    );
    sdrc_wait_idle(tb_clk_100m, tb_sdrc_busy_n);

    tb_log_pkg::log_info(
      "SDRAM UI PROBE TB",
      "scenario 4: host-style 26-word burst read at aligned address 0x00040"
    );
    req_addr = 21'h00040;
    start_data = 32'h5400_0040;

    sdrc_issue_write_burst(
      tb_clk_100m,
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
      tb_clk_100m,
      tb_sdrc_busy_n,
      tb_sdrc_wr_n,
      tb_sdrc_rd_n,
      tb_sdrc_addr,
      tb_sdrc_data_len,
      tb_sdrc_dqm,
      req_addr,
      8'd25
    );

    seen_beats = 0;
    repeat (timeout_cycles) begin
      @(posedge tb_clk_100m);
      if (tb_sdrc_rd_valid) begin
        tb_log_pkg::log_debug(
          "SDRAM UI PROBE TB",
          $sformatf(
            "scenario4 beat=%0d data=0x%08h",
            seen_beats,
            tb_sdrc_rd_data
          )
        );
        seen_beats += 1;
      end
    end
    tb_log_pkg::log_info(
      "SDRAM UI PROBE TB",
      $sformatf(
        "scenario4 result beats=%0d expected_first=0x%08h expected_last=0x%08h",
        seen_beats,
        start_data,
        start_data + 25
      )
    );

    tb_log_pkg::log_info(
      "SDRAM UI PROBE TB",
      "probe scenarios completed"
    );
    $finish;
  end
