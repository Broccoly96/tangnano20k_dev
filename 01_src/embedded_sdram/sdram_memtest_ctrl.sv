`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_memtest_ctrl.sv
// Description  : Embedded SDRAM write/read/compare self-test controller.
//                The controller follows the SDRC user-interface timing:
//                - launch `wr_n` / `rd_n` as a one-cycle pulse
//                - present beat 0 in the same cycle as a write launch
//                - advance write data one beat per clock after launch
//                - stream exactly `data_len + 1` total beats per request
//                  including the launch beat
//                - wait for the expected `rd_valid` beat count on reads
//                - use `wrd_ack` as a progress marker while only using
//                  `busy_n` to decide when a new request may launch
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
  output logic [31:0] O_EVT_ARG2
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

  localparam logic [1:0]  BANK_ADDR           = 2'd2;
  localparam logic [10:0] ROW_ADDR            = 11'd2;
  localparam logic [7:0]  COL_START           = 8'd5;
  localparam int unsigned DATA_LEN            = BURST_WORDS - 1;
  localparam int unsigned LAST_BASE_IDX       = (BURST_COUNT - 1) * BURST_WORDS;
  localparam int unsigned WORD_CNT_W          = $clog2(BURST_WORDS + 1);
  localparam int unsigned GAP_CNT_W           = $clog2(POST_WRITE_TO_READ_GAP_CYCLES + 1);
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
    CLEAR_WAIT,
    CLEAR_REQ,
    CLEAR_RUN,
    PASS,
    FAIL
  } st_state_e;

  st_state_e st_state;

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
  logic [31:0] r_read_burst_seed;
  logic [4:0]  r_write_word_index;

  logic        s_start_test;
  logic [20:0] s_curr_addr;
  logic [20:0] s_clear_addr;
  logic [7:0]  s_clear_data_len;
  logic [7:0]  s_active_data_len;
  logic [31:0] s_active_wr_data;
  logic        s_write_words_done;
  logic        s_read_words_done;
  logic        s_clear_words_done;
  integer      s_clear_remaining_words;
  integer      s_clear_words_this_burst;
  logic        s_clear_last_burst;

  assign s_curr_addr         = {BANK_ADDR, ROW_ADDR, (COL_START + r_burst_base_idx)};
  assign s_clear_addr        = r_clear_word_idx[20:0];
  assign s_start_test        = r_init_logged &&
                               (r_post_init_wait_cnt == POST_INIT_WAIT_CYCLES - 1) &&
                               I_SDRC_BUSY_N;
  assign s_write_words_done  = (r_write_word_count >= BURST_WORDS);
  assign s_read_words_done   = (r_read_word_count >= BURST_WORDS);
  assign s_clear_words_done  = (r_clear_words_sent >= (s_clear_data_len + 1'b1)) &&
                               (s_clear_words_this_burst != 0);

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
                            s_clear_words_this_burst[7:0] - 1'b1;
  assign s_clear_last_burst = (s_clear_words_this_burst != 0) &&
                              ((r_clear_word_idx + s_clear_words_this_burst) >= CLEAR_WORDS);
  assign s_active_data_len = ((st_state == CLEAR_WAIT) || (st_state == CLEAR_RUN)) ?
                             s_clear_data_len : DATA_LEN[7:0];
  assign s_active_wr_data  = ((st_state == CLEAR_WAIT) || (st_state == CLEAR_RUN)) ?
                             32'h0000_0000 :
                             (r_write_burst_seed + {{27{1'b0}}, r_write_word_index});

  assign O_SDRC_ADDR      = ((st_state == CLEAR_WAIT) || (st_state == CLEAR_REQ) || (st_state == CLEAR_RUN)) ?
                            s_clear_addr : s_curr_addr;
  assign O_SDRC_DATA_LEN  = s_active_data_len;
  assign O_SDRC_DQM       = 4'h0;
  assign O_SDRC_WR_DATA   = s_active_wr_data;
  assign O_SDRC_WR_N      = (((st_state == WRITE_REQ) || (st_state == CLEAR_REQ)) &&
                             I_SDRC_BUSY_N) ? 1'b0 : 1'b1;
  assign O_SDRC_RD_N      = (st_state == READ_REQ && I_SDRC_BUSY_N) ? 1'b0 : 1'b1;

  // Holds the main self-test state and sticky pass/fail status.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state      <= IDLE;
      O_TEST_ACTIVE <= 1'b0;
      O_TEST_PASS   <= 1'b0;
      O_TEST_FAIL   <= 1'b0;
    end else begin
      case (st_state)
        IDLE: begin
          if (s_start_test) begin
            st_state      <= WRITE_WAIT;
            O_TEST_ACTIVE <= 1'b1;
            O_TEST_PASS   <= 1'b0;
            O_TEST_FAIL   <= 1'b0;
          end
        end

        WRITE_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            st_state <= WRITE_REQ;
          end
        end

        WRITE_REQ: begin
          if (I_SDRC_BUSY_N) begin
            st_state <= WRITE_RUN;
          end
        end

        WRITE_RUN: begin
          if ((r_cycle_cnt >= DATA_LEN) && r_busy_seen_low &&
              r_wrd_ack_seen && I_SDRC_BUSY_N) begin
            st_state <= READ_WAIT;
          end
        end

        READ_WAIT: begin
          if (I_SDRC_BUSY_N && (r_post_write_gap_cnt == 0)) begin
            st_state <= READ_REQ;
          end
        end

        READ_REQ: begin
          if (I_SDRC_BUSY_N) begin
            st_state <= READ_RUN;
          end
        end

        READ_RUN: begin
          if (I_SDRC_RD_VALID && (I_SDRC_RD_DATA != r_expected_rd_data)) begin
            st_state      <= FAIL;
            O_TEST_ACTIVE <= 1'b0;
            O_TEST_FAIL   <= 1'b1;
          end else if (s_read_words_done && r_busy_seen_low && I_SDRC_BUSY_N) begin
            if (r_burst_base_idx == LAST_BASE_IDX) begin
              st_state <= CLEAR_WAIT;
            end else begin
              st_state <= WRITE_WAIT;
            end
          end else if (!s_read_words_done && (r_cycle_cnt >= READ_TIMEOUT_CYCLES)) begin
            st_state      <= FAIL;
            O_TEST_ACTIVE <= 1'b0;
            O_TEST_FAIL   <= 1'b1;
          end
        end

        CLEAR_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            st_state <= CLEAR_REQ;
          end
        end

        CLEAR_REQ: begin
          if (I_SDRC_BUSY_N) begin
            st_state <= CLEAR_RUN;
          end
        end

        CLEAR_RUN: begin
          if ((r_cycle_cnt >= s_clear_data_len) && r_busy_seen_low &&
              r_wrd_ack_seen && I_SDRC_BUSY_N) begin
            if (s_clear_last_burst) begin
              st_state      <= PASS;
              O_TEST_ACTIVE <= 1'b0;
              O_TEST_PASS   <= 1'b1;
            end else begin
              st_state <= CLEAR_WAIT;
            end
          end
        end

        PASS: begin
          st_state <= PASS;
        end

        FAIL: begin
          st_state <= FAIL;
        end

        default: begin
          st_state <= IDLE;
        end
      endcase
    end
  end

  // Tracks initialization completion and the post-init quiet period recommended
  // by the vendor example before the first user transaction starts.
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

  // Advances burst-local and burst-global counters.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_cycle_cnt        <= '0;
      r_write_word_count <= '0;
      r_read_word_count  <= '0;
      r_write_word_index <= '0;
      r_rd_seen_words    <= '0;
      r_burst_base_idx   <= '0;
      r_clear_word_idx   <= '0;
      r_post_write_gap_cnt <= '0;
      r_busy_seen_low    <= 1'b0;
      r_wrd_ack_seen     <= 1'b0;
      r_clear_words_sent <= '0;
      r_fail_arg0        <= 32'h0000_0000;
      r_fail_arg1        <= 32'h0000_0000;
      r_fail_arg2        <= 32'h0000_0000;
      r_fail_ctx_arg0    <= 32'h0000_0000;
      r_fail_ctx_arg1    <= 32'h0000_0000;
      r_fail_ctx_arg2    <= 32'h0000_0000;
      r_fail_wr_arg0     <= 32'h0000_0000;
      r_fail_wr_arg1     <= 32'h0000_0000;
      r_fail_wr_arg2     <= 32'h0000_0000;
      r_fail_rd_arg0     <= 32'h0000_0000;
      r_fail_rd_arg1     <= 32'h0000_0000;
      r_fail_rd_arg2     <= 32'h0000_0000;
      r_fail_replay_cnt  <= '0;
      r_fail_ctx_pending <= 1'b0;
      r_fail_wr_pending  <= 1'b0;
      r_fail_rd_pending  <= 1'b0;
      r_fail_replay_sel  <= 2'd0;
      r_read_burst_seed  <= 32'h0000_0000;
    end else begin
      case (st_state)
        IDLE: begin
          r_cycle_cnt        <= '0;
          r_write_word_count <= '0;
          r_read_word_count  <= '0;
          r_write_word_index <= '0;
          r_rd_seen_words    <= '0;
          r_burst_base_idx   <= '0;
          r_clear_word_idx   <= '0;
          r_post_write_gap_cnt <= '0;
          r_busy_seen_low    <= 1'b0;
          r_wrd_ack_seen     <= 1'b0;
          r_clear_words_sent <= '0;
          r_fail_replay_cnt  <= '0;
          r_fail_ctx_pending <= 1'b0;
          r_fail_wr_pending  <= 1'b0;
          r_fail_rd_pending  <= 1'b0;
          r_fail_replay_sel  <= 2'd0;
          r_read_burst_seed  <= 32'h0000_0000;
        end

        WRITE_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt        <= '0;
            r_write_word_count <= '0;
            r_read_word_count  <= '0;
            r_write_word_index <= '0;
            r_rd_seen_words    <= '0;
            r_post_write_gap_cnt <= '0;
            r_busy_seen_low    <= 1'b0;
            r_wrd_ack_seen     <= 1'b0;
          end
        end

        WRITE_REQ: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt        <= '0;
            r_write_word_count <= 8'd1;
            if (BURST_WORDS > 1) begin
              r_write_word_index <= 5'd1;
            end
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
          if ((r_cycle_cnt >= DATA_LEN) && r_busy_seen_low &&
              r_wrd_ack_seen && I_SDRC_BUSY_N) begin
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
            r_rd_seen_words   <= r_rd_seen_words + 1'b1;
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

          if (s_read_words_done && r_busy_seen_low && I_SDRC_BUSY_N) begin
            if (r_burst_base_idx != LAST_BASE_IDX) begin
              r_burst_base_idx <= r_burst_base_idx + 8'(BURST_WORDS);
            end
          end

          if (I_SDRC_RD_VALID && (I_SDRC_RD_DATA != r_expected_rd_data)) begin
            r_fail_arg0       <= {24'h0, r_rd_seen_words};
            r_fail_arg1       <= r_expected_rd_data;
            r_fail_arg2       <= I_SDRC_RD_DATA;
            r_fail_ctx_arg0   <= {24'h0, r_burst_base_idx};
            r_fail_ctx_arg1   <= {11'h0, s_curr_addr};
            r_fail_ctx_arg2   <= r_read_burst_seed;
            r_fail_replay_cnt <= '0;
            r_fail_ctx_pending <= 1'b1;
            r_fail_wr_pending  <= 1'b1;
            r_fail_rd_pending  <= 1'b1;
            r_fail_replay_sel  <= 2'd0;
          end else if (!s_read_words_done && (r_cycle_cnt >= READ_TIMEOUT_CYCLES)) begin
            r_fail_arg0       <= {24'h0, r_rd_seen_words};
            r_fail_arg1       <= r_expected_rd_data;
            r_fail_arg2       <= 32'hFFFF_FF01;
            r_fail_ctx_arg0   <= {24'h0, r_burst_base_idx};
            r_fail_ctx_arg1   <= {11'h0, s_curr_addr};
            r_fail_ctx_arg2   <= r_read_burst_seed;
            r_fail_replay_cnt <= '0;
            r_fail_ctx_pending <= 1'b1;
            r_fail_wr_pending  <= 1'b1;
            r_fail_rd_pending  <= 1'b1;
            r_fail_replay_sel  <= 2'd0;
          end
        end

        CLEAR_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt        <= '0;
            r_clear_words_sent <= '0;
            r_write_word_index <= '0;
            r_post_write_gap_cnt <= '0;
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
          if ((r_cycle_cnt >= s_clear_data_len) && r_busy_seen_low &&
              r_wrd_ack_seen && I_SDRC_BUSY_N) begin
            r_clear_word_idx <= r_clear_word_idx + 22'(s_clear_words_this_burst);
            r_clear_words_sent <= '0;
          end
        end

        FAIL: begin
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
        end

        default: begin
          r_write_word_count <= r_write_word_count;
          r_read_word_count  <= r_read_word_count;
          r_rd_seen_words    <= r_rd_seen_words;
        end
      endcase
    end
  end

  // Generates write data and the read-side expected sequence.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_write_burst_seed  <= 32'h0000_0000;
      r_expected_rd_data  <= 32'h0000_0000;
      r_next_wr_data_seed <= 32'h0000_0000;
    end else begin
      case (st_state)
        IDLE: begin
          r_write_burst_seed  <= 32'h0000_0000;
          r_expected_rd_data  <= 32'h0000_0000;
          r_next_wr_data_seed <= 32'h0000_0000;
        end

        WRITE_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            r_write_burst_seed <= r_next_wr_data_seed;
          end
        end

        WRITE_RUN: begin
          if ((r_cycle_cnt >= DATA_LEN) && r_busy_seen_low &&
              r_wrd_ack_seen && I_SDRC_BUSY_N) begin
            r_expected_rd_data  <= r_write_burst_seed;
            r_next_wr_data_seed <= r_next_wr_data_seed + BURST_WORDS;
          end
        end

        READ_RUN: begin
          if (I_SDRC_RD_VALID) begin
            r_expected_rd_data <= r_expected_rd_data + 1'b1;
          end
        end

        CLEAR_WAIT: begin
          r_write_burst_seed <= 32'h0000_0000;
        end

        CLEAR_REQ: begin
          r_write_burst_seed <= 32'h0000_0000;
        end

        CLEAR_RUN: begin
          r_write_burst_seed <= 32'h0000_0000;
        end

        default: begin
          r_write_burst_seed  <= r_write_burst_seed;
          r_expected_rd_data  <= r_expected_rd_data;
          r_next_wr_data_seed <= r_next_wr_data_seed;
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
      end else if (st_state == IDLE && s_start_test) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_START;
        O_EVT_ARG0  <= BURST_WORDS * BURST_COUNT;
        O_EVT_ARG1  <= BURST_COUNT;
        O_EVT_ARG2  <= CLEAR_WORDS;
      end else if (st_state == READ_RUN && I_SDRC_RD_VALID &&
                   (I_SDRC_RD_DATA != r_expected_rd_data)) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL;
        O_EVT_ARG0  <= {24'h0, r_rd_seen_words};
        O_EVT_ARG1  <= r_expected_rd_data;
        O_EVT_ARG2  <= I_SDRC_RD_DATA;
      end else if (st_state == READ_RUN && !s_read_words_done &&
                   (r_cycle_cnt >= READ_TIMEOUT_CYCLES)) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL;
        O_EVT_ARG0  <= {24'h0, r_rd_seen_words};
        O_EVT_ARG1  <= r_expected_rd_data;
        O_EVT_ARG2  <= 32'hFFFF_FF01;
      end else if (st_state == FAIL && r_fail_ctx_pending) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL_CTX;
        O_EVT_ARG0  <= r_fail_ctx_arg0;
        O_EVT_ARG1  <= r_fail_ctx_arg1;
        O_EVT_ARG2  <= r_fail_ctx_arg2;
      end else if (st_state == FAIL && r_fail_wr_pending) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL_WR;
        O_EVT_ARG0  <= r_fail_wr_arg0;
        O_EVT_ARG1  <= r_fail_wr_arg1;
        O_EVT_ARG2  <= r_fail_wr_arg2;
      end else if (st_state == FAIL && r_fail_rd_pending) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL_RD;
        O_EVT_ARG0  <= r_fail_rd_arg0;
        O_EVT_ARG1  <= r_fail_rd_arg1;
        O_EVT_ARG2  <= r_fail_rd_arg2;
      end else if (st_state == CLEAR_RUN &&
                   (r_cycle_cnt >= s_clear_data_len) &&
                   s_clear_last_burst && r_busy_seen_low &&
                   r_wrd_ack_seen && I_SDRC_BUSY_N) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_PASS;
        O_EVT_ARG0  <= CLEAR_WORDS;
        O_EVT_ARG1  <= BURST_WORDS * BURST_COUNT;
        O_EVT_ARG2  <= 32'h0000_0000;
      end else if (st_state == FAIL && (r_fail_replay_cnt == FAIL_REPLAY_CYCLES - 1)) begin
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
            "state %s -> %s base=%0d clear=%0d phase=%0d wr_cnt=%0d rd_cnt=%0d clr_cnt=%0d busy_n=%0b ack=%0b rd_valid=%0b",
            state_name(st_state_e'(r_state_dbg_q)),
            state_name(st_state),
            r_burst_base_idx,
            r_clear_word_idx,
            r_cycle_cnt,
            r_write_word_count,
            r_read_word_count,
            r_clear_words_sent,
            I_SDRC_BUSY_N,
            I_SDRC_WRD_ACK,
            I_SDRC_RD_VALID
          )
        );
      end

      if (!O_SDRC_WR_N) begin
        tb_log_pkg::log_debug(
          "SDRAM UIF",
          $sformatf(
            "write req addr=0x%05h len=%0d first_data=0x%08h",
            O_SDRC_ADDR,
            O_SDRC_DATA_LEN + 1,
            O_SDRC_WR_DATA
          )
        );
      end

      if (!O_SDRC_RD_N) begin
        tb_log_pkg::log_debug(
          "SDRAM UIF",
          $sformatf(
            "read req addr=0x%05h len=%0d",
            O_SDRC_ADDR,
            O_SDRC_DATA_LEN + 1
          )
        );
      end

      if (I_SDRC_WRD_ACK) begin
        tb_log_pkg::log_debug(
          "SDRAM UIF",
          $sformatf(
            "ack state=%s addr=0x%05h busy_n=%0b",
            state_name(st_state),
            O_SDRC_ADDR,
            I_SDRC_BUSY_N
          )
        );
      end

      if (I_SDRC_RD_VALID) begin
        tb_log_pkg::log_trace(
          "SDRAM UIF",
          $sformatf(
            "rd_valid word=%0d exp=0x%08h act=0x%08h",
            r_rd_seen_words,
            r_expected_rd_data,
            I_SDRC_RD_DATA
          )
        );
      end

      r_state_dbg_q <= st_state;
    end
  end
`endif

endmodule
