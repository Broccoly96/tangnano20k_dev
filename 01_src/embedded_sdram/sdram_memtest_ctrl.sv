`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_memtest_ctrl.sv
// Description  : Embedded SDRAM write/read/compare self-test controller.
//                This sequence follows the vendor user-interface example closely:
//                issue a one-cycle request when busy_n is high, stream write data
//                for data_len+3 cycles, then read back and compare on rd_valid.
//////////////////////////////////////////////////////////////////////////////////

module sdram_memtest_ctrl #(
  parameter int unsigned BURST_WORDS = 26,
  parameter int unsigned BURST_COUNT = 8,
  parameter int unsigned POST_INIT_WAIT_CYCLES = 20_000
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

  localparam logic [7:0] EVT_INIT_DONE  = 8'h20;
  localparam logic [7:0] EVT_TEST_START = 8'h21;
  localparam logic [7:0] EVT_TEST_PASS  = 8'h22;
  localparam logic [7:0] EVT_TEST_FAIL  = 8'h23;

  localparam logic [1:0]  BANK_ADDR      = 2'd2;
  localparam logic [10:0] ROW_ADDR       = 11'd2;
  localparam logic [7:0]  COL_START      = 8'd5;
  localparam int unsigned DATA_LEN       = BURST_WORDS - 1;
  localparam int unsigned LAST_BASE_IDX  = (BURST_COUNT - 1) * BURST_WORDS;

  typedef enum logic [2:0] {
    IDLE,
    WRITE_WAIT,
    WRITE_RUN,
    READ_WAIT,
    READ_RUN,
    PASS,
    FAIL
  } st_state_e;

  st_state_e st_state;

  logic        r_init_logged;
  logic [14:0] r_post_init_wait_cnt;
  logic [7:0]  r_burst_base_idx;
  logic [7:0]  r_cycle_cnt;
  logic [31:0] r_wr_data;
  logic [31:0] r_expected_rd_data;
  logic [31:0] r_next_wr_data_seed;
  logic [7:0]  r_rd_seen_words;
  logic        r_sdrc_rd_valid_q;

  logic        s_start_test;
  logic        s_write_window_done;
  logic        s_read_window_done;
  logic [20:0] s_curr_addr;
  logic        s_rd_valid_pulse;

  assign s_curr_addr         = {BANK_ADDR, ROW_ADDR, (COL_START + r_burst_base_idx)};
  assign s_start_test        = r_init_logged &&
                               (r_post_init_wait_cnt == POST_INIT_WAIT_CYCLES - 1) &&
                               I_SDRC_BUSY_N;
  assign s_write_window_done = (r_cycle_cnt > DATA_LEN + 1);
  assign s_read_window_done  = (r_cycle_cnt > DATA_LEN + 1);
  assign s_rd_valid_pulse    = I_SDRC_RD_VALID && !r_sdrc_rd_valid_q;

  assign O_SDRC_ADDR      = s_curr_addr;
  assign O_SDRC_DATA_LEN  = DATA_LEN[7:0];
  assign O_SDRC_DQM       = 4'h0;
  assign O_SDRC_WR_DATA   = r_wr_data;
  assign O_SDRC_WR_N      = (st_state == WRITE_WAIT) ? ~I_SDRC_BUSY_N : 1'b1;
  assign O_SDRC_RD_N      = (st_state == READ_WAIT)  ? ~I_SDRC_BUSY_N : 1'b1;

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
            st_state <= WRITE_RUN;
          end
        end

        WRITE_RUN: begin
          if (s_write_window_done) begin
            st_state <= READ_WAIT;
          end
        end

        READ_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            st_state <= READ_RUN;
          end
        end

        READ_RUN: begin
          if (s_rd_valid_pulse && (I_SDRC_RD_DATA != r_expected_rd_data)) begin
            st_state      <= FAIL;
            O_TEST_ACTIVE <= 1'b0;
            O_TEST_FAIL   <= 1'b1;
          end else if (s_read_window_done) begin
            if (r_burst_base_idx == LAST_BASE_IDX) begin
              st_state      <= PASS;
              O_TEST_ACTIVE <= 1'b0;
              O_TEST_PASS   <= 1'b1;
            end else begin
              st_state <= WRITE_WAIT;
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
      r_cycle_cnt       <= '0;
      r_rd_seen_words   <= '0;
      r_burst_base_idx  <= '0;
      r_sdrc_rd_valid_q <= 1'b0;
    end else begin
      r_sdrc_rd_valid_q <= I_SDRC_RD_VALID;
      case (st_state)
        IDLE: begin
          r_cycle_cnt      <= '0;
          r_rd_seen_words  <= '0;
          r_burst_base_idx <= '0;
        end

        WRITE_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt    <= '0;
            r_rd_seen_words <= '0;
          end
        end

        WRITE_RUN: begin
          if (s_write_window_done) begin
            r_cycle_cnt <= '0;
          end else begin
            r_cycle_cnt <= r_cycle_cnt + 1'b1;
          end
        end

        READ_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            r_cycle_cnt     <= '0;
            r_rd_seen_words <= '0;
          end
        end

        READ_RUN: begin
          if (s_rd_valid_pulse) begin
            r_rd_seen_words <= r_rd_seen_words + 1'b1;
          end

          if (s_read_window_done) begin
            r_cycle_cnt <= '0;
            if ((st_state == READ_RUN) && (r_burst_base_idx != LAST_BASE_IDX)) begin
              r_burst_base_idx <= r_burst_base_idx + BURST_WORDS;
            end
          end else begin
            r_cycle_cnt <= r_cycle_cnt + 1'b1;
          end
        end

        default: begin
          r_cycle_cnt     <= r_cycle_cnt;
          r_rd_seen_words <= r_rd_seen_words;
        end
      endcase
    end
  end

  // Generates write data and the read-side expected sequence.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_wr_data           <= 32'h0000_0000;
      r_expected_rd_data  <= 32'h0000_0000;
      r_next_wr_data_seed <= 32'h0000_0000;
    end else begin
      case (st_state)
        IDLE: begin
          r_wr_data           <= 32'h0000_0000;
          r_expected_rd_data  <= 32'h0000_0000;
          r_next_wr_data_seed <= 32'h0000_0000;
        end

        WRITE_WAIT: begin
          if (I_SDRC_BUSY_N) begin
            r_wr_data <= r_next_wr_data_seed;
          end
        end

        WRITE_RUN: begin
          if (s_write_window_done) begin
            r_expected_rd_data  <= r_next_wr_data_seed;
            r_next_wr_data_seed <= r_wr_data;
          end else begin
            r_wr_data <= r_wr_data + 1'b1;
          end
        end

        READ_RUN: begin
          if (I_SDRC_RD_VALID) begin
            r_expected_rd_data <= r_expected_rd_data + 1'b1;
          end
        end

        default: begin
          r_wr_data           <= r_wr_data;
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
        O_EVT_ARG2  <= DATA_LEN;
      end else if (st_state == READ_RUN && s_rd_valid_pulse &&
                   (I_SDRC_RD_DATA != r_expected_rd_data)) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_FAIL;
        O_EVT_ARG0  <= {24'h0, r_rd_seen_words};
        O_EVT_ARG1  <= r_expected_rd_data;
        O_EVT_ARG2  <= I_SDRC_RD_DATA;
      end else if (st_state == READ_RUN && s_read_window_done &&
                   (r_burst_base_idx == LAST_BASE_IDX)) begin
        O_EVT_VALID <= 1'b1;
        O_EVT_ID    <= EVT_TEST_PASS;
        O_EVT_ARG0  <= BURST_WORDS * BURST_COUNT;
        O_EVT_ARG1  <= 32'h0000_0000;
        O_EVT_ARG2  <= 32'h0000_0000;
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
      WRITE_RUN:  state_name = "WRITE_RUN";
      READ_WAIT:  state_name = "READ_WAIT";
      READ_RUN:   state_name = "READ_RUN";
      PASS:       state_name = "PASS";
      FAIL:       state_name = "FAIL";
      default:    state_name = "UNKNOWN";
    endcase
  endfunction

  logic [2:0] r_state_dbg_q;

  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_state_dbg_q <= IDLE;
    end else begin
      if (r_state_dbg_q != st_state) begin
        tb_log_pkg::log_debug(
          "SDRAM UIF",
          $sformatf(
            "state %s -> %s base=%0d cycle=%0d busy_n=%0b ack=%0b rd_valid=%0b",
            state_name(st_state_e'(r_state_dbg_q)),
            state_name(st_state),
            r_burst_base_idx,
            r_cycle_cnt,
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

      if (s_rd_valid_pulse) begin
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
