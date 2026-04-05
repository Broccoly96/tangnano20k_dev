  initial begin
    logic [7:0] seq;
    logic [127:0] payload;
    logic [7:0] crc;
    bit saw_init_done;
    bit saw_test_start;
    bit saw_test_pass;

    uart_log_cli_tb_pkg::recv_mirror_frame(
      tb_mirror_valid,
      tb_mirror_data,
      seq,
      payload,
      crc
    );
    if (payload[31:24] !== 8'h01 || payload[23:16] !== 8'h11) begin
      $fatal(1, "heartbeat frame missing before source switch");
    end
    if (crc !== uart_log_cli_tb_pkg::calc_frame_crc(seq, payload)) begin
      $fatal(1, "heartbeat CRC mismatch");
    end

    uart_log_cli_tb_pkg::send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h06);

    saw_init_done = 1'b0;
    saw_test_start = 1'b0;
    saw_test_pass = 1'b0;

    for (int frame_idx = 0; frame_idx < 12; frame_idx++) begin
      uart_log_cli_tb_pkg::recv_mirror_frame(
        tb_mirror_valid,
        tb_mirror_data,
        seq,
        payload,
        crc
      );
      $display(
        "frame[%0d] src=%02x evt=%02x arg0=%08x arg1=%08x arg2=%08x",
        frame_idx,
        payload[31:24],
        payload[23:16],
        payload[63:32],
        payload[95:64],
        payload[127:96]
      );
      if (crc !== uart_log_cli_tb_pkg::calc_frame_crc(seq, payload)) begin
        $fatal(1, "CRC mismatch after source switch");
      end

      if (payload[31:24] == 8'h02 && payload[23:16] == 8'h20) begin
        saw_init_done = 1'b1;
      end
      if (payload[31:24] == 8'h02 && payload[23:16] == 8'h21) begin
        saw_test_start = 1'b1;
      end
      if (payload[31:24] == 8'h02 && payload[23:16] == 8'h22) begin
        saw_test_pass = 1'b1;
        break;
      end
      if (payload[31:24] == 8'h02 && payload[23:16] == 8'h23) begin
        $fatal(
          1,
          "embedded SDRAM self-test failed idx=%0d exp=%08x act=%08x",
          payload[63:32],
          payload[95:64],
          payload[127:96]
        );
      end
    end

    if (!saw_init_done) begin
      $fatal(1, "SDRAM init-done event missing");
    end
    if (!saw_test_start) begin
      $fatal(1, "SDRAM test-start event missing");
    end
    if (!saw_test_pass) begin
      $fatal(1, "SDRAM test-pass event missing");
    end
    if (!tb_sdram_init_done || !tb_sdram_test_pass || tb_sdram_test_fail) begin
      $fatal(1, "SDRAM status outputs not in PASS state");
    end

    $display("embedded SDRAM self-test smoke test passed");
    $finish;
  end
