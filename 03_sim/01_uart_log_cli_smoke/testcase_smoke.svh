  initial begin
    logic [7:0]   seq;
    logic [127:0] payload;
    logic [7:0]   crc;
    logic [31:0]  first_heartbeat_count;
    logic [31:0]  second_heartbeat_count;
    logic [7:0]   first_seq_after_reset;
    bit           found_help;

    tb_uart_rx = 1'b1;
    repeat (20) @(posedge tb_clk);
    tb_rst_n = 1'b1;

    recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
    $display("stage: first heartbeat seq=%0d count=%0d", seq, payload[63:32]);
    if (payload[31:24] !== 8'h01) begin
      $fatal(1, "heartbeat src_id mismatch: %02x", payload[31:24]);
    end
    if (payload[23:16] !== 8'h11) begin
      $fatal(1, "heartbeat event_id mismatch: %02x", payload[23:16]);
    end
    if (crc !== calc_frame_crc(seq, payload)) begin
      $fatal(1, "heartbeat crc mismatch");
    end
    first_heartbeat_count = payload[63:32];

    recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
    $display("stage: second heartbeat seq=%0d count=%0d", seq, payload[63:32]);
    if (payload[31:24] !== 8'h01 || payload[23:16] !== 8'h11) begin
      $fatal(1, "second heartbeat missing");
    end
    if (crc !== calc_frame_crc(seq, payload)) begin
      $fatal(1, "second heartbeat crc mismatch");
    end
    second_heartbeat_count = payload[63:32];
    if (second_heartbeat_count !== (first_heartbeat_count + 1)) begin
      $fatal(1, "heartbeat counter did not increment");
    end

    @(negedge tb_clk);
    force u_uart_log_cli.r_help_pending_count = 4;
    repeat (2) @(posedge tb_clk);
    release u_uart_log_cli.r_help_pending_count;
    found_help = 1'b0;
    for (int help_try = 0; help_try < 8; help_try++) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      $display("stage: post-help frame seq=%0d src=%0h evt=%0h", seq, payload[31:24], payload[23:16]);
      if (payload[31:24] == 8'h00 && payload[23:16] == 8'h02) begin
        found_help = 1'b1;
        break;
      end
    end
    if (!found_help) begin
      $fatal(1, "help event missing");
    end
    if (crc !== calc_frame_crc(seq, payload)) begin
      $fatal(1, "help crc mismatch");
    end

    force tb_soft_rst_n = 1'b0;
    $display("stage: reset asserted");
    #(1ms);
    release tb_soft_rst_n;
    @(posedge tb_soft_rst_n);
    $display("stage: reset observed");

    recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
    $display("stage: heartbeat after reset seq=%0d count=%0d", seq, payload[63:32]);
    if (payload[31:24] !== 8'h01 || payload[23:16] !== 8'h11) begin
      $fatal(1, "heartbeat after reset missing");
    end
    if (crc !== calc_frame_crc(seq, payload)) begin
      $fatal(1, "heartbeat after reset crc mismatch");
    end
    if (payload[63:32] !== 32'h0000_0000) begin
      $fatal(1, "heartbeat counter did not reset");
    end
    first_seq_after_reset = seq;

    recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
    $display("stage: second heartbeat after reset seq=%0d count=%0d", seq, payload[63:32]);
    if (seq !== (first_seq_after_reset + 1'b1)) begin
      $fatal(1, "frame sequence did not restart cleanly after reset");
    end

    $display("UART log smoke test passed");
    $finish;
  end
