  initial begin : tc_smoke
    tb_uart_rx = 1'b1;
    tb_src_evt_valid = '0;
    for (int src_idx = 0; src_idx < NUM_SRC; src_idx++) begin
      tb_src_evt_id[src_idx] = 8'h00;
      tb_src_arg0[src_idx] = 32'h0;
      tb_src_arg1[src_idx] = 32'h0;
      tb_src_arg2[src_idx] = 32'h0;
    end

    repeat (20) @(posedge tb_clk);
    tb_rst_n = 1'b1;
    repeat (20) @(posedge tb_clk);

    if (tb_src_if[0].enable !== 1'b1) begin
      $fatal(1, "source 0 should be selected after reset");
    end

    fork
      expect_uart_event(8'h01, 8'hA0, 32'h0000_0000, 32'h1111_0000, 32'h2222_0000,
                        "source 0 event");
      begin
        repeat (5) @(posedge tb_clk);
        emit_source_event(0, 8'hA0, 32'h0000_0000, 32'h1111_0000, 32'h2222_0000);
      end
    join

    send_uart_byte(tb_uart_rx, BIT_PERIOD, uart_log_cli_pkg::CMD_NEXT_SRC);
    wait_cli_forward(uart_log_cli_pkg::CMD_NEXT_SRC, "Ctrl+F forward");
    expect_uart_event(uart_log_cli_pkg::SYS_SRC_ID, uart_log_cli_pkg::EV_MODE_CHANGE,
                      32'h0000_0000, 32'h0000_0001, 32'h0000_0000,
                      "source 0 to 1");
    if ((tb_src_if[0].enable !== 1'b0) || (tb_src_if[1].enable !== 1'b1)) begin
      $fatal(1, "source 1 should be selected after first Ctrl+F");
    end

    send_uart_byte(tb_uart_rx, BIT_PERIOD, uart_log_cli_pkg::CMD_NEXT_SRC);
    wait_cli_forward(uart_log_cli_pkg::CMD_NEXT_SRC, "second Ctrl+F forward");
    expect_uart_event(uart_log_cli_pkg::SYS_SRC_ID, uart_log_cli_pkg::EV_MODE_CHANGE,
                      32'h0000_0001, 32'h0000_0002, 32'h0000_0000,
                      "source 1 to 2");
    if ((tb_src_if[1].enable !== 1'b0) || (tb_src_if[2].enable !== 1'b1)) begin
      $fatal(1, "source 2 should be selected after second Ctrl+F");
    end

    send_uart_byte(tb_uart_rx, BIT_PERIOD, uart_log_cli_pkg::CMD_PREV_SRC);
    wait_cli_forward(uart_log_cli_pkg::CMD_PREV_SRC, "Ctrl+D forward");
    expect_uart_event(uart_log_cli_pkg::SYS_SRC_ID, uart_log_cli_pkg::EV_MODE_CHANGE,
                      32'h0000_0002, 32'h0000_0001, 32'h0000_0000,
                      "source 2 to 1");
    if ((tb_src_if[1].enable !== 1'b1) || (tb_src_if[2].enable !== 1'b0)) begin
      $fatal(1, "source 1 should be selected after Ctrl+D");
    end

    fork
      expect_uart_event(8'h02, 8'hB1, 32'h0000_0001, 32'h1111_0001, 32'h2222_0001,
                        "source 1 event");
      begin
        repeat (5) @(posedge tb_clk);
        emit_source_event(1, 8'hB1, 32'h0000_0001, 32'h1111_0001, 32'h2222_0001);
      end
    join

    send_uart_byte(tb_uart_rx, BIT_PERIOD, uart_log_cli_pkg::CMD_SOFT_RESET);
    wait_cli_forward(uart_log_cli_pkg::CMD_SOFT_RESET, "Ctrl+R forward");
    wait_soft_reset_pulse();
    expect_uart_event(uart_log_cli_pkg::SYS_SRC_ID, uart_log_cli_pkg::EV_RESET_ACK,
                      32'h0000_0000, 32'h0000_0000, 32'h0000_0000,
                      "reset ack");

    send_uart_byte(tb_uart_rx, BIT_PERIOD, uart_log_cli_pkg::CMD_LITERAL_NEXT);
    repeat (20) @(posedge tb_clk);
    send_uart_byte(tb_uart_rx, BIT_PERIOD, uart_log_cli_pkg::CMD_NEXT_SRC);
    wait_cli_forward(uart_log_cli_pkg::CMD_NEXT_SRC, "DLE literal Ctrl+F");
    repeat (2500) @(posedge tb_clk);
    if ((tb_src_if[1].enable !== 1'b1) || (tb_src_if[2].enable !== 1'b0)) begin
      $fatal(1, "DLE literal Ctrl+F changed source selection");
    end

    $display("UART log smoke test passed");
    $finish;
  end
