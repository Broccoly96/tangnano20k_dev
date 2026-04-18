`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;

  logic [15:0] tb_addr;
  logic        tb_init_done;
  logic        tb_test_active;
  logic        tb_test_pass;
  logic        tb_test_fail;
  logic        tb_host_busy;
  logic [31:0] tb_memtest_summary;
  logic [31:0] tb_memtest_curr_word_addr;
  logic [31:0] tb_memtest_expected_word;
  logic [31:0] tb_memtest_last_rd_data;
  logic [31:0] tb_memtest_last_rsp_status;
  logic [31:0] tb_memtest_fail_arg0;
  logic [31:0] tb_memtest_fail_arg1;
  logic [31:0] tb_memtest_fail_arg2;
  logic [31:0] tb_memtest_fail_ctx_arg0;
  logic [31:0] tb_memtest_fail_ctx_arg1;
  logic [31:0] tb_memtest_fail_ctx_arg2;
  logic [31:0] tb_word_ctrl_summary;
  logic [31:0] tb_word_ctrl_data;
  logic [31:0] tb_byte_ctrl_summary;
  logic [31:0] tb_byte_ctrl_detail;
  logic [31:0] tb_rd_data;

  initial begin
    configure_logging(LOG_INFO);
    tb_addr                   = 16'h0000;
    tb_init_done              = 1'b0;
    tb_test_active            = 1'b0;
    tb_test_pass              = 1'b0;
    tb_test_fail              = 1'b0;
    tb_host_busy              = 1'b0;
    tb_memtest_summary        = 32'h0000_0000;
    tb_memtest_curr_word_addr = 32'h0000_0000;
    tb_memtest_expected_word  = 32'h0000_0000;
    tb_memtest_last_rd_data   = 32'h0000_0000;
    tb_memtest_last_rsp_status= 32'h0000_0000;
    tb_memtest_fail_arg0      = 32'h0000_0000;
    tb_memtest_fail_arg1      = 32'h0000_0000;
    tb_memtest_fail_arg2      = 32'h0000_0000;
    tb_memtest_fail_ctx_arg0  = 32'h0000_0000;
    tb_memtest_fail_ctx_arg1  = 32'h0000_0000;
    tb_memtest_fail_ctx_arg2  = 32'h0000_0000;
    tb_word_ctrl_summary      = 32'h0000_0000;
    tb_word_ctrl_data         = 32'h0000_0000;
    tb_byte_ctrl_summary      = 32'h0000_0000;
    tb_byte_ctrl_detail       = 32'h0000_0000;
  end

  sdram_status_reg_map u_dut (
    .I_ADDR                   (tb_addr),
    .I_INIT_DONE              (tb_init_done),
    .I_TEST_ACTIVE            (tb_test_active),
    .I_TEST_PASS              (tb_test_pass),
    .I_TEST_FAIL              (tb_test_fail),
    .I_HOST_BUSY              (tb_host_busy),
    .I_MEMTEST_SUMMARY        (tb_memtest_summary),
    .I_MEMTEST_CURR_WORD_ADDR (tb_memtest_curr_word_addr),
    .I_MEMTEST_EXPECTED_WORD  (tb_memtest_expected_word),
    .I_MEMTEST_LAST_RD_DATA   (tb_memtest_last_rd_data),
    .I_MEMTEST_LAST_RSP_STATUS(tb_memtest_last_rsp_status),
    .I_MEMTEST_FAIL_ARG0      (tb_memtest_fail_arg0),
    .I_MEMTEST_FAIL_ARG1      (tb_memtest_fail_arg1),
    .I_MEMTEST_FAIL_ARG2      (tb_memtest_fail_arg2),
    .I_MEMTEST_FAIL_CTX_ARG0  (tb_memtest_fail_ctx_arg0),
    .I_MEMTEST_FAIL_CTX_ARG1  (tb_memtest_fail_ctx_arg1),
    .I_MEMTEST_FAIL_CTX_ARG2  (tb_memtest_fail_ctx_arg2),
    .I_WORD_CTRL_SUMMARY      (tb_word_ctrl_summary),
    .I_WORD_CTRL_DATA         (tb_word_ctrl_data),
    .I_BYTE_CTRL_SUMMARY      (tb_byte_ctrl_summary),
    .I_BYTE_CTRL_DETAIL       (tb_byte_ctrl_detail),
    .O_RD_DATA                (tb_rd_data)
  );

`include "testcase_smoke.svh"

endmodule
