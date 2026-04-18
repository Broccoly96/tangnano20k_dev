`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_memtest_ctrl.sv
// Description  : Embedded SDRAM write/read/compare self-test controller.
//                - Runs vendor SDRC burst write/read/clear sequences.
//                - Retries read-data mismatches up to three times on the exact
//                  failing word address before declaring FAIL.
//                - Exposes detailed debug words for the status register map.
//
// FSM flow:
//   IDLE -> WRITE_WAIT -> WRITE_REQ -> WRITE_RUN
//        -> READ_WAIT  -> READ_REQ  -> READ_RUN
//        -> (retry path) RETRY_WAIT -> RETRY_REQ -> RETRY_RUN
//        -> next burst or CLEAR_WAIT -> CLEAR_REQ -> CLEAR_RUN -> PASS
//        -> FAIL on timeout or exhausted mismatch retry
//////////////////////////////////////////////////////////////////////////////////

module sdram_memtest_ctrl #(
  parameter int unsigned BURST_WORDS = 26,
  parameter int unsigned BURST_COUNT = 8,
  parameter int unsigned POST_INIT_WAIT_CYCLES = 20_000,
  parameter int unsigned POST_WRITE_TO_READ_GAP_CYCLES = 4,
  parameter int unsigned CLEAR_WORDS = 2_097_152
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_SDRC_INIT_DONE,
  input  logic        I_SDRC_BUSY_N,
  input  logic        I_SDRC_WRD_ACK,
  input  logic        I_SDRC_RD_VALID,
  input  logic [31:0] I_SDRC_RD_DATA,
  output logic        O_SDRC_WR_N,
  output logic        O_SDRC_RD_N,
  output logic [20:0] O_SDRC_ADDR,
  output logic [7:0]  O_SDRC_DATA_LEN,
  output logic [3:0]  O_SDRC_DQM,
  output logic [31:0] O_SDRC_WR_DATA,
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

`ifdef SIM
  import tb_log_pkg::*;
