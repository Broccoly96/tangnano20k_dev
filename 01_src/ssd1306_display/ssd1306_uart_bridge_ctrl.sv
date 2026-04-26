`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : ssd1306_uart_bridge_ctrl.sv
// Description  : Minimal UART ASCII bridge for SSD1306 display control.
//                Accepted command lines:
//                  I
//                  C
//                  O
//                  X
//                  W
//////////////////////////////////////////////////////////////////////////////////

module ssd1306_uart_bridge_ctrl #(
  parameter int unsigned CLK_HZ          = 24_000_000,
  parameter int unsigned I2C_BIT_RATE_HZ = 400_000,
  parameter logic [6:0]  I2C_SLAVE_ADDR  = ssd1306_uart_proto_pkg::SSD1306_DEFAULT_SLAVE_ADDR,
  parameter int unsigned BULK_RX_TIMEOUT_CYCLES = 24_000_000
) (
  input  logic I_CLK,
  input  logic I_RST_N,
  input  logic I_ENABLE,
  input  logic I_CLI_RX_VALID,
  input  logic [7:0] I_CLI_RX_DATA,
  input  logic I_I2C_SDA_IN,
  input  logic I_I2C_SCL_IN,
  output logic O_I2C_SDA_DRIVE_LOW,
  output logic O_I2C_SCL_DRIVE_LOW,
  output logic O_CMD_BUSY,
  uart_log_evt_if.producer HOST_EVT_IF
);

  import ssd1306_uart_proto_pkg::*;

  localparam int unsigned MAX_LINE_BYTES   = 4;
  localparam int unsigned EVT_FIFO_DEPTH   = 4;
  localparam int unsigned EVT_FIFO_PTR_W   = (EVT_FIFO_DEPTH <= 1) ? 1 : $clog2(EVT_FIFO_DEPTH);
  localparam int unsigned EVT_FIFO_CNT_W   = $clog2(EVT_FIFO_DEPTH + 1);
  localparam int unsigned BULK_RX_TIMEOUT_W =
    (BULK_RX_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(BULK_RX_TIMEOUT_CYCLES + 1);
  localparam int unsigned FRAME_WORDS      = SSD1306_FRAME_BYTES / 4;
  localparam int unsigned FRAME_WORD_IDX_W = (FRAME_WORDS <= 1) ? 1 : $clog2(FRAME_WORDS + 1);
  localparam int unsigned FRAME_BYTE_IDX_W = (SSD1306_FRAME_BYTES <= 1) ? 1 : $clog2(SSD1306_FRAME_BYTES);

  typedef enum logic [1:0] {
    BULK_IDLE,
    BULK_WRITE_RECV,
    BULK_WRITE_WAIT_DONE
  } st_bulk_e;

  st_bulk_e st_bulk;

  logic [7:0]  r_line [0:MAX_LINE_BYTES-1];
  logic [2:0]  r_line_len;
  logic        r_line_overflow;

  logic        r_disp_req_valid;
  logic [2:0]  r_disp_req_op;
  logic [2:0]  r_last_req_op;
  logic        s_disp_req_ready;
  logic        s_disp_done_valid;
  logic [2:0]  s_disp_done_op;
  logic        s_disp_done_ok;
  logic [31:0] s_disp_done_status;
  logic [31:0] s_disp_done_detail;
  logic        s_disp_busy;

  logic [103:0] r_evt_fifo_mem [0:EVT_FIFO_DEPTH-1];
  logic [EVT_FIFO_PTR_W-1:0] r_evt_wr_ptr;
  logic [EVT_FIFO_PTR_W-1:0] r_evt_rd_ptr;
  logic [EVT_FIFO_CNT_W-1:0] r_evt_count;
  logic        s_evt_fifo_full;
  logic        s_evt_fifo_empty;
  logic        s_evt_pop;

  logic        r_evt_push_valid;
  logic [7:0]  r_evt_push_id;
  logic [31:0] r_evt_push_arg0;
  logic [31:0] r_evt_push_arg1;
  logic [31:0] r_evt_push_arg2;
  logic        s_evt_push_fire;

  logic        l_bulk_rx_word_valid;
  logic [31:0] l_bulk_rx_word_data;
  logic        l_bulk_rx_word_last;
  logic        l_bulk_rx_word_ready;
  logic        l_bulk_rx_block_done;
  logic [15:0] l_bulk_rx_block_bytes;
  logic [7:0]  l_bulk_rx_block_seq;
  logic        l_bulk_rx_abort_valid;
  logic [31:0] l_bulk_rx_abort_code;

  logic [7:0] r_frame_buffer [0:SSD1306_FRAME_BYTES-1];
  logic [FRAME_BYTE_IDX_W-1:0] s_disp_frame_byte_idx;
  logic [7:0] s_disp_frame_byte;
  logic [FRAME_WORD_IDX_W-1:0] r_bulk_word_index;
  logic [15:0] r_bulk_received_bytes;
  logic [7:0]  r_bulk_chunk_index;
  logic [BULK_RX_TIMEOUT_W-1:0] r_bulk_timeout_cnt;

  logic s_bulk_active;
  logic s_cli_enable;
  logic s_disp_req_fire;

  assign s_bulk_active     = (st_bulk != BULK_IDLE);
  assign s_cli_enable      = I_ENABLE && (HOST_EVT_IF.enable || s_bulk_active || s_disp_busy || r_disp_req_valid);
  assign O_CMD_BUSY        = s_bulk_active || s_disp_busy || r_disp_req_valid;
  assign s_disp_req_fire   = r_disp_req_valid && s_disp_req_ready;

  assign s_evt_fifo_full   = (r_evt_count == EVT_FIFO_DEPTH);
  assign s_evt_fifo_empty  = (r_evt_count == 0);
  assign s_evt_pop         = HOST_EVT_IF.evt_valid && HOST_EVT_IF.evt_ready;
  assign s_evt_push_fire   = r_evt_push_valid && !s_evt_fifo_full;

  assign HOST_EVT_IF.evt_valid = !s_evt_fifo_empty;
  assign HOST_EVT_IF.evt_id    = s_evt_fifo_empty ? 8'h00 : r_evt_fifo_mem[r_evt_rd_ptr][103:96];
  assign HOST_EVT_IF.arg0      = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][95:64];
  assign HOST_EVT_IF.arg1      = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][63:32];
  assign HOST_EVT_IF.arg2      = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][31:0];

  assign l_bulk_rx_word_ready  = (st_bulk == BULK_WRITE_RECV) && (r_bulk_word_index < FRAME_WORDS);
  assign s_disp_frame_byte     = r_frame_buffer[s_disp_frame_byte_idx];

  task automatic arm_event(
    input logic [7:0]  evt_id,
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

  task automatic issue_req(input logic [2:0] req_op);
    begin
      if (O_CMD_BUSY) begin
        arm_event(EVT_CMD_ERR, ERR_BUSY, {24'h0, r_line[0]}, 32'h0000_0000);
      end else begin
        r_disp_req_valid <= 1'b1;
        r_disp_req_op    <= req_op;
        r_last_req_op    <= req_op;
      end
    end
  endtask

  task automatic decode_line;
    begin
      if (r_line_overflow) begin
        arm_event(EVT_CMD_ERR, ERR_BAD_ASCII_FIELD, 32'hFFFF_FFFF, 32'h0000_0000);
      end else if (r_line_len == 0) begin
      end else if ((r_line_len == 1) && (r_line[0] == ASCII_CMD_INIT)) begin
        issue_req(DISP_OP_INIT);
      end else if ((r_line_len == 1) && (r_line[0] == ASCII_CMD_CLEAR)) begin
        issue_req(DISP_OP_CLEAR);
      end else if ((r_line_len == 1) && (r_line[0] == ASCII_CMD_ON)) begin
        issue_req(DISP_OP_ON);
      end else if ((r_line_len == 1) && (r_line[0] == ASCII_CMD_OFF)) begin
        issue_req(DISP_OP_OFF);
      end else if ((r_line_len == 1) && (r_line[0] == ASCII_CMD_WRITE)) begin
        if (O_CMD_BUSY) begin
          arm_event(EVT_CMD_ERR, ERR_BUSY, {24'h0, ASCII_CMD_WRITE}, 32'h0000_0000);
        end else begin
          st_bulk             <= BULK_WRITE_RECV;
          r_bulk_word_index   <= '0;
          r_bulk_received_bytes <= 16'h0000;
          r_bulk_chunk_index  <= 8'h00;
          r_bulk_timeout_cnt  <= '0;
          arm_event(EVT_FRAME_OK, SSD1306_FRAME_BYTES, SSD1306_FRAME_BLOCKS, 32'h0000_0000);
        end
      end else begin
        arm_event(EVT_CMD_ERR, ERR_UNSUPPORTED_CMD, {24'h0, r_line[0]}, {29'h0, r_line_len});
      end
    end
  endtask

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
    .O_FRAME_BYTE_IDX     (s_disp_frame_byte_idx),
    .I_FRAME_BYTE_DATA    (s_disp_frame_byte),
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

  sdram_uart_bulk_rx u_sdram_uart_bulk_rx (
    .I_CLK                (I_CLK),
    .I_RST_N              (I_RST_N),
    .I_ENABLE             (s_cli_enable && (st_bulk == BULK_WRITE_RECV)),
    .I_RX_VALID           (I_CLI_RX_VALID),
    .I_RX_DATA            (I_CLI_RX_DATA),
    .O_WORD_VALID         (l_bulk_rx_word_valid),
    .O_WORD_DATA          (l_bulk_rx_word_data),
    .O_WORD_LAST_IN_BLOCK (l_bulk_rx_word_last),
    .I_WORD_READY         (l_bulk_rx_word_ready),
    .O_BLOCK_DONE         (l_bulk_rx_block_done),
    .O_BLOCK_BYTES        (l_bulk_rx_block_bytes),
    .O_BLOCK_SEQ          (l_bulk_rx_block_seq),
    .O_ABORT_VALID        (l_bulk_rx_abort_valid),
    .O_ABORT_CODE         (l_bulk_rx_abort_code)
  );

  // Small event FIFO so bulk progress and controller completions can be drained
  // without requiring combinational backpressure into the command parser.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_evt_wr_ptr <= '0;
      r_evt_rd_ptr <= '0;
      r_evt_count  <= '0;
    end else begin
      if (s_evt_push_fire) begin
        r_evt_fifo_mem[r_evt_wr_ptr] <= {r_evt_push_id, r_evt_push_arg0, r_evt_push_arg1, r_evt_push_arg2};
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
        default: begin end
      endcase
    end
  end

  // Parses ASCII commands, manages raw frame upload state, and forwards high-level
  // operations into the SSD1306 display controller.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    integer line_idx;
    logic [15:0] next_total_bytes;
    if (!I_RST_N) begin
      r_line_len            <= '0;
      r_line_overflow       <= 1'b0;
      for (line_idx = 0; line_idx < MAX_LINE_BYTES; line_idx++) begin
        r_line[line_idx]    <= 8'h00;
      end
      r_disp_req_valid      <= 1'b0;
      r_disp_req_op         <= DISP_OP_OFF;
      r_last_req_op         <= DISP_OP_OFF;
      r_evt_push_valid      <= 1'b0;
      r_evt_push_id         <= 8'h00;
      r_evt_push_arg0       <= 32'h0;
      r_evt_push_arg1       <= 32'h0;
      r_evt_push_arg2       <= 32'h0;
      st_bulk               <= BULK_IDLE;
      r_bulk_word_index     <= '0;
      r_bulk_received_bytes <= '0;
      r_bulk_chunk_index    <= '0;
      r_bulk_timeout_cnt    <= '0;
    end else begin
      if (s_disp_req_fire) begin
        r_disp_req_valid <= 1'b0;
      end

      if (s_evt_push_fire) begin
        r_evt_push_valid <= 1'b0;
      end

      if (st_bulk == BULK_WRITE_RECV) begin
        if (BULK_RX_TIMEOUT_CYCLES > 0) begin
          r_bulk_timeout_cnt <= r_bulk_timeout_cnt + 1'b1;
        end
      end else begin
        r_bulk_timeout_cnt <= '0;
      end

      if ((st_bulk == BULK_WRITE_RECV) && (BULK_RX_TIMEOUT_CYCLES > 0) &&
          (r_bulk_timeout_cnt >= BULK_RX_TIMEOUT_CYCLES)) begin
        st_bulk <= BULK_IDLE;
        arm_event(EVT_FRAME_ERR, ERR_BULK_TIMEOUT, r_bulk_received_bytes, 32'h0000_0000);
      end

      if (I_ENABLE && HOST_EVT_IF.enable && (st_bulk == BULK_IDLE) && I_CLI_RX_VALID) begin
        if (I_CLI_RX_DATA == ASCII_CMD_CR) begin
        end else if (I_CLI_RX_DATA == ASCII_CMD_LF) begin
          decode_line();
          r_line_len      <= '0;
          r_line_overflow <= 1'b0;
        end else if (I_CLI_RX_DATA < 8'h20) begin
          // Source-select control bytes are forwarded by uart_log_cli as escaped
          // literals. Ignore non-printable controls so they do not poison the
          // next ASCII command line.
        end else if (r_line_len < MAX_LINE_BYTES) begin
          r_line[r_line_len] <= I_CLI_RX_DATA;
          r_line_len         <= r_line_len + 1'b1;
        end else begin
          r_line_overflow <= 1'b1;
        end
      end

      if ((st_bulk == BULK_WRITE_RECV) && l_bulk_rx_word_valid && l_bulk_rx_word_ready) begin
        if (r_bulk_word_index < FRAME_WORDS) begin
          r_frame_buffer[(r_bulk_word_index * 4) + 0] <= l_bulk_rx_word_data[7:0];
          r_frame_buffer[(r_bulk_word_index * 4) + 1] <= l_bulk_rx_word_data[15:8];
          r_frame_buffer[(r_bulk_word_index * 4) + 2] <= l_bulk_rx_word_data[23:16];
          r_frame_buffer[(r_bulk_word_index * 4) + 3] <= l_bulk_rx_word_data[31:24];
          r_bulk_word_index <= r_bulk_word_index + 1'b1;
          r_bulk_timeout_cnt <= '0;
        end
      end

      if ((st_bulk == BULK_WRITE_RECV) && l_bulk_rx_abort_valid) begin
        st_bulk <= BULK_IDLE;
        arm_event(EVT_FRAME_ABORT, l_bulk_rx_abort_code, r_bulk_received_bytes, 32'h0000_0000);
      end

      if ((st_bulk == BULK_WRITE_RECV) && l_bulk_rx_block_done) begin
        r_bulk_timeout_cnt <= '0;
        if (l_bulk_rx_block_bytes == 0) begin
          if (r_bulk_received_bytes != SSD1306_FRAME_BYTES) begin
            st_bulk <= BULK_IDLE;
            arm_event(EVT_FRAME_ERR, ERR_FRAME_SIZE, r_bulk_received_bytes, SSD1306_FRAME_BYTES);
          end else begin
            r_disp_req_valid <= 1'b1;
            r_disp_req_op    <= DISP_OP_FRAME_WRITE;
            r_last_req_op    <= DISP_OP_FRAME_WRITE;
            st_bulk          <= BULK_WRITE_WAIT_DONE;
          end
        end else if (l_bulk_rx_block_bytes > MAX_BULK_PAYLOAD_BYTES) begin
          st_bulk <= BULK_IDLE;
          arm_event(EVT_FRAME_ERR, ERR_BULK_LEN, l_bulk_rx_block_bytes, MAX_BULK_PAYLOAD_BYTES);
        end else begin
          next_total_bytes = r_bulk_received_bytes + l_bulk_rx_block_bytes;
          if (next_total_bytes > SSD1306_FRAME_BYTES) begin
            st_bulk <= BULK_IDLE;
            arm_event(EVT_FRAME_ERR, ERR_FRAME_SIZE, next_total_bytes, SSD1306_FRAME_BYTES);
          end else begin
            r_bulk_received_bytes <= next_total_bytes;
            r_bulk_chunk_index    <= r_bulk_chunk_index + 1'b1;
            arm_event(
              EVT_FRAME_PROG,
              pack_frame_progress_arg0(r_bulk_chunk_index, l_bulk_rx_block_bytes[7:0], next_total_bytes),
              {24'h0, l_bulk_rx_block_seq},
              32'h0000_0000
            );
          end
        end
      end

      if (s_disp_done_valid) begin
        if (s_disp_done_ok) begin
          if (s_disp_done_op == DISP_OP_FRAME_WRITE) begin
            st_bulk <= BULK_IDLE;
            arm_event(EVT_FRAME_DONE, SSD1306_FRAME_BYTES, SSD1306_FRAME_BLOCKS, 32'h0000_0000);
          end else begin
            arm_event(EVT_CMD_ACK, {29'h0, s_disp_done_op}, 32'h0000_0000, 32'h0000_0000);
          end
        end else if (s_disp_done_op == DISP_OP_FRAME_WRITE) begin
          st_bulk <= BULK_IDLE;
          arm_event(EVT_FRAME_ERR, s_disp_done_status, s_disp_done_detail, {29'h0, s_disp_done_op});
        end else begin
          arm_event(EVT_CMD_ERR, s_disp_done_status, s_disp_done_detail, {29'h0, s_disp_done_op});
        end
      end
    end
  end

endmodule