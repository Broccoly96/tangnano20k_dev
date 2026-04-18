`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_emb_hostif_ctrl.sv
// Description  : Shared SDRAM host/self-test controller on the native word
//                request interface.
//                - Owns startup memtest.
//                - Hands the memory port to the UART host after PASS/FAIL.
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

  logic l_host_enable;
  logic l_exec_owner_host;

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

  logic        l_host_req_valid;
  logic        l_host_req_ready;
  logic        l_host_req_is_write;
  logic [20:0] l_host_req_addr;
  logic [31:0] l_host_req_wr_data;
  logic [3:0]  l_host_req_wr_be;
  logic        l_host_rsp_valid;
  logic        l_host_rsp_ready;
  logic [31:0] l_host_rsp_rd_data;
  logic [31:0] l_host_rsp_status;

  assign l_host_enable     = O_TEST_PASS || O_TEST_FAIL;
  assign l_exec_owner_host = l_host_enable;

  assign O_INIT_DONE = I_INIT_DONE;
  assign O_REQ_VALID    = l_exec_owner_host ? l_host_req_valid    : l_test_req_valid;
  assign O_REQ_IS_WRITE = l_exec_owner_host ? l_host_req_is_write : l_test_req_is_write;
  assign O_REQ_ADDR     = l_exec_owner_host ? l_host_req_addr     : l_test_req_addr;
  assign O_REQ_WR_DATA  = l_exec_owner_host ? l_host_req_wr_data  : l_test_req_wr_data;
  assign O_REQ_WR_BE    = l_exec_owner_host ? l_host_req_wr_be    : l_test_req_wr_be;
  assign O_RSP_READY    = l_exec_owner_host ? l_host_rsp_ready    : l_test_rsp_ready;

  assign l_test_req_ready   = l_exec_owner_host ? 1'b0           : I_REQ_READY;
  assign l_test_rsp_valid   = l_exec_owner_host ? 1'b0           : I_RSP_VALID;
  assign l_test_rsp_rd_data = l_exec_owner_host ? 32'h0000_0000  : I_RSP_RD_DATA;
  assign l_test_rsp_status  = l_exec_owner_host ? 32'h0000_0000  : I_RSP_STATUS;

  assign l_host_req_ready   = l_exec_owner_host ? I_REQ_READY    : 1'b0;
  assign l_host_rsp_valid   = l_exec_owner_host ? I_RSP_VALID     : 1'b0;
  assign l_host_rsp_rd_data = l_exec_owner_host ? I_RSP_RD_DATA   : 32'h0000_0000;
  assign l_host_rsp_status  = l_exec_owner_host ? I_RSP_STATUS    : 32'h0000_0000;

  assign O_RAW_RX_BYPASS = 1'b0;
  assign O_RAW_TX_MODE   = 1'b0;
  assign O_RAW_TX_VALID  = 1'b0;
  assign O_RAW_TX_DATA   = 8'h00;

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
    .O_EVT_VALID (O_TEST_EVT_VALID),
    .O_EVT_ID    (O_TEST_EVT_ID),
    .O_EVT_ARG0  (O_TEST_EVT_ARG0),
    .O_EVT_ARG1  (O_TEST_EVT_ARG1),
    .O_EVT_ARG2  (O_TEST_EVT_ARG2)
  );

  sdram_uart_bridge_ctrl u_sdram_uart_bridge_ctrl (
    .I_CLK        (I_CLK),
    .I_RST_N      (I_RST_N),
    .I_ENABLE     (l_host_enable),
    .I_CLI_RX_VALID(I_CLI_RX_VALID),
    .I_CLI_RX_DATA(I_CLI_RX_DATA),
    .O_RAW_RX_BYPASS(),
    .O_RAW_TX_MODE(),
    .O_RAW_TX_VALID(),
    .O_RAW_TX_DATA(),
    .I_RAW_TX_READY(I_RAW_TX_READY),
    .I_INIT_DONE  (I_INIT_DONE),
    .O_REQ_VALID  (l_host_req_valid),
    .I_REQ_READY  (l_host_req_ready),
    .O_REQ_IS_WRITE(l_host_req_is_write),
    .O_REQ_ADDR   (l_host_req_addr),
    .O_REQ_WR_DATA(l_host_req_wr_data),
    .O_REQ_WR_BE  (l_host_req_wr_be),
    .I_RSP_VALID  (l_host_rsp_valid),
    .O_RSP_READY  (l_host_rsp_ready),
    .I_RSP_RD_DATA(l_host_rsp_rd_data),
    .I_RSP_STATUS (l_host_rsp_status),
    .O_EVT_VALID  (O_HOST_EVT_VALID),
    .O_EVT_ID     (O_HOST_EVT_ID),
    .O_EVT_ARG0   (O_HOST_EVT_ARG0),
    .O_EVT_ARG1   (O_HOST_EVT_ARG1),
    .O_EVT_ARG2   (O_HOST_EVT_ARG2),
    .I_EVT_READY  (I_HOST_EVT_READY),
    .O_CMD_BUSY   (O_HOST_BUSY)
  );

endmodule
