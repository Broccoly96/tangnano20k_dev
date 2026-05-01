`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : ssd1306_sdram_uart_bridge_ctrl.sv
// Purpose      : UART bridge that refreshes the SSD1306 from SDRAM-backed frame
//                storage.
// Behavior     : Parses ASCII control commands, requests frame chunks from the
//                SDRAM host interface, streams bytes into
//                `ssd1306_display_stream_ctrl`, and optionally auto-refreshes
//                at a programmable frame rate.
// Usage        : Supported commands are `I`, `C`, `O`, `X`, `R`, `E`, `D`,
//                and `F<n>` / `F<nn>` for manual refresh, auto-refresh enable,
//                auto-refresh disable, and FPS configuration.
//////////////////////////////////////////////////////////////////////////////////

module ssd1306_sdram_uart_bridge_ctrl #(
  parameter int unsigned CLK_HZ                = 48_000_000,
  parameter int unsigned I2C_BIT_RATE_HZ       = 400_000,
  parameter logic [6:0]  I2C_SLAVE_ADDR        =
    ssd1306_uart_proto_pkg::SSD1306_DEFAULT_SLAVE_ADDR,
  parameter logic [20:0] FRAMEBUFFER_BASE_ADDR = 21'h10000,
  parameter int unsigned DEFAULT_REFRESH_FPS   = 30
) (
  input  logic I_CLK,
  input  logic I_RST_N,
  input  logic I_ENABLE,
  input  logic I_CLI_RX_VALID,
  input  logic [7:0] I_CLI_RX_DATA,
  output logic O_MEM_REQ_VALID,
  input  logic I_MEM_REQ_READY,
  output logic [20:0] O_MEM_REQ_ADDR,
  output logic [8:0] O_MEM_REQ_WORDS,
  input  logic I_MEM_RAW_DONE,
  input  logic I_MEM_RAW_ERR_VALID,
  input  logic [31:0] I_MEM_RAW_ERR_CODE,
  input  logic I_MEM_RAW_RD_VALID,
  output logic O_MEM_RAW_RD_READY,
  input  logic [8:0] I_MEM_RAW_RD_INDEX,
  input  logic [31:0] I_MEM_RAW_RD_DATA,
  input  logic I_MEM_RAW_RD_LAST,
  input  logic I_I2C_SDA_IN,
  input  logic I_I2C_SCL_IN,
  output logic O_I2C_SDA_DRIVE_LOW,
  output logic O_I2C_SCL_DRIVE_LOW,
  output logic O_CMD_BUSY,
  uart_log_evt_if.producer HOST_EVT_IF
);

  import ssd1306_uart_proto_pkg::*;

  localparam int unsigned MAX_LINE_BYTES = 4;
  localparam int unsigned EVT_FIFO_DEPTH = 8;
  localparam int unsigned EVT_FIFO_PTR_W =
    (EVT_FIFO_DEPTH <= 1) ? 1 : $clog2(EVT_FIFO_DEPTH);
  localparam int unsigned EVT_FIFO_CNT_W = $clog2(EVT_FIFO_DEPTH + 1);
  localparam int unsigned FRAME_WORDS    = SSD1306_FRAME_BYTES / 4;
  localparam int unsigned FRAME_BYTE_IDX_W =
    (SSD1306_FRAME_BYTES <= 1) ? 1 : $clog2(SSD1306_FRAME_BYTES);
  localparam logic [3:0] DISP_OP_REFRESH  = 4'd5;
  localparam logic [3:0] DISP_OP_AUTO_ON  = 4'd6;
  localparam logic [3:0] DISP_OP_AUTO_OFF = 4'd7;
  localparam logic [3:0] DISP_OP_SET_FPS  = 4'd8;
  localparam logic [7:0] ASCII_CMD_REFRESH  = 8'h52; // R
  localparam logic [7:0] ASCII_CMD_AUTO_ON  = 8'h45; // E
  localparam logic [7:0] ASCII_CMD_AUTO_OFF = 8'h44; // D
  localparam logic [7:0] ASCII_CMD_SET_FPS  = 8'h46; // F

  logic [7:0] r_line [0:MAX_LINE_BYTES-1];
  logic [2:0] r_line_len;
  logic r_line_overflow;

  logic r_evt_push_valid;
  logic [7:0] r_evt_push_id;
  logic [31:0] r_evt_push_arg0;
  logic [31:0] r_evt_push_arg1;
  logic [31:0] r_evt_push_arg2;
  logic [103:0] r_evt_fifo_mem [0:EVT_FIFO_DEPTH-1];
  logic [EVT_FIFO_PTR_W-1:0] r_evt_wr_ptr;
  logic [EVT_FIFO_PTR_W-1:0] r_evt_rd_ptr;
  logic [EVT_FIFO_CNT_W-1:0] r_evt_count;
  logic s_evt_fifo_full;
  logic s_evt_fifo_empty;
  logic s_evt_pop;
  logic s_evt_push_fire;

  logic r_disp_req_valid;
  logic [2:0] r_disp_req_op;
  logic s_disp_req_ready;
  logic s_disp_done_valid;
  logic [2:0] s_disp_done_op;
  logic s_disp_done_ok;
  logic [31:0] s_disp_done_status;
  logic [31:0] s_disp_done_detail;
  logic s_disp_busy;
  logic s_frame_byte_req;
  logic [FRAME_BYTE_IDX_W-1:0] s_frame_byte_idx;
  logic s_frame_byte_valid;
  logic [7:0] s_frame_byte_data;

  logic r_mem_req_valid;
  logic [20:0] r_mem_req_addr;
  logic [8:0] r_mem_req_words;
  logic [6:0] r_chunk_start_word;
  logic [8:0] r_chunk_word_count;
  logic r_chunk_valid;
  logic r_chunk_error_fill;
  logic r_frame_byte_valid;
  logic [7:0] r_frame_byte_data;
  logic r_frame_byte_pending;
  logic [1:0] r_frame_byte_lane;
  logic r_refresh_active;
  logic r_refresh_report_on_done;
  logic r_refresh_error_seen;
  logic [31:0] r_refresh_error_code;
  logic [6:0] r_pending_chunk_start_word;
  logic [8:0] r_pending_chunk_word_count;
  logic r_auto_refresh_enable;
  logic [7:0] r_refresh_fps;
  logic [31:0] r_refresh_period_cycles;
  logic [31:0] r_refresh_countdown;

  logic [6:0] s_frame_word_idx;
  logic [6:0] s_req_chunk_start_word;
  logic [8:0] s_req_chunk_word_count;
  logic s_frame_byte_cache_hit;
  logic s_chunk_wr_en;
  logic [6:0] s_chunk_wr_addr;
  logic [31:0] s_chunk_wr_data;
  logic s_chunk_rd_en;
  logic [6:0] s_chunk_rd_addr;
  logic [31:0] s_chunk_rd_data;

  assign s_evt_fifo_full   = (r_evt_count == EVT_FIFO_DEPTH);
  assign s_evt_fifo_empty  = (r_evt_count == 0);
  assign s_evt_pop         = HOST_EVT_IF.evt_valid && HOST_EVT_IF.evt_ready;
  assign s_evt_push_fire   = r_evt_push_valid && !s_evt_fifo_full;
  assign HOST_EVT_IF.evt_valid = !s_evt_fifo_empty;
  assign HOST_EVT_IF.evt_id    =
    s_evt_fifo_empty ? 8'h00 : r_evt_fifo_mem[r_evt_rd_ptr][103:96];
  assign HOST_EVT_IF.arg0      =
    s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][95:64];
  assign HOST_EVT_IF.arg1      =
    s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][63:32];
  assign HOST_EVT_IF.arg2      =
    s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][31:0];

  assign O_MEM_REQ_VALID = r_mem_req_valid;
  assign O_MEM_REQ_ADDR  = r_mem_req_addr;
  assign O_MEM_REQ_WORDS = r_mem_req_words;
  assign O_MEM_RAW_RD_READY = 1'b1;
  assign O_CMD_BUSY      =
    r_disp_req_valid || s_disp_busy || r_mem_req_valid || r_refresh_active;

  assign s_frame_word_idx = s_frame_byte_idx[FRAME_BYTE_IDX_W-1:2];
  assign s_frame_byte_valid = r_frame_byte_valid;
  assign s_frame_byte_data = r_frame_byte_data;
  assign s_frame_byte_cache_hit =
    r_chunk_valid &&
    (s_frame_word_idx >= r_chunk_start_word) &&
    (s_frame_word_idx < (r_chunk_start_word + r_chunk_word_count));
  assign s_chunk_wr_en = I_MEM_RAW_RD_VALID && O_MEM_RAW_RD_READY;
  assign s_chunk_wr_addr = I_MEM_RAW_RD_INDEX[6:0];
  assign s_chunk_wr_data = I_MEM_RAW_RD_DATA;
  assign s_chunk_rd_en =
    s_frame_byte_req &&
    s_frame_byte_cache_hit &&
    !r_chunk_error_fill &&
    !r_frame_byte_pending &&
    !r_frame_byte_valid;
  assign s_chunk_rd_addr = s_frame_word_idx - r_chunk_start_word;

  function automatic [31:0] fps_to_period_cycles(input logic [7:0] fps);
    logic [31:0] safe_fps;
    begin
      safe_fps = (fps < 8'd1) ? 32'd1 : fps;
      fps_to_period_cycles = CLK_HZ / safe_fps;
      if (fps_to_period_cycles == 0) begin
        fps_to_period_cycles = 32'd1;
      end
    end
  endfunction

  function automatic [6:0] frame_chunk_start_word(
    input logic [6:0] word_idx
  );
    begin
      if (word_idx < 7'd26) begin
        frame_chunk_start_word = 7'd0;
      end else if (word_idx < 7'd52) begin
        frame_chunk_start_word = 7'd26;
      end else if (word_idx < 7'd78) begin
        frame_chunk_start_word = 7'd52;
      end else if (word_idx < 7'd104) begin
        frame_chunk_start_word = 7'd78;
      end else begin
        frame_chunk_start_word = 7'd104;
      end
    end
  endfunction

  function automatic [8:0] frame_chunk_word_count(
    input logic [6:0] chunk_start_word
  );
    begin
      if (chunk_start_word == 7'd104) begin
        frame_chunk_word_count = 9'd24;
      end else begin
        frame_chunk_word_count =
          sdram_uart_proto_pkg::MAX_BULK_PAYLOAD_WORDS[8:0];
      end
    end
  endfunction

  task automatic arm_event(
    input logic [7:0] evt_id,
    input logic [31:0] evt_arg0,
    input logic [31:0] evt_arg1,
    input logic [31:0] evt_arg2
  );
    begin
      r_evt_push_valid <= 1'b1;
      r_evt_push_id    <= evt_id;
      r_evt_push_arg0  <= evt_arg0;
      r_evt_push_arg1  <= evt_arg1;
      r_evt_push_arg2  <= evt_arg2;
    end
  endtask

  task automatic issue_display_req(input logic [2:0] req_op);
    begin
      if (O_CMD_BUSY) begin
        arm_event(
          EVT_CMD_ERR,
          ERR_BUSY,
          {24'h0, r_line[0]},
          32'h0000_0000
        );
      end else begin
        r_disp_req_valid <= 1'b1;
        r_disp_req_op    <= req_op;
      end
    end
  endtask

  function automatic logic [7:0] parse_decimal_digits(
    input logic [7:0] d0,
    input logic [7:0] d1,
    input logic has_second,
    output logic ok
  );
    logic [7:0] value;
    begin
      ok = 1'b0;
      value = 8'h00;
      if ((d0 < 8'h30) || (d0 > 8'h39)) begin
        parse_decimal_digits = 8'h00;
      end else if (has_second && ((d1 < 8'h30) || (d1 > 8'h39))) begin
        parse_decimal_digits = 8'h00;
      end else begin
        value = d0 - 8'h30;
        if (has_second) begin
          value = (value * 8'd10) + (d1 - 8'h30);
        end
        ok = (value >= 8'd1) && (value <= 8'd60);
        parse_decimal_digits = value;
      end
    end
  endfunction

  assign s_req_chunk_start_word = frame_chunk_start_word(s_frame_word_idx);
  assign s_req_chunk_word_count = frame_chunk_word_count(s_req_chunk_start_word);

  sdram_raw_word_bram #(
    .ADDR_W (7),
    .DEPTH  (128)
  ) u_chunk_bram (
    .I_CLK     (I_CLK),
    .I_WR_EN   (s_chunk_wr_en),
    .I_WR_ADDR (s_chunk_wr_addr),
    .I_WR_DATA (s_chunk_wr_data),
    .I_RD_EN   (s_chunk_rd_en),
    .I_RD_ADDR (s_chunk_rd_addr),
    .O_RD_DATA (s_chunk_rd_data)
  );

  ssd1306_display_stream_ctrl #(
    .CLK_HZ          (CLK_HZ),
    .I2C_BIT_RATE_HZ (I2C_BIT_RATE_HZ),
    .I2C_SLAVE_ADDR  (I2C_SLAVE_ADDR)
  ) u_ssd1306_display_stream_ctrl (
    .I_CLK                (I_CLK),
    .I_RST_N              (I_RST_N),
    .I_REQ_VALID          (r_disp_req_valid),
    .O_REQ_READY          (s_disp_req_ready),
    .I_REQ_OP             (r_disp_req_op),
    .O_FRAME_BYTE_REQ     (s_frame_byte_req),
    .O_FRAME_BYTE_IDX     (s_frame_byte_idx),
    .I_FRAME_BYTE_VALID   (s_frame_byte_valid),
    .I_FRAME_BYTE_DATA    (s_frame_byte_data),
    .O_DONE_VALID         (s_disp_done_valid),
    .O_DONE_OP            (s_disp_done_op),
    .O_DONE_OK            (s_disp_done_ok),
    .O_DONE_STATUS        (s_disp_done_status),
    .O_DONE_DETAIL        (s_disp_done_detail),
    .O_BUSY               (s_disp_busy),
    .I_I2C_SDA_IN         (I_I2C_SDA_IN),
    .I_I2C_SCL_IN         (I_I2C_SCL_IN),
    .O_I2C_SDA_DRIVE_LOW  (O_I2C_SDA_DRIVE_LOW),
    .O_I2C_SCL_DRIVE_LOW  (O_I2C_SCL_DRIVE_LOW)
  );

  // Main control FSM summary:
  // - Parses ASCII commands while idle.
  // - Launches manual or periodic frame refresh requests.
  // - Caches SDRAM read chunks on demand for the display stream controller.
  // - Aggregates errors so a refresh reports the first memory-side failure or
  //   the display-side failure once the transfer completes.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    integer line_idx;
    logic fps_ok;
    logic [7:0] fps_value;
    if (!I_RST_N) begin
      r_line_len                 <= '0;
      r_line_overflow            <= 1'b0;
      for (line_idx = 0; line_idx < MAX_LINE_BYTES; line_idx++) begin
        r_line[line_idx] <= 8'h00;
      end
      r_evt_push_valid         <= 1'b0;
      r_evt_push_id            <= 8'h00;
      r_evt_push_arg0          <= 32'h0;
      r_evt_push_arg1          <= 32'h0;
      r_evt_push_arg2          <= 32'h0;
      r_evt_wr_ptr             <= '0;
      r_evt_rd_ptr             <= '0;
      r_evt_count              <= '0;
      r_disp_req_valid         <= 1'b0;
      r_disp_req_op            <= DISP_OP_OFF;
      r_mem_req_valid          <= 1'b0;
      r_mem_req_addr           <= FRAMEBUFFER_BASE_ADDR;
      r_mem_req_words          <= 9'd0;
      r_chunk_start_word       <= '0;
      r_chunk_word_count       <= '0;
      r_chunk_valid            <= 1'b0;
      r_chunk_error_fill       <= 1'b0;
      r_frame_byte_valid       <= 1'b0;
      r_frame_byte_data        <= 8'h00;
      r_frame_byte_pending     <= 1'b0;
      r_frame_byte_lane        <= 2'b00;
      r_refresh_active         <= 1'b0;
      r_refresh_report_on_done <= 1'b0;
      r_refresh_error_seen     <= 1'b0;
      r_refresh_error_code     <= 32'h0;
      r_pending_chunk_start_word <= '0;
      r_pending_chunk_word_count <= '0;
      r_auto_refresh_enable    <= 1'b0;
      r_refresh_fps            <= DEFAULT_REFRESH_FPS[7:0];
      r_refresh_period_cycles  <=
        fps_to_period_cycles(DEFAULT_REFRESH_FPS[7:0]);
      r_refresh_countdown      <=
        fps_to_period_cycles(DEFAULT_REFRESH_FPS[7:0]);
    end else begin
      r_frame_byte_valid <= 1'b0;

      if (r_frame_byte_pending) begin
        unique case (r_frame_byte_lane)
          2'd0: r_frame_byte_data <= s_chunk_rd_data[7:0];
          2'd1: r_frame_byte_data <= s_chunk_rd_data[15:8];
          2'd2: r_frame_byte_data <= s_chunk_rd_data[23:16];
          default: r_frame_byte_data <= s_chunk_rd_data[31:24];
        endcase
        r_frame_byte_valid   <= 1'b1;
        r_frame_byte_pending <= 1'b0;
      end else if (s_frame_byte_req &&
                   s_frame_byte_cache_hit &&
                   !r_frame_byte_valid) begin
        if (r_chunk_error_fill) begin
          r_frame_byte_data  <= 8'h00;
          r_frame_byte_valid <= 1'b1;
        end else if (s_chunk_rd_en) begin
          r_frame_byte_lane    <= s_frame_byte_idx[1:0];
          r_frame_byte_pending <= 1'b1;
        end
      end

      if (s_evt_push_fire) begin
        r_evt_push_valid <= 1'b0;
        r_evt_fifo_mem[r_evt_wr_ptr] <= {
          r_evt_push_id,
          r_evt_push_arg0,
          r_evt_push_arg1,
          r_evt_push_arg2
        };
        if (r_evt_wr_ptr == EVT_FIFO_DEPTH - 1) begin
          r_evt_wr_ptr <= '0;
        end else begin
          r_evt_wr_ptr <= r_evt_wr_ptr + 1'b1;
        end
      end

      if (s_evt_pop) begin
        if (r_evt_rd_ptr == EVT_FIFO_DEPTH - 1) begin
          r_evt_rd_ptr <= '0;
        end else begin
          r_evt_rd_ptr <= r_evt_rd_ptr + 1'b1;
        end
      end

      case ({s_evt_push_fire, s_evt_pop})
        2'b10: r_evt_count <= r_evt_count + 1'b1;
        2'b01: r_evt_count <= r_evt_count - 1'b1;
        default: begin
        end
      endcase

      if (r_disp_req_valid && s_disp_req_ready) begin
        r_disp_req_valid <= 1'b0;
      end

      if (r_auto_refresh_enable) begin
        if (r_refresh_countdown != 0) begin
          r_refresh_countdown <= r_refresh_countdown - 1'b1;
        end
      end else begin
        r_refresh_countdown <= r_refresh_period_cycles;
      end

      if (r_mem_req_valid && I_MEM_REQ_READY) begin
        r_mem_req_valid <= 1'b0;
      end

      if (I_MEM_RAW_DONE) begin
        r_chunk_start_word <= r_pending_chunk_start_word;
        r_chunk_word_count <= r_pending_chunk_word_count;
        r_chunk_valid      <= 1'b1;
        r_chunk_error_fill <= 1'b0;
      end

      if (I_MEM_RAW_ERR_VALID) begin
        r_chunk_start_word   <= r_pending_chunk_start_word;
        r_chunk_word_count   <= r_pending_chunk_word_count;
        r_chunk_valid        <= 1'b1;
        r_chunk_error_fill   <= 1'b1;
        r_refresh_error_seen <= 1'b1;
        if (!r_refresh_error_seen) begin
          r_refresh_error_code <= I_MEM_RAW_ERR_CODE;
        end
      end

      if (s_frame_byte_req && !s_frame_byte_valid && !r_mem_req_valid) begin
        r_mem_req_valid            <= 1'b1;
        r_mem_req_addr             <= FRAMEBUFFER_BASE_ADDR +
                                      s_req_chunk_start_word;
        r_mem_req_words            <= s_req_chunk_word_count;
        r_pending_chunk_start_word <= s_req_chunk_start_word;
        r_pending_chunk_word_count <= s_req_chunk_word_count;
        r_chunk_valid              <= 1'b0;
        r_chunk_error_fill         <= 1'b0;
      end

      if (I_ENABLE && HOST_EVT_IF.enable && I_CLI_RX_VALID) begin
        if (I_CLI_RX_DATA == ASCII_CMD_CR) begin
        end else if (I_CLI_RX_DATA == ASCII_CMD_LF) begin
          if (r_line_overflow) begin
            arm_event(
              EVT_CMD_ERR,
              ERR_BAD_ASCII_FIELD,
              32'hFFFF_FFFF,
              32'h0000_0000
            );
          end else if (r_line_len == 1 && r_line[0] == ASCII_CMD_INIT) begin
            issue_display_req(DISP_OP_INIT);
          end else if (r_line_len == 1 && r_line[0] == ASCII_CMD_CLEAR) begin
            issue_display_req(DISP_OP_CLEAR);
          end else if (r_line_len == 1 && r_line[0] == ASCII_CMD_ON) begin
            issue_display_req(DISP_OP_ON);
          end else if (r_line_len == 1 && r_line[0] == ASCII_CMD_OFF) begin
            issue_display_req(DISP_OP_OFF);
          end else if (r_line_len == 1 && r_line[0] == ASCII_CMD_REFRESH) begin
            if (O_CMD_BUSY) begin
              arm_event(
                EVT_CMD_ERR,
                ERR_BUSY,
                {24'h0, ASCII_CMD_REFRESH},
                32'h0000_0000
              );
            end else begin
              r_refresh_active         <= 1'b1;
              r_refresh_report_on_done <= 1'b1;
              r_refresh_error_seen     <= 1'b0;
              r_refresh_error_code     <= 32'h0000_0000;
              r_chunk_valid            <= 1'b0;
              r_chunk_error_fill       <= 1'b0;
              r_disp_req_valid         <= 1'b1;
              r_disp_req_op            <= DISP_OP_FRAME_WRITE;
              r_refresh_countdown      <= r_refresh_period_cycles;
            end
          end else if (r_line_len == 1 && r_line[0] == ASCII_CMD_AUTO_ON) begin
            r_auto_refresh_enable <= 1'b1;
            r_refresh_countdown   <= r_refresh_period_cycles;
            arm_event(
              EVT_CMD_ACK,
              {28'h0, DISP_OP_AUTO_ON},
              {24'h0, r_refresh_fps},
              32'h0000_0000
            );
          end else if (r_line_len == 1 && r_line[0] == ASCII_CMD_AUTO_OFF) begin
            r_auto_refresh_enable <= 1'b0;
            arm_event(
              EVT_CMD_ACK,
              {28'h0, DISP_OP_AUTO_OFF},
              {24'h0, r_refresh_fps},
              32'h0000_0000
            );
          end else if ((r_line_len == 2 || r_line_len == 3) &&
                       (r_line[0] == ASCII_CMD_SET_FPS)) begin
            fps_value = parse_decimal_digits(
              r_line[1],
              r_line[2],
              (r_line_len == 3),
              fps_ok
            );
            if (!fps_ok) begin
              arm_event(
                EVT_CMD_ERR,
                ERR_BAD_ASCII_FIELD,
                {24'h0, ASCII_CMD_SET_FPS},
                32'h0000_0000
              );
            end else begin
              r_refresh_fps           <= fps_value;
              r_refresh_period_cycles <= fps_to_period_cycles(fps_value);
              r_refresh_countdown     <= fps_to_period_cycles(fps_value);
              arm_event(
                EVT_CMD_ACK,
                {28'h0, DISP_OP_SET_FPS},
                {24'h0, fps_value},
                fps_to_period_cycles(fps_value)
              );
            end
          end else if (r_line_len != 0) begin
            arm_event(
              EVT_CMD_ERR,
              ERR_UNSUPPORTED_CMD,
              {24'h0, r_line[0]},
              {29'h0, r_line_len}
            );
          end

          r_line_len      <= '0;
          r_line_overflow <= 1'b0;
        end else if (I_CLI_RX_DATA < 8'h20) begin
        end else if (r_line_len < MAX_LINE_BYTES) begin
          r_line[r_line_len] <= I_CLI_RX_DATA;
          r_line_len         <= r_line_len + 1'b1;
        end else begin
          r_line_overflow <= 1'b1;
        end
      end

      if (r_auto_refresh_enable &&
          !O_CMD_BUSY &&
          (r_refresh_countdown == 0)) begin
        r_refresh_active         <= 1'b1;
        r_refresh_report_on_done <= 1'b0;
        r_refresh_error_seen     <= 1'b0;
        r_refresh_error_code     <= 32'h0000_0000;
        r_chunk_valid            <= 1'b0;
        r_chunk_error_fill       <= 1'b0;
        r_disp_req_valid         <= 1'b1;
        r_disp_req_op            <= DISP_OP_FRAME_WRITE;
        r_refresh_countdown      <= r_refresh_period_cycles;
      end

      if (s_disp_done_valid) begin
        if (s_disp_done_op == DISP_OP_FRAME_WRITE) begin
          r_refresh_active <= 1'b0;
          r_chunk_valid    <= 1'b0;
          r_chunk_error_fill <= 1'b0;
          if (r_refresh_report_on_done) begin
            if (s_disp_done_ok && !r_refresh_error_seen) begin
              arm_event(
                EVT_CMD_ACK,
                {28'h0, DISP_OP_REFRESH},
                {24'h0, r_refresh_fps},
                32'h0000_0000
              );
            end else begin
              arm_event(
                EVT_CMD_ERR,
                s_disp_done_ok ? r_refresh_error_code : s_disp_done_status,
                s_disp_done_ok ? 32'h0000_0000 : s_disp_done_detail,
                {28'h0, DISP_OP_REFRESH}
              );
            end
          end else if ((!s_disp_done_ok || r_refresh_error_seen) &&
                       !r_evt_push_valid) begin
            arm_event(
              EVT_CMD_ERR,
              s_disp_done_ok ? r_refresh_error_code : s_disp_done_status,
              s_disp_done_ok ? 32'h0000_0000 : s_disp_done_detail,
              {28'h0, DISP_OP_REFRESH}
            );
          end
        end else if (s_disp_done_ok) begin
          arm_event(
            EVT_CMD_ACK,
            {29'h0, s_disp_done_op},
            32'h0000_0000,
            32'h0000_0000
          );
        end else begin
          arm_event(
            EVT_CMD_ERR,
            s_disp_done_status,
            s_disp_done_detail,
            {29'h0, s_disp_done_op}
          );
        end
      end
    end
  end

endmodule
