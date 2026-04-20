  initial begin : tc_smoke
    @(posedge tb_rst_n);
    repeat (4) @(posedge tb_clk);

    log_info("ASCII CTRL TB", "case: single read");
    send_text("R 00308\n");
    expect_cmd(ASCII_OP_READ, 1'b0, 1'b0, 1'b0, 21'h000308,
               32'h0000_0000, 21'h0, "read");

    log_info("ASCII CTRL TB", "case: full-range six-digit read");
    send_text("R 1FFFFF\n");
    expect_cmd(ASCII_OP_READ, 1'b0, 1'b0, 1'b0, 21'h1FFFFF,
               32'h0000_0000, 21'h0, "six-digit read");

    log_info("ASCII CTRL TB", "case: single write");
    send_text("W 00308 89ABCDEF\n");
    expect_cmd(ASCII_OP_WRITE, 1'b0, 1'b0, 1'b0, 21'h000308,
               32'h89AB_CDEF, 21'h0, "write");

    log_info("ASCII CTRL TB", "case: status read");
    send_text("SR 0003C\n");
    expect_cmd(ASCII_OP_READ, 1'b1, 1'b0, 1'b0, 21'h00003C,
               32'h0000_0000, 21'h0, "status read");

    log_info("ASCII CTRL TB", "case: status write");
    send_text("SW 0003C 00000001\n");
    expect_cmd(ASCII_OP_WRITE, 1'b1, 1'b0, 1'b0, 21'h00003C,
               32'h0000_0001, 21'h0, "status write");

    log_info("ASCII CTRL TB", "case: reserved bulk read");
    send_text("BR 00100 00040\n");
    expect_cmd(ASCII_OP_BULK, 1'b0, 1'b1, 1'b0, 21'h000000,
               32'h0000_0000, 21'h00000, "bulk read reserved");

    log_info("ASCII CTRL TB", "case: reserved bulk write");
    send_text("BW 00100 00040\n");
    expect_cmd(ASCII_OP_BULK, 1'b0, 1'b0, 1'b0, 21'h000000,
               32'h0000_0000, 21'h00000, "bulk write reserved");

    log_info("ASCII CTRL TB", "case: burst read test");
    send_text("BRT 00100 00040\n");
    expect_cmd(ASCII_OP_BULK, 1'b0, 1'b1, 1'b1, 21'h000100,
               32'h0000_0000, 21'h00040, "burst read test");

    log_info("ASCII CTRL TB", "case: burst write test");
    send_text("BWT 00100 00040\n");
    expect_cmd(ASCII_OP_BULK, 1'b0, 1'b0, 1'b1, 21'h000100,
               32'h0000_0000, 21'h00040, "burst write test");

    log_info("ASCII CTRL TB", "case: CRLF");
    send_text("R 00120");
    send_byte(ASCII_CMD_CR);
    send_byte(ASCII_CMD_LF);
    expect_cmd(ASCII_OP_READ, 1'b0, 1'b0, 1'b0, 21'h000120,
               32'h0000_0000, 21'h0, "crlf");

    log_info("ASCII CTRL TB", "case: empty line");
    send_text("\n");
    repeat (3) @(posedge tb_clk);
    if (tb_cmd_valid || tb_err_valid) begin
      log_fatal(1, "ASCII CTRL TB", "empty line produced output");
    end

    log_info("ASCII CTRL TB", "case: lowercase rejected");
    send_text("W 00308 deadbeef\n");
    expect_err(ERR_BAD_ASCII_CMD, 32'h0000_0057, "lowercase data");

    log_info("ASCII CTRL TB", "case: repeated spaces rejected");
    send_text("R   00120\n");
    expect_err(ERR_BAD_ASCII_CMD, 32'h0000_0052, "repeated spaces");

    log_info("ASCII CTRL TB", "case: bad command");
    send_text("X\n");
    expect_err(ERR_BAD_ASCII_CMD, 32'h0000_0058, "bad command");

    log_info("ASCII CTRL TB", "case: malformed status namespace");
    send_text("S\n");
    expect_err(ERR_BAD_ASCII_CMD, 32'h0000_0053, "bare status command");
    send_text("SX\n");
    expect_err(ERR_BAD_ASCII_CMD, 32'h0000_0053, "bad status command");
    send_text("SR\n");
    expect_err(ERR_BAD_ASCII_CMD, 32'h0000_0053, "status read without address");
    send_text("SW 0003C\n");
    expect_err(ERR_BAD_ASCII_CMD, 32'h0000_0053, "status write without data");

    log_info("ASCII CTRL TB", "case: bad field");
    send_text("R 00GHI\n");
    expect_err(ERR_BAD_ASCII_CMD, 32'h0000_0052, "bad field");

    log_info("ASCII CTRL TB", "case: addr overflow");
    send_text("R 200000\n");
    expect_err(ERR_ADDR_RANGE, 32'h0020_0000, "addr overflow");

    log_info("ASCII CTRL TB", "case: too many nibbles");
    send_text("W 00308 123456789\n");
    expect_err(ERR_BAD_ASCII_CMD, 32'h0000_0057, "too many data nibbles");

    log_info("ASCII CTRL TB", "case: extra trailing tokens");
    send_text("R 00308 XX\n");
    expect_err(ERR_BAD_ASCII_CMD, 32'h0000_0052, "read trailing");

    log_info("ASCII CTRL TB", "case: ignored control bytes");
    send_byte(8'h12);
    send_byte(8'h14);
    send_text("R 00120\n");
    expect_cmd(ASCII_OP_READ, 1'b0, 1'b0, 1'b0, 21'h000120,
               32'h0000_0000, 21'h0, "control ignore");

    log_info("ASCII CTRL TB", "case: pending command backpressure");
    send_text("R 00121\n");
    repeat (3) @(posedge tb_clk);
    if (!tb_cmd_valid) begin
      log_fatal(1, "ASCII CTRL TB", "expected pending command");
    end
    send_text("W 00122 12345678\n");
    repeat (6) @(posedge tb_clk);
    if (!tb_cmd_valid || tb_cmd_op !== ASCII_OP_READ ||
        tb_cmd_addr !== 21'h000121) begin
      log_fatal(1, "ASCII CTRL TB", "pending command changed while busy");
    end
    pulse_cmd_ready();
    repeat (6) @(posedge tb_clk);
    if (tb_cmd_valid || tb_err_valid) begin
      log_fatal(1, "ASCII CTRL TB", "busy-time input should have been ignored");
    end

    log_info("ASCII CTRL TB", "sdram_uart_ascii_ctrl smoke test passed");
    $finish;
  end
