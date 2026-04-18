`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_emb_hostif_ctrl.sv
// Description  : Shared embedded SDRAM host/test controller without SDRAM IP.
//                - Owns startup self-test on the vendor SDRC user interface.
//                - Exposes a read-only debug status-map to uart_log_cli.
//                - Intentionally disables host SDRAM read/write during debug.
//////////////////////////////////////////////////////////////////////////////////

module sdram_emb_hostif_ctrl #(
  parameter int unsigned MEMTEST_BURST_WORDS = 26,
  parameter int unsigned MEMTEST_BURST_COUNT = 8,
  parameter int unsigned MEMTEST_POST_INIT_WAIT_CYCLES = 20_000,
  parameter int unsigned MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES = 4,
  parameter int unsigned MEMTEST_CLEAR_WORDS = 2_097_152
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
  input  logic [31:0] I_SDRC_RD_DATA,
  input  logic        I_SDRC_BUSY_N,
  input  logic        I_SDRC_RD_VALID,
  input  logic        I_SDRC_WRD_ACK,
  input  logic        I_SDRC_INIT_DONE,
  output logic        O_INIT_DONE,
  output logic        O_TEST_ACTIVE,
  output logic        O_TEST_PASS,
  output logic        O_TEST_FAIL,
  output logic        O_HOST_BUSY,
  output logic        O_SDRC_WR_N,
  output logic        O_SDRC_RD_N,
  output logic [20:0] O_SDRC_ADDR,
  output logic [7:0]  O_SDRC_DATA_LEN,
  output logic [3:0]  O_SDRC_DQM,
  output logic [31:0] O_SDRC_WR_DATA
);

  logic        l_test_wr_n;
  logic        l_test_rd_n;
  logic [20:0] l_test_addr;
  logic [7:0]  l_test_data_len;
  logic [3:0]  l_test_dqm;
  logic [31:0] l_test_wr_data;

  logic [15:0] l_status_addr;
  logic [31:0] l_status_rd_data;

  logic [31:0] l_memtest_summary;
  logic [7:0]  l_memtest_state;
  logic [7:0]  l_memtest_fail_reason;
  logic [20:0] l_memtest_curr_addr;
  logic [31:0] l_memtest_expected;
  logic [31:0] l_memtest_last_read;
  logic [31:0] l_memtest_last_status;
  logic [31:0] l_memtest_fail_addr;
  logic [31:0] l_memtest_fail_expected;
  logic [31:0] l_memtest_fail_actual;
  logic [31:0] l_memtest_retry_summary;
  logic [31:0] l_memtest_retry_data1;
  logic [31:0] l_memtest_retry_data2;
  logic [31:0] l_memtest_ctrl_summary;
  logic [31:0] l_memtest_ctrl_detail;

  assign O_INIT_DONE      = I_SDRC_INIT_DONE;
  assign O_RAW_RX_BYPASS  = 1'b0;
  assign O_RAW_TX_MODE    = 1'b0;
  assign O_RAW_TX_VALID   = 1'b0;
  assign O_RAW_TX_DATA    = 8'h00;

  // Self-test is the only producer of SDRC traffic in this debug configuration.
  assign O_SDRC_WR_N      = l_test_wr_n;
  assign O_SDRC_RD_N      = l_test_rd_n;
  assign O_SDRC_ADDR      = l_test_addr;
  assign O_SDRC_DATA_LEN  = l_test_data_len;
  assign O_SDRC_DQM       = l_test_dqm;
  assign O_SDRC_WR_DATA   = l_test_wr_data;

  sdram_memtest_ctrl #(
    .BURST_WORDS(MEMTEST_BURST_WORDS),
    .BURST_COUNT(MEMTEST_BURST_COUNT),
    .POST_INIT_WAIT_CYCLES(MEMTEST_POST_INIT_WAIT_CYCLES),
    .POST_WRITE_TO_READ_GAP_CYCLES(MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES),
    .CLEAR_WORDS(MEMTEST_CLEAR_WORDS)
  ) u_sdram_memtest_ctrl (
    .I_CLK                (I_CLK),
    .I_RST_N              (I_RST_N),
    .I_SDRC_INIT_DONE     (I_SDRC_INIT_DONE),
    .I_SDRC_BUSY_N        (I_SDRC_BUSY_N),
    .I_SDRC_WRD_ACK       (I_SDRC_WRD_ACK),
    .I_SDRC_RD_VALID      (I_SDRC_RD_VALID),
    .I_SDRC_RD_DATA       (I_SDRC_RD_DATA),
    .O_SDRC_WR_N          (l_test_wr_n),
    .O_SDRC_RD_N          (l_test_rd_n),
    .O_SDRC_ADDR          (l_test_addr),
    .O_SDRC_DATA_LEN      (l_test_data_len),
    .O_SDRC_DQM           (l_test_dqm),
    .O_SDRC_WR_DATA       (l_test_wr_data),
    .O_TEST_ACTIVE        (O_TEST_ACTIVE),
    .O_TEST_PASS          (O_TEST_PASS),
    .O_TEST_FAIL          (O_TEST_FAIL),
    .O_EVT_VALID          (O_TEST_EVT_VALID),
    .O_EVT_ID             (O_TEST_EVT_ID),
    .O_EVT_ARG0           (O_TEST_EVT_ARG0),
    .O_EVT_ARG1           (O_TEST_EVT_ARG1),
    .O_EVT_ARG2           (O_TEST_EVT_ARG2),
    .O_DBG_MEM_SUMMARY    (l_memtest_summary),
    .O_DBG_STATE          (l_memtest_state),
    .O_DBG_FAIL_REASON    (l_memtest_fail_reason),
    .O_DBG_CURRENT_ADDR   (l_memtest_curr_addr),
    .O_DBG_EXPECTED_WORD  (l_memtest_expected),
    .O_DBG_LAST_READ_DATA (l_memtest_last_read),
    .O_DBG_LAST_STATUS    (l_memtest_last_status),
    .O_DBG_FAIL_ADDR      (l_memtest_fail_addr),
    .O_DBG_FAIL_EXPECTED  (l_memtest_fail_expected),
    .O_DBG_FAIL_ACTUAL    (l_memtest_fail_actual),
    .O_DBG_RETRY_SUMMARY  (l_memtest_retry_summary),
    .O_DBG_RETRY_DATA1    (l_memtest_retry_data1),
    .O_DBG_RETRY_DATA2    (l_memtest_retry_data2),
    .O_DBG_CTRL_SUMMARY   (l_memtest_ctrl_summary),
    .O_DBG_CTRL_DETAIL    (l_memtest_ctrl_detail)
  );

  sdram_status_reg_map u_sdram_status_reg_map (
    .I_ADDR                 (l_status_addr),
    .I_INIT_DONE            (I_SDRC_INIT_DONE),
    .I_TEST_ACTIVE          (O_TEST_ACTIVE),
    .I_TEST_PASS            (O_TEST_PASS),
    .I_TEST_FAIL            (O_TEST_FAIL),
    .I_HOST_BUSY            (O_HOST_BUSY),
    .I_SDRC_BUSY_N          (I_SDRC_BUSY_N),
    .I_SDRC_RD_VALID        (I_SDRC_RD_VALID),
    .I_SDRC_WRD_ACK         (I_SDRC_WRD_ACK),
    .I_SDRC_RD_DATA         (I_SDRC_RD_DATA),
    .I_MEMTEST_SUMMARY      (l_memtest_summary),
    .I_MEMTEST_STATE        (l_memtest_state),
    .I_MEMTEST_FAIL_REASON  (l_memtest_fail_reason),
    .I_MEMTEST_CURR_ADDR    (l_memtest_curr_addr),
    .I_MEMTEST_EXPECTED     (l_memtest_expected),
    .I_MEMTEST_LAST_READ    (l_memtest_last_read),
    .I_MEMTEST_LAST_STATUS  (l_memtest_last_status),
    .I_MEMTEST_FAIL_ADDR    (l_memtest_fail_addr),
    .I_MEMTEST_FAIL_EXPECTED(l_memtest_fail_expected),
    .I_MEMTEST_FAIL_ACTUAL  (l_memtest_fail_actual),
    .I_MEMTEST_RETRY_SUMMARY(l_memtest_retry_summary),
    .I_MEMTEST_RETRY_DATA1  (l_memtest_retry_data1),
    .I_MEMTEST_RETRY_DATA2  (l_memtest_retry_data2),
    .I_MEMTEST_CTRL_SUMMARY (l_memtest_ctrl_summary),
    .I_MEMTEST_CTRL_DETAIL  (l_memtest_ctrl_detail),
    .O_RD_DATA              (l_status_rd_data)
  );

  sdram_uart_bridge_ctrl u_sdram_uart_bridge_ctrl (
    .I_CLK           (I_CLK),
    .I_RST_N         (I_RST_N),
    .I_ENABLE        (1'b1),
    .I_CLI_RX_VALID  (I_CLI_RX_VALID),
    .I_CLI_RX_DATA   (I_CLI_RX_DATA),
    .O_RAW_RX_BYPASS (),
    .O_RAW_TX_MODE   (),
    .O_RAW_TX_VALID  (),
    .O_RAW_TX_DATA   (),
    .I_RAW_TX_READY  (I_RAW_TX_READY),
    .I_SDRC_INIT_DONE(I_SDRC_INIT_DONE),
    .I_SDRC_BUSY_N   (I_SDRC_BUSY_N),
    .I_SDRC_WRD_ACK  (I_SDRC_WRD_ACK),
    .I_SDRC_RD_VALID (I_SDRC_RD_VALID),
    .I_SDRC_RD_DATA  (I_SDRC_RD_DATA),
    .I_STATUS_RD_DATA(l_status_rd_data),
    .O_STATUS_ADDR   (l_status_addr),
    .O_SDRC_WR_N     (),
    .O_SDRC_RD_N     (),
    .O_SDRC_ADDR     (),
    .O_SDRC_DATA_LEN (),
    .O_SDRC_DQM      (),
    .O_SDRC_WR_DATA  (),
    .O_EVT_VALID     (O_HOST_EVT_VALID),
    .O_EVT_ID        (O_HOST_EVT_ID),
    .O_EVT_ARG0      (O_HOST_EVT_ARG0),
    .O_EVT_ARG1      (O_HOST_EVT_ARG1),
    .O_EVT_ARG2      (O_HOST_EVT_ARG2),
    .I_EVT_READY     (I_HOST_EVT_READY),
    .O_CMD_BUSY      (O_HOST_BUSY)
  );

endmodule
