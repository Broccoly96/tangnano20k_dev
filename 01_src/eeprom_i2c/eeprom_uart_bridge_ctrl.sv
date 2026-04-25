`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : eeprom_uart_bridge_ctrl.sv
// Description  : UART host bridge for 24FC1025 EEPROM access.
//                - Accepts ASCII single read/write and BR/BW commands.
//                - Reuses the raw bulk RX frame parser for BW payload blocks.
//                - Emits uart_log_cli events for single completions and bulk
//                  progress/done notifications.
//////////////////////////////////////////////////////////////////////////////////

module eeprom_uart_bridge_ctrl #(
  parameter int unsigned I2C_BIT_RATE_HZ        = 100_000,
  parameter int unsigned BULK_RX_TIMEOUT_CYCLES = 24_000_000
) (
  input  logic             I_CLK,
  input  logic             I_RST_N,
  input  logic             I_ENABLE,
  input  logic             I_CLI_RX_VALID,
  input  logic [7:0]       I_CLI_RX_DATA,
  input  logic             I_I2C_SDA_IN,
  input  logic             I_I2C_SCL_IN,
  output logic             O_I2C_SDA_DRIVE_LOW,
  output logic             O_I2C_SCL_DRIVE_LOW,
  output logic             O_CMD_BUSY,
  uart_log_evt_if.producer HOST_EVT_IF
);

  import eeprom_uart_proto_pkg::*;

  localparam int unsigned EVT_FIFO_DEPTH    = 4;
  localparam int unsigned EVT_FIFO_PTR_W    = $clog2(EVT_FIFO_DEPTH);
  localparam int unsigned EVT_FIFO_CNT_W    = $clog2(EVT_FIFO_DEPTH + 1);
  localparam int unsigned BULK_RX_TIMEOUT_W =
    (BULK_RX_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(BULK_RX_TIMEOUT_CYCLES + 1);

  typedef enum logic [2:0] {
    BULK_IDLE,
    BULK_WRITE_RECV,
    BULK_WRITE_PREP,
    BULK_WRITE_ISSUE,
    BULK_WRITE_WAIT,
    BULK_READ_ISSUE,
    BULK_READ_WAIT
  } st_bulk_e;

  st_bulk_e st_bulk;

  logic        s_ascii_cmd_valid;
  logic [1:0]  s_ascii_cmd_op;
  logic        s_ascii_cmd_bulk_is_read;
  logic [16:0] s_ascii_cmd_addr;
  logic [7:0]  s_ascii_cmd_data;
  logic [16:0] s_ascii_cmd_count;
  logic        s_ascii_err_valid;
  logic [31:0] s_ascii_err_code;
  logic [31:0] s_ascii_err_detail;
  logic        r_ascii_cmd_ready;

  logic        r_access_req_valid;
  logic        r_access_req_is_write;
  logic        r_access_req_is_raw_bulk;
  logic [16:0] r_access_req_addr;
  logic [7:0]  r_access_req_count;
  logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] r_access_req_raw_wr_data;
  logic        l_access_req_ready;
  logic        l_access_evt_valid;
  logic        l_access_evt_ready;
  logic [7:0]  l_access_evt_id;
  logic [31:0] l_access_evt_arg0;
  logic [31:0] l_access_evt_arg1;
  logic [31:0] l_access_evt_arg2;
  logic        l_access_raw_done;
  logic        l_access_raw_err_valid;
  logic [31:0] l_access_raw_err_code;
  logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] l_access_raw_rd_data;
  logic        l_access_busy;

  logic [103:0] r_evt_fifo_mem [0:EVT_FIFO_DEPTH-1];
  logic [EVT_FIFO_PTR_W-1:0] r_evt_wr_ptr;
  logic [EVT_FIFO_PTR_W-1:0] r_evt_rd_ptr;
  logic [EVT_FIFO_CNT_W-1:0] r_evt_count;
  logic        s_evt_fifo_full;
  logic        s_evt_fifo_empty;
  logic        r_evt_push_valid;
  logic [7:0]  r_evt_push_id;
  logic [31:0] r_evt_push_arg0;
  logic [31:0] r_evt_push_arg1;
  logic [31:0] r_evt_push_arg2;
  logic        s_evt_push;
  logic        s_evt_pop;

  logic        s_evt_push_req;
  logic [7:0]  s_evt_push_id;
  logic [31:0] s_evt_push_arg0;
  logic [31:0] s_evt_push_arg1;
  logic [31:0] s_evt_push_arg2;

  logic        l_bulk_rx_word_valid;
  logic [31:0] l_bulk_rx_word_data;
  logic        l_bulk_rx_word_last;
  logic        l_bulk_rx_word_ready;
  logic        l_bulk_rx_block_done;
  logic [15:0] l_bulk_rx_block_bytes;
  logic [7:0]  l_bulk_rx_block_seq;
  logic        l_bulk_rx_abort_valid;
  logic [31:0] l_bulk_rx_abort_code;

  logic        r_bulk_evt_pending;
  logic [7:0]  r_bulk_evt_id;
  logic [31:0] r_bulk_evt_arg0;
  logic [31:0] r_bulk_evt_arg1;
  logic [31:0] r_bulk_evt_arg2;
  logic        s_bulk_evt_accept;
  logic        s_bulk_active;
  logic        r_bulk_is_read;
  logic [16:0] r_bulk_start_addr;
  logic [16:0] r_bulk_next_addr;
  logic [16:0] r_bulk_total_bytes;
  logic [16:0] r_bulk_remaining_bytes;
  logic [16:0] r_bulk_completed_bytes;
  logic [7:0]  r_bulk_issue_bytes;
  logic [15:0] r_bulk_block_bytes;
  logic [7:0]  r_bulk_block_offset;
  logic [7:0]  r_bulk_prep_byte_idx;
  logic [5:0]  r_bulk_wr_capture_word_count;
  logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] r_bulk_block_data;
  logic [BULK_RX_TIMEOUT_W-1:0] r_bulk_rx_timeout_cnt;
  logic        r_bulk_read_done_pending;

  logic [7:0]  s_bulk_write_issue_bytes;
  logic [7:0]  s_bulk_read_issue_bytes;
  logic        s_cli_enable;
  logic        s_emit_access_event;
  logic        s_emit_ascii_err;
  logic        s_cmd_accept;
  logic        s_cmd_blocked;
  logic        s_single_read_req;
  logic        s_single_write_req;
  logic        s_bulk_read_req;
  logic        s_bulk_write_req;
  logic        s_bulk_range_bad;
  logic        s_access_req_blocked;
  logic        s_access_read_fire;
  logic        s_access_write_fire;
  logic        s_bulk_start_read;
  logic        s_bulk_start_write;
  logic        s_access_bulk_write_fire;
  logic        s_access_bulk_read_fire;
  logic        s_bulk_rx_timeout;
  logic        s_access_evt_can_push;

  assign s_cli_enable = I_ENABLE && (HOST_EVT_IF.enable || s_bulk_active);
  assign s_bulk_active = (st_bulk != BULK_IDLE);
  assign O_CMD_BUSY = l_access_busy || s_bulk_active;

  assign s_evt_fifo_full  = (r_evt_count == EVT_FIFO_DEPTH);
  assign s_evt_fifo_empty = (r_evt_count == 0);
  assign s_evt_push       = r_evt_push_valid && !s_evt_fifo_full;
  assign s_evt_pop        = HOST_EVT_IF.evt_valid && HOST_EVT_IF.evt_ready;
  assign s_bulk_evt_accept = r_bulk_evt_pending && !s_evt_fifo_full;
  assign s_bulk_rx_timeout = (BULK_RX_TIMEOUT_CYCLES > 0) &&
                             (r_bulk_rx_timeout_cnt >= BULK_RX_TIMEOUT_CYCLES);
  assign s_access_evt_can_push = l_access_evt_valid && !s_evt_fifo_full && !r_evt_push_valid && !r_bulk_evt_pending;
  assign l_access_evt_ready = s_access_evt_can_push;

  assign HOST_EVT_IF.evt_valid = !s_evt_fifo_empty;
  assign HOST_EVT_IF.evt_id    = s_evt_fifo_empty ? 8'h00 : r_evt_fifo_mem[r_evt_rd_ptr][103:96];
  assign HOST_EVT_IF.arg0      = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][95:64];
  assign HOST_EVT_IF.arg1      = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][63:32];
  assign HOST_EVT_IF.arg2      = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][31:0];

  always_comb begin
    int unsigned issue_bytes_value;
    int unsigned page_remaining;
    int unsigned block_remaining;

    issue_bytes_value = r_bulk_block_bytes - r_bulk_block_offset;
    page_remaining = EEPROM_PAGE_BYTES - r_bulk_next_addr[6:0];
    block_remaining = EEPROM_BLOCK_BYTES - {1'b0, r_bulk_next_addr[15:0]};

    if (issue_bytes_value > page_remaining) begin
      issue_bytes_value = page_remaining;
    end
    if (issue_bytes_value > block_remaining) begin
      issue_bytes_value = block_remaining;
    end
    if (issue_bytes_value > MAX_BULK_PAYLOAD_BYTES) begin
      issue_bytes_value = MAX_BULK_PAYLOAD_BYTES;
    end
    s_bulk_write_issue_bytes = issue_bytes_value[7:0];
  end

  always_comb begin
    int unsigned issue_bytes_value;
    int unsigned block_remaining;

    issue_bytes_value = r_bulk_remaining_bytes;
    block_remaining = EEPROM_BLOCK_BYTES - {1'b0, r_bulk_next_addr[15:0]};

    if (issue_bytes_value > EEPROM_BULK_PROGRESS_BYTES) begin
      issue_bytes_value = EEPROM_BULK_PROGRESS_BYTES;
    end
    if (issue_bytes_value > block_remaining) begin
      issue_bytes_value = block_remaining;
    end
    s_bulk_read_issue_bytes = issue_bytes_value[7:0];
  end

  eeprom_uart_ascii_ctrl u_eeprom_uart_ascii_ctrl (
    .I_CLK              (I_CLK),
    .I_RST_N            (I_RST_N),
    .I_ENABLE           (I_ENABLE && HOST_EVT_IF.enable && !s_bulk_active),
    .I_RX_VALID         (I_CLI_RX_VALID),
    .I_RX_DATA          (I_CLI_RX_DATA),
    .I_CMD_READY        (r_ascii_cmd_ready),
    .O_CMD_VALID        (s_ascii_cmd_valid),
    .O_CMD_OP           (s_ascii_cmd_op),
    .O_CMD_BULK_IS_READ (s_ascii_cmd_bulk_is_read),
    .O_CMD_ADDR         (s_ascii_cmd_addr),
    .O_CMD_DATA         (s_ascii_cmd_data),
    .O_CMD_COUNT        (s_ascii_cmd_count),
    .O_ERR_VALID        (s_ascii_err_valid),
    .O_ERR_CODE         (s_ascii_err_code),
    .O_ERR_DETAIL       (s_ascii_err_detail)
  );

  eeprom_i2c_access_engine #(
    .I2C_BIT_RATE_HZ        (I2C_BIT_RATE_HZ)
  ) u_eeprom_i2c_access_engine (
    .I_CLK                  (I_CLK),
    .I_RST_N                (I_RST_N),
    .I_REQ_VALID            (r_access_req_valid),
    .O_REQ_READY            (l_access_req_ready),
    .I_REQ_IS_WRITE         (r_access_req_is_write),
    .I_REQ_IS_RAW_BULK      (r_access_req_is_raw_bulk),
    .I_REQ_ADDR             (r_access_req_addr),
    .I_REQ_COUNT            (r_access_req_count),
    .I_REQ_RAW_WR_DATA      (r_access_req_raw_wr_data),
    .I_I2C_SDA_IN           (I_I2C_SDA_IN),
    .I_I2C_SCL_IN           (I_I2C_SCL_IN),
    .O_I2C_SDA_DRIVE_LOW    (O_I2C_SDA_DRIVE_LOW),
    .O_I2C_SCL_DRIVE_LOW    (O_I2C_SCL_DRIVE_LOW),
    .O_EVT_VALID            (l_access_evt_valid),
    .I_EVT_READY            (l_access_evt_ready),
    .O_EVT_ID               (l_access_evt_id),
    .O_EVT_ARG0             (l_access_evt_arg0),
    .O_EVT_ARG1             (l_access_evt_arg1),
    .O_EVT_ARG2             (l_access_evt_arg2),
    .O_RAW_DONE             (l_access_raw_done),
    .O_RAW_ERR_VALID        (l_access_raw_err_valid),
    .O_RAW_ERR_CODE         (l_access_raw_err_code),
    .O_RAW_RD_DATA          (l_access_raw_rd_data),
    .O_BUSY                 (l_access_busy)
  );

  sdram_uart_bulk_rx u_sdram_uart_bulk_rx (
    .I_CLK                (I_CLK),
    .I_RST_N              (I_RST_N),
    .I_ENABLE             (s_cli_enable && !r_bulk_is_read && (st_bulk != BULK_IDLE)),
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

  assign l_bulk_rx_word_ready = (st_bulk == BULK_WRITE_RECV) && (r_bulk_wr_capture_word_count < MAX_BULK_PAYLOAD_WORDS);

  assign s_emit_access_event = s_access_evt_can_push;
  assign s_emit_ascii_err    = !s_emit_access_event && s_ascii_err_valid;
  assign s_cmd_accept        = !s_emit_access_event && s_ascii_cmd_valid && !r_ascii_cmd_ready;
  assign s_cmd_blocked       = s_cmd_accept && (!I_ENABLE || !HOST_EVT_IF.enable || l_access_busy || s_bulk_active);

  assign s_single_read_req   = s_cmd_accept && !s_cmd_blocked && (s_ascii_cmd_op == ASCII_OP_READ);
  assign s_single_write_req  = s_cmd_accept && !s_cmd_blocked && (s_ascii_cmd_op == ASCII_OP_WRITE);
  assign s_bulk_read_req     = s_cmd_accept && !s_cmd_blocked && (s_ascii_cmd_op == ASCII_OP_BULK) && s_ascii_cmd_bulk_is_read;
  assign s_bulk_write_req    = s_cmd_accept && !s_cmd_blocked && (s_ascii_cmd_op == ASCII_OP_BULK) && !s_ascii_cmd_bulk_is_read;
  assign s_bulk_range_bad    = (s_ascii_cmd_count == 0) ||
                               (({1'b0, s_ascii_cmd_addr} + {1'b0, s_ascii_cmd_count} - 18'd1) > {1'b0, EEPROM_MAX_ADDR});
  assign s_access_req_blocked = !l_access_req_ready;
  assign s_access_read_fire   = s_single_read_req && !s_access_req_blocked;
  assign s_access_write_fire  = s_single_write_req && !s_access_req_blocked;
  assign s_bulk_start_read    = s_bulk_read_req && !s_access_req_blocked && !s_bulk_range_bad;
  assign s_bulk_start_write   = s_bulk_write_req && !s_access_req_blocked && !s_bulk_range_bad;
  assign s_access_bulk_write_fire = (st_bulk == BULK_WRITE_ISSUE) && l_access_req_ready;
  assign s_access_bulk_read_fire  = (st_bulk == BULK_READ_ISSUE) && l_access_req_ready;

  always_comb begin
    s_evt_push_req  = 1'b0;
    s_evt_push_id   = 8'h00;
    s_evt_push_arg0 = 32'h0;
    s_evt_push_arg1 = 32'h0;
    s_evt_push_arg2 = 32'h0;

    if (r_bulk_evt_pending) begin
      s_evt_push_req  = 1'b1;
      s_evt_push_id   = r_bulk_evt_id;
      s_evt_push_arg0 = r_bulk_evt_arg0;
      s_evt_push_arg1 = r_bulk_evt_arg1;
      s_evt_push_arg2 = r_bulk_evt_arg2;
    end else if (s_emit_access_event) begin
      s_evt_push_req  = 1'b1;
      s_evt_push_id   = l_access_evt_id;
      s_evt_push_arg0 = l_access_evt_arg0;
      s_evt_push_arg1 = l_access_evt_arg1;
      s_evt_push_arg2 = l_access_evt_arg2;
    end else if (s_emit_ascii_err) begin
      s_evt_push_req  = 1'b1;
      s_evt_push_id   = EVT_CMD_ERR;
      s_evt_push_arg0 = s_ascii_err_code;
      s_evt_push_arg1 = s_ascii_err_detail;
      s_evt_push_arg2 = 32'h0000_0000;
    end else if (s_cmd_accept) begin
      if (s_cmd_blocked) begin
        s_evt_push_req  = 1'b1;
        s_evt_push_id   = EVT_CMD_ERR;
        s_evt_push_arg0 = ERR_BUSY;
        s_evt_push_arg1 = {15'h0000, s_ascii_cmd_addr};
        s_evt_push_arg2 = 32'h0000_0000;
      end else if ((s_ascii_cmd_op == ASCII_OP_BULK) && s_bulk_range_bad) begin
        s_evt_push_req  = 1'b1;
        s_evt_push_id   = EVT_BULK_ERR;
        s_evt_push_arg0 = (s_ascii_cmd_count == 0) ? ERR_BYTE_COUNT : ERR_ADDR_RANGE;
        s_evt_push_arg1 = {15'h0000, s_ascii_cmd_addr};
        s_evt_push_arg2 = {14'h0000, s_ascii_cmd_bulk_is_read, s_ascii_cmd_count};
      end else if ((s_ascii_cmd_op == ASCII_OP_READ) || (s_ascii_cmd_op == ASCII_OP_WRITE)) begin
        if (s_access_req_blocked) begin
          s_evt_push_req  = 1'b1;
          s_evt_push_id   = EVT_CMD_ERR;
          s_evt_push_arg0 = ERR_BUSY;
          s_evt_push_arg1 = {15'h0000, s_ascii_cmd_addr};
          s_evt_push_arg2 = {24'h000000, s_ascii_cmd_data};
        end
      end
    end
  end

  // Keeps host events ordered through a small FIFO before uart_log_cli drains them.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_evt_wr_ptr <= '0;
      r_evt_rd_ptr <= '0;
      r_evt_count  <= '0;
      for (int idx = 0; idx < EVT_FIFO_DEPTH; idx++) begin
        r_evt_fifo_mem[idx] <= '0;
      end
    end else begin
      if (s_evt_push) begin
        r_evt_fifo_mem[r_evt_wr_ptr] <= {r_evt_push_id, r_evt_push_arg0, r_evt_push_arg1, r_evt_push_arg2};
        r_evt_wr_ptr <= (r_evt_wr_ptr == EVT_FIFO_DEPTH - 1) ? '0 : (r_evt_wr_ptr + 1'b1);
      end

      if (s_evt_pop) begin
        r_evt_rd_ptr <= (r_evt_rd_ptr == EVT_FIFO_DEPTH - 1) ? '0 : (r_evt_rd_ptr + 1'b1);
      end

      case ({s_evt_push, s_evt_pop})
        2'b10: r_evt_count <= r_evt_count + 1'b1;
        2'b01: r_evt_count <= r_evt_count - 1'b1;
        default: r_evt_count <= r_evt_count;
      endcase
    end
  end

  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_evt_push_valid <= 1'b0;
      r_evt_push_id    <= 8'h00;
      r_evt_push_arg0  <= 32'h0;
      r_evt_push_arg1  <= 32'h0;
      r_evt_push_arg2  <= 32'h0;
    end else begin
      r_evt_push_valid <= 1'b0;
      if (s_evt_push_req && !s_evt_fifo_full) begin
        r_evt_push_valid <= 1'b1;
        r_evt_push_id    <= s_evt_push_id;
        r_evt_push_arg0  <= s_evt_push_arg0;
        r_evt_push_arg1  <= s_evt_push_arg1;
        r_evt_push_arg2  <= s_evt_push_arg2;
      end
    end
  end

  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_ascii_cmd_ready <= 1'b0;
    end else begin
      r_ascii_cmd_ready <= s_cmd_accept;
    end
  end

  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_access_req_valid       <= 1'b0;
      r_access_req_is_write    <= 1'b0;
      r_access_req_is_raw_bulk <= 1'b0;
      r_access_req_addr        <= '0;
      r_access_req_count       <= 8'h01;
      r_access_req_raw_wr_data <= '0;
    end else begin
      r_access_req_valid <= 1'b0;

      if (st_bulk == BULK_WRITE_PREP) begin
        if (r_bulk_prep_byte_idx == 0) begin
          r_access_req_is_write    <= 1'b1;
          r_access_req_is_raw_bulk <= 1'b1;
          r_access_req_addr        <= r_bulk_next_addr;
          r_access_req_count       <= s_bulk_write_issue_bytes;
          r_access_req_raw_wr_data <= '0;
        end
        r_access_req_raw_wr_data[r_bulk_prep_byte_idx*8 +: 8] <=
          r_bulk_block_data[(r_bulk_block_offset + r_bulk_prep_byte_idx)*8 +: 8];
      end else if (s_access_bulk_write_fire) begin
        r_access_req_valid       <= 1'b1;
        r_access_req_is_write    <= 1'b1;
        r_access_req_is_raw_bulk <= 1'b1;
      end else if (s_access_bulk_read_fire) begin
        r_access_req_valid       <= 1'b1;
        r_access_req_is_write    <= 1'b0;
        r_access_req_is_raw_bulk <= 1'b1;
        r_access_req_addr        <= r_bulk_next_addr;
        r_access_req_count       <= s_bulk_read_issue_bytes;
        r_access_req_raw_wr_data <= '0;
      end else if (s_access_read_fire) begin
        r_access_req_valid       <= 1'b1;
        r_access_req_is_write    <= 1'b0;
        r_access_req_is_raw_bulk <= 1'b0;
        r_access_req_addr        <= s_ascii_cmd_addr;
        r_access_req_count       <= 8'd1;
        r_access_req_raw_wr_data <= '0;
      end else if (s_access_write_fire) begin
        r_access_req_valid       <= 1'b1;
        r_access_req_is_write    <= 1'b1;
        r_access_req_is_raw_bulk <= 1'b0;
        r_access_req_addr        <= s_ascii_cmd_addr;
        r_access_req_count       <= 8'd1;
        r_access_req_raw_wr_data <= '0;
        r_access_req_raw_wr_data[7:0] <= s_ascii_cmd_data;
      end
    end
  end

  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    logic [16:0] next_completed_bytes;
    logic [16:0] next_remaining_bytes;
    logic [31:0] progress_arg0;
    logic [31:0] progress_arg1;
    logic [31:0] progress_arg2;
    logic [15:0] effective_block_bytes;

    if (!I_RST_N) begin
      st_bulk                  <= BULK_IDLE;
      r_bulk_evt_pending       <= 1'b0;
      r_bulk_evt_id            <= 8'h00;
      r_bulk_evt_arg0          <= 32'h0;
      r_bulk_evt_arg1          <= 32'h0;
      r_bulk_evt_arg2          <= 32'h0;
      r_bulk_is_read           <= 1'b0;
      r_bulk_start_addr        <= '0;
      r_bulk_next_addr         <= '0;
      r_bulk_total_bytes       <= '0;
      r_bulk_remaining_bytes   <= '0;
      r_bulk_completed_bytes   <= '0;
      r_bulk_issue_bytes       <= '0;
      r_bulk_block_bytes       <= '0;
      r_bulk_block_offset      <= '0;
      r_bulk_prep_byte_idx     <= '0;
      r_bulk_wr_capture_word_count <= '0;
      r_bulk_block_data        <= '0;
      r_bulk_rx_timeout_cnt    <= '0;
      r_bulk_read_done_pending <= 1'b0;
    end else begin
      if (s_bulk_evt_accept) begin
        r_bulk_evt_pending <= 1'b0;
      end

      if (st_bulk != BULK_WRITE_RECV) begin
        r_bulk_rx_timeout_cnt <= '0;
      end else if (r_bulk_evt_pending || I_CLI_RX_VALID || l_bulk_rx_abort_valid || l_bulk_rx_block_done) begin
        r_bulk_rx_timeout_cnt <= '0;
      end else if (!s_bulk_rx_timeout) begin
        r_bulk_rx_timeout_cnt <= r_bulk_rx_timeout_cnt + 1'b1;
      end

      if (l_bulk_rx_word_valid && l_bulk_rx_word_ready) begin
        r_bulk_block_data[r_bulk_wr_capture_word_count*32 +: 32] <= l_bulk_rx_word_data;
        r_bulk_wr_capture_word_count <= r_bulk_wr_capture_word_count + 1'b1;
      end

      case (st_bulk)
        BULK_IDLE: begin
          r_bulk_wr_capture_word_count <= '0;
          r_bulk_block_offset <= '0;
          r_bulk_prep_byte_idx <= '0;
          r_bulk_rx_timeout_cnt <= '0;
          r_bulk_read_done_pending <= 1'b0;

          if (s_bulk_start_read || s_bulk_start_write) begin
            st_bulk                <= s_bulk_start_read ? BULK_READ_ISSUE : BULK_WRITE_RECV;
            r_bulk_is_read         <= s_bulk_start_read;
            r_bulk_start_addr      <= s_ascii_cmd_addr;
            r_bulk_next_addr       <= s_ascii_cmd_addr;
            r_bulk_total_bytes     <= s_ascii_cmd_count;
            r_bulk_remaining_bytes <= s_ascii_cmd_count;
            r_bulk_completed_bytes <= '0;
            r_bulk_issue_bytes     <= '0;
            r_bulk_block_bytes     <= '0;
            r_bulk_block_offset    <= '0;
            r_bulk_prep_byte_idx   <= '0;
            r_bulk_block_data      <= '0;
            r_bulk_read_done_pending <= 1'b0;

            if (!r_bulk_evt_pending) begin
              r_bulk_evt_pending <= 1'b1;
              r_bulk_evt_id      <= EVT_BULK_OK;
              r_bulk_evt_arg0    <= {15'h0000, s_ascii_cmd_addr};
              r_bulk_evt_arg1    <= {15'h0000, s_ascii_cmd_count};
              r_bulk_evt_arg2    <= {31'h0, s_bulk_start_read};
            end
          end
        end

        BULK_WRITE_RECV: begin
          if (!r_bulk_evt_pending && l_bulk_rx_abort_valid) begin
            st_bulk             <= BULK_IDLE;
            r_bulk_evt_pending  <= 1'b1;
            r_bulk_evt_id       <= EVT_BULK_ABORT;
            r_bulk_evt_arg0     <= l_bulk_rx_abort_code;
            r_bulk_evt_arg1     <= {15'h0000, r_bulk_next_addr};
            r_bulk_evt_arg2     <= {15'h0000, r_bulk_completed_bytes};
            r_bulk_wr_capture_word_count <= '0;
          end else if (!r_bulk_evt_pending && s_bulk_rx_timeout) begin
            st_bulk             <= BULK_IDLE;
            r_bulk_evt_pending  <= 1'b1;
            r_bulk_evt_id       <= EVT_BULK_ABORT;
            r_bulk_evt_arg0     <= ERR_BULK_TIMEOUT;
            r_bulk_evt_arg1     <= {15'h0000, r_bulk_next_addr};
            r_bulk_evt_arg2     <= {15'h0000, r_bulk_completed_bytes};
            r_bulk_wr_capture_word_count <= '0;
          end else if (!r_bulk_evt_pending && l_bulk_rx_block_done) begin
            if (l_bulk_rx_block_bytes == 16'h0) begin
              st_bulk            <= BULK_IDLE;
              r_bulk_evt_pending <= 1'b1;
              if (r_bulk_remaining_bytes == 0) begin
                r_bulk_evt_id    <= EVT_BULK_DONE;
                r_bulk_evt_arg0  <= {15'h0000, r_bulk_start_addr};
                r_bulk_evt_arg1  <= {15'h0000, r_bulk_total_bytes};
                r_bulk_evt_arg2  <= {15'h0000, r_bulk_completed_bytes};
              end else begin
                r_bulk_evt_id    <= EVT_BULK_ABORT;
                r_bulk_evt_arg0  <= ERR_BYTE_COUNT;
                r_bulk_evt_arg1  <= {15'h0000, r_bulk_next_addr};
                r_bulk_evt_arg2  <= {15'h0000, r_bulk_completed_bytes};
              end
              r_bulk_wr_capture_word_count <= '0;
            end else if (l_bulk_rx_block_bytes > (r_bulk_remaining_bytes + 17'd3)) begin
              st_bulk                <= BULK_IDLE;
              r_bulk_evt_pending     <= 1'b1;
              r_bulk_evt_id          <= EVT_BULK_ABORT;
              r_bulk_evt_arg0        <= ERR_BYTE_COUNT;
              r_bulk_evt_arg1        <= {15'h0000, r_bulk_next_addr};
              r_bulk_evt_arg2        <= {15'h0000, r_bulk_completed_bytes};
              r_bulk_wr_capture_word_count <= '0;
            end else begin
              effective_block_bytes = (l_bulk_rx_block_bytes > r_bulk_remaining_bytes) ? r_bulk_remaining_bytes[15:0] : l_bulk_rx_block_bytes;
              r_bulk_block_bytes  <= effective_block_bytes;
              r_bulk_block_offset <= 8'h00;
              r_bulk_prep_byte_idx <= 8'h00;
              st_bulk             <= BULK_WRITE_PREP;
            end
          end
        end

        BULK_WRITE_PREP: begin
          if (r_bulk_prep_byte_idx + 1'b1 >= s_bulk_write_issue_bytes) begin
            r_bulk_prep_byte_idx <= '0;
            st_bulk              <= BULK_WRITE_ISSUE;
          end else begin
            r_bulk_prep_byte_idx <= r_bulk_prep_byte_idx + 1'b1;
          end
        end

        BULK_WRITE_ISSUE: begin
          if (s_access_bulk_write_fire) begin
            r_bulk_issue_bytes <= s_bulk_write_issue_bytes;
            st_bulk            <= BULK_WRITE_WAIT;
          end
        end

        BULK_WRITE_WAIT: begin
          if (!r_bulk_evt_pending && l_access_raw_err_valid) begin
            st_bulk            <= BULK_IDLE;
            r_bulk_evt_pending <= 1'b1;
            r_bulk_evt_id      <= EVT_BULK_ERR;
            r_bulk_evt_arg0    <= l_access_raw_err_code;
            r_bulk_evt_arg1    <= {15'h0000, r_bulk_next_addr};
            r_bulk_evt_arg2    <= {15'h0000, r_bulk_completed_bytes};
          end else if (!r_bulk_evt_pending && l_access_raw_done) begin
            next_completed_bytes = r_bulk_completed_bytes + r_bulk_issue_bytes;
            next_remaining_bytes = r_bulk_remaining_bytes - r_bulk_issue_bytes;

            r_bulk_block_offset    <= r_bulk_block_offset + r_bulk_issue_bytes;
            r_bulk_next_addr       <= r_bulk_next_addr + r_bulk_issue_bytes;
            r_bulk_remaining_bytes <= next_remaining_bytes;
            r_bulk_completed_bytes <= next_completed_bytes;

            r_bulk_evt_pending <= 1'b1;
            r_bulk_evt_id      <= EVT_BULK_PROG;
            r_bulk_evt_arg0    <= {15'h0000, r_bulk_next_addr};
            r_bulk_evt_arg1    <= {15'h0000, next_completed_bytes};
            r_bulk_evt_arg2    <= {15'h0000, next_remaining_bytes};

            if ((r_bulk_block_offset + r_bulk_issue_bytes) < r_bulk_block_bytes) begin
              r_bulk_prep_byte_idx <= 8'h00;
              st_bulk <= BULK_WRITE_PREP;
            end else begin
              st_bulk <= BULK_WRITE_RECV;
              r_bulk_prep_byte_idx <= '0;
              r_bulk_wr_capture_word_count <= '0;
            end
          end
        end

        BULK_READ_ISSUE: begin
          if (s_access_bulk_read_fire) begin
            r_bulk_issue_bytes <= s_bulk_read_issue_bytes;
            st_bulk            <= BULK_READ_WAIT;
          end
        end

        BULK_READ_WAIT: begin
          if (!r_bulk_evt_pending && r_bulk_read_done_pending) begin
            st_bulk                  <= BULK_IDLE;
            r_bulk_read_done_pending <= 1'b0;
            r_bulk_evt_pending       <= 1'b1;
            r_bulk_evt_id            <= EVT_BULK_DONE;
            r_bulk_evt_arg0          <= {15'h0000, r_bulk_start_addr};
            r_bulk_evt_arg1          <= {15'h0000, r_bulk_total_bytes};
            r_bulk_evt_arg2          <= {15'h0000, r_bulk_completed_bytes};
          end else if (!r_bulk_evt_pending && l_access_raw_err_valid) begin
            st_bulk            <= BULK_IDLE;
            r_bulk_read_done_pending <= 1'b0;
            r_bulk_evt_pending <= 1'b1;
            r_bulk_evt_id      <= EVT_BULK_ERR;
            r_bulk_evt_arg0    <= l_access_raw_err_code;
            r_bulk_evt_arg1    <= {15'h0000, r_bulk_next_addr};
            r_bulk_evt_arg2    <= {15'h0000, r_bulk_completed_bytes};
          end else if (!r_bulk_evt_pending && l_access_raw_done) begin
            next_completed_bytes = r_bulk_completed_bytes + r_bulk_issue_bytes;
            next_remaining_bytes = r_bulk_remaining_bytes - r_bulk_issue_bytes;

            progress_arg0 = pack_eeprom_bulk_progress_arg0(r_bulk_next_addr, r_bulk_issue_bytes);
            progress_arg1 = l_access_raw_rd_data[31:0];
            progress_arg2 = l_access_raw_rd_data[63:32];

            r_bulk_next_addr       <= r_bulk_next_addr + r_bulk_issue_bytes;
            r_bulk_remaining_bytes <= next_remaining_bytes;
            r_bulk_completed_bytes <= next_completed_bytes;
            r_bulk_read_done_pending <= (next_remaining_bytes == 0);
            r_bulk_evt_pending     <= 1'b1;
            r_bulk_evt_id          <= EVT_BULK_PROG;
            r_bulk_evt_arg0        <= progress_arg0;
            r_bulk_evt_arg1        <= progress_arg1;
            r_bulk_evt_arg2        <= progress_arg2;

            if (next_remaining_bytes != 0) begin
              st_bulk <= BULK_READ_ISSUE;
            end
          end
        end

        default: begin
          st_bulk <= BULK_IDLE;
        end
      endcase
    end
  end

endmodule