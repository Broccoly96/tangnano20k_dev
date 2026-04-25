  initial begin : tc_smoke
    int cmd_idx;
    logic [(MAX_BULK_PAYLOAD_WORDS*32)-1:0] raw_words;

    @(posedge tb_rst_n);
    repeat (4) @(posedge tb_clk);

    log_info("ACCESS ENG TB", "case: single write");
    cmd_idx = cmd_history_count;
    issue_request(1'b1, 1'b0, 21'h00030, 32'h89AB_CDEF, 9'd1);
    expect_event(EVT_WRITE_ACK, 32'h0000_0030, 32'h89AB_CDEF, 32'h0, "single write");
    expect_command_pair(cmd_idx, SDRAM_HS_CMD_WRITE, "single write");

    log_info("ACCESS ENG TB", "case: single readback");
    cmd_idx = cmd_history_count;
    issue_request(1'b0, 1'b0, 21'h00030, 32'h0, 9'd1);
    expect_event(EVT_READ_RSP, 32'h0000_0030, 32'h89AB_CDEF, 32'h0, "single readback");
    expect_command_pair(cmd_idx, SDRAM_HS_CMD_READ, "single readback");

    foreach (mem_words[idx]) begin
      if (idx < MEM_WORDS) begin
        mem_words[idx] = 32'hA000_0000 + idx;
      end
    end

    log_info("ACCESS ENG TB", "case: burst write lengths");
    foreach (mem_words[idx]) begin
      if (idx < 256) begin
        mem_words[21'h00100 + idx] = 32'hFFFF_0000;
      end
    end
    issue_request(1'b1, 1'b1, 21'h00100, 32'h0, 9'd1);
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_0001, 32'h0, "burst write len1");
    issue_request(1'b1, 1'b1, 21'h00100, 32'h0, 9'd2);
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_0002, 32'h0, "burst write len2");
    issue_request(1'b1, 1'b1, 21'h00100, 32'h0, 9'd4);
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_0004, 32'h0, "burst write len4");
    issue_request(1'b1, 1'b1, 21'h00100, 32'h0, 9'd26);
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_001a, 32'h0, "burst write len26");
    issue_request(1'b1, 1'b1, 21'h00100, 32'h0, 9'd64);
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_0040, 32'h0, "burst write len64");
    issue_request(1'b1, 1'b1, 21'h00100, 32'h0, 9'd255);
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_00ff, 32'h0, "burst write len255");
    cmd_idx = cmd_history_count;
    issue_request(1'b1, 1'b1, 21'h00100, 32'h0, 9'd256);
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_0100, 32'h0, "burst write len256");
    expect_command_pair(cmd_idx, SDRAM_HS_CMD_WRITE, "burst write len256");
    for (int beat = 0; beat < 256; beat++) begin
      if (mem_words[21'h00100 + beat] !== beat[31:0]) begin
        log_fatal(
          1,
          "ACCESS ENG TB",
          $sformatf("burst write data mismatch beat=%0d data=0x%08h", beat, mem_words[21'h00100 + beat])
        );
      end
    end

    log_info("ACCESS ENG TB", "case: burst read four words");
    cmd_idx = cmd_history_count;
    issue_request(1'b0, 1'b1, 21'h00100, 32'h0, 9'd4);
    expect_event(EVT_BURST_DATA, 32'h0002_0002, 32'h0000_0000, 32'h0000_0001, "burst data 0");
    expect_event(EVT_BURST_DATA, 32'h0102_0202, 32'h0000_0002, 32'h0000_0003, "burst data 1");
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_0004, 32'h8000_0002, "burst read done");
    expect_command_pair(cmd_idx, SDRAM_HS_CMD_READ, "burst read four words");

    log_info("ACCESS ENG TB", "case: burst read odd length");
    issue_request(1'b0, 1'b1, 21'h00100, 32'h0, 9'd3);
    expect_event(EVT_BURST_DATA, 32'h0002_0002, 32'h0000_0000, 32'h0000_0001, "burst odd data 0");
    expect_event(EVT_BURST_DATA, 32'h0102_0201, 32'h0000_0002, 32'h0000_0000, "burst odd data 1");
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_0003, 32'h8000_0002, "burst odd done");

    log_info("ACCESS ENG TB", "case: burst read one word");
    issue_request(1'b0, 1'b1, 21'h00100, 32'h0, 9'd1);
    expect_event(EVT_BURST_DATA, 32'h0001_0001, 32'h0000_0000, 32'h0000_0000, "burst one data");
    expect_event(EVT_BURST_DONE, 32'h0000_0100, 32'h0000_0001, 32'h8000_0001, "burst one done");

    log_info("ACCESS ENG TB", "case: burst page crossing error");
    issue_request(1'b0, 1'b1, 21'h000f8, 32'h0, 9'd16);
    expect_event(EVT_BULK_ERR, ERR_ADDR_RANGE, 32'h0000_00f8, 32'h8000_0010, "burst page cross");

    log_info("ACCESS ENG TB", "case: burst bad length");
    issue_request(1'b0, 1'b1, 21'h00100, 32'h0, 9'd0);
    expect_event(EVT_BULK_ERR, ERR_WORD_COUNT, 32'h0000_0100, 32'h8000_0000, "burst zero length");
    issue_request(1'b0, 1'b1, 21'h00100, 32'h0, 9'd257);
    expect_event(EVT_BULK_ERR, ERR_WORD_COUNT, 32'h0000_0100, 32'h8000_0101, "burst too long");

    log_info("ACCESS ENG TB", "case: raw bulk write chunk");
    raw_words = '0;
    raw_words[0 +: 32] = 32'h3F14_1006;
    raw_words[32 +: 32] = 32'h0012_0410;
    raw_words[64 +: 32] = 32'hA5A5_0604;
    raw_words[96 +: 32] = 32'h55AA_123F;
    cmd_idx = cmd_history_count;
    issue_raw_request(1'b1, 21'h00120, 9'd4, raw_words);
    expect_raw_done("raw bulk write");
    expect_command_pair(cmd_idx, SDRAM_HS_CMD_WRITE, "raw bulk write");
    for (int beat = 0; beat < 4; beat++) begin
      if (mem_words[21'h00120 + beat] !== raw_words[beat*32 +: 32]) begin
        log_fatal(
          1,
          "ACCESS ENG TB",
          $sformatf(
            "raw write mismatch beat=%0d exp=0x%08h got=0x%08h",
            beat,
            raw_words[beat*32 +: 32],
            mem_words[21'h00120 + beat]
          )
        );
      end
    end

    log_info("ACCESS ENG TB", "case: raw bulk read chunk");
    cmd_idx = cmd_history_count;
    issue_raw_request(1'b0, 21'h00120, 9'd4, '0);
    expect_raw_done("raw bulk read");
    expect_command_pair(cmd_idx, SDRAM_HS_CMD_READ, "raw bulk read");
    for (int beat = 0; beat < 4; beat++) begin
      if (tb_raw_rd_data[beat*32 +: 32] !== mem_words[21'h00120 + beat]) begin
        log_fatal(
          1,
          "ACCESS ENG TB",
          $sformatf(
            "raw read mismatch beat=%0d exp=0x%08h got=0x%08h",
            beat,
            mem_words[21'h00120 + beat],
            tb_raw_rd_data[beat*32 +: 32]
          )
        );
      end
    end

    log_info("ACCESS ENG TB", "case: raw bulk length 27 rejected");
    issue_raw_request(1'b0, 21'h00120, 9'd27, '0);
    expect_raw_error(ERR_WORD_COUNT, "raw bulk too long");

    log_info("ACCESS ENG TB", "case: write timeout");
    inject_next_wr_timeout = 1'b1;
    issue_request(1'b1, 1'b0, 21'h00040, 32'h1234_5678, 9'd1);
    expect_event(EVT_WRITE_ACK, 32'h0000_0040, 32'h1234_5678, ERR_SDRAM_WR_TO, "write timeout");

    log_info("ACCESS ENG TB", "sdram_uart_access_engine smoke test passed");
    $finish;
  end
