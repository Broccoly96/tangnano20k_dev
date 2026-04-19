  initial begin : tc_hostif
    logic [7:0]   seq;
    logic [127:0] payload;
    logic [7:0]   crc;
    logic [31:0]  arg0;
    logic [31:0]  arg1;
    logic [31:0]  arg2;
    string        ascii_cmd;

    tb_log_pkg::log_info("SDRAM HOSTIF TB", "waiting for self-test PASS");
    wait (tb_sdram_test_pass || tb_sdram_test_fail);
    if (tb_sdram_test_fail) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "self-test ended in FAIL");
    end

    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h06);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h06);
    wait (u_uart_log_cli.r_log_src_sel == 2);

    ascii_cmd = "SR 00000\n";
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (20) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_READ_RSP)) begin
        break;
      end
    end
    arg0 = payload[63:32];
    arg1 = payload[95:64];
    arg2 = payload[127:96];
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_READ_RSP) ||
        (arg0 != 32'h0000_0000) || (arg1 != 32'h040D_00A8) || (arg2 != 32'h0000_0000)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "final summary read response mismatch");
    end

    ascii_cmd = "SR 00024\n";
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (20) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_READ_RSP)) begin
        break;
      end
    end
    arg0 = payload[63:32];
    arg1 = payload[95:64];
    arg2 = payload[127:96];
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_READ_RSP) ||
        (arg0 != 32'h0000_0024) || (arg1 != 32'h0300_0000) || (arg2 != 32'h0000_0000)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "retry summary read response mismatch");
    end

    ascii_cmd = "W 00010 12345678\n";
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (20) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_WRITE_ACK)) begin
        break;
      end
    end
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_WRITE_ACK) ||
        (payload[63:32] != 32'h0000_0010) ||
        (payload[95:64] != 32'h1234_5678) ||
        (payload[127:96] != 32'h0000_0000)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "linear single write response mismatch");
    end

    ascii_cmd = "R 00010\n";
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (20) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_READ_RSP)) begin
        break;
      end
    end
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_READ_RSP) ||
        (payload[63:32] != 32'h0000_0010) ||
        (payload[95:64] != 32'h1234_5678) ||
        (payload[127:96] != 32'h0000_0000)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "linear single readback response mismatch");
    end

    ascii_cmd = "BR 00040 00001\n";
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (20) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_CMD_ERR)) begin
        break;
      end
    end
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_CMD_ERR) ||
        (payload[63:32] != ERR_UNSUPPORTED)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "BR did not return unsupported CMD_ERR");
    end

    ascii_cmd = "BW 00040 00001\n";
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (20) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_CMD_ERR)) begin
        break;
      end
    end
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_CMD_ERR) ||
        (payload[63:32] != ERR_UNSUPPORTED)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "BW did not return unsupported CMD_ERR");
    end

    tb_log_pkg::log_info("SDRAM HOSTIF TB", "linear SDRAM host interface smoke test passed");
    $finish;
  end
