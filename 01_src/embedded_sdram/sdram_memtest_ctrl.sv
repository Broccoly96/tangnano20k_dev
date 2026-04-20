`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_memtest_ctrl.sv
// Description  : Embedded SDRAM HS native write/read/compare self-test.
//                - Issues explicit ACTIVE then WRITE/READ commands.
//                - Waits for O_sdrc_cmd_ack through I_SDRC_CMD_ACK.
//                - Samples read data after the configured HS read latency.
//                - Keeps the legacy debug/status outputs used by uart_log_tool.
//
// FSM flow:
//   IDLE -> POST_INIT -> WRITE_WAIT -> WRITE_ACTIVE_REQ/ACK
//        -> WRITE_REQ/ACK -> READ_GAP -> READ_ACTIVE_REQ/ACK
//        -> READ_REQ -> READ_SAMPLE -> next burst or CLEAR_WAIT
//        -> CLEAR_ACTIVE_REQ/ACK -> CLEAR_REQ/ACK -> PASS
//        -> RETRY_* for a single failing word, or FAIL on timeout/mismatch.
//////////////////////////////////////////////////////////////////////////////////

module sdram_memtest_ctrl #(
  parameter int unsigned BURST_WORDS = 1,
  parameter int unsigned BURST_COUNT = 8,
  parameter int unsigned TEST_WORDS = BURST_WORDS * BURST_COUNT,
  parameter bit          USE_FIXED_WINDOW_ADDR = 1'b0,
  parameter logic [1:0]  FIXED_BANK_ADDR = 2'd2,
  parameter logic [10:0] FIXED_ROW_ADDR = 11'd2,
  parameter logic [7:0]  FIXED_COL_START = 8'd5,
  parameter int unsigned POST_INIT_WAIT_CYCLES = 20_000,
  parameter int unsigned POST_WRITE_TO_READ_GAP_CYCLES = 4,
  parameter int unsigned CLEAR_WORDS = 2_097_152,
  parameter int unsigned READ_DATA_LATENCY_CYCLES =
    sdram_hs_cmd_pkg::SDRAM_HS_READ_DATA_LATENCY_CYCLES
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_SDRC_INIT_DONE,
  input  logic        I_SDRC_READY,
  input  logic        I_SDRC_CMD_ACK,
  input  logic [31:0] I_SDRC_RD_DATA,
  output logic        O_SDRC_CMD_EN,
  output logic [2:0]  O_SDRC_CMD,
  output logic        O_SDRC_PRECHARGE_CTRL,
  output logic [20:0] O_SDRC_ADDR,
  output logic [7:0]  O_SDRC_DATA_LEN,
  output logic [3:0]  O_SDRC_DQM,
  output logic [31:0] O_SDRC_WR_DATA,
  output logic        O_SDRC_PAIR_ACTIVE,
  output logic        O_READ_SAMPLE_VALID,
  output logic        O_TEST_ACTIVE,
  output logic        O_TEST_PASS,
  output logic        O_TEST_FAIL,
  output logic        O_EVT_VALID,
  output logic [7:0]  O_EVT_ID,
  output logic [31:0] O_EVT_ARG0,
  output logic [31:0] O_EVT_ARG1,
  output logic [31:0] O_EVT_ARG2,
  output logic [31:0] O_DBG_MEM_SUMMARY,
  output logic [7:0]  O_DBG_STATE,
  output logic [7:0]  O_DBG_FAIL_REASON,
  output logic [20:0] O_DBG_CURRENT_ADDR,
  output logic [31:0] O_DBG_EXPECTED_WORD,
  output logic [31:0] O_DBG_LAST_READ_DATA,
  output logic [31:0] O_DBG_LAST_STATUS,
  output logic [31:0] O_DBG_FAIL_ADDR,
  output logic [31:0] O_DBG_FAIL_EXPECTED,
  output logic [31:0] O_DBG_FAIL_ACTUAL,
  output logic [31:0] O_DBG_RETRY_SUMMARY,
  output logic [31:0] O_DBG_RETRY_DATA1,
  output logic [31:0] O_DBG_RETRY_DATA2,
  output logic [31:0] O_DBG_CTRL_SUMMARY,
  output logic [31:0] O_DBG_CTRL_DETAIL
);

  import sdram_hs_cmd_pkg::*;

  localparam logic [7:0] EVT_INIT_DONE     = 8'h20;
  localparam logic [7:0] EVT_TEST_START    = 8'h21;
  localparam logic [7:0] EVT_TEST_PASS     = 8'h22;
  localparam logic [7:0] EVT_TEST_FAIL     = 8'h23;
  localparam logic [7:0] EVT_TEST_FAIL_CTX = 8'h24;

  localparam logic [7:0] FAIL_REASON_NONE       = 8'h00;
  localparam logic [7:0] FAIL_REASON_TIMEOUT    = 8'h01;
  localparam logic [7:0] FAIL_REASON_PAGE_CROSS = 8'h02;
  localparam logic [7:0] FAIL_REASON_MISMATCH   = 8'h03;
  localparam int unsigned RETRY_LIMIT           = 3;

  localparam int unsigned WORD_CNT_W = (BURST_WORDS <= 1) ? 1 :
                                       $clog2(BURST_WORDS + 1);
  localparam int unsigned TEST_IDX_W = (TEST_WORDS <= 1) ? 1 :
                                       $clog2(TEST_WORDS + 1);
  localparam int unsigned CLEAR_IDX_W = (CLEAR_WORDS <= 1) ? 1 :
                                        $clog2(CLEAR_WORDS + 1);
  localparam int unsigned GAP_CNT_W = (POST_WRITE_TO_READ_GAP_CYCLES <= 1) ?
                                      1 : $clog2(POST_WRITE_TO_READ_GAP_CYCLES + 1);
  localparam int unsigned INIT_CNT_W = (POST_INIT_WAIT_CYCLES <= 1) ? 1 :
                                       $clog2(POST_INIT_WAIT_CYCLES + 1);
  localparam int unsigned LAT_CNT_W = (READ_DATA_LATENCY_CYCLES <= 1) ? 1 :
                                      $clog2(READ_DATA_LATENCY_CYCLES + 1);
  localparam int unsigned ACK_TIMEOUT_CYCLES = 128;
  localparam int unsigned ACK_CNT_W = $clog2(ACK_TIMEOUT_CYCLES + 1);
  localparam int unsigned TEST_IDX_ADDR_COPY_W =
    (TEST_IDX_W < 21) ? TEST_IDX_W : 21;
  localparam int unsigned CLEAR_IDX_ADDR_COPY_W =
    (CLEAR_IDX_W < 21) ? CLEAR_IDX_W : 21;
  localparam logic [GAP_CNT_W-1:0] POST_WRITE_GAP_INIT =
    POST_WRITE_TO_READ_GAP_CYCLES;
  localparam logic [LAT_CNT_W-1:0] READ_LATENCY_COUNTER_INIT =
    (READ_DATA_LATENCY_CYCLES <= 1) ? '0 :
      (READ_DATA_LATENCY_CYCLES - 1);

`ifndef SYNTHESIS
  initial begin
    if ((BURST_WORDS < 1) || (BURST_WORDS > 256)) begin
      $fatal(1, "BURST_WORDS must be in range 1..256, got %0d", BURST_WORDS);
    end
    if ((TEST_WORDS < 1) || (TEST_WORDS > CLEAR_WORDS)) begin
      $fatal(1, "TEST_WORDS must be in range 1..CLEAR_WORDS");
    end
  end
