`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_bridge_ctrl.sv
// Description  : SDRAM debug register-map bridge for uart_log_cli.
//                - Parses ASCII host commands.
//                - Routes SR/SW to the status/control register namespace.
//                - Routes R/W to the linear single-word SDRAM access engine.
//                - Routes BRT/BWT to RTL-generated burst test transactions.
//                - Keeps BR/BW reserved and rejected with ERR_UNSUPPORTED.
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_bridge_ctrl #(
  parameter int unsigned BULK_RX_TIMEOUT_CYCLES = 24_000_000
) (
  input  logic              I_CLK,
  input  logic              I_RST_N,
  input  logic              I_ENABLE,
  input  logic              I_HOST_ACCESS_ENABLE,
  input  logic              I_CLI_RX_VALID,
  input  logic [7:0]        I_CLI_RX_DATA,
  input  logic              I_SDRC_INIT_DONE,
  input  logic              I_SDRC_READY,
  input  logic              I_SDRC_CMD_ACK,
  input  logic [31:0]       I_SDRC_RD_DATA,
  input  logic [31:0]       I_STATUS_RD_DATA,
  output logic [15:0]       O_STATUS_ADDR,
  output logic              O_SELFTEST_RESTART_REQ,
  output logic              O_SDRC_CMD_EN,
  output logic [2:0]        O_SDRC_CMD,
  output logic              O_SDRC_PRECHARGE_CTRL,
  output logic [20:0]       O_SDRC_ADDR,
  output logic [7:0]        O_SDRC_DATA_LEN,
  output logic [3:0]        O_SDRC_DQM,
  output logic [31:0]       O_SDRC_WR_DATA,
  output logic              O_SDRC_PAIR_ACTIVE,
  output logic              O_READ_SAMPLE_VALID,
  output logic              O_SDRC_ACTIVE,
  output logic [31:0]       O_HOST_DBG_SUMMARY,
  output logic [31:0]       O_HOST_DBG_DETAIL,
  output logic [31:0]       O_HOST_DBG_RD_BEATS,
  output logic              O_CMD_BUSY,
  uart_log_evt_if.producer  HOST_EVT_IF
);

  import sdram_uart_proto_pkg::*;

  localparam int unsigned EVT_FIFO_DEPTH    = 2;
  localparam int unsigned EVT_FIFO_PTR_W    = $clog2(EVT_FIFO_DEPTH);
  localparam int unsigned EVT_FIFO_CNT_W    = $clog2(EVT_FIFO_DEPTH + 1);
  localparam int unsigned BULK_RX_TIMEOUT_W =
    (BULK_RX_TIMEOUT_CYCLES <= 1) ? 1 :
      $clog2(BULK_RX_TIMEOUT_CYCLES + 1);
  localparam logic [20:0] STATUS_ADDR_MAX   = 21'h0004C;
  localparam logic [20:0] STATUS_CTRL_ADDR  = 21'h0003C;
  localparam logic [20:0] SDRAM_ADDR_MAX    = 21'h1F_FFFF;

  typedef enum logic [2:0] {
    BULK_IDLE,
    BULK_WRITE_RECV,
    BULK_WRITE_ISSUE,
    BULK_WRITE_WAIT_ACCESS,
    BULK_READ_ISSUE,
    BULK_READ_WAIT_ACCESS,
    BULK_READ_SEND
  } st_bulk_e;

  st_bulk_e st_bulk;

  logic         s_ascii_cmd_valid;
  logic [1:0]   s_ascii_cmd_op;
  logic         s_ascii_cmd_is_status;
  logic         s_ascii_cmd_bulk_is_read;
  logic         s_ascii_cmd_bulk_is_test;
  logic [20:0]  s_ascii_cmd_addr;
  logic [31:0]  s_ascii_cmd_data;
  logic [20:0]  s_ascii_cmd_words;
  logic         s_ascii_err_valid;
  logic [31:0]  s_ascii_err_code;
  logic [31:0]  s_ascii_err_detail;

  logic         r_ascii_cmd_ready;
  logic         r_cmd_busy;
  logic         r_read_rsp_pending;
  logic [20:0]  r_read_addr;
  logic         r_access_req_valid;
  logic         r_access_req_is_write;
  logic         r_access_req_is_burst_test;
  logic         r_access_req_is_raw_bulk;
  logic [20:0]  r_access_req_addr;
  logic [31:0]  r_access_req_data;
  logic [8:0]   r_access_req_words;
  logic [(MAX_BULK_PAYLOAD_WORDS*32)-1:0] r_access_req_raw_wr_data;
  logic         l_access_req_ready;
  logic         l_access_evt_valid;
  logic         l_access_evt_ready;
  logic [7:0]   l_access_evt_id;
  logic [31:0]  l_access_evt_arg0;
  logic [31:0]  l_access_evt_arg1;
  logic [31:0]  l_access_evt_arg2;
  logic         l_access_raw_done;
  logic         l_access_raw_err_valid;
  logic [31:0]  l_access_raw_err_code;
  logic [(MAX_BULK_PAYLOAD_WORDS*32)-1:0] l_access_raw_rd_data;
  logic         l_access_busy;
  logic [31:0]  l_access_dbg_rd_beats;
  logic         s_access_evt_can_push;

  logic [103:0] r_evt_fifo_mem [0:EVT_FIFO_DEPTH-1];
  logic [EVT_FIFO_PTR_W-1:0]  r_evt_wr_ptr;
  logic [EVT_FIFO_PTR_W-1:0]  r_evt_rd_ptr;
  logic [EVT_FIFO_CNT_W-1:0]  r_evt_count;
  logic                       s_evt_fifo_full;
  logic                       s_evt_fifo_empty;
  logic                       r_evt_push_valid;
  logic [7:0]                 r_evt_push_id;
  logic [31:0]                r_evt_push_arg0;
  logic [31:0]                r_evt_push_arg1;
  logic [31:0]                r_evt_push_arg2;
  logic                       s_evt_push;
  logic                       s_evt_pop;
  logic                       s_evt_push_req;
  logic [7:0]                 s_evt_push_id;
  logic [31:0]                s_evt_push_arg0;
  logic [31:0]                s_evt_push_arg1;
  logic [31:0]                s_evt_push_arg2;

  logic                       s_ascii_decode_window;
  logic                       s_cmd_accept;
  logic                       s_cmd_blocked;
  logic                       s_status_read_req;
  logic                       s_status_write_req;
  logic                       s_sdram_read_req;
  logic                       s_sdram_write_req;
  logic                       s_burst_test_req;
  logic                       s_burst_word_count_bad;
  logic                       s_bulk_range_bad;
  logic                       s_bulk_raw_read_req;
  logic                       s_bulk_raw_write_req;
  logic                       s_bulk_start_read;
  logic                       s_bulk_start_write;
  logic                       s_status_read_addr_bad;
  logic                       s_status_ctrl_write;
  logic                       s_access_req_blocked;
  logic                       s_emit_access_event;
  logic                       s_emit_status_read_rsp;
  logic                       s_emit_ascii_err;
  logic                       s_status_read_start;
  logic                       s_access_read_fire;
  logic                       s_access_write_fire;
  logic                       s_access_burst_fire;
  logic                       s_access_bulk_write_fire;
  logic                       s_access_bulk_read_fire;
  logic                       s_selftest_restart_pulse;

  logic                       l_bulk_rx_word_valid;
  logic [31:0]                l_bulk_rx_word_data;
  logic                       l_bulk_rx_word_last;
  logic                       l_bulk_rx_word_ready;
  logic                       l_bulk_rx_block_done;
  logic [15:0]                l_bulk_rx_block_bytes;
  logic [7:0]                 l_bulk_rx_block_seq;
  logic                       l_bulk_rx_abort_valid;
  logic [31:0]                l_bulk_rx_abort_code;

  logic                       r_bulk_evt_pending;
  logic [7:0]                 r_bulk_evt_id;
  logic [31:0]                r_bulk_evt_arg0;
  logic [31:0]                r_bulk_evt_arg1;
  logic [31:0]                r_bulk_evt_arg2;
  logic                       s_bulk_evt_accept;
  logic                       s_bulk_active;
  logic                       r_bulk_is_read;
  logic [20:0]                r_bulk_start_addr;
  logic [20:0]                r_bulk_next_addr;
  logic [20:0]                r_bulk_total_words;
  logic [20:0]                r_bulk_remaining_words;
  logic [20:0]                r_bulk_completed_words;
  logic [8:0]                 r_bulk_chunk_words;
  logic [5:0]                 r_bulk_wr_capture_count;
  logic [(MAX_BULK_PAYLOAD_WORDS*32)-1:0] r_bulk_wr_data;
  logic [(MAX_BULK_PAYLOAD_WORDS*32)-1:0] r_bulk_rd_chunk_data;
  logic [7:0]                 r_bulk_rd_packet_id;
  logic [7:0]                 r_bulk_rd_packet_count;
  logic [BULK_RX_TIMEOUT_W-1:0] r_bulk_rx_timeout_cnt;
  logic [8:0]                 s_bulk_issue_words;
  logic [8:0]                 s_bulk_send_word_idx;
  logic                       s_bulk_send_one_word;
  logic [20:0]                s_bulk_send_addr;
  logic [31:0]                s_bulk_send_data0;
  logic [31:0]                s_bulk_send_data1;
  logic                       s_bulk_rx_timeout;

  assign O_STATUS_ADDR          = r_read_addr[15:0];

  assign s_bulk_active          = (st_bulk != BULK_IDLE);
  assign O_CMD_BUSY             = r_cmd_busy || r_read_rsp_pending || l_access_busy || s_bulk_active;
  assign O_SDRC_ACTIVE          = l_access_busy;
  assign O_HOST_DBG_RD_BEATS    = l_access_dbg_rd_beats;
  assign s_access_evt_can_push  = l_access_evt_valid && !s_evt_fifo_full && !r_evt_push_valid && !r_bulk_evt_pending;
  assign l_access_evt_ready     = s_access_evt_can_push;
  assign s_evt_fifo_full        = (r_evt_count == EVT_FIFO_DEPTH);
  assign s_evt_fifo_empty       = (r_evt_count == 0);
  assign s_evt_push             = r_evt_push_valid && !s_evt_fifo_full;
  assign s_evt_pop              = HOST_EVT_IF.evt_valid && HOST_EVT_IF.evt_ready;
  assign s_bulk_evt_accept      = r_bulk_evt_pending && !s_evt_fifo_full;
  assign s_bulk_send_word_idx   = {1'b0, r_bulk_rd_packet_id} << 1;
  assign s_bulk_send_one_word   = (s_bulk_send_word_idx + 9'd1) >= r_bulk_chunk_words;
  assign s_bulk_send_addr       = r_bulk_next_addr + s_bulk_send_word_idx;
  assign s_bulk_send_data0      = r_bulk_rd_chunk_data[s_bulk_send_word_idx*32 +: 32];
  assign s_bulk_send_data1      = r_bulk_rd_chunk_data[(s_bulk_send_word_idx + 9'd1)*32 +: 32];
  assign s_bulk_rx_timeout      = (BULK_RX_TIMEOUT_CYCLES > 0) &&
                                  (r_bulk_rx_timeout_cnt >= BULK_RX_TIMEOUT_CYCLES);

  assign HOST_EVT_IF.evt_valid  = !s_evt_fifo_empty;
  assign HOST_EVT_IF.evt_id     = s_evt_fifo_empty ? 8'h00 : r_evt_fifo_mem[r_evt_rd_ptr][103:96];
  assign HOST_EVT_IF.arg0       = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][95:64];
  assign HOST_EVT_IF.arg1       = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][63:32];
  assign HOST_EVT_IF.arg2       = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][31:0];

  always_comb begin
    int unsigned issue_words_value;
    int unsigned page_words_value;

    issue_words_value = r_bulk_remaining_words;
    if (issue_words_value > MAX_BULK_PAYLOAD_WORDS) begin
      issue_words_value = MAX_BULK_PAYLOAD_WORDS;
    end

    page_words_value = 9'd256 - {1'b0, r_bulk_next_addr[7:0]};
    if (issue_words_value > page_words_value) begin
      issue_words_value = page_words_value;
    end

    s_bulk_issue_words = issue_words_value[8:0];
  end

  sdram_uart_ascii_ctrl u_sdram_uart_ascii_ctrl (
    .I_CLK              (I_CLK),
    .I_RST_N            (I_RST_N),
    .I_ENABLE           (I_ENABLE && !s_bulk_active),
    .I_RX_VALID         (I_CLI_RX_VALID),
    .I_RX_DATA          (I_CLI_RX_DATA),
    .I_CMD_READY        (r_ascii_cmd_ready),
    .O_CMD_VALID        (s_ascii_cmd_valid),
    .O_CMD_OP           (s_ascii_cmd_op),
    .O_CMD_IS_STATUS    (s_ascii_cmd_is_status),
    .O_CMD_BULK_IS_READ (s_ascii_cmd_bulk_is_read),
    .O_CMD_BULK_IS_TEST (s_ascii_cmd_bulk_is_test),
    .O_CMD_ADDR         (s_ascii_cmd_addr),
    .O_CMD_DATA         (s_ascii_cmd_data),
    .O_CMD_WORDS        (s_ascii_cmd_words),
    .O_ERR_VALID        (s_ascii_err_valid),
    .O_ERR_CODE         (s_ascii_err_code),
    .O_ERR_DETAIL       (s_ascii_err_detail)
  );

  sdram_uart_access_engine u_sdram_uart_access_engine (
    .I_CLK                  (I_CLK),
    .I_RST_N                (I_RST_N),
    .I_REQ_VALID            (r_access_req_valid),
    .O_REQ_READY            (l_access_req_ready),
    .I_REQ_IS_WRITE         (r_access_req_is_write),
    .I_REQ_IS_BURST_TEST    (r_access_req_is_burst_test),
    .I_REQ_IS_RAW_BULK      (r_access_req_is_raw_bulk),
    .I_REQ_ADDR             (r_access_req_addr),
    .I_REQ_DATA             (r_access_req_data),
    .I_REQ_WORDS            (r_access_req_words),
    .I_REQ_RAW_WR_DATA      (r_access_req_raw_wr_data),
    .I_SDRC_INIT_DONE       (I_SDRC_INIT_DONE),
    .I_SDRC_READY           (I_SDRC_READY),
    .I_SDRC_CMD_ACK         (I_SDRC_CMD_ACK),
    .I_SDRC_RD_DATA         (I_SDRC_RD_DATA),
    .O_SDRC_CMD_EN          (O_SDRC_CMD_EN),
    .O_SDRC_CMD             (O_SDRC_CMD),
    .O_SDRC_PRECHARGE_CTRL  (O_SDRC_PRECHARGE_CTRL),
    .O_SDRC_ADDR            (O_SDRC_ADDR),
    .O_SDRC_DATA_LEN        (O_SDRC_DATA_LEN),
    .O_SDRC_DQM             (O_SDRC_DQM),
    .O_SDRC_WR_DATA         (O_SDRC_WR_DATA),
    .O_SDRC_PAIR_ACTIVE     (O_SDRC_PAIR_ACTIVE),
    .O_READ_SAMPLE_VALID    (O_READ_SAMPLE_VALID),
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
    .O_BUSY                 (l_access_busy),
    .O_DBG_HOST_SUMMARY     (O_HOST_DBG_SUMMARY),
    .O_DBG_HOST_DETAIL      (O_HOST_DBG_DETAIL),
    .O_DBG_HOST_RD_BEATS    (l_access_dbg_rd_beats)
  );

  sdram_uart_bulk_rx u_sdram_uart_bulk_rx (
    .I_CLK                  (I_CLK),
    .I_RST_N                (I_RST_N),
    .I_ENABLE               (I_ENABLE && !r_bulk_is_read && (st_bulk != BULK_IDLE)),
    .I_RX_VALID             (I_CLI_RX_VALID),
    .I_RX_DATA              (I_CLI_RX_DATA),
    .O_WORD_VALID           (l_bulk_rx_word_valid),
    .O_WORD_DATA            (l_bulk_rx_word_data),
    .O_WORD_LAST_IN_BLOCK   (l_bulk_rx_word_last),
    .I_WORD_READY           (l_bulk_rx_word_ready),
    .O_BLOCK_DONE           (l_bulk_rx_block_done),
    .O_BLOCK_BYTES          (l_bulk_rx_block_bytes),
    .O_BLOCK_SEQ            (l_bulk_rx_block_seq),
    .O_ABORT_VALID          (l_bulk_rx_abort_valid),
    .O_ABORT_CODE           (l_bulk_rx_abort_code)
  );

  assign l_bulk_rx_word_ready = (st_bulk == BULK_WRITE_RECV) &&
                                (r_bulk_wr_capture_count < MAX_BULK_PAYLOAD_WORDS);

  assign s_emit_access_event      = s_access_evt_can_push;
  assign s_emit_status_read_rsp   = !s_emit_access_event && r_read_rsp_pending;
  assign s_ascii_decode_window    = !s_emit_access_event && !r_read_rsp_pending;
  assign s_emit_ascii_err         = s_ascii_decode_window && s_ascii_err_valid;
  assign s_cmd_accept             = s_ascii_decode_window && s_ascii_cmd_valid && !r_ascii_cmd_ready;
  assign s_cmd_blocked            = s_cmd_accept && (!I_ENABLE || r_cmd_busy || r_read_rsp_pending || s_bulk_active);

  assign s_status_read_req        = s_cmd_accept && !s_cmd_blocked && s_ascii_cmd_is_status && (s_ascii_cmd_op == ASCII_OP_READ);
  assign s_status_write_req       = s_cmd_accept && !s_cmd_blocked && s_ascii_cmd_is_status && (s_ascii_cmd_op == ASCII_OP_WRITE);
  assign s_sdram_read_req         = s_cmd_accept && !s_cmd_blocked && !s_ascii_cmd_is_status && (s_ascii_cmd_op == ASCII_OP_READ);
  assign s_sdram_write_req        = s_cmd_accept && !s_cmd_blocked && !s_ascii_cmd_is_status && (s_ascii_cmd_op == ASCII_OP_WRITE);
  assign s_burst_test_req         = s_cmd_accept && !s_cmd_blocked && (s_ascii_cmd_op == ASCII_OP_BULK) && s_ascii_cmd_bulk_is_test;
  assign s_bulk_raw_read_req      = s_cmd_accept && !s_cmd_blocked && (s_ascii_cmd_op == ASCII_OP_BULK) && !s_ascii_cmd_bulk_is_test && s_ascii_cmd_bulk_is_read;
  assign s_bulk_raw_write_req     = s_cmd_accept && !s_cmd_blocked && (s_ascii_cmd_op == ASCII_OP_BULK) && !s_ascii_cmd_bulk_is_test && !s_ascii_cmd_bulk_is_read;

  assign s_burst_word_count_bad   = (s_ascii_cmd_words == 21'h0) || (s_ascii_cmd_words > 21'h00100);
  assign s_bulk_range_bad         = (s_ascii_cmd_words == 21'h0) ||
                                    (({1'b0, s_ascii_cmd_addr} + {1'b0, s_ascii_cmd_words} - 22'd1) > {1'b0, SDRAM_ADDR_MAX});
  assign s_status_read_addr_bad   = (s_ascii_cmd_addr > STATUS_ADDR_MAX) || (s_ascii_cmd_addr[1:0] != 2'b00);
  assign s_status_ctrl_write      = s_status_write_req && (s_ascii_cmd_addr == STATUS_CTRL_ADDR);
  assign s_access_req_blocked     = !I_HOST_ACCESS_ENABLE || !l_access_req_ready;
  assign s_status_read_start      = s_status_read_req && !s_status_read_addr_bad;
  assign s_access_read_fire       = s_sdram_read_req && !s_access_req_blocked;
  assign s_access_write_fire      = s_sdram_write_req && !s_access_req_blocked;
  assign s_access_burst_fire      = s_burst_test_req && !s_access_req_blocked && !s_burst_word_count_bad;
  assign s_bulk_start_read        = s_bulk_raw_read_req && !s_access_req_blocked && !s_bulk_range_bad;
  assign s_bulk_start_write       = s_bulk_raw_write_req && !s_access_req_blocked && !s_bulk_range_bad;
  assign s_access_bulk_write_fire = (st_bulk == BULK_WRITE_ISSUE) && l_access_req_ready;
  assign s_access_bulk_read_fire  = (st_bulk == BULK_READ_ISSUE) && l_access_req_ready;
  assign s_selftest_restart_pulse = s_status_ctrl_write && !l_access_busy && s_ascii_cmd_data[0];

  // Event request priority matches the previous monolithic block:
  // bulk-session pending event, access-engine event, pending status response,
  // ASCII parser error, then the immediate response generated while accepting a
  // host command.
  always_comb begin
    s_evt_push_req   = 1'b0;
    s_evt_push_id    = 8'h00;
    s_evt_push_arg0  = 32'h0;
    s_evt_push_arg1  = 32'h0;
    s_evt_push_arg2  = 32'h0;

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

    end else if (s_emit_status_read_rsp) begin
      s_evt_push_req  = 1'b1;
      s_evt_push_id   = EVT_READ_RSP;
      s_evt_push_arg0 = {11'h000, r_read_addr};
      s_evt_push_arg1 = I_STATUS_RD_DATA;
      s_evt_push_arg2 = 32'h0000_0000;

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
        s_evt_push_arg1 = {11'h000, s_ascii_cmd_addr};
        s_evt_push_arg2 = 32'h0000_0000;

      end else if (s_status_read_req) begin
        if (s_status_read_addr_bad) begin
          s_evt_push_req  = 1'b1;
          s_evt_push_id   = EVT_CMD_ERR;
          s_evt_push_arg0 = ERR_ADDR_RANGE;
          s_evt_push_arg1 = {11'h000, s_ascii_cmd_addr};
          s_evt_push_arg2 = 32'h0000_004C;
        end

      end else if (s_status_write_req) begin
        if (s_status_ctrl_write) begin
          if (l_access_busy) begin
            s_evt_push_req  = 1'b1;
            s_evt_push_id   = EVT_CMD_ERR;
            s_evt_push_arg0 = ERR_BUSY;
            s_evt_push_arg1 = {11'h000, s_ascii_cmd_addr};
            s_evt_push_arg2 = s_ascii_cmd_data;
          end else begin
            s_evt_push_req   = 1'b1;
            s_evt_push_id    = EVT_WRITE_ACK;
            s_evt_push_arg0  = {11'h000, s_ascii_cmd_addr};
            s_evt_push_arg1  = s_ascii_cmd_data;
            s_evt_push_arg2  = 32'h0000_0000;
          end
        end else begin
          s_evt_push_req  = 1'b1;
          s_evt_push_id   = EVT_CMD_ERR;
          s_evt_push_arg0 = ERR_UNSUPPORTED;
          s_evt_push_arg1 = {11'h000, s_ascii_cmd_addr};
          s_evt_push_arg2 = s_ascii_cmd_data;
        end

      end else if (s_sdram_read_req) begin
        if (s_access_req_blocked) begin
          s_evt_push_req  = 1'b1;
          s_evt_push_id   = EVT_CMD_ERR;
          s_evt_push_arg0 = ERR_BUSY;
          s_evt_push_arg1 = {11'h000, s_ascii_cmd_addr};
          s_evt_push_arg2 = 32'h0000_0000;
        end

      end else if (s_sdram_write_req) begin
        if (s_access_req_blocked) begin
          s_evt_push_req  = 1'b1;
          s_evt_push_id   = EVT_CMD_ERR;
          s_evt_push_arg0 = ERR_BUSY;
          s_evt_push_arg1 = {11'h000, s_ascii_cmd_addr};
          s_evt_push_arg2 = s_ascii_cmd_data;
        end

      end else if (s_ascii_cmd_op == ASCII_OP_BULK) begin
        if (s_access_req_blocked) begin
          s_evt_push_req   = 1'b1;
          s_evt_push_id    = EVT_BULK_ERR;
          s_evt_push_arg0  = ERR_BUSY;
          s_evt_push_arg1  = {11'h000, s_ascii_cmd_addr};
          s_evt_push_arg2  = {s_ascii_cmd_bulk_is_read, 15'h0, s_ascii_cmd_words[15:0]};
        end else if (s_ascii_cmd_bulk_is_test && s_burst_word_count_bad) begin
          s_evt_push_req   = 1'b1;
          s_evt_push_id    = EVT_BULK_ERR;
          s_evt_push_arg0  = ERR_WORD_COUNT;
          s_evt_push_arg1  = {11'h000, s_ascii_cmd_addr};
          s_evt_push_arg2  = {s_ascii_cmd_bulk_is_read, 15'h0, s_ascii_cmd_words[15:0]};
        end else if (!s_ascii_cmd_bulk_is_test && s_bulk_range_bad) begin
          s_evt_push_req   = 1'b1;
          s_evt_push_id    = EVT_BULK_ERR;
          s_evt_push_arg0  = (s_ascii_cmd_words == 21'h0) ? ERR_WORD_COUNT : ERR_ADDR_RANGE;
          s_evt_push_arg1  = {11'h000, s_ascii_cmd_addr};
          s_evt_push_arg2  = {s_ascii_cmd_bulk_is_read, 15'h0, s_ascii_cmd_words[15:0]};
        end

      end else begin
        s_evt_push_req  = 1'b1;
        s_evt_push_id   = EVT_CMD_ERR;
        s_evt_push_arg0 = ERR_BAD_ASCII_CMD;
        s_evt_push_arg1 = 32'h0000_0000;
        s_evt_push_arg2 = 32'h0000_0000;
      end
    end
  end

  // Preserves status-map response events until uart_log_cli drains them.
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
        r_evt_fifo_mem[r_evt_wr_ptr] <= {
          r_evt_push_id,
          r_evt_push_arg0,
          r_evt_push_arg1,
          r_evt_push_arg2
        };
        r_evt_wr_ptr <= (r_evt_wr_ptr == EVT_FIFO_DEPTH - 1) ? '0 : (r_evt_wr_ptr + 1'b1);
      end

      if (s_evt_pop) begin
        r_evt_rd_ptr <= (r_evt_rd_ptr == EVT_FIFO_DEPTH - 1) ? '0 : (r_evt_rd_ptr + 1'b1);
      end

      case ({s_evt_push, s_evt_pop})
        2'b10:    r_evt_count <= r_evt_count + 1'b1;
        2'b01:    r_evt_count <= r_evt_count - 1'b1;
        default:  r_evt_count <= r_evt_count;
      endcase
    end
  end

  // Latches one event request for the FIFO writer. If the FIFO is full, the
  // request is dropped exactly as the previous push_event task did.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_evt_push_valid    <= 1'b0;
      r_evt_push_id       <= 8'h00;
      r_evt_push_arg0     <= 32'h0;
      r_evt_push_arg1     <= 32'h0;
      r_evt_push_arg2     <= 32'h0;
    end else begin
      r_evt_push_valid    <= 1'b0;

      if (s_evt_push_req && !s_evt_fifo_full) begin
        r_evt_push_valid  <= 1'b1;
        r_evt_push_id     <= s_evt_push_id;
        r_evt_push_arg0   <= s_evt_push_arg0;
        r_evt_push_arg1   <= s_evt_push_arg1;
        r_evt_push_arg2   <= s_evt_push_arg2;
      end
    end
  end

  // One-cycle ready pulse back to the ASCII parser when a command is consumed.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_ascii_cmd_ready <= 1'b0;
    end else begin
      r_ascii_cmd_ready <= s_cmd_accept;
    end
  end

  // Tracks delayed status-map reads. The read address is held until the response
  // event is generated on a later cycle.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_read_rsp_pending <= 1'b0;
      r_read_addr        <= '0;
    end else begin
      if (s_emit_status_read_rsp) begin
        r_read_rsp_pending <= 1'b0;
      end else if (s_status_read_start) begin
        r_read_rsp_pending <= 1'b1;
        r_read_addr        <= s_ascii_cmd_addr;
      end
    end
  end

  // Command busy is only used to cover the delayed status-map read response.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_cmd_busy <= 1'b0;
    end else begin
      if (s_emit_status_read_rsp) begin
        r_cmd_busy <= 1'b0;
      end else if (s_status_read_start) begin
        r_cmd_busy <= 1'b1;
      end
    end
  end

  // Issues one-cycle access-engine requests for ASCII single accesses, burst
  // tests, and chunked raw bulk bursts.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_access_req_valid          <= 1'b0;
      r_access_req_is_write       <= 1'b0;
      r_access_req_is_burst_test  <= 1'b0;
      r_access_req_is_raw_bulk    <= 1'b0;
      r_access_req_addr           <= '0;
      r_access_req_data           <= '0;
      r_access_req_words          <= 9'd1;
      r_access_req_raw_wr_data    <= '0;
    end else begin
      r_access_req_valid          <= 1'b0;

      if (s_access_bulk_write_fire) begin
        r_access_req_valid         <= 1'b1;
        r_access_req_is_write      <= 1'b1;
        r_access_req_is_burst_test <= 1'b0;
        r_access_req_is_raw_bulk   <= 1'b1;
        r_access_req_addr          <= r_bulk_next_addr;
        r_access_req_data          <= 32'h0000_0000;
        r_access_req_words         <= r_bulk_chunk_words;
        r_access_req_raw_wr_data   <= r_bulk_wr_data;
      end else if (s_access_bulk_read_fire) begin
        r_access_req_valid         <= 1'b1;
        r_access_req_is_write      <= 1'b0;
        r_access_req_is_burst_test <= 1'b0;
        r_access_req_is_raw_bulk   <= 1'b1;
        r_access_req_addr          <= r_bulk_next_addr;
        r_access_req_data          <= 32'h0000_0000;
        r_access_req_words         <= s_bulk_issue_words;
        r_access_req_raw_wr_data   <= '0;
      end else if (s_access_read_fire) begin
        r_access_req_valid         <= 1'b1;
        r_access_req_is_write      <= 1'b0;
        r_access_req_is_burst_test <= 1'b0;
        r_access_req_is_raw_bulk   <= 1'b0;
        r_access_req_addr          <= s_ascii_cmd_addr;
        r_access_req_data          <= 32'h0000_0000;
        r_access_req_words         <= 9'd1;
        r_access_req_raw_wr_data   <= '0;
      end else if (s_access_write_fire) begin
        r_access_req_valid         <= 1'b1;
        r_access_req_is_write      <= 1'b1;
        r_access_req_is_burst_test <= 1'b0;
        r_access_req_is_raw_bulk   <= 1'b0;
        r_access_req_addr          <= s_ascii_cmd_addr;
        r_access_req_data          <= s_ascii_cmd_data;
        r_access_req_words         <= 9'd1;
        r_access_req_raw_wr_data   <= '0;
      end else if (s_access_burst_fire) begin
        r_access_req_valid         <= 1'b1;
        r_access_req_is_write      <= !s_ascii_cmd_bulk_is_read;
        r_access_req_is_burst_test <= 1'b1;
        r_access_req_is_raw_bulk   <= 1'b0;
        r_access_req_addr          <= s_ascii_cmd_addr;
        r_access_req_data          <= 32'h0000_0000;
        r_access_req_words         <= s_ascii_cmd_words[8:0];
        r_access_req_raw_wr_data   <= '0;
      end
    end
  end

  // Bulk session controller:
  // - BW receives one CRC-checked payload block at a time and writes it using
  //   one SDRAM burst per block.
  // - BR issues one SDRAM burst at a time, then drains the captured words as
  //   2-word host events until the requested range is complete.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    logic [20:0] next_completed_words;
    logic [20:0] next_remaining_words;
    logic [31:0] data_evt_arg0;
    logic [31:0] data_evt_arg1;
    logic [31:0] data_evt_arg2;

    if (!I_RST_N) begin
      st_bulk               <= BULK_IDLE;
      r_bulk_evt_pending    <= 1'b0;
      r_bulk_evt_id         <= 8'h00;
      r_bulk_evt_arg0       <= 32'h0;
      r_bulk_evt_arg1       <= 32'h0;
      r_bulk_evt_arg2       <= 32'h0;
      r_bulk_is_read        <= 1'b0;
      r_bulk_start_addr     <= '0;
      r_bulk_next_addr      <= '0;
      r_bulk_total_words    <= '0;
      r_bulk_remaining_words<= '0;
      r_bulk_completed_words<= '0;
      r_bulk_chunk_words    <= '0;
      r_bulk_wr_capture_count <= '0;
      r_bulk_wr_data        <= '0;
      r_bulk_rd_chunk_data  <= '0;
      r_bulk_rd_packet_id   <= '0;
      r_bulk_rd_packet_count<= '0;
      r_bulk_rx_timeout_cnt <= '0;
    end else begin
      if (s_bulk_evt_accept) begin
        r_bulk_evt_pending <= 1'b0;
      end

      if (st_bulk != BULK_WRITE_RECV) begin
        r_bulk_rx_timeout_cnt <= '0;
      end else if (r_bulk_evt_pending || I_CLI_RX_VALID ||
                   l_bulk_rx_abort_valid || l_bulk_rx_block_done) begin
        r_bulk_rx_timeout_cnt <= '0;
      end else if (!s_bulk_rx_timeout) begin
        r_bulk_rx_timeout_cnt <= r_bulk_rx_timeout_cnt + 1'b1;
      end

      if (l_bulk_rx_word_valid && l_bulk_rx_word_ready) begin
        r_bulk_wr_data[r_bulk_wr_capture_count*32 +: 32] <= l_bulk_rx_word_data;
        r_bulk_wr_capture_count <= r_bulk_wr_capture_count + 1'b1;
      end

      case (st_bulk)
        BULK_IDLE: begin
          r_bulk_wr_capture_count <= '0;
          r_bulk_rx_timeout_cnt   <= '0;

          if (s_bulk_start_read || s_bulk_start_write) begin
            st_bulk                <= s_bulk_start_read ? BULK_READ_ISSUE : BULK_WRITE_RECV;
            r_bulk_is_read         <= s_bulk_start_read;
            r_bulk_start_addr      <= s_ascii_cmd_addr;
            r_bulk_next_addr       <= s_ascii_cmd_addr;
            r_bulk_total_words     <= s_ascii_cmd_words;
            r_bulk_remaining_words <= s_ascii_cmd_words;
            r_bulk_completed_words <= '0;
            r_bulk_chunk_words     <= '0;
            r_bulk_rd_chunk_data   <= '0;
            r_bulk_rd_packet_id    <= '0;
            r_bulk_rd_packet_count <= '0;

            if (!r_bulk_evt_pending) begin
              r_bulk_evt_pending <= 1'b1;
              r_bulk_evt_id      <= EVT_BULK_OK;
              r_bulk_evt_arg0    <= {11'h000, s_ascii_cmd_addr};
              r_bulk_evt_arg1    <= {11'h000, s_ascii_cmd_words};
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
            r_bulk_evt_arg1     <= {11'h000, r_bulk_next_addr};
            r_bulk_evt_arg2     <= r_bulk_completed_words;
            r_bulk_wr_capture_count <= '0;
          end else if (!r_bulk_evt_pending && s_bulk_rx_timeout) begin
            st_bulk             <= BULK_IDLE;
            r_bulk_evt_pending  <= 1'b1;
            r_bulk_evt_id       <= EVT_BULK_ABORT;
            r_bulk_evt_arg0     <= ERR_BULK_TIMEOUT;
            r_bulk_evt_arg1     <= {11'h000, r_bulk_next_addr};
            r_bulk_evt_arg2     <= r_bulk_completed_words;
            r_bulk_wr_capture_count <= '0;
          end else if (!r_bulk_evt_pending && l_bulk_rx_block_done) begin
            if (l_bulk_rx_block_bytes == 16'h0) begin
              st_bulk            <= BULK_IDLE;
              r_bulk_evt_pending <= 1'b1;
              if (r_bulk_remaining_words == 0) begin
                r_bulk_evt_id    <= EVT_BULK_DONE;
                r_bulk_evt_arg0  <= {11'h000, r_bulk_start_addr};
                r_bulk_evt_arg1  <= {11'h000, r_bulk_total_words};
                r_bulk_evt_arg2  <= r_bulk_completed_words;
              end else begin
                r_bulk_evt_id    <= EVT_BULK_ABORT;
                r_bulk_evt_arg0  <= ERR_WORD_COUNT;
                r_bulk_evt_arg1  <= {11'h000, r_bulk_next_addr};
                r_bulk_evt_arg2  <= r_bulk_completed_words;
              end
              r_bulk_wr_capture_count <= '0;
            end else if (({12'h000, l_bulk_rx_block_bytes[15:2]}) > r_bulk_remaining_words) begin
              st_bulk                <= BULK_IDLE;
              r_bulk_evt_pending     <= 1'b1;
              r_bulk_evt_id          <= EVT_BULK_ABORT;
              r_bulk_evt_arg0        <= ERR_WORD_COUNT;
              r_bulk_evt_arg1        <= {11'h000, r_bulk_next_addr};
              r_bulk_evt_arg2        <= r_bulk_completed_words;
              r_bulk_wr_capture_count<= '0;
            end else begin
              r_bulk_chunk_words <= l_bulk_rx_block_bytes[10:2];
              st_bulk            <= BULK_WRITE_ISSUE;
            end
          end
        end

        BULK_WRITE_ISSUE: begin
          if (s_access_bulk_write_fire) begin
            st_bulk <= BULK_WRITE_WAIT_ACCESS;
          end
        end

        BULK_WRITE_WAIT_ACCESS: begin
          if (!r_bulk_evt_pending && l_access_raw_err_valid) begin
            st_bulk            <= BULK_IDLE;
            r_bulk_evt_pending <= 1'b1;
            r_bulk_evt_id      <= EVT_BULK_ERR;
            r_bulk_evt_arg0    <= l_access_raw_err_code;
            r_bulk_evt_arg1    <= {11'h000, r_bulk_next_addr};
            r_bulk_evt_arg2    <= r_bulk_completed_words;
            r_bulk_wr_capture_count <= '0;
          end else if (!r_bulk_evt_pending && l_access_raw_done) begin
            next_completed_words = r_bulk_completed_words + r_bulk_chunk_words;
            next_remaining_words = r_bulk_remaining_words - r_bulk_chunk_words;

            r_bulk_next_addr        <= r_bulk_next_addr + r_bulk_chunk_words;
            r_bulk_remaining_words  <= next_remaining_words;
            r_bulk_completed_words  <= next_completed_words;
            r_bulk_wr_capture_count <= '0;
            st_bulk                 <= BULK_WRITE_RECV;

            r_bulk_evt_pending <= 1'b1;
            r_bulk_evt_id      <= EVT_BULK_PROG;
            r_bulk_evt_arg0    <= {11'h000, r_bulk_next_addr};
            r_bulk_evt_arg1    <= next_completed_words;
            r_bulk_evt_arg2    <= next_remaining_words;
          end
        end

        BULK_READ_ISSUE: begin
          if (s_access_bulk_read_fire) begin
            r_bulk_chunk_words <= s_bulk_issue_words;
            st_bulk            <= BULK_READ_WAIT_ACCESS;
          end
        end

        BULK_READ_WAIT_ACCESS: begin
          if (!r_bulk_evt_pending && l_access_raw_err_valid) begin
            st_bulk            <= BULK_IDLE;
            r_bulk_evt_pending <= 1'b1;
            r_bulk_evt_id      <= EVT_BULK_ERR;
            r_bulk_evt_arg0    <= l_access_raw_err_code;
            r_bulk_evt_arg1    <= {11'h000, r_bulk_next_addr};
            r_bulk_evt_arg2    <= r_bulk_completed_words;
          end else if (l_access_raw_done) begin
            r_bulk_rd_chunk_data   <= l_access_raw_rd_data;
            r_bulk_rd_packet_id    <= '0;
            r_bulk_rd_packet_count <= r_bulk_chunk_words[8:1] + {7'h0, r_bulk_chunk_words[0]};
            st_bulk                <= BULK_READ_SEND;
          end
        end

        BULK_READ_SEND: begin
          if (!r_bulk_evt_pending) begin
            if (r_bulk_rd_packet_id < r_bulk_rd_packet_count) begin
              data_evt_arg0 = {9'h000, s_bulk_send_one_word ? 2'd1 : 2'd2, s_bulk_send_addr};
              data_evt_arg1 = s_bulk_send_data0;
              data_evt_arg2 = s_bulk_send_one_word ? 32'h0000_0000 : s_bulk_send_data1;

              r_bulk_evt_pending <= 1'b1;
              r_bulk_evt_id      <= EVT_BULK_PROG;
              r_bulk_evt_arg0    <= data_evt_arg0;
              r_bulk_evt_arg1    <= data_evt_arg1;
              r_bulk_evt_arg2    <= data_evt_arg2;
            end else begin
              next_completed_words = r_bulk_completed_words + r_bulk_chunk_words;
              next_remaining_words = r_bulk_remaining_words - r_bulk_chunk_words;

              r_bulk_next_addr       <= r_bulk_next_addr + r_bulk_chunk_words;
              r_bulk_remaining_words <= next_remaining_words;
              r_bulk_completed_words <= next_completed_words;

              if (next_remaining_words != 0) begin
                st_bulk <= BULK_READ_ISSUE;
              end else begin
                st_bulk            <= BULK_IDLE;
                r_bulk_evt_pending <= 1'b1;
                r_bulk_evt_id      <= EVT_BULK_DONE;
                r_bulk_evt_arg0    <= {11'h000, r_bulk_start_addr};
                r_bulk_evt_arg1    <= {11'h000, r_bulk_total_words};
                r_bulk_evt_arg2    <= next_completed_words;
              end
            end
          end else if (s_bulk_evt_accept && (r_bulk_evt_id == EVT_BULK_PROG)) begin
            r_bulk_rd_packet_id <= r_bulk_rd_packet_id + 1'b1;
          end
        end

        default: begin
          st_bulk <= BULK_IDLE;
        end
      endcase
    end
  end

  // Self-test restart is a one-cycle pulse generated by the status control word.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      O_SELFTEST_RESTART_REQ <= 1'b0;
    end else begin
      O_SELFTEST_RESTART_REQ <= s_selftest_restart_pulse;
    end
  end

endmodule
