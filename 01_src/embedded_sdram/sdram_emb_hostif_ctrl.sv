`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_emb_hostif_ctrl.sv
// Description  : SDRAM self-test controller with uart_log_cli status export.
//                - Owns startup memtest.
//                - Keeps SDRAM connected only to the self-test engine.
//                - Exposes self-test status through a read-only host map.
//////////////////////////////////////////////////////////////////////////////////

module sdram_emb_hostif_ctrl #(
  parameter int unsigned MEMTEST_CLK_HZ = 48_000_000,
  parameter int unsigned MEMTEST_BURST_WORDS = 256,
  parameter int unsigned MEMTEST_TOTAL_WORDS = 2_097_152,
  parameter int unsigned MEMTEST_POST_INIT_WAIT_CYCLES = 20_000,
  parameter int unsigned MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES = 4
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_CLI_RX_VALID,
  input  logic [7:0]  I_CLI_RX_DATA,
  output logic        O_RAW_RX_BYPASS,
  output logic        O_RAW_TX_MODE,
  output logic        O_RAW_TX_VALID,
  output logic [7:0]  O_RAW_TX_DATA,
  input  logic        I_RAW_TX_READY,
  output logic        O_TEST_EVT_VALID,
  output logic [7:0]  O_TEST_EVT_ID,
  output logic [31:0] O_TEST_EVT_ARG0,
  output logic [31:0] O_TEST_EVT_ARG1,
  output logic [31:0] O_TEST_EVT_ARG2,
  input  logic        I_TEST_EVT_READY,
  output logic        O_HOST_EVT_VALID,
  output logic [7:0]  O_HOST_EVT_ID,
  output logic [31:0] O_HOST_EVT_ARG0,
  output logic [31:0] O_HOST_EVT_ARG1,
  output logic [31:0] O_HOST_EVT_ARG2,
  input  logic        I_HOST_EVT_READY,
  input  logic        I_INIT_DONE,
  output logic        O_INIT_DONE,
  output logic        O_TEST_ACTIVE,
  output logic        O_TEST_PASS,
  output logic        O_TEST_FAIL,
  output logic        O_HOST_BUSY,
  input  logic [31:0] I_WORD_CTRL_DBG_SUMMARY,
  input  logic [31:0] I_WORD_CTRL_DBG_DATA,
  input  logic [31:0] I_BYTE_CTRL_DBG_SUMMARY,
  input  logic [31:0] I_BYTE_CTRL_DBG_DETAIL,

  output logic        O_REQ_VALID,
  input  logic        I_REQ_READY,
  output logic        O_REQ_IS_WRITE,
  output logic [20:0] O_REQ_ADDR,
  output logic [31:0] O_REQ_WR_DATA,
  output logic [3:0]  O_REQ_WR_BE,

  input  logic        I_RSP_VALID,
  output logic        O_RSP_READY,
  input  logic [31:0] I_RSP_RD_DATA,
  input  logic [31:0] I_RSP_STATUS
);

  logic        l_test_req_valid;
  logic        l_test_req_ready;
  logic        l_test_req_is_write;
  logic [20:0] l_test_req_addr;
  logic [31:0] l_test_req_wr_data;
  logic [3:0]  l_test_req_wr_be;
  logic        l_test_rsp_valid;
  logic        l_test_rsp_ready;
  logic [31:0] l_test_rsp_rd_data;
  logic [31:0] l_test_rsp_status;
  logic [31:0] l_memtest_dbg_summary;
  logic [31:0] l_memtest_dbg_curr_word_addr;
  logic [31:0] l_memtest_dbg_expected_word;
  logic [31:0] l_memtest_dbg_last_rd_data;
  logic [31:0] l_memtest_dbg_last_rsp_status;
  logic [31:0] l_memtest_dbg_fail_arg0;
  logic [31:0] l_memtest_dbg_fail_arg1;
  logic [31:0] l_memtest_dbg_fail_arg2;
  logic [31:0] l_memtest_dbg_fail_ctx_arg0;
  logic [31:0] l_memtest_dbg_fail_ctx_arg1;
  logic [31:0] l_memtest_dbg_fail_ctx_arg2;
  logic [31:0] r_word_ctrl_dbg_summary_snap;
  logic [31:0] r_word_ctrl_dbg_data_snap;
  logic [31:0] r_byte_ctrl_dbg_summary_snap;
  logic [31:0] r_byte_ctrl_dbg_detail_snap;
  logic        r_fail_dbg_snapshot_valid;
  logic [3:0]  s_memtest_state;
  logic [31:0] s_status_word_ctrl_summary;
  logic [31:0] s_status_word_ctrl_data;
  logic [31:0] s_status_byte_ctrl_summary;
  logic [31:0] s_status_byte_ctrl_detail;

  assign O_INIT_DONE = I_INIT_DONE;

  assign O_REQ_VALID    = l_test_req_valid;
  assign O_REQ_IS_WRITE = l_test_req_is_write;
  assign O_REQ_ADDR     = l_test_req_addr;
  assign O_REQ_WR_DATA  = l_test_req_wr_data;
  assign O_REQ_WR_BE    = l_test_req_wr_be;
  assign O_RSP_READY    = l_test_rsp_ready;

  assign l_test_req_ready   = I_REQ_READY;
  assign l_test_rsp_valid   = I_RSP_VALID;
  assign l_test_rsp_rd_data = I_RSP_RD_DATA;
  assign l_test_rsp_status  = I_RSP_STATUS;

  assign O_RAW_RX_BYPASS = 1'b0;
  assign O_RAW_TX_MODE   = 1'b0;
  assign O_RAW_TX_VALID  = 1'b0;
  assign O_RAW_TX_DATA   = 8'h00;
  assign s_memtest_state = l_memtest_dbg_summary[31:28];
  assign s_status_word_ctrl_summary =
    r_fail_dbg_snapshot_valid ? r_word_ctrl_dbg_summary_snap : I_WORD_CTRL_DBG_SUMMARY;
  assign s_status_word_ctrl_data =
    r_fail_dbg_snapshot_valid ? r_word_ctrl_dbg_data_snap : I_WORD_CTRL_DBG_DATA;
  assign s_status_byte_ctrl_summary =
    r_fail_dbg_snapshot_valid ? r_byte_ctrl_dbg_summary_snap : I_BYTE_CTRL_DBG_SUMMARY;
  assign s_status_byte_ctrl_detail =
    r_fail_dbg_snapshot_valid ? r_byte_ctrl_dbg_detail_snap : I_BYTE_CTRL_DBG_DETAIL;

  sdram_memtest_ctrl #(
    .CLK_HZ(MEMTEST_CLK_HZ),
    .MEMTEST_BURST_WORDS(MEMTEST_BURST_WORDS),
    .MEMTEST_TOTAL_WORDS(MEMTEST_TOTAL_WORDS),
    .POST_INIT_WAIT_CYCLES(MEMTEST_POST_INIT_WAIT_CYCLES),
    .POST_WRITE_TO_READ_GAP_CYCLES(MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES)
  ) u_sdram_memtest_ctrl (
    .I_CLK       (I_CLK),
    .I_RST_N     (I_RST_N),
    .I_INIT_DONE (I_INIT_DONE),
    .O_REQ_VALID (l_test_req_valid),
    .I_REQ_READY (l_test_req_ready),
    .O_REQ_IS_WRITE(l_test_req_is_write),
    .O_REQ_ADDR  (l_test_req_addr),
    .O_REQ_WR_DATA(l_test_req_wr_data),
    .O_REQ_WR_BE (l_test_req_wr_be),
    .I_RSP_VALID (l_test_rsp_valid),
    .O_RSP_READY (l_test_rsp_ready),
    .I_RSP_RD_DATA(l_test_rsp_rd_data),
    .I_RSP_STATUS(l_test_rsp_status),
    .O_TEST_ACTIVE(O_TEST_ACTIVE),
    .O_TEST_PASS (O_TEST_PASS),
    .O_TEST_FAIL (O_TEST_FAIL),
    .O_DBG_SUMMARY(l_memtest_dbg_summary),
    .O_DBG_CURR_WORD_ADDR(l_memtest_dbg_curr_word_addr),
    .O_DBG_EXPECTED_WORD(l_memtest_dbg_expected_word),
    .O_DBG_LAST_RD_DATA(l_memtest_dbg_last_rd_data),
    .O_DBG_LAST_RSP_STATUS(l_memtest_dbg_last_rsp_status),
    .O_DBG_FAIL_ARG0(l_memtest_dbg_fail_arg0),
    .O_DBG_FAIL_ARG1(l_memtest_dbg_fail_arg1),
    .O_DBG_FAIL_ARG2(l_memtest_dbg_fail_arg2),
    .O_DBG_FAIL_CTX_ARG0(l_memtest_dbg_fail_ctx_arg0),
    .O_DBG_FAIL_CTX_ARG1(l_memtest_dbg_fail_ctx_arg1),
    .O_DBG_FAIL_CTX_ARG2(l_memtest_dbg_fail_ctx_arg2),
    .O_EVT_VALID (O_TEST_EVT_VALID),
    .O_EVT_ID    (O_TEST_EVT_ID),
    .O_EVT_ARG0  (O_TEST_EVT_ARG0),
    .O_EVT_ARG1  (O_TEST_EVT_ARG1),
    .O_EVT_ARG2  (O_TEST_EVT_ARG2)
  );

  sdram_uart_bridge_ctrl u_sdram_uart_bridge_ctrl (
    .I_CLK        (I_CLK),
    .I_RST_N      (I_RST_N),
    .I_ENABLE     (1'b1),
    .I_CLI_RX_VALID(I_CLI_RX_VALID),
    .I_CLI_RX_DATA(I_CLI_RX_DATA),
    .O_RAW_RX_BYPASS(),
    .O_RAW_TX_MODE(),
    .O_RAW_TX_VALID(),
    .O_RAW_TX_DATA(),
    .I_RAW_TX_READY(I_RAW_TX_READY),
    .I_STATUS_INIT_DONE(I_INIT_DONE),
    .I_STATUS_TEST_ACTIVE(O_TEST_ACTIVE),
    .I_STATUS_TEST_PASS(O_TEST_PASS),
    .I_STATUS_TEST_FAIL(O_TEST_FAIL),
    .I_STATUS_HOST_BUSY(O_HOST_BUSY),
    .I_STATUS_MEMTEST_SUMMARY(l_memtest_dbg_summary),
    .I_STATUS_MEMTEST_CURR_WORD_ADDR(l_memtest_dbg_curr_word_addr),
    .I_STATUS_MEMTEST_EXPECTED_WORD(l_memtest_dbg_expected_word),
    .I_STATUS_MEMTEST_LAST_RD_DATA(l_memtest_dbg_last_rd_data),
    .I_STATUS_MEMTEST_LAST_RSP_STATUS(l_memtest_dbg_last_rsp_status),
    .I_STATUS_MEMTEST_FAIL_ARG0(l_memtest_dbg_fail_arg0),
    .I_STATUS_MEMTEST_FAIL_ARG1(l_memtest_dbg_fail_arg1),
    .I_STATUS_MEMTEST_FAIL_ARG2(l_memtest_dbg_fail_arg2),
    .I_STATUS_MEMTEST_FAIL_CTX_ARG0(l_memtest_dbg_fail_ctx_arg0),
    .I_STATUS_MEMTEST_FAIL_CTX_ARG1(l_memtest_dbg_fail_ctx_arg1),
    .I_STATUS_MEMTEST_FAIL_CTX_ARG2(l_memtest_dbg_fail_ctx_arg2),
    .I_STATUS_WORD_CTRL_SUMMARY(s_status_word_ctrl_summary),
    .I_STATUS_WORD_CTRL_DATA(s_status_word_ctrl_data),
    .I_STATUS_BYTE_CTRL_SUMMARY(s_status_byte_ctrl_summary),
    .I_STATUS_BYTE_CTRL_DETAIL(s_status_byte_ctrl_detail),
    .O_EVT_VALID  (O_HOST_EVT_VALID),
    .O_EVT_ID     (O_HOST_EVT_ID),
    .O_EVT_ARG0   (O_HOST_EVT_ARG0),
    .O_EVT_ARG1   (O_HOST_EVT_ARG1),
    .O_EVT_ARG2   (O_HOST_EVT_ARG2),
    .I_EVT_READY  (I_HOST_EVT_READY),
    .O_CMD_BUSY   (O_HOST_BUSY)
  );

  // Latches wrapper debug words at the first detected self-test failure so the
  // host can inspect the exact failing transaction after the wrappers return idle.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_word_ctrl_dbg_summary_snap <= 32'h0000_0000;
      r_word_ctrl_dbg_data_snap    <= 32'h0000_0000;
      r_byte_ctrl_dbg_summary_snap <= 32'h0000_0000;
      r_byte_ctrl_dbg_detail_snap  <= 32'h0000_0000;
      r_fail_dbg_snapshot_valid    <= 1'b0;
    end else begin
      if (s_memtest_state == 4'h0) begin
        r_word_ctrl_dbg_summary_snap <= 32'h0000_0000;
        r_word_ctrl_dbg_data_snap    <= 32'h0000_0000;
        r_byte_ctrl_dbg_summary_snap <= 32'h0000_0000;
        r_byte_ctrl_dbg_detail_snap  <= 32'h0000_0000;
        r_fail_dbg_snapshot_valid    <= 1'b0;
      end else if (!r_fail_dbg_snapshot_valid && O_TEST_FAIL) begin
        r_word_ctrl_dbg_summary_snap <= I_WORD_CTRL_DBG_SUMMARY;
        r_word_ctrl_dbg_data_snap    <= I_WORD_CTRL_DBG_DATA;
        r_byte_ctrl_dbg_summary_snap <= I_BYTE_CTRL_DBG_SUMMARY;
        r_byte_ctrl_dbg_detail_snap  <= I_BYTE_CTRL_DBG_DETAIL;
        r_fail_dbg_snapshot_valid    <= 1'b1;
      end
    end
  end

endmodule
