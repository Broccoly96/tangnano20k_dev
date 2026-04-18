`timescale 1ns / 1ps

module testbench #(
  parameter bit USE_FIXED_WINDOW_ADDR = 1'b0
);

  import tb_log_pkg::*;

  localparam time CLK_PERIOD = 10ns;
  localparam int unsigned MEM_WORDS = 64;
  localparam int unsigned BURST_WORDS = 4;
  localparam int unsigned BURST_COUNT = 2;
  localparam int unsigned CLEAR_WORDS = 16;
  localparam logic [31:0] CORRUPT_DATA = 32'hDEAD_BEEF;
  localparam logic [20:0] FIRST_WORD_ADDR = 21'h00000;

  localparam int unsigned SC_PASS    = 0;
  localparam int unsigned SC_RECOVER = 1;
  localparam int unsigned SC_EXHAUST = 2;
  localparam int unsigned SC_TIMEOUT = 3;

  typedef enum logic [1:0] {
    UIF_IDLE,
    UIF_WRITE,
    UIF_READ
  } uif_state_e;

  logic        tb_clk;
  logic        tb_rst_n;
  logic        tb_sdrc_init_done;
  logic        tb_sdrc_busy_n;
  logic        tb_sdrc_wrd_ack;
  logic        tb_sdrc_rd_valid;
  logic [31:0] tb_sdrc_rd_data;
  logic        tb_sdrc_wr_n;
  logic        tb_sdrc_rd_n;
  logic [20:0] tb_sdrc_addr;
  logic [7:0]  tb_sdrc_data_len;
  logic [3:0]  tb_sdrc_dqm;
  logic [31:0] tb_sdrc_wr_data;
  logic        tb_test_active;
  logic        tb_test_pass;
  logic        tb_test_fail;
  logic        tb_evt_valid;
  logic [7:0]  tb_evt_id;
  logic [31:0] tb_evt_arg0;
  logic [31:0] tb_evt_arg1;
  logic [31:0] tb_evt_arg2;
  logic [31:0] tb_dbg_mem_summary;
  logic [7:0]  tb_dbg_state;
  logic [7:0]  tb_dbg_fail_reason;
  logic [20:0] tb_dbg_current_addr;
  logic [31:0] tb_dbg_expected_word;
  logic [31:0] tb_dbg_last_read_data;
  logic [31:0] tb_dbg_last_status;
  logic [31:0] tb_dbg_fail_addr;
  logic [31:0] tb_dbg_fail_expected;
  logic [31:0] tb_dbg_fail_actual;
  logic [31:0] tb_dbg_retry_summary;
  logic [31:0] tb_dbg_retry_data1;
  logic [31:0] tb_dbg_retry_data2;
  logic [31:0] tb_dbg_ctrl_summary;
  logic [31:0] tb_dbg_ctrl_detail;

  logic [31:0] mem_words [0:MEM_WORDS-1];
  uif_state_e  st_uif;
  logic [20:0] r_base_addr;
  logic [7:0]  r_len_words;
  logic [7:0]  r_count;
  integer      r_scenario;
  integer      r_corrupt_reads_remaining;
  integer      r_timeout_reads_remaining;

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  sdram_memtest_ctrl #(
    .BURST_WORDS(BURST_WORDS),
    .BURST_COUNT(BURST_COUNT),
    .TEST_WORDS(BURST_WORDS * BURST_COUNT),
    .USE_FIXED_WINDOW_ADDR(USE_FIXED_WINDOW_ADDR),
    .POST_INIT_WAIT_CYCLES(4),
    .POST_WRITE_TO_READ_GAP_CYCLES(1),
    .CLEAR_WORDS(CLEAR_WORDS)
  ) u_dut (
    .I_CLK                (tb_clk),
    .I_RST_N              (tb_rst_n),
    .I_SDRC_INIT_DONE     (tb_sdrc_init_done),
    .I_SDRC_BUSY_N        (tb_sdrc_busy_n),
    .I_SDRC_WRD_ACK       (tb_sdrc_wrd_ack),
    .I_SDRC_RD_VALID      (tb_sdrc_rd_valid),
    .I_SDRC_RD_DATA       (tb_sdrc_rd_data),
    .O_SDRC_WR_N          (tb_sdrc_wr_n),
    .O_SDRC_RD_N          (tb_sdrc_rd_n),
    .O_SDRC_ADDR          (tb_sdrc_addr),
    .O_SDRC_DATA_LEN      (tb_sdrc_data_len),
    .O_SDRC_DQM           (tb_sdrc_dqm),
    .O_SDRC_WR_DATA       (tb_sdrc_wr_data),
    .O_TEST_ACTIVE        (tb_test_active),
    .O_TEST_PASS          (tb_test_pass),
    .O_TEST_FAIL          (tb_test_fail),
    .O_EVT_VALID          (tb_evt_valid),
    .O_EVT_ID             (tb_evt_id),
    .O_EVT_ARG0           (tb_evt_arg0),
    .O_EVT_ARG1           (tb_evt_arg1),
    .O_EVT_ARG2           (tb_evt_arg2),
    .O_DBG_MEM_SUMMARY    (tb_dbg_mem_summary),
    .O_DBG_STATE          (tb_dbg_state),
    .O_DBG_FAIL_REASON    (tb_dbg_fail_reason),
    .O_DBG_CURRENT_ADDR   (tb_dbg_current_addr),
    .O_DBG_EXPECTED_WORD  (tb_dbg_expected_word),
    .O_DBG_LAST_READ_DATA (tb_dbg_last_read_data),
    .O_DBG_LAST_STATUS    (tb_dbg_last_status),
    .O_DBG_FAIL_ADDR      (tb_dbg_fail_addr),
    .O_DBG_FAIL_EXPECTED  (tb_dbg_fail_expected),
    .O_DBG_FAIL_ACTUAL    (tb_dbg_fail_actual),
    .O_DBG_RETRY_SUMMARY  (tb_dbg_retry_summary),
    .O_DBG_RETRY_DATA1    (tb_dbg_retry_data1),
    .O_DBG_RETRY_DATA2    (tb_dbg_retry_data2),
    .O_DBG_CTRL_SUMMARY   (tb_dbg_ctrl_summary),
    .O_DBG_CTRL_DETAIL    (tb_dbg_ctrl_detail)
  );

  function automatic [31:0] next_read_data(
    input logic [20:0] addr_word,
    input logic [7:0]  word_index
  );
    logic [31:0] data_word;
    begin
      data_word = mem_words[(addr_word + word_index) & 21'h3F];
      if ((word_index == 0) && (r_corrupt_reads_remaining > 0)) begin
        data_word = CORRUPT_DATA;
      end
      next_read_data = data_word;
    end
  endfunction

  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      tb_sdrc_busy_n  <= 1'b1;
      tb_sdrc_wrd_ack <= 1'b0;
      tb_sdrc_rd_valid<= 1'b0;
      tb_sdrc_rd_data <= 32'h0000_0000;
      st_uif          <= UIF_IDLE;
      r_base_addr     <= '0;
      r_len_words     <= '0;
      r_count         <= '0;
    end else begin
      tb_sdrc_wrd_ack  <= 1'b0;
      tb_sdrc_rd_valid <= 1'b0;

      case (st_uif)
        UIF_IDLE: begin
          tb_sdrc_busy_n <= 1'b1;
          r_count        <= '0;
          if (!tb_sdrc_wr_n) begin
            log_debug("MEMTEST UIF", $sformatf(
              "accept write addr=0x%05h len=%0d data0=0x%08h",
              tb_sdrc_addr,
              tb_sdrc_data_len + 1'b1,
              tb_sdrc_wr_data
            ));
            r_base_addr    <= tb_sdrc_addr;
            r_len_words    <= tb_sdrc_data_len + 1'b1;
            mem_words[tb_sdrc_addr & 21'h3F] <= tb_sdrc_wr_data;
            tb_sdrc_wrd_ack <= 1'b1;
            tb_sdrc_busy_n  <= 1'b0;
            r_count         <= 8'd1;
            st_uif          <= UIF_WRITE;
          end else if (!tb_sdrc_rd_n) begin
            log_debug("MEMTEST UIF", $sformatf(
              "accept read addr=0x%05h len=%0d timeout_budget=%0d corrupt_budget=%0d",
              tb_sdrc_addr,
              tb_sdrc_data_len + 1'b1,
              r_timeout_reads_remaining,
              r_corrupt_reads_remaining
            ));
            r_base_addr    <= tb_sdrc_addr;
            r_len_words    <= tb_sdrc_data_len + 1'b1;
            tb_sdrc_busy_n <= 1'b0;
            r_count        <= '0;
            if ((tb_sdrc_data_len != 0) && (r_timeout_reads_remaining > 0)) begin
              r_timeout_reads_remaining <= r_timeout_reads_remaining - 1;
            end
            st_uif <= UIF_READ;
          end
        end

        UIF_WRITE: begin
          if (r_count < r_len_words) begin
            log_debug("MEMTEST UIF", $sformatf(
              "write beat addr=0x%05h beat=%0d/%0d data=0x%08h",
              r_base_addr,
              r_count,
              r_len_words,
              tb_sdrc_wr_data
            ));
            mem_words[(r_base_addr + r_count) & 21'h3F] <= tb_sdrc_wr_data;
            tb_sdrc_wrd_ack <= 1'b1;
            r_count <= r_count + 1'b1;
          end else begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif <= UIF_IDLE;
          end
        end

        UIF_READ: begin
          if ((r_scenario == SC_TIMEOUT) && (r_len_words != 1) && (r_timeout_reads_remaining < 0)) begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif <= UIF_IDLE;
          end else if ((r_scenario == SC_TIMEOUT) && (r_len_words != 1) && (r_timeout_reads_remaining == 0)) begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif <= UIF_IDLE;
            r_timeout_reads_remaining <= -1;
          end else if (r_count < r_len_words) begin
            tb_sdrc_rd_valid <= 1'b1;
            tb_sdrc_rd_data  <= next_read_data(r_base_addr, r_count);
            log_debug("MEMTEST UIF", $sformatf(
              "return read addr=0x%05h beat=%0d/%0d data=0x%08h corrupt_budget=%0d",
              r_base_addr,
              r_count,
              r_len_words,
              next_read_data(r_base_addr, r_count),
              r_corrupt_reads_remaining
            ));
            if ((r_count == 0) && (r_corrupt_reads_remaining > 0)) begin
              r_corrupt_reads_remaining <= r_corrupt_reads_remaining - 1;
            end
            r_count <= r_count + 1'b1;
          end else begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif <= UIF_IDLE;
          end
        end

        default: begin
          st_uif <= UIF_IDLE;
        end
      endcase
    end
  end

  task automatic reset_case(
    input int scenario_value
  );
    begin
      r_scenario = scenario_value;
      case (scenario_value)
        SC_PASS: begin
          r_corrupt_reads_remaining = 0;
          r_timeout_reads_remaining = -1;
        end
        SC_RECOVER: begin
          r_corrupt_reads_remaining = 1;
          r_timeout_reads_remaining = -1;
        end
        SC_EXHAUST: begin
          r_corrupt_reads_remaining = 4;
          r_timeout_reads_remaining = -1;
        end
        default: begin
          r_corrupt_reads_remaining = 0;
          r_timeout_reads_remaining = 0;
        end
      endcase

      for (int idx = 0; idx < MEM_WORDS; idx++) begin
        mem_words[idx] = 32'h0000_0000;
      end

      tb_rst_n = 1'b0;
      tb_sdrc_init_done = 1'b0;
      repeat (8) @(posedge tb_clk);
      tb_rst_n = 1'b1;
      repeat (8) @(posedge tb_clk);
      tb_sdrc_init_done = 1'b1;
    end
  endtask

  task automatic wait_done(
    input string label
  );
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_test_pass && !tb_test_fail) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 5000) begin
          log_fatal(1, "MEMTEST TB", {"timeout waiting for ", label});
        end
      end
    end
  endtask

`include "testcase_smoke.svh"

endmodule
