  initial begin : tc_smoke
    int read_req_count_q;

    @(posedge tb_rst_n);
    repeat (4) @(posedge tb_clk);

    log_info("ACCESS ENG TB", "case: single write");
    issue_request(1'b1, 21'h00030, 32'h89AB_CDEF);
    expect_response(1'b1, 21'h00030, 32'h89AB_CDEF, 32'h0, "single write");

    log_info("ACCESS ENG TB", "case: read miss refill");
    issue_request(1'b0, 21'h00030, 32'h0);
    expect_response(1'b0, 21'h00030, 32'h89AB_CDEF, 32'h0, "read miss");

    log_info("ACCESS ENG TB", "case: cache hit");
    read_req_count_q = read_req_count;
    issue_request(1'b0, 21'h00031, 32'h0);
    expect_response(1'b0, 21'h00031, 32'h1000_0031, 32'h0, "cache hit next word");
    if (read_req_count != read_req_count_q) begin
      log_fatal(1, "ACCESS ENG TB", "cache hit unexpectedly issued new SDRC read");
    end

    log_info("ACCESS ENG TB", "case: write timeout");
    inject_next_wr_timeout = 1'b1;
    issue_request(1'b1, 21'h00040, 32'h1234_5678);
    expect_response(1'b1, 21'h00040, 32'h1234_5678, ERR_SDRAM_WR_TO, "write timeout");

    log_info("ACCESS ENG TB", "case: read timeout");
    inject_next_rd_timeout = 1'b1;
    issue_request(1'b0, 21'h00050, 32'h0);
    expect_response(1'b0, 21'h00050, 32'h0000_0000, ERR_SDRAM_RD_TO, "read timeout");

    log_info("ACCESS ENG TB", "sdram_uart_access_engine smoke test passed");
    $finish;
  end