`endif

  localparam logic [7:0] EVT_INIT_DONE     = 8'h20;
  localparam logic [7:0] EVT_TEST_START    = 8'h21;
  localparam logic [7:0] EVT_TEST_PASS     = 8'h22;
  localparam logic [7:0] EVT_TEST_FAIL     = 8'h23;
  localparam logic [7:0] EVT_TEST_FAIL_CTX = 8'h24;
  localparam logic [7:0] EVT_TEST_FAIL_WR  = 8'h25;
  localparam logic [7:0] EVT_TEST_FAIL_RD  = 8'h26;

  localparam logic [7:0] FAIL_REASON_NONE     = 8'h00;
  localparam logic [7:0] FAIL_REASON_TIMEOUT  = 8'h01;
  localparam logic [7:0] FAIL_REASON_MISMATCH = 8'h03;
  localparam int unsigned RETRY_LIMIT         = 3;

  localparam logic [1:0]  BANK_ADDR           = 2'd2;
  localparam logic [10:0] ROW_ADDR            = 11'd2;
  localparam logic [7:0]  COL_START           = 8'd5;
  localparam int unsigned DATA_LEN            = BURST_WORDS - 1;
  localparam int unsigned LAST_BASE_IDX       = (BURST_COUNT - 1) * BURST_WORDS;
  localparam int unsigned WORD_CNT_W          = $clog2(BURST_WORDS + 1);
  localparam int unsigned GAP_CNT_W           = (POST_WRITE_TO_READ_GAP_CYCLES <= 1) ? 1 : $clog2(POST_WRITE_TO_READ_GAP_CYCLES + 1);
  localparam int unsigned POST_INIT_WAIT_W    = (POST_INIT_WAIT_CYCLES <= 1) ? 1 : $clog2(POST_INIT_WAIT_CYCLES + 1);
  localparam int unsigned READ_TIMEOUT_CYCLES = BURST_WORDS + 16;
  localparam int unsigned FAIL_REPLAY_CYCLES  = 24_000_000;
  localparam int unsigned FAIL_REPLAY_CNT_W   = $clog2(FAIL_REPLAY_CYCLES + 1);

  typedef enum logic [3:0] {
    IDLE,
    WRITE_WAIT,
    WRITE_REQ,
    WRITE_RUN,
    READ_WAIT,
    READ_REQ,
    READ_RUN,
    RETRY_WAIT,
    RETRY_REQ,
    RETRY_RUN,
    CLEAR_WAIT,
    CLEAR_REQ,
    CLEAR_RUN,
    PASS,
    FAIL
  } st_state_e;

  st_state_e st_state;
  st_state_e st_nextstate;

  logic        r_init_logged;
  logic [POST_INIT_WAIT_W-1:0] r_post_init_wait_cnt;
  logic [7:0]  r_burst_base_idx;
  logic [7:0]  r_cycle_cnt;
  logic [WORD_CNT_W-1:0] r_write_word_count;
  logic [WORD_CNT_W-1:0] r_read_word_count;
  logic [31:0] r_write_burst_seed;
  logic [31:0] r_expected_rd_data;
  logic [31:0] r_next_wr_data_seed;
  logic [7:0]  r_rd_seen_words;
  logic [21:0] r_clear_word_idx;
  logic [GAP_CNT_W-1:0] r_post_write_gap_cnt;
  logic        r_busy_seen_low;
  logic        r_wrd_ack_seen;
  logic [7:0]  r_clear_words_sent;
  logic [31:0] r_read_burst_seed;
  logic [4:0]  r_write_word_index;

  logic [31:0] r_last_read_data;
  logic [31:0] r_last_status;
  logic [7:0]  r_fail_reason;
  logic [31:0] r_fail_addr;
  logic [31:0] r_fail_expected;
  logic [31:0] r_fail_actual;
  logic [31:0] r_retry_data1;
  logic [31:0] r_retry_data2;
  logic        r_retry_valid;
  logic        r_retry_recovered;
  logic        r_retry_exhausted;
  logic [2:0]  r_retry_count;
  logic [2:0]  r_retry_total_attempts;
  logic [20:0] r_retry_addr;
  logic [31:0] r_retry_expected;

  logic [31:0] r_fail_arg0;
  logic [31:0] r_fail_arg1;
  logic [31:0] r_fail_arg2;
  logic [31:0] r_fail_ctx_arg0;
  logic [31:0] r_fail_ctx_arg1;
  logic [31:0] r_fail_ctx_arg2;
  logic [31:0] r_fail_wr_arg0;
  logic [31:0] r_fail_wr_arg1;
  logic [31:0] r_fail_wr_arg2;
  logic [31:0] r_fail_rd_arg0;
  logic [31:0] r_fail_rd_arg1;
  logic [31:0] r_fail_rd_arg2;
  logic [FAIL_REPLAY_CNT_W-1:0] r_fail_replay_cnt;
  logic        r_fail_ctx_pending;
  logic        r_fail_wr_pending;
  logic        r_fail_rd_pending;
  logic [1:0]  r_fail_replay_sel;

  logic        s_start_test;
  logic [20:0] s_curr_addr;
  logic [20:0] s_clear_addr;
  logic [20:0] s_active_addr;
  logic [7:0]  s_clear_data_len;
  logic [7:0]  s_active_data_len;
  logic [31:0] s_active_wr_data;
  logic [31:0] s_active_expected;
  logic        s_write_words_done;
  logic        s_read_words_done;
  logic        s_clear_words_done;
  logic        s_retry_state;
  logic        s_clear_state;
  logic        s_next_after_retry_is_clear;
  logic [31:0] s_fail_word_addr;
  integer      s_clear_remaining_words;
  integer      s_clear_words_this_burst;
  logic        s_clear_last_burst;
  logic        s_write_complete;
  logic        s_read_complete;
  logic        s_clear_complete;
  logic        s_read_mismatch;
  logic        s_read_timeout;
  logic        s_retry_match;
  logic        s_retry_mismatch;
  logic        s_retry_timeout;

  assign s_curr_addr = {BANK_ADDR, ROW_ADDR, (COL_START + r_burst_base_idx)};
  assign s_clear_addr = r_clear_word_idx[20:0];
  assign s_retry_state = (st_state == RETRY_WAIT) || (st_state == RETRY_REQ) || (st_state == RETRY_RUN);
  assign s_clear_state = (st_state == CLEAR_WAIT) || (st_state == CLEAR_REQ) || (st_state == CLEAR_RUN);
  assign s_start_test = r_init_logged &&
                        (r_post_init_wait_cnt == POST_INIT_WAIT_CYCLES - 1) &&
                        I_SDRC_BUSY_N;
  assign s_write_words_done = (r_write_word_count >= BURST_WORDS);
  assign s_read_words_done  = (r_read_word_count >= BURST_WORDS);
  assign s_next_after_retry_is_clear = (r_burst_base_idx == LAST_BASE_IDX);
  assign s_fail_word_addr = {11'h000, (s_curr_addr + r_rd_seen_words)};

  always_comb begin
    s_clear_remaining_words = 0;
    if (CLEAR_WORDS > r_clear_word_idx) begin
      s_clear_remaining_words = CLEAR_WORDS - r_clear_word_idx;
    end

    if (s_clear_remaining_words >= BURST_WORDS) begin
      s_clear_words_this_burst = BURST_WORDS;
    end else begin
      s_clear_words_this_burst = s_clear_remaining_words;
    end
  end

  assign s_clear_data_len = (s_clear_words_this_burst == 0) ? 8'h00 :
                            (s_clear_words_this_burst[7:0] - 1'b1);
  assign s_clear_last_burst = (s_clear_words_this_burst != 0) &&
                              ((r_clear_word_idx + s_clear_words_this_burst) >= CLEAR_WORDS);
  assign s_active_addr = s_retry_state ? r_retry_addr :
                         (s_clear_state ? s_clear_addr : s_curr_addr);
  assign s_active_data_len = s_retry_state ? 8'h00 :
                             (s_clear_state ? s_clear_data_len : DATA_LEN[7:0]);
  assign s_active_wr_data = s_clear_state ? 32'h0000_0000 :
                            (r_write_burst_seed + {{27{1'b0}}, r_write_word_index});
  assign s_active_expected = s_retry_state ? r_retry_expected : r_expected_rd_data;

  assign s_write_complete = (st_state == WRITE_RUN) &&
                            (r_cycle_cnt >= DATA_LEN) &&
                            r_busy_seen_low &&
                            r_wrd_ack_seen &&
                            I_SDRC_BUSY_N;
  assign s_read_complete = (st_state == READ_RUN) &&
                           s_read_words_done &&
                           r_busy_seen_low &&
                           I_SDRC_BUSY_N;
  assign s_clear_words_done = (r_clear_words_sent >= (s_clear_data_len + 1'b1)) &&
                              (s_clear_words_this_burst != 0);
  assign s_clear_complete = (st_state == CLEAR_RUN) &&
                            (r_cycle_cnt >= s_clear_data_len) &&
                            r_busy_seen_low &&
                            r_wrd_ack_seen &&
                            I_SDRC_BUSY_N;
  assign s_read_mismatch = (st_state == READ_RUN) &&
                           I_SDRC_RD_VALID &&
                           (I_SDRC_RD_DATA != r_expected_rd_data);
  assign s_read_timeout = (st_state == READ_RUN) &&
                          !s_read_words_done &&
                          (r_cycle_cnt >= READ_TIMEOUT_CYCLES);
  assign s_retry_match = (st_state == RETRY_RUN) &&
                         I_SDRC_RD_VALID &&
                         (I_SDRC_RD_DATA == r_retry_expected);
  assign s_retry_mismatch = (st_state == RETRY_RUN) &&
                            I_SDRC_RD_VALID &&
                            (I_SDRC_RD_DATA != r_retry_expected);
  assign s_retry_timeout = (st_state == RETRY_RUN) &&
                           !I_SDRC_RD_VALID &&
                           (r_cycle_cnt >= READ_TIMEOUT_CYCLES);

  assign O_SDRC_ADDR      = s_active_addr;
  assign O_SDRC_DATA_LEN  = s_active_data_len;
  assign O_SDRC_DQM       = 4'h0;
  assign O_SDRC_WR_DATA   = s_active_wr_data;
  assign O_SDRC_WR_N      = (((st_state == WRITE_REQ) || (st_state == CLEAR_REQ)) && I_SDRC_BUSY_N) ? 1'b0 : 1'b1;
  assign O_SDRC_RD_N      = (((st_state == READ_REQ) || (st_state == RETRY_REQ)) && I_SDRC_BUSY_N) ? 1'b0 : 1'b1;

  assign O_TEST_ACTIVE = !(st_state inside {IDLE, PASS, FAIL});
  assign O_TEST_PASS   = (st_state == PASS);
  assign O_TEST_FAIL   = (st_state == FAIL);

  assign O_DBG_STATE         = {4'h0, st_state};
  assign O_DBG_FAIL_REASON   = r_fail_reason;
  assign O_DBG_CURRENT_ADDR  = s_active_addr;
  assign O_DBG_EXPECTED_WORD = s_active_expected;
  assign O_DBG_LAST_READ_DATA = r_last_read_data;
  assign O_DBG_LAST_STATUS   = r_last_status;
  assign O_DBG_FAIL_ADDR     = r_fail_addr;
  assign O_DBG_FAIL_EXPECTED = r_fail_expected;
  assign O_DBG_FAIL_ACTUAL   = r_fail_actual;
  assign O_DBG_RETRY_DATA1   = r_retry_data1;
  assign O_DBG_RETRY_DATA2   = r_retry_data2;

  always_comb begin
    O_DBG_MEM_SUMMARY = 32'h0000_0000;
    O_DBG_MEM_SUMMARY[31:24] = r_burst_base_idx;
    O_DBG_MEM_SUMMARY[23:16] = r_rd_seen_words;
    O_DBG_MEM_SUMMARY[15:8]  = {{(8-WORD_CNT_W){1'b0}}, r_write_word_count};
    O_DBG_MEM_SUMMARY[7:0]   = r_cycle_cnt;
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
    O_DBG_CTRL_SUMMARY[31:28] = st_state;
    O_DBG_CTRL_SUMMARY[27]    = !O_SDRC_WR_N;
    O_DBG_CTRL_SUMMARY[26]    = !O_SDRC_RD_N;
    O_DBG_CTRL_SUMMARY[25]    = I_SDRC_BUSY_N;
    O_DBG_CTRL_SUMMARY[24]    = I_SDRC_RD_VALID;
    O_DBG_CTRL_SUMMARY[23]    = I_SDRC_WRD_ACK;
    O_DBG_CTRL_SUMMARY[22]    = I_SDRC_INIT_DONE;
    O_DBG_CTRL_SUMMARY[21]    = s_retry_state;
    O_DBG_CTRL_SUMMARY[20]    = r_retry_valid;
    O_DBG_CTRL_SUMMARY[19]    = r_retry_recovered;
    O_DBG_CTRL_SUMMARY[18]    = r_retry_exhausted;
    O_DBG_CTRL_SUMMARY[17:16] = r_retry_count[1:0];
    O_DBG_CTRL_SUMMARY[15:8]  = {{(8-WORD_CNT_W){1'b0}}, r_read_word_count};
    O_DBG_CTRL_SUMMARY[7:0]   = {{(8-WORD_CNT_W){1'b0}}, r_write_word_count};
  end

  assign O_DBG_CTRL_DETAIL = r_fail_ctx_arg2;

  // Decides the next state based on current transfer progress and retry outcome.
  always_comb begin
    st_nextstate = st_state;

    case (st_state)
      IDLE: begin
        if (s_start_test) begin
          st_nextstate = WRITE_WAIT;
        end
      end

      WRITE_WAIT: begin
        if (I_SDRC_BUSY_N) begin
          st_nextstate = WRITE_REQ;
        end
      end

      WRITE_REQ: begin
        if (I_SDRC_BUSY_N) begin
          st_nextstate = WRITE_RUN;
        end
      end

      WRITE_RUN: begin
        if (s_write_complete) begin
          st_nextstate = READ_WAIT;
        end
      end

      READ_WAIT: begin
        if (I_SDRC_BUSY_N && (r_post_write_gap_cnt == 0)) begin
          st_nextstate = READ_REQ;
        end
      end

      READ_REQ: begin
        if (I_SDRC_BUSY_N) begin
          st_nextstate = READ_RUN;
        end
      end

      READ_RUN: begin
        if (s_read_mismatch) begin
          if (r_retry_count < RETRY_LIMIT) begin
            st_nextstate = RETRY_WAIT;
          end else begin
            st_nextstate = FAIL;
          end
        end else if (s_read_complete) begin
          if (r_burst_base_idx == LAST_BASE_IDX) begin
            st_nextstate = CLEAR_WAIT;
          end else begin
            st_nextstate = WRITE_WAIT;
          end
        end else if (s_read_timeout) begin
          st_nextstate = FAIL;
        end
      end

      RETRY_WAIT: begin
        if (I_SDRC_BUSY_N) begin
          st_nextstate = RETRY_REQ;
        end
      end

      RETRY_REQ: begin
        if (I_SDRC_BUSY_N) begin
          st_nextstate = RETRY_RUN;
        end
      end

      RETRY_RUN: begin
        if (s_retry_match) begin
          if (s_next_after_retry_is_clear) begin
            st_nextstate = CLEAR_WAIT;
          end else begin
            st_nextstate = WRITE_WAIT;
          end
        end else if (s_retry_mismatch) begin
          if (r_retry_count < RETRY_LIMIT) begin
            st_nextstate = RETRY_WAIT;
          end else begin
            st_nextstate = FAIL;
          end
        end else if (s_retry_timeout) begin
          st_nextstate = FAIL;
        end
      end

      CLEAR_WAIT: begin
        if (I_SDRC_BUSY_N) begin
          st_nextstate = CLEAR_REQ;
        end
      end

      CLEAR_REQ: begin
        if (I_SDRC_BUSY_N) begin
          st_nextstate = CLEAR_RUN;
        end
      end

      CLEAR_RUN: begin
        if (s_clear_complete) begin
          if (s_clear_last_burst) begin
            st_nextstate = PASS;
          end else begin
            st_nextstate = CLEAR_WAIT;
          end
        end
      end

      PASS: begin
        st_nextstate = PASS;
      end

      FAIL: begin
        st_nextstate = FAIL;
      end

      default: begin
        st_nextstate = IDLE;
      end
    endcase
  end

  // Holds the FSM state.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state <= IDLE;
    end else begin
      st_state <= st_nextstate;
    end
  end

  // Tracks initialization completion and the vendor-recommended post-init quiet period.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_init_logged        <= 1'b0;
      r_post_init_wait_cnt <= '0;
    end else if (!r_init_logged && I_SDRC_INIT_DONE) begin
      r_init_logged        <= 1'b1;
      r_post_init_wait_cnt <= '0;
    end else if (r_init_logged && (r_post_init_wait_cnt != POST_INIT_WAIT_CYCLES - 1)) begin
      r_post_init_wait_cnt <= r_post_init_wait_cnt + 1'b1;
    end
  end

  // Tracks transfer counters, retry bookkeeping, and debug snapshots.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_burst_base_idx     <= '0;
      r_cycle_cnt          <= '0;
      r_write_word_count   <= '0;
      r_read_word_count    <= '0;
      r_rd_seen_words      <= '0;
      r_clear_word_idx     <= '0;
      r_post_write_gap_cnt <= '0;
      r_busy_seen_low      <= 1'b0;
      r_wrd_ack_seen       <= 1'b0;
      r_clear_words_sent   <= '0;
      r_read_burst_seed    <= 32'h0000_0000;
      r_write_word_index   <= '0;
      r_last_read_data     <= 32'h0000_0000;
      r_last_status        <= 32'h0000_0000;
      r_fail_reason        <= FAIL_REASON_NONE;
      r_fail_addr          <= 32'h0000_0000;
      r_fail_expected      <= 32'h0000_0000;
      r_fail_actual        <= 32'h0000_0000;
      r_retry_data1        <= 32'h0000_0000;
      r_retry_data2        <= 32'h0000_0000;
      r_retry_valid        <= 1'b0;
      r_retry_recovered    <= 1'b0;
      r_retry_exhausted    <= 1'b0;
      r_retry_count        <= '0;
      r_retry_total_attempts <= '0;
      r_retry_addr         <= '0;
      r_retry_expected     <= 32'h0000_0000;
      r_fail_arg0          <= 32'h0000_0000;
      r_fail_arg1          <= 32'h0000_0000;
      r_fail_arg2          <= 32'h0000_0000;
      r_fail_ctx_arg0      <= 32'h0000_0000;
      r_fail_ctx_arg1      <= 32'h0000_0000;
      r_fail_ctx_arg2      <= 32'h0000_0000;
      r_fail_wr_arg0       <= 32'h0000_0000;
      r_fail_wr_arg1       <= 32'h0000_0000;
      r_fail_wr_arg2       <= 32'h0000_0000;
      r_fail_rd_arg0       <= 32'h0000_0000;
      r_fail_rd_arg1       <= 32'h0000_0000;
      r_fail_rd_arg2       <= 32'h0000_0000;
      r_fail_replay_cnt    <= '0;
      r_fail_ctx_pending   <= 1'b0;
      r_fail_wr_pending    <= 1'b0;
      r_fail_rd_pending    <= 1'b0;
      r_fail_replay_sel    <= 2'd0;
    end else begin
      if (st_state == FAIL) begin
        if (r_fail_ctx_pending) begin
          r_fail_ctx_pending <= 1'b0;
        end else if (r_fail_wr_pending) begin
          r_fail_wr_pending <= 1'b0;
        end else if (r_fail_rd_pending) begin
          r_fail_rd_pending <= 1'b0;
        end

        if (r_fail_replay_cnt < FAIL_REPLAY_CYCLES - 1) begin
          r_fail_replay_cnt <= r_fail_replay_cnt + 1'b1;
        end else begin
          r_fail_replay_cnt <= '0;
          r_fail_replay_sel <= r_fail_replay_sel + 1'b1;
        end
      end else begin
        r_fail_replay_cnt <= '0;
        r_fail_replay_sel <= 2'd0;
      end

      case (st_state)
        IDLE: begin
          if (st_nextstate == WRITE_WAIT) begin
            r_burst_base_idx       <= '0;
            r_cycle_cnt            <= '0;
            r_write_word_count     <= '0;
            r_read_word_count      <= '0;
            r_rd_seen_words        <= '0;
            r_clear_word_idx       <= '0;
            r_post_write_gap_cnt   <= '0;
            r_busy_seen_low        <= 1'b0;
            r_wrd_ack_seen         <= 1'b0;
            r_clear_words_sent     <= '0;
            r_read_burst_seed      <= 32'h0000_0000;
            r_write_word_index     <= '0;
            r_last_read_data       <= 32'h0000_0000;
            r_last_status          <= 32'h0000_0000;
            r_fail_reason          <= FAIL_REASON_NONE;
            r_fail_addr            <= 32'h0000_0000;
            r_fail_expected        <= 32'h0000_0000;
            r_fail_actual          <= 32'h0000_0000;
            r_retry_data1          <= 32'h0000_0000;
            r_retry_data2          <= 32'h0000_0000;
            r_retry_valid          <= 1'b0;
            r_retry_recovered      <= 1'b0;
            r_retry_exhausted      <= 1'b0;
            r_retry_count          <= '0;
            r_retry_total_attempts <= '0;
            r_retry_addr           <= '0;
            r_retry_expected       <= 32'h0000_0000;
            r_fail_arg0            <= 32'h0000_0000;
            r_fail_arg1            <= 32'h0000_0000;
            r_fail_arg2            <= 32'h0000_0000;
            r_fail_ctx_arg0        <= 32'h0000_0000;
            r_fail_ctx_arg1        <= 32'h0000_0000;
            r_fail_ctx_arg2        <= 32'h0000_0000;
            r_fail_wr_arg0         <= 32'h0000_0000;
            r_fail_wr_arg1         <= 32'h0000_0000;
            r_fail_wr_arg2         <= 32'h0000_0000;
            r_fail_rd_arg0         <= 32'h0000_0000;
            r_fail_rd_arg1         <= 32'h0000_0000;
            r_fail_rd_arg2         <= 32'h0000_0000;
          end
        end

        WRITE_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt          <= '0;
            r_write_word_count   <= '0;
            r_read_word_count    <= '0;
            r_rd_seen_words      <= '0;
            r_busy_seen_low      <= 1'b0;
            r_wrd_ack_seen       <= 1'b0;
            r_post_write_gap_cnt <= '0;
            r_write_word_index   <= '0;
          end
        end

        WRITE_REQ: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt        <= '0;
            r_write_word_count <= 8'd1;
            r_write_word_index <= (BURST_WORDS > 1) ? 5'd1 : 5'd0;
            r_busy_seen_low    <= 1'b0;
            r_wrd_ack_seen     <= 1'b0;
          end
        end

        WRITE_RUN: begin
          r_cycle_cnt <= r_cycle_cnt + 1'b1;
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end
          if (I_SDRC_WRD_ACK) begin
            r_wrd_ack_seen <= 1'b1;
          end
          if (r_write_word_count < BURST_WORDS) begin
            r_write_word_count <= r_write_word_count + 1'b1;
          end
          if (r_cycle_cnt < (BURST_WORDS - 2)) begin
            r_write_word_index <= r_write_word_index + 1'b1;
          end
          if (r_burst_base_idx == 0) begin
            case (r_write_word_index)
              5'd22: r_fail_wr_arg0 <= s_active_wr_data;
              5'd23: r_fail_wr_arg1 <= s_active_wr_data;
              5'd24: r_fail_wr_arg2 <= s_active_wr_data;
              default: begin end
            endcase
          end
          if (s_write_complete) begin
            r_post_write_gap_cnt <= POST_WRITE_TO_READ_GAP_CYCLES[GAP_CNT_W-1:0];
          end
        end

        READ_WAIT: begin
          if (r_post_write_gap_cnt != 0) begin
            r_post_write_gap_cnt <= r_post_write_gap_cnt - 1'b1;
          end
          if (I_SDRC_BUSY_N && (r_post_write_gap_cnt == 0)) begin
            r_cycle_cnt       <= '0;
            r_read_word_count <= '0;
            r_rd_seen_words   <= '0;
            r_busy_seen_low   <= 1'b0;
            r_read_burst_seed <= r_expected_rd_data;
          end
        end

        READ_REQ: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt       <= '0;
            r_read_word_count <= '0;
            r_rd_seen_words   <= '0;
            r_busy_seen_low   <= 1'b0;
          end
        end

        READ_RUN: begin
          r_cycle_cnt <= r_cycle_cnt + 1'b1;
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end
          if (I_SDRC_RD_VALID) begin
            r_last_read_data <= I_SDRC_RD_DATA;
            r_rd_seen_words  <= r_rd_seen_words + 1'b1;
            if (r_read_word_count < BURST_WORDS) begin
              r_read_word_count <= r_read_word_count + 1'b1;
            end
            if (r_burst_base_idx == 0) begin
              case (r_rd_seen_words)
                8'd22: r_fail_rd_arg0 <= I_SDRC_RD_DATA;
                8'd23: r_fail_rd_arg1 <= I_SDRC_RD_DATA;
                8'd24: r_fail_rd_arg2 <= I_SDRC_RD_DATA;
                default: begin end
              endcase
            end
          end

          if (s_read_complete) begin
            if (r_burst_base_idx != LAST_BASE_IDX) begin
              r_burst_base_idx <= r_burst_base_idx + 8'(BURST_WORDS);
            end
          end

          if (s_read_mismatch) begin
            r_last_status        <= {FAIL_REASON_MISMATCH, r_rd_seen_words, r_cycle_cnt, 1'b0, I_SDRC_BUSY_N, I_SDRC_RD_VALID, I_SDRC_WRD_ACK, I_SDRC_INIT_DONE, r_retry_count[2:0]};
            r_fail_reason        <= FAIL_REASON_MISMATCH;
            r_fail_addr          <= s_fail_word_addr;
            r_fail_expected      <= r_expected_rd_data;
            r_fail_actual        <= I_SDRC_RD_DATA;
            r_retry_valid        <= 1'b1;
            r_retry_recovered    <= 1'b0;
            r_retry_exhausted    <= 1'b0;
            r_retry_addr         <= s_fail_word_addr[20:0];
            r_retry_expected     <= r_expected_rd_data;
            r_retry_total_attempts <= 3'd1;
            r_fail_arg0          <= s_fail_word_addr;
            r_fail_arg1          <= r_expected_rd_data;
            r_fail_arg2          <= I_SDRC_RD_DATA;
            r_fail_ctx_arg0      <= {24'h0, r_burst_base_idx};
            r_fail_ctx_arg1      <= {11'h000, s_curr_addr};
            r_fail_ctx_arg2      <= r_read_burst_seed;
            if (r_retry_count < RETRY_LIMIT) begin
              r_retry_count          <= r_retry_count + 1'b1;
              r_retry_total_attempts <= r_retry_count + 3'd2;
            end else begin
              r_retry_exhausted <= 1'b1;
              r_fail_ctx_pending <= 1'b1;
              r_fail_wr_pending  <= 1'b1;
              r_fail_rd_pending  <= 1'b1;
            end
          end else if (s_read_timeout) begin
            r_last_status        <= {FAIL_REASON_TIMEOUT, r_rd_seen_words, r_cycle_cnt, 1'b0, I_SDRC_BUSY_N, I_SDRC_RD_VALID, I_SDRC_WRD_ACK, I_SDRC_INIT_DONE, 3'b000};
            r_fail_reason        <= FAIL_REASON_TIMEOUT;
            r_fail_addr          <= {11'h000, s_curr_addr};
            r_fail_expected      <= r_expected_rd_data;
            r_fail_actual        <= 32'hFFFF_FF01;
            r_fail_arg0          <= {11'h000, s_curr_addr};
            r_fail_arg1          <= r_expected_rd_data;
            r_fail_arg2          <= 32'hFFFF_FF01;
            r_fail_ctx_arg0      <= {24'h0, r_burst_base_idx};
            r_fail_ctx_arg1      <= {11'h000, s_curr_addr};
            r_fail_ctx_arg2      <= r_read_burst_seed;
            r_fail_ctx_pending   <= 1'b1;
            r_fail_wr_pending    <= 1'b1;
            r_fail_rd_pending    <= 1'b1;
            r_retry_exhausted    <= 1'b0;
          end
        end

        RETRY_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt      <= '0;
            r_busy_seen_low  <= 1'b0;
          end
        end

        RETRY_REQ: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt      <= '0;
            r_busy_seen_low  <= 1'b0;
          end
        end

        RETRY_RUN: begin
          r_cycle_cnt <= r_cycle_cnt + 1'b1;
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end
          if (I_SDRC_RD_VALID) begin
            r_last_read_data <= I_SDRC_RD_DATA;
            r_last_status    <= {FAIL_REASON_MISMATCH, 8'h00, r_cycle_cnt, 1'b1, I_SDRC_BUSY_N, I_SDRC_RD_VALID, I_SDRC_WRD_ACK, I_SDRC_INIT_DONE, r_retry_count[2:0]};
            case (r_retry_count)
              3'd1: r_retry_data1 <= I_SDRC_RD_DATA;
              3'd2: r_retry_data2 <= I_SDRC_RD_DATA;
              default: begin end
            endcase

            if (s_retry_match) begin
              r_retry_recovered    <= 1'b1;
              r_retry_total_attempts <= r_retry_count + 3'd1;
              if (r_burst_base_idx != LAST_BASE_IDX) begin
                r_burst_base_idx <= r_burst_base_idx + 8'(BURST_WORDS);
              end
            end else if (r_retry_count < RETRY_LIMIT) begin
              r_retry_count          <= r_retry_count + 1'b1;
              r_retry_total_attempts <= r_retry_count + 3'd2;
            end else begin
              r_retry_exhausted      <= 1'b1;
              r_fail_reason          <= FAIL_REASON_MISMATCH;
              r_fail_actual          <= I_SDRC_RD_DATA;
              r_fail_arg0            <= {11'h000, r_retry_addr};
              r_fail_arg1            <= r_retry_expected;
              r_fail_arg2            <= I_SDRC_RD_DATA;
              r_fail_ctx_pending     <= 1'b1;
              r_fail_wr_pending      <= 1'b1;
              r_fail_rd_pending      <= 1'b1;
            end
          end else if (s_retry_timeout) begin
            r_last_status          <= {FAIL_REASON_TIMEOUT, 8'h00, r_cycle_cnt, 1'b1, I_SDRC_BUSY_N, I_SDRC_RD_VALID, I_SDRC_WRD_ACK, I_SDRC_INIT_DONE, r_retry_count[2:0]};
            r_fail_reason          <= FAIL_REASON_TIMEOUT;
            r_fail_actual          <= 32'hFFFF_FF01;
            r_fail_arg0            <= {11'h000, r_retry_addr};
            r_fail_arg1            <= r_retry_expected;
            r_fail_arg2            <= 32'hFFFF_FF01;
            r_fail_ctx_pending     <= 1'b1;
            r_fail_wr_pending      <= 1'b1;
            r_fail_rd_pending      <= 1'b1;
          end
        end

        CLEAR_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt        <= '0;
            r_clear_words_sent <= '0;
            r_write_word_index <= '0;
            r_busy_seen_low    <= 1'b0;
            r_wrd_ack_seen     <= 1'b0;
          end
        end

        CLEAR_REQ: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt        <= '0;
            r_clear_words_sent <= 8'd1;
            r_write_word_index <= '0;
            r_busy_seen_low    <= 1'b0;
            r_wrd_ack_seen     <= 1'b0;
          end
        end

        CLEAR_RUN: begin
          r_cycle_cnt <= r_cycle_cnt + 1'b1;
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end
          if (I_SDRC_WRD_ACK) begin
            r_wrd_ack_seen <= 1'b1;
          end
          if (r_clear_words_sent < (s_clear_data_len + 1'b1)) begin
            r_clear_words_sent <= r_clear_words_sent + 1'b1;
          end
          if (s_clear_complete) begin
            r_clear_word_idx   <= r_clear_word_idx + 22'(s_clear_words_this_burst);
            r_clear_words_sent <= '0;
          end
        end

        default: begin
        end
      endcase
    end
  end

  // Tracks write data seeds and the expected read sequence.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_write_burst_seed  <= 32'h0000_0000;
      r_expected_rd_data  <= 32'h0000_0000;
      r_next_wr_data_seed <= 32'h0000_0000;
    end else begin
      case (st_state)
        IDLE: begin
          if (st_nextstate == WRITE_WAIT) begin
            r_write_burst_seed  <= 32'h0000_0000;
            r_expected_rd_data  <= 32'h0000_0000;
            r_next_wr_data_seed <= 32'h0000_0000;
          end
        end

        WRITE_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            r_write_burst_seed <= r_next_wr_data_seed;
          end
        end

        WRITE_RUN: begin
          if (s_write_complete) begin
            r_expected_rd_data  <= r_write_burst_seed;
            r_next_wr_data_seed <= r_next_wr_data_seed + BURST_WORDS;
          end
        end

        READ_RUN: begin
          if (I_SDRC_RD_VALID && !s_read_mismatch) begin
            r_expected_rd_data <= r_expected_rd_data + 1'b1;
          end
        end

        CLEAR_WAIT,
        CLEAR_REQ,
        CLEAR_RUN: begin
          r_write_burst_seed <= 32'h0000_0000;
        end

        default: begin
        end
      endcase
    end
  end

  // Emits one-cycle event pulses for UART logging.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      O_EVT_VALID <= 1'b0;
      O_EVT_ID    <= 8'h00;
      O_EVT_ARG0  <= 32'h0000_0000;
      O_EVT_ARG1  <= 32'h0000_0000;
      O_EVT_ARG2  <= 32'h0000_0000;
    end else begin
      O_EVT_VALID <= 1'b0;

      if (!r_init_logged && I_SDRC_INIT_DONE) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_INIT_DONE;
        O_EVT_ARG0  <= 32'h0000_0000;
        O_EVT_ARG1  <= 32'h0000_0000;
        O_EVT_ARG2  <= 32'h0000_0000;
      end else if ((st_state == IDLE) && (st_nextstate == WRITE_WAIT)) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_START;
        O_EVT_ARG0  <= BURST_WORDS * BURST_COUNT;
        O_EVT_ARG1  <= BURST_COUNT;
        O_EVT_ARG2  <= CLEAR_WORDS;
      end else if ((st_nextstate == PASS) && (st_state == CLEAR_RUN)) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_PASS;
        O_EVT_ARG0  <= CLEAR_WORDS;
        O_EVT_ARG1  <= BURST_WORDS * BURST_COUNT;
        O_EVT_ARG2  <= 32'h0000_0000;
      end else if (((st_state == READ_RUN) && ((s_read_timeout) || (s_read_mismatch && (r_retry_count >= RETRY_LIMIT)))) ||
                   ((st_state == RETRY_RUN) && (s_retry_timeout || (s_retry_mismatch && (r_retry_count >= RETRY_LIMIT))))) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL;
        O_EVT_ARG0  <= r_fail_addr;
        O_EVT_ARG1  <= r_fail_expected;
        O_EVT_ARG2  <= r_fail_actual;
      end else if ((st_state == FAIL) && r_fail_ctx_pending) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL_CTX;
        O_EVT_ARG0  <= r_fail_ctx_arg0;
        O_EVT_ARG1  <= r_fail_ctx_arg1;
        O_EVT_ARG2  <= r_fail_ctx_arg2;
      end else if ((st_state == FAIL) && r_fail_wr_pending) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL_WR;
        O_EVT_ARG0  <= r_fail_wr_arg0;
        O_EVT_ARG1  <= r_fail_wr_arg1;
        O_EVT_ARG2  <= r_fail_wr_arg2;
      end else if ((st_state == FAIL) && r_fail_rd_pending) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL_RD;
        O_EVT_ARG0  <= r_fail_rd_arg0;
        O_EVT_ARG1  <= r_fail_rd_arg1;
        O_EVT_ARG2  <= r_fail_rd_arg2;
      end else if ((st_state == FAIL) && (r_fail_replay_cnt == FAIL_REPLAY_CYCLES - 1)) begin
        O_EVT_VALID <= 1'b1;
        case (r_fail_replay_sel)
          2'd0: begin
            O_EVT_ID    <= EVT_TEST_FAIL;
            O_EVT_ARG0  <= r_fail_arg0;
            O_EVT_ARG1  <= r_fail_arg1;
            O_EVT_ARG2  <= r_fail_arg2;
          end
          2'd1: begin
            O_EVT_ID    <= EVT_TEST_FAIL_CTX;
            O_EVT_ARG0  <= r_fail_ctx_arg0;
            O_EVT_ARG1  <= r_fail_ctx_arg1;
            O_EVT_ARG2  <= r_fail_ctx_arg2;
          end
          2'd2: begin
            O_EVT_ID    <= EVT_TEST_FAIL_WR;
            O_EVT_ARG0  <= r_fail_wr_arg0;
            O_EVT_ARG1  <= r_fail_wr_arg1;
            O_EVT_ARG2  <= r_fail_wr_arg2;
          end
          default: begin
            O_EVT_ID    <= EVT_TEST_FAIL_RD;
            O_EVT_ARG0  <= r_fail_rd_arg0;
            O_EVT_ARG1  <= r_fail_rd_arg1;
            O_EVT_ARG2  <= r_fail_rd_arg2;
          end
        endcase
      end
    end
  end

`ifdef SIM
  function automatic string state_name(
    input st_state_e state_value
  );
    case (state_value)
      IDLE:       state_name = "IDLE";
      WRITE_WAIT: state_name = "WRITE_WAIT";
      WRITE_REQ:  state_name = "WRITE_REQ";
      WRITE_RUN:  state_name = "WRITE_RUN";
      READ_WAIT:  state_name = "READ_WAIT";
      READ_REQ:   state_name = "READ_REQ";
      READ_RUN:   state_name = "READ_RUN";
      RETRY_WAIT: state_name = "RETRY_WAIT";
      RETRY_REQ:  state_name = "RETRY_REQ";
      RETRY_RUN:  state_name = "RETRY_RUN";
      CLEAR_WAIT: state_name = "CLEAR_WAIT";
      CLEAR_REQ:  state_name = "CLEAR_REQ";
      CLEAR_RUN:  state_name = "CLEAR_RUN";
      PASS:       state_name = "PASS";
      FAIL:       state_name = "FAIL";
      default:    state_name = "UNKNOWN";
    endcase
  endfunction

  logic [3:0] r_state_dbg_q;

  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_state_dbg_q <= IDLE;
    end else begin
      if (r_state_dbg_q != st_state) begin
        tb_log_pkg::log_debug(
          "SDRAM UIF",
          $sformatf(
            "state %s -> %s base=%0d clear=%0d cycle=%0d wr_cnt=%0d rd_cnt=%0d retry=%0d busy_n=%0b ack=%0b rd_valid=%0b",
            state_name(st_state_e'(r_state_dbg_q)),
            state_name(st_state),
            r_burst_base_idx,
            r_clear_word_idx,
            r_cycle_cnt,
            r_write_word_count,
            r_read_word_count,
            r_retry_count,
            I_SDRC_BUSY_N,
            I_SDRC_WRD_ACK,
            I_SDRC_RD_VALID
          )
        );
      end

      r_state_dbg_q <= st_state;
    end
  end
`endif

endmodule
