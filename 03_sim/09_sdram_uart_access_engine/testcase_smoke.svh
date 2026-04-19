  initial begin : tc_smoke
    int read_req_count_q;

    @(posedge tb_rst_n);
    repeat (4) @(posedge tb_clk);

    log_info("ACCESS ENG TB", "case: single write");
    issue_request(1'b1, 21'h00030, 32'h89AB_CDEF);
    expect_response(1'b1, 21'h00030, 32'h89AB_CDEF, 32'h0, "single write");

    log_info("ACCESS ENG TB", "case: single readback");
    issue_request(1'b0, 21'h00030, 32'h0);
    expect_response(1'b0, 21'h00030, 32'h89AB_CDEF, 32'h0, "single readback");

    log_info("ACCESS ENG TB", "case: next linear word read");
    read_req_count_q = read_req_count;
    issue_request(1'b0, 21'h00031, 32'h0);
    expect_response(1'b0, 21'h00031, 32'h1000_0031, 32'h0, "next linear word read");
    if (read_req_count != (read_req_count_q + 1)) begin
      log_fatal(1, "ACCESS ENG TB", "linear read did not issue exactly one SDRC read");
    end

    log_info("ACCESS ENG TB", "case: nonzero linear word write/readback");
    issue_request(1'b1, 21'h00343, 32'h5566_7788);
    expect_response(1'b1, 21'h00343, 32'h5566_7788, 32'h0, "nonzero word write");
    issue_request(1'b0, 21'h00343, 32'h0);
    expect_response(1'b0, 21'h00343, 32'h5566_7788, 32'h0, "nonzero word readback");

    log_info("ACCESS ENG TB", "case: rewrite same word");
    issue_request(1'b1, 21'h00030, 32'hCAFE_BABE);
    expect_response(1'b1, 21'h00030, 32'hCAFE_BABE, 32'h0, "rewrite same addr");
    read_req_count_q = read_req_count;
    issue_request(1'b0, 21'h00030, 32'h0);
    expect_response(1'b0, 21'h00030, 32'hCAFE_BABE, 32'h0, "readback after rewrite");
    if (read_req_count != (read_req_count_q + 1)) begin
      log_fatal(1, "ACCESS ENG TB", "rewrite readback did not issue exactly one SDRC read");
    end

    log_info("ACCESS ENG TB", "case: two-address separation");
    issue_request(1'b1, 21'h00012, 32'h0012_A55A);
    expect_response(1'b1, 21'h00012, 32'h0012_A55A, 32'h0, "control-pattern write");
    issue_request(1'b0, 21'h00343, 32'h0);
    expect_response(1'b0, 21'h00343, 32'h5566_7788, 32'h0, "nonzero word still intact");
    issue_request(1'b0, 21'h00012, 32'h0);
    expect_response(1'b0, 21'h00012, 32'h0012_A55A, 32'h0, "control-pattern readback");

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
