  initial begin : tc_smoke
    logic [7:0]   seq;
    logic [127:0] payload;
    logic [7:0]   crc;
    logic [7:0]   src_id;
    logic [7:0]   evt_id;
    logic [15:0]  timestamp;
    logic [31:0]  arg0;
    logic [31:0]  arg1;
    logic [31:0]  arg2;

    logic [20:0]  wr_addr;
    logic [31:0]  wr_data;

    wr_addr = 21'h100_308;
    wr_data = 32'h1234_5678;

    tb_log_pkg::log_info(
      "SDRAM UART TB",
      "waiting for INIT_DONE event"
    );

    recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
    if (crc !== calc_frame_crc(seq, payload)) begin
      tb_log_pkg::log_fatal(1, "SDRAM UART TB", "init frame CRC mismatch");
    end

    src_id    = payload[31:24];
    evt_id    = payload[23:16];
    timestamp = payload[15:0];
    arg0      = payload[63:32];
    arg1      = payload[95:64];
    arg2      = payload[127:96];

    if (src_id !== 8'h01 || evt_id !== 8'h20) begin
      tb_log_pkg::log_fatal(
        1,
        "SDRAM UART TB",
        $sformatf("unexpected init event src=0x%02h evt=0x%02h", src_id, evt_id)
      );
    end

    tb_log_pkg::log_info(
      "SDRAM UART TB",
      $sformatf("init done timestamp=%0d", timestamp)
    );

    tb_log_pkg::log_info(
      "SDRAM UART TB",
      $sformatf("issuing WRITE addr=0x%05h data=0x%08h", wr_addr, wr_data)
    );

    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h57);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, {3'b000, wr_addr[20:16]});
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_addr[15:8]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_addr[7:0]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_data[31:24]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_data[23:16]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_data[15:8]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_data[7:0]);

    recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
    if (crc !== calc_frame_crc(seq, payload)) begin
      tb_log_pkg::log_fatal(1, "SDRAM UART TB", "write ack CRC mismatch");
    end

    src_id    = payload[31:24];
    evt_id    = payload[23:16];
    arg0      = payload[63:32];
    arg1      = payload[95:64];
    arg2      = payload[127:96];

    if (src_id !== 8'h01 || evt_id !== 8'h30) begin
      tb_log_pkg::log_fatal(
        1,
        "SDRAM UART TB",
        $sformatf("unexpected write ack src=0x%02h evt=0x%02h", src_id, evt_id)
      );
    end
    if (arg0[20:0] !== wr_addr || arg1 !== wr_data || arg2 !== 32'h0) begin
      tb_log_pkg::log_fatal(
        1,
        "SDRAM UART TB",
        $sformatf(
          "write ack mismatch addr=0x%05h data=0x%08h status=0x%08h",
          arg0[20:0],
          arg1,
          arg2
        )
      );
    end

    tb_log_pkg::log_info(
      "SDRAM UART TB",
      $sformatf("issuing READ addr=0x%05h", wr_addr)
    );

    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h52);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, {3'b000, wr_addr[20:16]});
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_addr[15:8]);
    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, wr_addr[7:0]);

    recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
    if (crc !== calc_frame_crc(seq, payload)) begin
      tb_log_pkg::log_fatal(1, "SDRAM UART TB", "read response CRC mismatch");
    end

    src_id    = payload[31:24];
    evt_id    = payload[23:16];
    arg0      = payload[63:32];
    arg1      = payload[95:64];
    arg2      = payload[127:96];

    if (src_id !== 8'h01 || evt_id !== 8'h31) begin
      tb_log_pkg::log_fatal(
        1,
        "SDRAM UART TB",
        $sformatf("unexpected read response src=0x%02h evt=0x%02h", src_id, evt_id)
      );
    end
    if (arg0[20:0] !== wr_addr || arg1 !== wr_data || arg2 !== 32'h0) begin
      tb_log_pkg::log_fatal(
        1,
        "SDRAM UART TB",
        $sformatf(
          "read response mismatch addr=0x%05h data=0x%08h status=0x%08h",
          arg0[20:0],
          arg1,
          arg2
        )
      );
    end

    tb_log_pkg::log_info(
      "SDRAM UART TB",
      "issuing invalid command to confirm CMD_ERR"
    );

    send_uart_byte(tb_uart_rx, UART_BIT_PERIOD, 8'h58);

    recv_mirror_frame(tb_mirror_valid, tb_mirror_data, seq, payload, crc);
    if (crc !== calc_frame_crc(seq, payload)) begin
      tb_log_pkg::log_fatal(1, "SDRAM UART TB", "error response CRC mismatch");
    end

    src_id = payload[31:24];
    evt_id = payload[23:16];
    arg0   = payload[63:32];
    arg1   = payload[95:64];

    if (src_id !== 8'h01 || evt_id !== 8'h3E || arg0 !== 32'h1 || arg1[7:0] !== 8'h58) begin
      tb_log_pkg::log_fatal(
        1,
        "SDRAM UART TB",
        $sformatf(
          "unexpected CMD_ERR src=0x%02h evt=0x%02h arg0=0x%08h arg1=0x%08h",
          src_id,
          evt_id,
          arg0,
          arg1
        )
      );
    end

    tb_log_pkg::log_info(
      "SDRAM UART TB",
      "embedded SDRAM UART bridge smoke test passed"
    );
    $finish;
  end
