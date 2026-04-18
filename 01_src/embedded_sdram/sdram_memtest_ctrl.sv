`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_memtest_ctrl.sv
// Description  : SDRAM self-test sweep controller on the native 32-bit word
//                request interface.
//                - Waits for SDRAM initialization to complete.
//                - Writes the full target address range one word at a time.
//                - Reads the full target address range back one word at a time.
//                - Reports PASS only after the verify sweep finishes.
//////////////////////////////////////////////////////////////////////////////////

module sdram_memtest_ctrl #(
  parameter int unsigned CLK_HZ = 48_000_000,
  parameter int unsigned MEMTEST_BURST_WORDS = 256,
  parameter int unsigned MEMTEST_TOTAL_WORDS = 2_097_152,
  parameter int unsigned POST_INIT_WAIT_CYCLES = 20_000,
  parameter int unsigned POST_WRITE_TO_READ_GAP_CYCLES = 4,
  parameter bit          MEMTEST_USE_INCREMENT_PATTERN = 1'b0
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_INIT_DONE,

  output logic        O_REQ_VALID,
  input  logic        I_REQ_READY,
  output logic        O_REQ_IS_WRITE,
  output logic [20:0] O_REQ_ADDR,
  output logic [31:0] O_REQ_WR_DATA,
  output logic [3:0]  O_REQ_WR_BE,

  input  logic        I_RSP_VALID,
  output logic        O_RSP_READY,
  input  logic [31:0] I_RSP_RD_DATA,
  input  logic [31:0] I_RSP_STATUS,

  output logic        O_TEST_ACTIVE,
  output logic        O_TEST_PASS,
  output logic        O_TEST_FAIL,
  output logic        O_EVT_VALID,
  output logic [7:0]  O_EVT_ID,
  output logic [31:0] O_EVT_ARG0,
  output logic [31:0] O_EVT_ARG1,
  output logic [31:0] O_EVT_ARG2
);

  localparam logic [7:0] EVT_INIT_DONE     = 8'h20;
  localparam logic [7:0] EVT_TEST_START    = 8'h21;
  localparam logic [7:0] EVT_TEST_PASS     = 8'h22;
  localparam logic [7:0] EVT_TEST_FAIL     = 8'h23;
  localparam logic [7:0] EVT_TEST_FAIL_CTX = 8'h24;

  localparam int unsigned POST_INIT_WAIT_W =
    (POST_INIT_WAIT_CYCLES <= 1) ? 1 :
    $clog2(POST_INIT_WAIT_CYCLES + 1);
  localparam int unsigned GAP_CNT_W =
    (POST_WRITE_TO_READ_GAP_CYCLES <= 1) ? 1 :
    $clog2(POST_WRITE_TO_READ_GAP_CYCLES + 1);
  localparam int unsigned WORD_IDX_W =
    (MEMTEST_TOTAL_WORDS <= 1) ? 1 :
    $clog2(MEMTEST_TOTAL_WORDS + 1);
  localparam int unsigned FAIL_REPLAY_CYCLES =
    (CLK_HZ <= 1) ? 1 : CLK_HZ;
  localparam int unsigned FAIL_REPLAY_CNT_W =
    (FAIL_REPLAY_CYCLES <= 1) ? 1 :
    $clog2(FAIL_REPLAY_CYCLES + 1);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_WAIT_INIT,
    ST_POST_INIT_WAIT,
    ST_WRITE_REQ,
    ST_WRITE_WAIT,
    ST_READ_GAP,
    ST_READ_REQ,
    ST_READ_WAIT,
    ST_PASS,
    ST_FAIL
  } st_state_e;

  st_state_e st_state;

  logic r_init_logged;
  logic [POST_INIT_WAIT_W-1:0] r_post_init_wait_cnt;
  logic [GAP_CNT_W-1:0]        r_read_gap_cnt;
  logic [WORD_IDX_W-1:0]       r_word_idx;
  logic [31:0]                 r_fail_arg0;
  logic [31:0]                 r_fail_arg1;
  logic [31:0]                 r_fail_arg2;
  logic [31:0]                 r_fail_ctx_arg0;
  logic [31:0]                 r_fail_ctx_arg1;
  logic [31:0]                 r_fail_ctx_arg2;
  logic [FAIL_REPLAY_CNT_W-1:0] r_fail_replay_cnt;
  logic                         r_fail_ctx_pending;
  logic                         r_fail_replay_sel;

  logic [31:0] s_expected_word;
  logic        s_last_word;
  logic        s_post_init_wait_done;

  function automatic logic [31:0] memtest_expected_word(
    input logic [20:0] word_addr
  );
    begin
      if (MEMTEST_USE_INCREMENT_PATTERN) begin
        memtest_expected_word = {11'h000, word_addr};
      end else begin
        memtest_expected_word = 32'h0000_0000;
      end
    end
  endfunction

  assign s_expected_word = memtest_expected_word(r_word_idx[20:0]);
  assign s_last_word = (r_word_idx == (MEMTEST_TOTAL_WORDS - 1));
  assign s_post_init_wait_done =
    (POST_INIT_WAIT_CYCLES == 0) ? 1'b1 :
    (r_post_init_wait_cnt >= (POST_INIT_WAIT_CYCLES - 1));

  assign O_REQ_VALID = (st_state == ST_WRITE_REQ) || (st_state == ST_READ_REQ);
  assign O_REQ_IS_WRITE = (st_state == ST_WRITE_REQ);
  assign O_REQ_ADDR = r_word_idx[20:0];
  assign O_REQ_WR_DATA = s_expected_word;
  assign O_REQ_WR_BE = 4'hF;
  assign O_RSP_READY = 1'b1;

  // Main self-test flow.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state      <= ST_IDLE;
      O_TEST_ACTIVE <= 1'b0;
      O_TEST_PASS   <= 1'b0;
      O_TEST_FAIL   <= 1'b0;
    end else begin
      case (st_state)
        ST_IDLE: begin
          st_state      <= ST_WAIT_INIT;
          O_TEST_ACTIVE <= 1'b0;
          O_TEST_PASS   <= 1'b0;
          O_TEST_FAIL   <= 1'b0;
        end

        ST_WAIT_INIT: begin
          if (I_INIT_DONE) begin
            st_state <= ST_POST_INIT_WAIT;
          end
        end

        ST_POST_INIT_WAIT: begin
          if (s_post_init_wait_done) begin
            st_state      <= ST_WRITE_REQ;
            O_TEST_ACTIVE <= 1'b1;
          end
        end

        ST_WRITE_REQ: begin
          if (I_REQ_READY) begin
            st_state <= ST_WRITE_WAIT;
          end
        end

        ST_WRITE_WAIT: begin
          if (I_RSP_VALID) begin
            if (I_RSP_STATUS != 32'h0000_0000) begin
              st_state      <= ST_FAIL;
              O_TEST_ACTIVE <= 1'b0;
              O_TEST_FAIL   <= 1'b1;
            end else if (s_last_word) begin
              st_state <= ST_READ_GAP;
            end else begin
              st_state <= ST_WRITE_REQ;
            end
          end
        end

        ST_READ_GAP: begin
          if (r_read_gap_cnt == 0) begin
            st_state <= ST_READ_REQ;
          end
        end

        ST_READ_REQ: begin
          if (I_REQ_READY) begin
            st_state <= ST_READ_WAIT;
          end
        end

        ST_READ_WAIT: begin
          if (I_RSP_VALID) begin
            if ((I_RSP_STATUS != 32'h0000_0000) ||
                (I_RSP_RD_DATA != s_expected_word)) begin
              st_state      <= ST_FAIL;
              O_TEST_ACTIVE <= 1'b0;
              O_TEST_FAIL   <= 1'b1;
            end else if (s_last_word) begin
              st_state      <= ST_PASS;
              O_TEST_ACTIVE <= 1'b0;
              O_TEST_PASS   <= 1'b1;
            end else begin
              st_state <= ST_READ_REQ;
            end
          end
        end

        ST_PASS: begin
          st_state <= ST_PASS;
        end

        ST_FAIL: begin
          st_state <= ST_FAIL;
        end

        default: begin
          st_state <= ST_IDLE;
        end
      endcase
    end
  end

  // Tracks sweep position and captures fail context.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_init_logged        <= 1'b0;
      r_post_init_wait_cnt <= '0;
      r_read_gap_cnt       <= '0;
      r_word_idx           <= '0;
      r_fail_arg0          <= 32'h0000_0000;
      r_fail_arg1          <= 32'h0000_0000;
      r_fail_arg2          <= 32'h0000_0000;
      r_fail_ctx_arg0      <= 32'h0000_0000;
      r_fail_ctx_arg1      <= 32'h0000_0000;
      r_fail_ctx_arg2      <= 32'h0000_0000;
      r_fail_replay_cnt    <= '0;
      r_fail_ctx_pending   <= 1'b0;
      r_fail_replay_sel    <= 1'b0;
    end else begin
      case (st_state)
        ST_IDLE: begin
          r_init_logged        <= 1'b0;
          r_post_init_wait_cnt <= '0;
          r_read_gap_cnt       <= '0;
          r_word_idx           <= '0;
          r_fail_replay_cnt    <= '0;
          r_fail_ctx_pending   <= 1'b0;
          r_fail_replay_sel    <= 1'b0;
        end

        ST_WAIT_INIT: begin
          if (!r_init_logged && I_INIT_DONE) begin
            r_init_logged        <= 1'b1;
            r_post_init_wait_cnt <= '0;
          end
        end

        ST_POST_INIT_WAIT: begin
          if (!s_post_init_wait_done) begin
            r_post_init_wait_cnt <= r_post_init_wait_cnt + 1'b1;
          end
        end

        ST_WRITE_WAIT: begin
          if (I_RSP_VALID) begin
            if (I_RSP_STATUS != 32'h0000_0000) begin
              r_fail_arg0        <= 32'h0000_0000;
              r_fail_arg1        <= 32'h0000_0000;
              r_fail_arg2        <= I_RSP_STATUS;
              r_fail_ctx_arg0    <= 32'h0000_0000;
              r_fail_ctx_arg1    <= {11'h000, r_word_idx[20:0]};
              r_fail_ctx_arg2    <= {11'h000, r_word_idx[20:0]};
              r_fail_ctx_pending <= 1'b1;
              r_fail_replay_cnt  <= '0;
              r_fail_replay_sel  <= 1'b0;
            end else if (s_last_word) begin
              r_word_idx     <= '0;
              r_read_gap_cnt <= POST_WRITE_TO_READ_GAP_CYCLES[GAP_CNT_W-1:0];
            end else begin
              r_word_idx <= r_word_idx + 1'b1;
            end
          end
        end

        ST_READ_GAP: begin
          if (r_read_gap_cnt != 0) begin
            r_read_gap_cnt <= r_read_gap_cnt - 1'b1;
          end
        end

        ST_READ_WAIT: begin
          if (I_RSP_VALID) begin
            if (I_RSP_STATUS != 32'h0000_0000) begin
              r_fail_arg0        <= 32'h0000_0000;
              r_fail_arg1        <= 32'h0000_0000;
              r_fail_arg2        <= I_RSP_STATUS;
              r_fail_ctx_arg0    <= 32'h0000_0001;
              r_fail_ctx_arg1    <= {11'h000, r_word_idx[20:0]};
              r_fail_ctx_arg2    <= {11'h000, r_word_idx[20:0]};
              r_fail_ctx_pending <= 1'b1;
              r_fail_replay_cnt  <= '0;
              r_fail_replay_sel  <= 1'b0;
            end else if (I_RSP_RD_DATA != s_expected_word) begin
              r_fail_arg0        <= {11'h000, r_word_idx[20:0]};
              r_fail_arg1        <= s_expected_word;
              r_fail_arg2        <= I_RSP_RD_DATA;
              r_fail_ctx_arg0    <= 32'h0000_0002;
              r_fail_ctx_arg1    <= {11'h000, r_word_idx[20:0]};
              r_fail_ctx_arg2    <= {11'h000, r_word_idx[20:0]};
              r_fail_ctx_pending <= 1'b1;
              r_fail_replay_cnt  <= '0;
              r_fail_replay_sel  <= 1'b0;
            end else if (!s_last_word) begin
              r_word_idx <= r_word_idx + 1'b1;
            end
          end
        end

        ST_FAIL: begin
          if (r_fail_ctx_pending) begin
            r_fail_ctx_pending <= 1'b0;
          end
          if (r_fail_replay_cnt < (FAIL_REPLAY_CYCLES - 1)) begin
            r_fail_replay_cnt <= r_fail_replay_cnt + 1'b1;
          end else begin
            r_fail_replay_cnt <= '0;
            r_fail_replay_sel <= ~r_fail_replay_sel;
          end
        end

        default: begin
          r_word_idx <= r_word_idx;
        end
      endcase
    end
  end

  // Generates event pulses for the logger path.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      O_EVT_VALID <= 1'b0;
      O_EVT_ID    <= 8'h00;
      O_EVT_ARG0  <= 32'h0000_0000;
      O_EVT_ARG1  <= 32'h0000_0000;
      O_EVT_ARG2  <= 32'h0000_0000;
    end else begin
      O_EVT_VALID <= 1'b0;

      if (!r_init_logged && I_INIT_DONE) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_INIT_DONE;
        O_EVT_ARG0  <= 32'h0000_0000;
        O_EVT_ARG1  <= 32'h0000_0000;
        O_EVT_ARG2  <= 32'h0000_0000;
      end else if ((st_state == ST_POST_INIT_WAIT) && s_post_init_wait_done) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_START;
        O_EVT_ARG0  <= MEMTEST_TOTAL_WORDS;
        O_EVT_ARG1  <= MEMTEST_BURST_WORDS;
        O_EVT_ARG2  <= 32'h0000_0001;
      end else if ((st_state == ST_WRITE_WAIT) && I_RSP_VALID &&
                   (I_RSP_STATUS != 32'h0000_0000)) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL;
        O_EVT_ARG0  <= 32'h0000_0000;
        O_EVT_ARG1  <= 32'h0000_0000;
        O_EVT_ARG2  <= I_RSP_STATUS;
      end else if ((st_state == ST_READ_WAIT) && I_RSP_VALID &&
                   (I_RSP_STATUS != 32'h0000_0000)) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL;
        O_EVT_ARG0  <= 32'h0000_0000;
        O_EVT_ARG1  <= 32'h0000_0000;
        O_EVT_ARG2  <= I_RSP_STATUS;
      end else if ((st_state == ST_READ_WAIT) && I_RSP_VALID &&
                   (I_RSP_STATUS == 32'h0000_0000) &&
                   (I_RSP_RD_DATA != s_expected_word)) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL;
        O_EVT_ARG0  <= {11'h000, r_word_idx[20:0]};
        O_EVT_ARG1  <= s_expected_word;
        O_EVT_ARG2  <= I_RSP_RD_DATA;
      end else if ((st_state == ST_READ_WAIT) && I_RSP_VALID &&
                   (I_RSP_STATUS == 32'h0000_0000) &&
                   (I_RSP_RD_DATA == s_expected_word) &&
                   s_last_word) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_PASS;
        O_EVT_ARG0  <= MEMTEST_TOTAL_WORDS;
        O_EVT_ARG1  <= MEMTEST_BURST_WORDS;
        O_EVT_ARG2  <= 32'h0000_0000;
      end else if ((st_state == ST_FAIL) && r_fail_ctx_pending) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL_CTX;
        O_EVT_ARG0  <= r_fail_ctx_arg0;
        O_EVT_ARG1  <= r_fail_ctx_arg1;
        O_EVT_ARG2  <= r_fail_ctx_arg2;
      end else if ((st_state == ST_FAIL) &&
                   (r_fail_replay_cnt == (FAIL_REPLAY_CYCLES - 1))) begin
        O_EVT_VALID <= 1'b1;
        if (!r_fail_replay_sel) begin
          O_EVT_ID   <= EVT_TEST_FAIL;
          O_EVT_ARG0 <= r_fail_arg0;
          O_EVT_ARG1 <= r_fail_arg1;
          O_EVT_ARG2 <= r_fail_arg2;
        end else begin
          O_EVT_ID   <= EVT_TEST_FAIL_CTX;
          O_EVT_ARG0 <= r_fail_ctx_arg0;
          O_EVT_ARG1 <= r_fail_ctx_arg1;
          O_EVT_ARG2 <= r_fail_ctx_arg2;
        end
      end
    end
  end

endmodule
