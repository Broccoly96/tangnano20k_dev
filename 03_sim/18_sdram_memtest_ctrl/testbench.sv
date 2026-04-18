`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;

  localparam time CLK_HALF_PERIOD = 10ns;

  logic        tb_clk;
  logic        tb_rst_n;
  logic        tb_init_done;

  logic        tb_req_valid;
  logic        tb_req_ready;
  logic        tb_req_is_write;
  logic [20:0] tb_req_addr;
  logic [31:0] tb_req_wr_data;
  logic [3:0]  tb_req_wr_be;

  logic        tb_rsp_valid;
  logic        tb_rsp_ready;
  logic [31:0] tb_rsp_rd_data;
  logic [31:0] tb_rsp_status;

  logic        tb_test_active;
  logic        tb_test_pass;
  logic        tb_test_fail;
  logic [31:0] tb_dbg_summary;
  logic [31:0] tb_dbg_curr_word_addr;
  logic [31:0] tb_dbg_expected_word;
  logic [31:0] tb_dbg_last_rd_data;
  logic [31:0] tb_dbg_last_rsp_status;
  logic [31:0] tb_dbg_fail_arg0;
  logic [31:0] tb_dbg_fail_arg1;
  logic [31:0] tb_dbg_fail_arg2;
  logic [31:0] tb_dbg_fail_ctx_arg0;
  logic [31:0] tb_dbg_fail_ctx_arg1;
  logic [31:0] tb_dbg_fail_ctx_arg2;
  logic        tb_evt_valid;
  logic [7:0]  tb_evt_id;
  logic [31:0] tb_evt_arg0;
  logic [31:0] tb_evt_arg1;
  logic [31:0] tb_evt_arg2;

  logic        r_rsp_pending;
  logic        r_rsp_is_write;
  logic [20:0] r_rsp_addr;
  logic [31:0] r_rsp_data;
  logic [31:0] r_rsp_status;
  int unsigned r_run_index;
  int unsigned r_addr0_read_count;

  initial begin
    configure_logging(LOG_INFO);
    tb_clk = 1'b0;
    forever #CLK_HALF_PERIOD tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n    = 1'b0;
    tb_init_done= 1'b0;
    r_run_index = 0;
    repeat (8) @(posedge tb_clk);
    tb_rst_n     = 1'b1;
    tb_init_done = 1'b1;
  end

  initial begin
    #(5ms);
    log_fatal(1, "MEMTEST CTRL TB", "simulation timeout");
  end

  assign tb_req_ready = 1'b1;

  sdram_memtest_ctrl #(
    .CLK_HZ(1_000_000),
    .MEMTEST_BURST_WORDS(2),
    .MEMTEST_TOTAL_WORDS(2),
    .POST_INIT_WAIT_CYCLES(0),
    .POST_WRITE_TO_READ_GAP_CYCLES(0),
    .MEMTEST_READBACK_RETRY_COUNT(3)
  ) u_dut (
    .I_CLK                (tb_clk),
    .I_RST_N              (tb_rst_n),
    .I_INIT_DONE          (tb_init_done),
    .O_REQ_VALID          (tb_req_valid),
    .I_REQ_READY          (tb_req_ready),
    .O_REQ_IS_WRITE       (tb_req_is_write),
    .O_REQ_ADDR           (tb_req_addr),
    .O_REQ_WR_DATA        (tb_req_wr_data),
    .O_REQ_WR_BE          (tb_req_wr_be),
    .I_RSP_VALID          (tb_rsp_valid),
    .O_RSP_READY          (tb_rsp_ready),
    .I_RSP_RD_DATA        (tb_rsp_rd_data),
    .I_RSP_STATUS         (tb_rsp_status),
    .O_TEST_ACTIVE        (tb_test_active),
    .O_TEST_PASS          (tb_test_pass),
    .O_TEST_FAIL          (tb_test_fail),
    .O_DBG_SUMMARY        (tb_dbg_summary),
    .O_DBG_CURR_WORD_ADDR (tb_dbg_curr_word_addr),
    .O_DBG_EXPECTED_WORD  (tb_dbg_expected_word),
    .O_DBG_LAST_RD_DATA   (tb_dbg_last_rd_data),
    .O_DBG_LAST_RSP_STATUS(tb_dbg_last_rsp_status),
    .O_DBG_FAIL_ARG0      (tb_dbg_fail_arg0),
    .O_DBG_FAIL_ARG1      (tb_dbg_fail_arg1),
    .O_DBG_FAIL_ARG2      (tb_dbg_fail_arg2),
    .O_DBG_FAIL_CTX_ARG0  (tb_dbg_fail_ctx_arg0),
    .O_DBG_FAIL_CTX_ARG1  (tb_dbg_fail_ctx_arg1),
    .O_DBG_FAIL_CTX_ARG2  (tb_dbg_fail_ctx_arg2),
    .O_EVT_VALID          (tb_evt_valid),
    .O_EVT_ID             (tb_evt_id),
    .O_EVT_ARG0           (tb_evt_arg0),
    .O_EVT_ARG1           (tb_evt_arg1),
    .O_EVT_ARG2           (tb_evt_arg2)
  );

  // Models a one-cycle-latency memory backend and injects deterministic
  // readback mismatches on address 0 so retry behavior can be verified.
  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      tb_rsp_valid       <= 1'b0;
      tb_rsp_rd_data     <= 32'h0000_0000;
      tb_rsp_status      <= 32'h0000_0000;
      r_rsp_pending      <= 1'b0;
      r_rsp_is_write     <= 1'b0;
      r_rsp_addr         <= '0;
      r_rsp_data         <= 32'h0000_0000;
      r_rsp_status       <= 32'h0000_0000;
      r_addr0_read_count <= 0;
    end else begin
      tb_rsp_valid <= 1'b0;

      if (r_rsp_pending) begin
        tb_rsp_valid   <= 1'b1;
        tb_rsp_rd_data <= r_rsp_data;
        tb_rsp_status  <= r_rsp_status;
        r_rsp_pending  <= 1'b0;
      end

      if (tb_req_valid && tb_req_ready) begin
        r_rsp_pending  <= 1'b1;
        r_rsp_is_write <= tb_req_is_write;
        r_rsp_addr     <= tb_req_addr;
        r_rsp_status   <= 32'h0000_0000;

        if (tb_req_is_write) begin
          r_rsp_data <= 32'h0000_0000;
        end else if (tb_req_addr == 21'h0) begin
          if (r_run_index == 0) begin
            case (r_addr0_read_count)
              0: r_rsp_data <= 32'hFFFF_FFFF;
              1: r_rsp_data <= 32'hFFFF_FFFF;
              default: r_rsp_data <= 32'h0000_0000;
            endcase
          end else begin
            r_rsp_data <= 32'hFFFF_FFFF;
          end
          r_addr0_read_count <= r_addr0_read_count + 1;
        end else begin
          r_rsp_data <= 32'h0000_0000;
        end
      end
    end
  end

`include "testcase_smoke.svh"

endmodule
