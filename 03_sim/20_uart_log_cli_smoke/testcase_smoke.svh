  initial begin
    tb_uart_rx = 1'b1;
    repeat (20) @(posedge tb_clk);
    tb_rst_n = 1'b1;

    repeat (1000) @(posedge tb_clk);
    if (tb_src_if[0].enable !== 1'b1) begin
      $fatal(1, "source 0 should be selected after reset");
    end

    send_uart_byte(tb_uart_rx, BIT_PERIOD, 8'h06);
    repeat (2000) @(posedge tb_clk);
    if (tb_src_if[0].enable !== 1'b1) begin
      $fatal(1, "single-source select should wrap back to source 0");
    end

    $display("UART log smoke test passed");
    $finish;
  end
