  initial begin : tc_hostif
    logic [7:0]   seq;
    logic [127:0] payload;
    logic [7:0]   crc;
    logic [7:0]   src_id;
    logic [7:0]   evt_id;
    logic [31:0]  arg0;
    logic [31:0]  arg1;
    logic [31:0]  arg2;
    logic [20:0]  wr_addr;
    logic [31:0]  wr_data;
    bit           saw_write_ack;
    bit           saw_read_rsp;

    wr_addr = 21'h000_012;
    wr_data = 32'h0612_143F;
    saw_write_ack = 1'b0;
    saw_read_rsp = 1'b0;

    tb_log_pkg::log_info(
      "SDRAM HOSTIF TB",
      "waiting for self-test PASS before enabling host access"
    );

    wait (tb_sdram_test_pass || tb_sdram_test_fail);
    if (tb_sdram_test_fail) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "self-test ended in FAIL");
    end
    tb_log_pkg::log_info("SDRAM HOSTIF TB", "self-test PASS signal observed");

    tb_log_pkg::log_info(
      "SDRAM HOSTIF TB",
      "switching source selection to SDRAM host interface"
    );
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h06);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h06);

    wait (u_uart_log_cli.r_log_src_sel == 2);

    tb_log_pkg::log_info(
      "SDRAM HOSTIF TB",
      $sformatf("issuing host WRITE addr=0x%05h data=0x%08h", wr_addr, wr_data)
    );
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h57);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, {3'b000, wr_addr[20:16]});
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_addr[15:8]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h10);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_addr[7:0]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h10);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_data[31:24]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h10);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_data[23:16]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h10);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_data[15:8]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h10);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_data[7:0]);

    repeat (6) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      src_id = payload[31:24];
      evt_id = payload[23:16];
      arg0   = payload[63:32];
      arg1   = payload[95:64];
      arg2   = payload[127:96];
      if (src_id == 8'h03 && evt_id == 8'h30) begin
        if (arg0[20:0] !== wr_addr || arg1 !== wr_data || arg2 !== 32'h0) begin
          tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "WRITE_ACK payload mismatch");
        end
        saw_write_ack = 1'b1;
        break;
      end
    end

    if (!saw_write_ack) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "WRITE_ACK was not observed");
    end

    tb_log_pkg::log_info(
      "SDRAM HOSTIF TB",
      $sformatf("issuing host READ addr=0x%05h", wr_addr)
    );
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h52);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, {3'b000, wr_addr[20:16]});
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_addr[15:8]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h10);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_addr[7:0]);

    repeat (6) begin
      recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
      src_id = payload[31:24];
      evt_id = payload[23:16];
      arg0   = payload[63:32];
      arg1   = payload[95:64];
      arg2   = payload[127:96];
      if (src_id == 8'h03 && evt_id == 8'h31) begin
        if (arg0[20:0] !== wr_addr || arg1 !== wr_data || arg2 !== 32'h0) begin
          tb_log_pkg::log_fatal(
            1,
            "SDRAM HOSTIF TB",
            $sformatf(
              "READ_RSP payload mismatch addr=0x%05h data=0x%08h status=0x%08h exp_addr=0x%05h exp_data=0x%08h",
              arg0[20:0],
              arg1,
              arg2,
              wr_addr,
              wr_data
            )
          );
        end
        saw_read_rsp = 1'b1;
        break;
      end
    end

    if (!saw_read_rsp) begin
      tb_log_pkg::log_fatal(1, "SDRAM HOSTIF TB", "READ_RSP was not observed");
    end

    tb_log_pkg::log_info(
      "SDRAM HOSTIF TB",
      "embedded SDRAM host interface smoke test passed"
    );
    $finish;
  end
