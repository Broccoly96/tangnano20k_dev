  initial begin : tc_stress
    logic [31:0] score_mem [0:255];
    logic [31:0] exp_words [0:25];
    logic [20:0] req_addr;
    logic [31:0] start_data;
    int unsigned seen_beats;
    int unsigned exp_idx;
    int unsigned base_idx;
    int unsigned rand_slot;
    bit          slot_written [0:7];
    int unsigned slot_len [0:7];
    int unsigned rand_len;
    int unsigned rand_gap;
    int unsigned rand_op;
    int unsigned valid_slot_count;
    int unsigned pick_slot;
    string       read_context;

    for (int idx = 0; idx < 256; idx++) begin
      score_mem[idx] = 32'h0000_0000;
    end
    for (int slot_idx = 0; slot_idx < 8; slot_idx++) begin
      slot_written[slot_idx] = 1'b0;
      slot_len[slot_idx]     = 0;
    end

    tb_log_pkg::log_info(
      "SDRAM STRESS TB",
      "waiting for SDRAM initialization to complete"
    );
    sdrc_wait_init(tb_clk_100m, tb_sdrc_init_done, 32);

    tb_log_pkg::log_info(
      "SDRAM STRESS TB",
      "scenario 1: sequential 26-word write/read burst pairs"
    );
    for (int burst_idx = 0; burst_idx < 8; burst_idx++) begin
      base_idx = burst_idx * 26;
      req_addr = make_sdrc_addr(2'd2, 11'd2, 8'(8 + burst_idx * 26));
      start_data = 32'h1100_0000 + base_idx;
      for (int word_idx = 0; word_idx < 26; word_idx++) begin
        score_mem[base_idx + word_idx] = start_data + word_idx;
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

      seen_beats = 0;
      exp_idx = base_idx;
      repeat (80) begin
        @(posedge tb_clk_100m);
        if (tb_sdrc_rd_valid) begin
          if (seen_beats >= 26) begin
            tb_log_pkg::log_fatal(
              1,
              "SDRAM STRESS TB",
              $sformatf("too many beats in sequential pair burst=%0d", burst_idx)
            );
          end
          if (tb_sdrc_rd_data !== score_mem[exp_idx]) begin
            tb_log_pkg::log_fatal(
              1,
              "SDRAM STRESS TB",
              $sformatf(
                "seq pair mismatch burst=%0d beat=%0d exp=0x%08h act=0x%08h",
                burst_idx,
                seen_beats,
                score_mem[exp_idx],
                tb_sdrc_rd_data
              )
            );
          end
          exp_idx += 1;
          seen_beats += 1;
        end
      end
      if (seen_beats == 0) begin
        tb_log_pkg::log_fatal(
          1,
          "SDRAM STRESS TB",
          $sformatf("no read data returned in sequential pair burst=%0d", burst_idx)
        );
      end
      sdrc_wait_idle(tb_clk_100m, tb_sdrc_busy_n);
    end

    tb_log_pkg::log_info(
      "SDRAM STRESS TB",
      "scenario 2: consecutive write sweep followed by consecutive read sweep"
    );
    for (int burst_idx = 0; burst_idx < 8; burst_idx++) begin
      base_idx = burst_idx * 26;
      req_addr = make_sdrc_addr(2'd2, 11'd2, 8'(8 + burst_idx * 26));
      start_data = 32'h2200_0000 + base_idx;
      for (int word_idx = 0; word_idx < 26; word_idx++) begin
        score_mem[base_idx + word_idx] = start_data + word_idx;
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
    end

    sdrc_wait_idle(tb_clk_100m, tb_sdrc_busy_n);
    sdrc_wait_cycles(tb_clk_100m, 64);

    for (int burst_idx = 0; burst_idx < 8; burst_idx++) begin
      base_idx = burst_idx * 26;
      req_addr = make_sdrc_addr(2'd2, 11'd2, 8'(8 + burst_idx * 26));
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
      exp_idx = base_idx;
      repeat (80) begin
        @(posedge tb_clk_100m);
        if (tb_sdrc_rd_valid) begin
          if (seen_beats >= 26) begin
            tb_log_pkg::log_fatal(
              1,
              "SDRAM STRESS TB",
              $sformatf("too many beats in sweep read burst=%0d", burst_idx)
            );
          end
          if (tb_sdrc_rd_data !== score_mem[exp_idx]) begin
            tb_log_pkg::log_fatal(
              1,
              "SDRAM STRESS TB",
              $sformatf(
                "sweep read mismatch burst=%0d beat=%0d exp=0x%08h act=0x%08h",
                burst_idx,
                seen_beats,
                score_mem[exp_idx],
                tb_sdrc_rd_data
              )
            );
          end
          exp_idx += 1;
          seen_beats += 1;
        end
      end
      if (seen_beats == 0) begin
        tb_log_pkg::log_fatal(
          1,
          "SDRAM STRESS TB",
          $sformatf("no read data returned in sweep burst=%0d", burst_idx)
        );
      end
      sdrc_wait_idle(tb_clk_100m, tb_sdrc_busy_n);
    end

    tb_log_pkg::log_info(
      "SDRAM STRESS TB",
      "scenario 3: random burst slots with randomized payload"
    );
    for (int op_idx = 0; op_idx < 16; op_idx++) begin
      rand_slot = $urandom_range(0, 7);
      base_idx = rand_slot * 26;
      req_addr = make_sdrc_addr(2'd2, 11'd2, 8'(8 + rand_slot * 26));
      start_data = 32'h3300_0000 ^ (op_idx << 12) ^ base_idx;
      for (int word_idx = 0; word_idx < 26; word_idx++) begin
        score_mem[base_idx + word_idx] = start_data + word_idx;
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

      seen_beats = 0;
      exp_idx = base_idx;
      repeat (80) begin
        @(posedge tb_clk_100m);
        if (tb_sdrc_rd_valid) begin
          if (seen_beats >= 26) begin
            tb_log_pkg::log_fatal(
              1,
              "SDRAM STRESS TB",
              $sformatf("too many beats in random burst op=%0d", op_idx)
            );
          end
          if (tb_sdrc_rd_data !== score_mem[exp_idx]) begin
            tb_log_pkg::log_fatal(
              1,
              "SDRAM STRESS TB",
              $sformatf(
                "random burst mismatch op=%0d beat=%0d exp=0x%08h act=0x%08h",
                op_idx,
                seen_beats,
                score_mem[exp_idx],
                tb_sdrc_rd_data
              )
            );
          end
          exp_idx += 1;
          seen_beats += 1;
        end
      end
      if (seen_beats == 0) begin
        tb_log_pkg::log_fatal(
          1,
          "SDRAM STRESS TB",
          $sformatf("no read data returned in random burst op=%0d", op_idx)
        );
      end
      sdrc_wait_idle(tb_clk_100m, tb_sdrc_busy_n);
    end

    tb_log_pkg::log_info(
      "SDRAM STRESS TB",
      "scenario 4: self-refresh entry/exit and access recovery"
    );
    sdrc_drive_selfrefresh(tb_clk_100m, tb_sdrc_busy_n, tb_sdrc_selfrefresh, 64);
    base_idx = 26;
    req_addr = make_sdrc_addr(2'd2, 11'd2, 8'(8 + base_idx));
    start_data = 32'h4400_0000;
    for (int word_idx = 0; word_idx < 26; word_idx++) begin
      score_mem[base_idx + word_idx] = start_data + word_idx;
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
    seen_beats = 0;
    exp_idx = base_idx;
    repeat (80) begin
      @(posedge tb_clk_100m);
      if (tb_sdrc_rd_valid) begin
        if (tb_sdrc_rd_data !== score_mem[exp_idx]) begin
          tb_log_pkg::log_fatal(
            1,
            "SDRAM STRESS TB",
            $sformatf(
              "self-refresh recovery mismatch beat=%0d exp=0x%08h act=0x%08h",
              seen_beats,
              score_mem[exp_idx],
              tb_sdrc_rd_data
            )
          );
        end
        exp_idx += 1;
        seen_beats += 1;
      end
    end
    if (seen_beats == 0) begin
      tb_log_pkg::log_fatal(1, "SDRAM STRESS TB", "self-refresh recovery returned no data");
    end

    tb_log_pkg::log_info(
      "SDRAM STRESS TB",
      "scenario 5: power-down entry/exit and access recovery"
    );
    sdrc_drive_power_down(tb_clk_100m, tb_sdrc_busy_n, tb_sdrc_power_down, 64);
    base_idx = 52;
    req_addr = make_sdrc_addr(2'd2, 11'd2, 8'(8 + base_idx));
    start_data = 32'h5500_0000;
    for (int word_idx = 0; word_idx < 26; word_idx++) begin
      score_mem[base_idx + word_idx] = start_data + word_idx;
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
    seen_beats = 0;
    exp_idx = base_idx;
    repeat (80) begin
      @(posedge tb_clk_100m);
      if (tb_sdrc_rd_valid) begin
        if (tb_sdrc_rd_data !== score_mem[exp_idx]) begin
          tb_log_pkg::log_fatal(
            1,
            "SDRAM STRESS TB",
            $sformatf(
              "power-down recovery mismatch beat=%0d exp=0x%08h act=0x%08h",
              seen_beats,
              score_mem[exp_idx],
              tb_sdrc_rd_data
            )
          );
        end
        exp_idx += 1;
        seen_beats += 1;
      end
    end
    if (seen_beats == 0) begin
      tb_log_pkg::log_fatal(1, "SDRAM STRESS TB", "power-down recovery returned no data");
    end

    tb_log_pkg::log_info(
      "SDRAM STRESS TB",
      "scenario 6: long idle window for auto-refresh observation"
    );
    sdrc_wait_idle(tb_clk_100m, tb_sdrc_busy_n);
    sdrc_wait_cycles(tb_clk_100m, 8_000);

    tb_log_pkg::log_info(
      "SDRAM STRESS TB",
      "scenario 7: soak test with randomized burst length and idle gaps"
    );
    for (int op_idx = 0; op_idx < 64; op_idx++) begin
      rand_gap = $urandom_range(0, 120);
      tb_log_pkg::log_debug(
        "SDRAM STRESS TB",
        $sformatf("soak op=%0d pre-gap cycles=%0d", op_idx, rand_gap)
      );
      sdrc_wait_gap(tb_clk_100m, rand_gap);

      valid_slot_count = 0;
      for (int slot_idx = 0; slot_idx < 8; slot_idx++) begin
        if (slot_written[slot_idx]) begin
          valid_slot_count += 1;
        end
      end

      rand_op = $urandom_range(0, 99);
      if ((valid_slot_count == 0) || (rand_op < 65)) begin
        rand_slot = $urandom_range(0, 7);
        rand_len  = $urandom_range(8, 26);
        base_idx  = rand_slot * 26;
        req_addr  = make_sdrc_addr(2'd2, 11'd3, 8'(8 + base_idx));
        start_data = 32'h6600_0000 ^
                     (op_idx * 32'h0001_0101) ^
                     (rand_slot << 8) ^
                     rand_len;

        tb_log_pkg::log_debug(
          "SDRAM STRESS TB",
          $sformatf(
            "soak write op=%0d slot=%0d len=%0d addr=0x%05h start=0x%08h",
            op_idx,
            rand_slot,
            rand_len,
            req_addr,
            start_data
          )
        );

        for (int word_idx = 0; word_idx < rand_len; word_idx++) begin
          score_mem[base_idx + word_idx] = start_data + word_idx;
          exp_words[word_idx]            = start_data + word_idx;
        end
        for (int word_idx = rand_len; word_idx < 26; word_idx++) begin
          exp_words[word_idx] = 32'h0000_0000;
        end

        slot_written[rand_slot] = 1'b1;
        slot_len[rand_slot]     = rand_len;

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
          rand_len - 1,
          start_data
        );

        if ($urandom_range(0, 99) < 45) begin
          sdrc_wait_gap(tb_clk_100m, $urandom_range(0, 24));
          sdrc_issue_read_burst(
            tb_clk_100m,
            tb_sdrc_busy_n,
            tb_sdrc_wr_n,
            tb_sdrc_rd_n,
            tb_sdrc_addr,
            tb_sdrc_data_len,
            tb_sdrc_dqm,
            req_addr,
            rand_len - 1
          );
          read_context = $sformatf(
            "soak write-readback op=%0d slot=%0d len=%0d",
            op_idx,
            rand_slot,
            rand_len
          );
          sdrc_expect_read_words(
            tb_clk_100m,
            tb_sdrc_rd_valid,
            tb_sdrc_rd_data,
            exp_words,
            rand_len,
            140,
            read_context
          );
        end
      end else begin
        pick_slot = $urandom_range(0, valid_slot_count - 1);
        rand_slot = 0;
        for (int slot_idx = 0; slot_idx < 8; slot_idx++) begin
          if (slot_written[slot_idx]) begin
            if (pick_slot == 0) begin
              rand_slot = slot_idx;
              break;
            end
            pick_slot -= 1;
          end
        end

        rand_len = $urandom_range(8, slot_len[rand_slot]);
        base_idx = rand_slot * 26;
        req_addr = make_sdrc_addr(2'd2, 11'd3, 8'(8 + base_idx));

        for (int word_idx = 0; word_idx < rand_len; word_idx++) begin
          exp_words[word_idx] = score_mem[base_idx + word_idx];
        end
        for (int word_idx = rand_len; word_idx < 26; word_idx++) begin
          exp_words[word_idx] = 32'h0000_0000;
        end

        tb_log_pkg::log_debug(
          "SDRAM STRESS TB",
          $sformatf(
            "soak read op=%0d slot=%0d len=%0d addr=0x%05h",
            op_idx,
            rand_slot,
            rand_len,
            req_addr
          )
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
          rand_len - 1
        );
        read_context = $sformatf(
          "soak read op=%0d slot=%0d len=%0d",
          op_idx,
          rand_slot,
          rand_len
        );
        sdrc_expect_read_words(
          tb_clk_100m,
          tb_sdrc_rd_valid,
          tb_sdrc_rd_data,
          exp_words,
          rand_len,
          140,
          read_context
        );
      end
      sdrc_wait_idle(tb_clk_100m, tb_sdrc_busy_n);
    end

    for (int cmd_idx = 0; cmd_idx <= 8; cmd_idx++) begin
      tb_log_pkg::log_info(
        "SDRAM STRESS TB",
        $sformatf(
          "command %-13s count=%0d",
          sdram_cmd_name(sdram_cmd_e'(cmd_idx)),
          tb_cmd_count[cmd_idx]
        )
      );
    end

    if (tb_cmd_count[SDRAM_CMD_ACTIVE] == 0) begin
      tb_log_pkg::log_fatal(1, "SDRAM STRESS TB", "ACTIVE command was never observed");
    end
    if (tb_cmd_count[SDRAM_CMD_READ] == 0) begin
      tb_log_pkg::log_fatal(1, "SDRAM STRESS TB", "READ command was never observed");
    end
    if (tb_cmd_count[SDRAM_CMD_WRITE] == 0) begin
      tb_log_pkg::log_fatal(1, "SDRAM STRESS TB", "WRITE command was never observed");
    end
    if (tb_cmd_count[SDRAM_CMD_PRECHARGE] == 0) begin
      tb_log_pkg::log_fatal(1, "SDRAM STRESS TB", "PRECHARGE command was never observed");
    end
    if (tb_cmd_count[SDRAM_CMD_AUTO_REFRESH] == 0) begin
      tb_log_pkg::log_fatal(1, "SDRAM STRESS TB", "AUTO_REFRESH command was never observed");
    end
    if (tb_cmd_count[SDRAM_CMD_LOAD_MODE_REGISTER] == 0) begin
      tb_log_pkg::log_fatal(1, "SDRAM STRESS TB", "LOAD_MODE command was never observed");
    end

    tb_log_pkg::log_info(
      "SDRAM STRESS TB",
      "embedded SDRAM stress test passed"
    );
    $finish;
  end
