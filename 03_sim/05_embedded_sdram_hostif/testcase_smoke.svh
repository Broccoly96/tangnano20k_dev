  initial begin : tc_hostif
    logic [7:0]   seq;
    logic [127:0] payload;
    logic [7:0]   crc;
    logic [31:0]  arg0;
    logic [31:0]  arg1;
    logic [31:0]  arg2;
    string        ascii_cmd;
    logic [20:0]  wr_addr_safe;
    logic [31:0]  wr_data_safe;
    logic [20:0]  wr_addr_ctrl;
    logic [31:0]  wr_data_ctrl;

    wr_addr_safe = 21'h00030;
    wr_data_safe = 32'h89AB_CDEF;
    wr_addr_ctrl = 21'h00012;
    wr_data_ctrl = 32'h0012_A55A;

    tb_log_pkg::log_info("SDRAM HOSTIF TB", "waiting for self-test PASS");
    wait (tb_sdram_test_pass || tb_sdram_test_fail);
    if (tb_sdram_test_fail) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "self-test ended in FAIL");
    end

    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h06);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h06);
    wait (u_uart_log_cli.r_log_src_sel == 2);

    ascii_cmd = $sformatf("W %05X %08X\n", wr_addr_safe, wr_data_safe);
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (12) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_WRITE_ACK)) begin
        break;
      end
    end
    arg0 = payload[63:32];
    arg1 = payload[95:64];
    arg2 = payload[127:96];
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_WRITE_ACK) ||
        (arg0[20:0] != wr_addr_safe) || (arg1 != wr_data_safe) || (arg2 != 32'h0)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "ASCII safe write response mismatch");
    end

    ascii_cmd = $sformatf("R %05X\n", wr_addr_safe);
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (12) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_READ_RSP)) begin
        break;
      end
    end
    arg0 = payload[63:32];
    arg1 = payload[95:64];
    arg2 = payload[127:96];
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_READ_RSP) ||
        (arg0[20:0] != wr_addr_safe) || (arg1 != wr_data_safe) || (arg2 != 32'h0)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "ASCII safe read response mismatch");
    end

    ascii_cmd = $sformatf("W %05X %08X\n", wr_addr_ctrl, wr_data_ctrl);
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (12) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_WRITE_ACK)) begin
        break;
      end
    end
    arg0 = payload[63:32];
    arg1 = payload[95:64];
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_WRITE_ACK) ||
        (arg0[20:0] != wr_addr_ctrl) || (arg1 != wr_data_ctrl)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "ASCII control-pattern write mismatch");
    end

    ascii_cmd = $sformatf("R %05X\n", wr_addr_ctrl);
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (12) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_READ_RSP)) begin
        break;
      end
    end
    arg0 = payload[63:32];
    arg1 = payload[95:64];
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_READ_RSP) ||
        (arg0[20:0] != wr_addr_ctrl) || (arg1 != wr_data_ctrl)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "ASCII control-pattern read mismatch");
    end

    ascii_cmd = "X\n";
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (12) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_CMD_ERR)) begin
        break;
      end
    end
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_CMD_ERR) ||
        (payload[63:32] != ERR_BAD_ASCII_CMD)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "ASCII syntax error was not reported");
    end

    ascii_cmd = "BR 00040 00001\n";
    send_uart_string(tb_uart_rx, UART_BIT_PERIOD, ascii_cmd);
    repeat (12) begin
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
    repeat (12) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      if ((payload[31:24] == 8'h03) && (payload[23:16] == EVT_CMD_ERR)) begin
        break;
      end
    end
    if ((payload[31:24] != 8'h03) || (payload[23:16] != EVT_CMD_ERR) ||
        (payload[63:32] != ERR_UNSUPPORTED)) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "BW did not return unsupported CMD_ERR");
    end

    tb_log_pkg::log_info("SDRAM HOSTIF TB", "single-access-only host interface smoke test passed");
    $finish;
  end