`endif

  typedef enum logic [4:0] {
    IDLE,
    POST_INIT,
    WRITE_WAIT,
    WRITE_ACTIVE_REQ,
    WRITE_ACTIVE_ACK,
    WRITE_REQ,
    WRITE_ACK,
    READ_GAP,
    READ_ACTIVE_REQ,
    READ_ACTIVE_ACK,
    READ_REQ,
    READ_SAMPLE,
    RETRY_WAIT,
    RETRY_ACTIVE_REQ,
    RETRY_ACTIVE_ACK,
    RETRY_READ_REQ,
    RETRY_SAMPLE,
    CLEAR_WAIT,
    CLEAR_ACTIVE_REQ,
    CLEAR_ACTIVE_ACK,
    CLEAR_REQ,
    CLEAR_ACK,
    PASS,
    FAIL
  } st_state_e;

  st_state_e st_state;

  logic [INIT_CNT_W-1:0]  r_init_cnt;
  logic [GAP_CNT_W-1:0]   r_gap_cnt;
  logic [LAT_CNT_W-1:0]   r_lat_cnt;
  logic [ACK_CNT_W-1:0]   r_ack_cnt;
  logic [TEST_IDX_W-1:0]  r_test_word_idx;
  logic [CLEAR_IDX_W-1:0] r_clear_word_idx;
  logic [WORD_CNT_W-1:0]  r_write_word_idx;
  logic [WORD_CNT_W-1:0]  r_read_word_idx;
  logic [31:0]            r_write_seed;
  logic [31:0]            r_expected_word;
  logic [31:0]            r_last_read_data;
  logic [31:0]            r_last_status;
  logic [7:0]             r_fail_reason;
  logic [31:0]            r_fail_addr;
  logic [31:0]            r_fail_expected;
  logic [31:0]            r_fail_actual;
  logic [31:0]            r_retry_data1;
  logic [31:0]            r_retry_data2;
  logic [2:0]             r_retry_count;
  logic [2:0]             r_retry_total_attempts;
  logic                   r_retry_valid;
  logic                   r_retry_recovered;
  logic                   r_retry_exhausted;
  logic [20:0]            r_retry_addr;
  logic [31:0]            r_retry_expected;
  logic                   r_init_logged;
  logic                   r_evt_valid;
  logic [7:0]             r_evt_id;
  logic [31:0]            r_evt_arg0;
  logic [31:0]            r_evt_arg1;
  logic [31:0]            r_evt_arg2;

  logic [31:0] s_test_remaining;
  logic [31:0] s_clear_remaining;
  logic [8:0]  s_fixed_col_addr;
  logic [20:0] s_test_word_idx_addr;
  logic [20:0] s_clear_word_idx_addr;
  logic [20:0] s_curr_addr;
  logic [20:0] s_clear_addr;
  logic [20:0] s_active_addr;
  logic [7:0]  s_test_words_this_burst_m1;
  logic [7:0]  s_clear_words_this_burst_m1;
  logic [7:0]  s_active_data_len;
  logic        s_test_last_burst;
  logic        s_clear_last_burst;
  logic        s_active_page_cross;
  logic [31:0] s_read_expected;

  function automatic logic [20:0] test_idx_to_addr(
    input logic [TEST_IDX_W-1:0] idx
  );
    begin
      test_idx_to_addr = 21'h00000;
      for (int bit_idx = 0; bit_idx < TEST_IDX_ADDR_COPY_W; bit_idx++) begin
        test_idx_to_addr[bit_idx] = idx[bit_idx];
      end
    end
  endfunction

  function automatic logic [20:0] clear_idx_to_addr(
    input logic [CLEAR_IDX_W-1:0] idx
  );
    begin
      clear_idx_to_addr = 21'h00000;
      for (int bit_idx = 0; bit_idx < CLEAR_IDX_ADDR_COPY_W; bit_idx++) begin
        clear_idx_to_addr[bit_idx] = idx[bit_idx];
      end
    end
  endfunction

  assign s_test_remaining = (TEST_WORDS > r_test_word_idx) ?
                            (TEST_WORDS - r_test_word_idx) : 32'd0;
  assign s_clear_remaining = (CLEAR_WORDS > r_clear_word_idx) ?
                             (CLEAR_WORDS - r_clear_word_idx) : 32'd0;
  assign s_test_word_idx_addr = test_idx_to_addr(r_test_word_idx);
  assign s_clear_word_idx_addr = clear_idx_to_addr(r_clear_word_idx);
  assign s_test_words_this_burst_m1 =
    (s_test_remaining >= BURST_WORDS) ? (BURST_WORDS[7:0] - 1'b1) :
    ((s_test_remaining == 0) ? 8'h00 : (s_test_remaining[7:0] - 1'b1));
  assign s_clear_words_this_burst_m1 =
    (s_clear_remaining >= BURST_WORDS) ? (BURST_WORDS[7:0] - 1'b1) :
    ((s_clear_remaining == 0) ? 8'h00 : (s_clear_remaining[7:0] - 1'b1));
  assign s_test_last_burst =
    (s_test_remaining <= BURST_WORDS) && (s_test_remaining != 0);
  assign s_clear_last_burst =
    (s_clear_remaining <= BURST_WORDS) && (s_clear_remaining != 0);

  assign s_fixed_col_addr = {1'b0, FIXED_COL_START} +
                            {1'b0, s_test_word_idx_addr[7:0]};
  assign s_curr_addr = USE_FIXED_WINDOW_ADDR ?
                       {FIXED_BANK_ADDR, FIXED_ROW_ADDR, s_fixed_col_addr[7:0]} :
                       s_test_word_idx_addr;
  assign s_clear_addr = s_clear_word_idx_addr;
  assign s_active_addr =
    (st_state inside {RETRY_WAIT, RETRY_ACTIVE_REQ, RETRY_ACTIVE_ACK,
                      RETRY_READ_REQ, RETRY_SAMPLE}) ? r_retry_addr :
    (st_state inside {CLEAR_WAIT, CLEAR_ACTIVE_REQ, CLEAR_ACTIVE_ACK,
                      CLEAR_REQ, CLEAR_ACK}) ? s_clear_addr : s_curr_addr;
  assign s_active_data_len =
    (st_state inside {RETRY_WAIT, RETRY_ACTIVE_REQ, RETRY_ACTIVE_ACK,
                      RETRY_READ_REQ, RETRY_SAMPLE}) ? 8'h00 :
    (st_state inside {CLEAR_WAIT, CLEAR_ACTIVE_REQ, CLEAR_ACTIVE_ACK,
                      CLEAR_REQ, CLEAR_ACK}) ?
      s_clear_words_this_burst_m1 : s_test_words_this_burst_m1;
  assign s_active_page_cross =
    sdram_hs_burst_crosses_page(s_active_addr, s_active_data_len);
  assign s_read_expected =
    (st_state == RETRY_SAMPLE) ? r_retry_expected : r_expected_word;

  assign O_SDRC_ADDR = s_active_addr;
  assign O_SDRC_DATA_LEN = s_active_data_len;
  assign O_SDRC_DQM = 4'h0;
  assign O_SDRC_PRECHARGE_CTRL =
    (st_state inside {WRITE_REQ, READ_REQ, RETRY_READ_REQ, CLEAR_REQ});
  assign O_SDRC_PAIR_ACTIVE =
    !(st_state inside {IDLE, POST_INIT, WRITE_WAIT, READ_GAP, RETRY_WAIT,
                       CLEAR_WAIT, PASS, FAIL});
  assign O_READ_SAMPLE_VALID =
    (st_state == READ_SAMPLE) && (r_lat_cnt == 0);
  assign O_TEST_ACTIVE = !(st_state inside {IDLE, PASS, FAIL});
  assign O_TEST_PASS = (st_state == PASS);
  assign O_TEST_FAIL = (st_state == FAIL);
  assign O_EVT_VALID = r_evt_valid;
  assign O_EVT_ID = r_evt_id;
  assign O_EVT_ARG0 = r_evt_arg0;
  assign O_EVT_ARG1 = r_evt_arg1;
  assign O_EVT_ARG2 = r_evt_arg2;
  assign O_DBG_STATE = {3'h0, st_state};
  assign O_DBG_FAIL_REASON = r_fail_reason;
  assign O_DBG_CURRENT_ADDR = s_active_addr;
  assign O_DBG_EXPECTED_WORD = s_read_expected;
  assign O_DBG_LAST_READ_DATA = r_last_read_data;
  assign O_DBG_LAST_STATUS = r_last_status;
  assign O_DBG_FAIL_ADDR = r_fail_addr;
  assign O_DBG_FAIL_EXPECTED = r_fail_expected;
  assign O_DBG_FAIL_ACTUAL = r_fail_actual;
  assign O_DBG_RETRY_DATA1 = r_retry_data1;
  assign O_DBG_RETRY_DATA2 = r_retry_data2;

  always_comb begin
    O_SDRC_CMD_EN = 1'b0;
    O_SDRC_CMD = SDRAM_HS_CMD_NOP;
    unique case (st_state)
      WRITE_ACTIVE_REQ,
      READ_ACTIVE_REQ,
      RETRY_ACTIVE_REQ,
      CLEAR_ACTIVE_REQ: begin
        O_SDRC_CMD_EN = I_SDRC_READY;
        O_SDRC_CMD = SDRAM_HS_CMD_ACTIVE;
      end
      WRITE_REQ,
      CLEAR_REQ: begin
        O_SDRC_CMD_EN = 1'b1;
        O_SDRC_CMD = SDRAM_HS_CMD_WRITE;
      end
      READ_REQ,
      RETRY_READ_REQ: begin
        O_SDRC_CMD_EN = 1'b1;
        O_SDRC_CMD = SDRAM_HS_CMD_READ;
      end
      default: begin
        O_SDRC_CMD_EN = 1'b0;
        O_SDRC_CMD = SDRAM_HS_CMD_NOP;
      end
    endcase
  end

  always_comb begin
    O_SDRC_WR_DATA = 32'h0000_0000;
    if (st_state inside {CLEAR_REQ, CLEAR_ACK}) begin
      O_SDRC_WR_DATA = 32'h0000_0000;
    end else if (st_state inside {WRITE_REQ, WRITE_ACK}) begin
      O_SDRC_WR_DATA = r_write_seed +
                       {{(32-WORD_CNT_W){1'b0}}, r_write_word_idx};
    end
  end

  always_comb begin
    O_DBG_MEM_SUMMARY = 32'h0000_0000;
    O_DBG_MEM_SUMMARY[31:24] = r_test_word_idx[7:0];
    O_DBG_MEM_SUMMARY[23:16] = {{(8-WORD_CNT_W){1'b0}}, r_read_word_idx};
    O_DBG_MEM_SUMMARY[15:8]  = {{(8-WORD_CNT_W){1'b0}}, r_write_word_idx};
    O_DBG_MEM_SUMMARY[7:0]   = r_ack_cnt[7:0];
  end

  always_comb begin
    O_DBG_RETRY_SUMMARY = 32'h0000_0000;
    O_DBG_RETRY_SUMMARY[31:24] = RETRY_LIMIT[7:0];
    O_DBG_RETRY_SUMMARY[23:16] = {5'h00, r_retry_count};
    O_DBG_RETRY_SUMMARY[15:8]  = {5'h00, r_retry_total_attempts};
    O_DBG_RETRY_SUMMARY[7]     = r_retry_recovered;
    O_DBG_RETRY_SUMMARY[6]     = r_retry_exhausted;
    O_DBG_RETRY_SUMMARY[5]     = r_retry_valid;
    O_DBG_RETRY_SUMMARY[4:0]   = r_fail_reason[4:0];
  end

  always_comb begin
    O_DBG_CTRL_SUMMARY = 32'h0000_0000;
    O_DBG_CTRL_SUMMARY[31:27] = st_state;
    O_DBG_CTRL_SUMMARY[26]    = O_SDRC_CMD_EN;
    O_DBG_CTRL_SUMMARY[25:23] = O_SDRC_CMD;
    O_DBG_CTRL_SUMMARY[22]    = I_SDRC_CMD_ACK;
    O_DBG_CTRL_SUMMARY[21]    = I_SDRC_INIT_DONE;
    O_DBG_CTRL_SUMMARY[20]    = I_SDRC_READY;
    O_DBG_CTRL_SUMMARY[19]    = O_READ_SAMPLE_VALID;
    O_DBG_CTRL_SUMMARY[18]    = O_SDRC_PAIR_ACTIVE;
    O_DBG_CTRL_SUMMARY[17:16] = r_retry_count[1:0];
    O_DBG_CTRL_SUMMARY[15:8]  = {{(8-WORD_CNT_W){1'b0}}, r_read_word_idx};
    O_DBG_CTRL_SUMMARY[7:0]   = {{(8-WORD_CNT_W){1'b0}}, r_write_word_idx};
  end

  assign O_DBG_CTRL_DETAIL = {11'h000, s_active_addr};

  task automatic set_event(
    input logic [7:0]  evt_id,
    input logic [31:0] arg0,
    input logic [31:0] arg1,
    input logic [31:0] arg2
  );
    begin
      r_evt_valid <= 1'b1;
      r_evt_id    <= evt_id;
      r_evt_arg0  <= arg0;
      r_evt_arg1  <= arg1;
      r_evt_arg2  <= arg2;
    end
  endtask

  task automatic set_fail(
    input logic [7:0] reason,
    input logic [31:0] addr,
    input logic [31:0] expected,
    input logic [31:0] actual
  );
    begin
      r_fail_reason   <= reason;
      r_fail_addr     <= addr;
      r_fail_expected <= expected;
      r_fail_actual   <= actual;
      r_last_status   <= {reason, st_state, I_SDRC_CMD_ACK, I_SDRC_INIT_DONE,
                          I_SDRC_READY, O_SDRC_CMD_EN, O_SDRC_CMD, r_ack_cnt};
      set_event(EVT_TEST_FAIL, {24'h0, reason}, addr, actual);
    end
  endtask

  // Owns the HS command self-test sequence and debug state.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state <= IDLE;
      r_init_cnt <= '0;
      r_gap_cnt <= '0;
      r_lat_cnt <= '0;
      r_ack_cnt <= '0;
      r_test_word_idx <= '0;
      r_clear_word_idx <= '0;
      r_write_word_idx <= '0;
      r_read_word_idx <= '0;
      r_write_seed <= 32'hA500_0000;
      r_expected_word <= 32'hA500_0000;
      r_last_read_data <= 32'h0000_0000;
      r_last_status <= 32'h0000_0000;
      r_fail_reason <= FAIL_REASON_NONE;
      r_fail_addr <= 32'h0000_0000;
      r_fail_expected <= 32'h0000_0000;
      r_fail_actual <= 32'h0000_0000;
      r_retry_data1 <= 32'h0000_0000;
      r_retry_data2 <= 32'h0000_0000;
      r_retry_count <= 3'h0;
      r_retry_total_attempts <= 3'h0;
      r_retry_valid <= 1'b0;
      r_retry_recovered <= 1'b0;
      r_retry_exhausted <= 1'b0;
      r_retry_addr <= 21'h00000;
      r_retry_expected <= 32'h0000_0000;
      r_init_logged <= 1'b0;
      r_evt_valid <= 1'b0;
      r_evt_id <= 8'h00;
      r_evt_arg0 <= 32'h0000_0000;
      r_evt_arg1 <= 32'h0000_0000;
      r_evt_arg2 <= 32'h0000_0000;
    end else begin
      r_evt_valid <= 1'b0;

      if (r_ack_cnt != 0) begin
        r_ack_cnt <= r_ack_cnt + 1'b1;
      end

      case (st_state)
        IDLE: begin
          r_ack_cnt <= '0;
          if (I_SDRC_INIT_DONE) begin
            st_state <= POST_INIT;
            r_init_cnt <= '0;
            if (!r_init_logged) begin
              r_init_logged <= 1'b1;
              set_event(EVT_INIT_DONE, 32'h0000_0000, 32'h0000_0000, 32'h0000_0000);
            end
          end
        end

        POST_INIT: begin
          if (r_init_cnt >= POST_INIT_WAIT_CYCLES - 1) begin
            st_state <= WRITE_WAIT;
            set_event(EVT_TEST_START, 32'h0000_0000, TEST_WORDS, CLEAR_WORDS);
          end else begin
            r_init_cnt <= r_init_cnt + 1'b1;
          end
        end

        WRITE_WAIT: begin
          r_write_word_idx <= '0;
          r_write_seed <= 32'hA500_0000 + {{(32-TEST_IDX_W){1'b0}}, r_test_word_idx};
          r_expected_word <= 32'hA500_0000 + {{(32-TEST_IDX_W){1'b0}}, r_test_word_idx};
          if (s_active_page_cross) begin
            set_fail(FAIL_REASON_PAGE_CROSS, {11'h000, s_active_addr},
                     32'h0000_0000, {24'h0, s_active_data_len});
            st_state <= FAIL;
          end else if (I_SDRC_READY) begin
            st_state <= WRITE_ACTIVE_REQ;
          end
        end

        WRITE_ACTIVE_REQ: begin
          if (I_SDRC_READY) begin
            st_state <= WRITE_ACTIVE_ACK;
            r_ack_cnt <= 1;
          end
        end

        WRITE_ACTIVE_ACK: begin
          if (I_SDRC_CMD_ACK) begin
            st_state <= WRITE_REQ;
            r_ack_cnt <= '0;
          end else if (r_ack_cnt >= ACK_TIMEOUT_CYCLES) begin
            set_fail(FAIL_REASON_TIMEOUT, {11'h000, s_active_addr}, 32'h0, 32'h0);
            st_state <= FAIL;
          end
        end

        WRITE_REQ: begin
          st_state <= WRITE_ACK;
          r_ack_cnt <= 1;
          r_write_word_idx <= (s_active_data_len == 0) ? '0 : 1;
        end

        WRITE_ACK: begin
          if (r_write_word_idx < s_active_data_len) begin
            r_write_word_idx <= r_write_word_idx + 1'b1;
          end
          if (I_SDRC_CMD_ACK) begin
            st_state <= READ_GAP;
            r_gap_cnt <= POST_WRITE_GAP_INIT;
            r_ack_cnt <= '0;
          end else if (r_ack_cnt >= ACK_TIMEOUT_CYCLES) begin
            set_fail(FAIL_REASON_TIMEOUT, {11'h000, s_active_addr}, r_write_seed, 32'h0);
            st_state <= FAIL;
          end
        end

        READ_GAP: begin
          r_read_word_idx <= '0;
          r_expected_word <= r_write_seed;
          if (r_gap_cnt == 0) begin
            st_state <= READ_ACTIVE_REQ;
          end else begin
            r_gap_cnt <= r_gap_cnt - 1'b1;
          end
        end

        READ_ACTIVE_REQ: begin
          if (I_SDRC_READY) begin
            st_state <= READ_ACTIVE_ACK;
            r_ack_cnt <= 1;
          end
        end

        READ_ACTIVE_ACK: begin
          if (I_SDRC_CMD_ACK) begin
            st_state <= READ_REQ;
            r_ack_cnt <= '0;
          end else if (r_ack_cnt >= ACK_TIMEOUT_CYCLES) begin
            set_fail(FAIL_REASON_TIMEOUT, {11'h000, s_active_addr}, 32'h0, 32'h0);
            st_state <= FAIL;
          end
        end

        READ_REQ: begin
          st_state <= READ_SAMPLE;
          r_lat_cnt <= READ_LATENCY_COUNTER_INIT;
          r_ack_cnt <= 1;
        end

        READ_SAMPLE: begin
          if (r_lat_cnt != 0) begin
            r_lat_cnt <= r_lat_cnt - 1'b1;
          end else begin
            r_last_read_data <= I_SDRC_RD_DATA;
            if (I_SDRC_RD_DATA != r_expected_word) begin
              r_retry_valid <= 1'b1;
              r_retry_addr <= s_active_addr + {{(21-WORD_CNT_W){1'b0}}, r_read_word_idx};
              r_retry_expected <= r_expected_word;
              r_retry_total_attempts <= r_retry_total_attempts + 1'b1;
              if (r_retry_count == 0) begin
                r_retry_data1 <= I_SDRC_RD_DATA;
              end else begin
                r_retry_data2 <= I_SDRC_RD_DATA;
              end
              if (r_retry_count < RETRY_LIMIT) begin
                r_retry_count <= r_retry_count + 1'b1;
                st_state <= RETRY_WAIT;
              end else begin
                r_retry_exhausted <= 1'b1;
                set_fail(FAIL_REASON_MISMATCH, {11'h000, s_active_addr},
                         r_expected_word, I_SDRC_RD_DATA);
                st_state <= FAIL;
              end
            end else if (r_read_word_idx >= s_active_data_len) begin
              r_retry_count <= 3'h0;
              if (s_test_last_burst) begin
                st_state <= CLEAR_WAIT;
              end else begin
                r_test_word_idx <= r_test_word_idx + (s_active_data_len + 1'b1);
                st_state <= WRITE_WAIT;
              end
            end else begin
              r_read_word_idx <= r_read_word_idx + 1'b1;
              r_expected_word <= r_expected_word + 1'b1;
            end
          end
        end

        RETRY_WAIT: begin
          if (I_SDRC_READY) begin
            st_state <= RETRY_ACTIVE_REQ;
          end
        end

        RETRY_ACTIVE_REQ: begin
          if (I_SDRC_READY) begin
            st_state <= RETRY_ACTIVE_ACK;
            r_ack_cnt <= 1;
          end
        end

        RETRY_ACTIVE_ACK: begin
          if (I_SDRC_CMD_ACK) begin
            st_state <= RETRY_READ_REQ;
            r_ack_cnt <= '0;
          end else if (r_ack_cnt >= ACK_TIMEOUT_CYCLES) begin
            set_fail(FAIL_REASON_TIMEOUT, {11'h000, r_retry_addr}, r_retry_expected, 32'h0);
            st_state <= FAIL;
          end
        end

        RETRY_READ_REQ: begin
          st_state <= RETRY_SAMPLE;
          r_lat_cnt <= READ_LATENCY_COUNTER_INIT;
          r_ack_cnt <= 1;
        end

        RETRY_SAMPLE: begin
          if (r_lat_cnt != 0) begin
            r_lat_cnt <= r_lat_cnt - 1'b1;
          end else begin
            r_last_read_data <= I_SDRC_RD_DATA;
            if (I_SDRC_RD_DATA == r_retry_expected) begin
              r_retry_recovered <= 1'b1;
              r_retry_count <= 3'h0;
              if (s_test_last_burst) begin
                st_state <= CLEAR_WAIT;
              end else begin
                r_test_word_idx <= r_test_word_idx + (s_active_data_len + 1'b1);
                st_state <= WRITE_WAIT;
              end
            end else if (r_retry_count < RETRY_LIMIT) begin
              r_retry_count <= r_retry_count + 1'b1;
              r_retry_total_attempts <= r_retry_total_attempts + 1'b1;
              st_state <= RETRY_WAIT;
            end else begin
              r_retry_exhausted <= 1'b1;
              set_fail(FAIL_REASON_MISMATCH, {11'h000, r_retry_addr},
                       r_retry_expected, I_SDRC_RD_DATA);
              st_state <= FAIL;
            end
          end
        end

        CLEAR_WAIT: begin
          r_write_word_idx <= '0;
          if (s_clear_remaining == 0) begin
            st_state <= PASS;
            set_event(EVT_TEST_PASS, TEST_WORDS, CLEAR_WORDS, 32'h0000_0000);
          end else if (s_active_page_cross) begin
            set_fail(FAIL_REASON_PAGE_CROSS, {11'h000, s_active_addr},
                     32'h0000_0000, {24'h0, s_active_data_len});
            st_state <= FAIL;
          end else if (I_SDRC_READY) begin
            st_state <= CLEAR_ACTIVE_REQ;
          end
        end

        CLEAR_ACTIVE_REQ: begin
          if (I_SDRC_READY) begin
            st_state <= CLEAR_ACTIVE_ACK;
            r_ack_cnt <= 1;
          end
        end

        CLEAR_ACTIVE_ACK: begin
          if (I_SDRC_CMD_ACK) begin
            st_state <= CLEAR_REQ;
            r_ack_cnt <= '0;
          end else if (r_ack_cnt >= ACK_TIMEOUT_CYCLES) begin
            set_fail(FAIL_REASON_TIMEOUT, {11'h000, s_active_addr}, 32'h0, 32'h0);
            st_state <= FAIL;
          end
        end

        CLEAR_REQ: begin
          st_state <= CLEAR_ACK;
          r_ack_cnt <= 1;
          r_write_word_idx <= (s_active_data_len == 0) ? '0 : 1;
        end

        CLEAR_ACK: begin
          if (r_write_word_idx < s_active_data_len) begin
            r_write_word_idx <= r_write_word_idx + 1'b1;
          end
          if (I_SDRC_CMD_ACK) begin
            r_ack_cnt <= '0;
            if (s_clear_last_burst) begin
              st_state <= PASS;
              set_event(EVT_TEST_PASS, TEST_WORDS, CLEAR_WORDS, 32'h0000_0000);
            end else begin
              r_clear_word_idx <= r_clear_word_idx + (s_active_data_len + 1'b1);
              st_state <= CLEAR_WAIT;
            end
          end else if (r_ack_cnt >= ACK_TIMEOUT_CYCLES) begin
            set_fail(FAIL_REASON_TIMEOUT, {11'h000, s_active_addr}, 32'h0, 32'h0);
            st_state <= FAIL;
          end
        end

        PASS: begin
          st_state <= PASS;
        end

        FAIL: begin
          if (!r_evt_valid) begin
            set_event(EVT_TEST_FAIL_CTX, r_fail_addr, r_fail_expected, r_fail_actual);
          end
          st_state <= FAIL;
        end

        default: begin
          st_state <= IDLE;
        end
      endcase
    end
  end

endmodule
