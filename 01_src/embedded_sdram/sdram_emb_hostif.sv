`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_emb_hostif.sv
// Description  : Integrated SDRAM subsystem for startup self-test and UART host
//                accesses.
//                - Instantiates the host/self-test arbiter.
//                - Instantiates the native word controller and byte controller.
//////////////////////////////////////////////////////////////////////////////////

module sdram_emb_hostif #(
  parameter int unsigned MEMTEST_CLK_HZ = 48_000_000,
  parameter int unsigned MEMTEST_BURST_WORDS = 256,
  parameter int unsigned MEMTEST_TOTAL_WORDS = 2_097_152,
  parameter int unsigned MEMTEST_POST_INIT_WAIT_CYCLES = 20_000,
  parameter int unsigned MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES = 4
) (
  input  logic        I_CLK,
  input  logic        I_CLK_SDRAM,
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
  output logic        O_INIT_DONE,
  output logic        O_TEST_ACTIVE,
  output logic        O_TEST_PASS,
  output logic        O_TEST_FAIL,
  output logic        O_HOST_BUSY,
  output logic        O_sdram_clk,
  output logic        O_sdram_cke,
  output logic        O_sdram_cs_n,
  output logic        O_sdram_cas_n,
  output logic        O_sdram_ras_n,
  output logic        O_sdram_wen_n,
  output logic [3:0]  O_sdram_dqm,
  output logic [10:0] O_sdram_addr,
  output logic [1:0]  O_sdram_ba,
  inout  wire [31:0]  IO_sdram_dq
);

  logic        l_mem_req_valid;
  logic        l_mem_req_ready;
  logic        l_mem_req_is_write;
  logic [20:0] l_mem_req_addr;
  logic [31:0] l_mem_req_wr_data;
  logic [3:0]  l_mem_req_wr_be;
  logic        l_mem_rsp_valid;
  logic        l_mem_rsp_ready;
  logic [31:0] l_mem_rsp_rd_data;
  logic [31:0] l_mem_rsp_status;

  logic        l_byte_req_valid;
  logic        l_byte_req_ready;
  logic        l_byte_req_is_write;
  logic [22:0] l_byte_req_addr;
  logic [7:0]  l_byte_req_wr_data;
  logic        l_byte_rsp_valid;
  logic        l_byte_rsp_ready;
  logic [7:0]  l_byte_rsp_rd_data;
  logic [31:0] l_byte_rsp_status;
  logic        l_init_done;
  logic [31:0] l_word_ctrl_dbg_summary;
  logic [31:0] l_word_ctrl_dbg_data;
  logic [31:0] l_byte_ctrl_dbg_summary;
  logic [31:0] l_byte_ctrl_dbg_detail;

  sdram_emb_hostif_ctrl #(
    .MEMTEST_CLK_HZ(MEMTEST_CLK_HZ),
    .MEMTEST_BURST_WORDS(MEMTEST_BURST_WORDS),
    .MEMTEST_TOTAL_WORDS(MEMTEST_TOTAL_WORDS),
    .MEMTEST_POST_INIT_WAIT_CYCLES(MEMTEST_POST_INIT_WAIT_CYCLES),
    .MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES(MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES)
  ) u_sdram_emb_hostif_ctrl (
    .I_CLK        (I_CLK),
    .I_RST_N      (I_RST_N),
    .I_CLI_RX_VALID(I_CLI_RX_VALID),
    .I_CLI_RX_DATA(I_CLI_RX_DATA),
    .O_RAW_RX_BYPASS(O_RAW_RX_BYPASS),
    .O_RAW_TX_MODE(O_RAW_TX_MODE),
    .O_RAW_TX_VALID(O_RAW_TX_VALID),
    .O_RAW_TX_DATA(O_RAW_TX_DATA),
    .I_RAW_TX_READY(I_RAW_TX_READY),
    .O_TEST_EVT_VALID(O_TEST_EVT_VALID),
    .O_TEST_EVT_ID (O_TEST_EVT_ID),
    .O_TEST_EVT_ARG0(O_TEST_EVT_ARG0),
    .O_TEST_EVT_ARG1(O_TEST_EVT_ARG1),
    .O_TEST_EVT_ARG2(O_TEST_EVT_ARG2),
    .I_TEST_EVT_READY(I_TEST_EVT_READY),
    .O_HOST_EVT_VALID(O_HOST_EVT_VALID),
    .O_HOST_EVT_ID (O_HOST_EVT_ID),
    .O_HOST_EVT_ARG0(O_HOST_EVT_ARG0),
    .O_HOST_EVT_ARG1(O_HOST_EVT_ARG1),
    .O_HOST_EVT_ARG2(O_HOST_EVT_ARG2),
    .I_HOST_EVT_READY(I_HOST_EVT_READY),
    .I_INIT_DONE  (l_init_done),
    .O_INIT_DONE  (),
    .O_TEST_ACTIVE(O_TEST_ACTIVE),
    .O_TEST_PASS  (O_TEST_PASS),
    .O_TEST_FAIL  (O_TEST_FAIL),
    .O_HOST_BUSY  (O_HOST_BUSY),
    .I_WORD_CTRL_DBG_SUMMARY(l_word_ctrl_dbg_summary),
    .I_WORD_CTRL_DBG_DATA(l_word_ctrl_dbg_data),
    .I_BYTE_CTRL_DBG_SUMMARY(l_byte_ctrl_dbg_summary),
    .I_BYTE_CTRL_DBG_DETAIL(l_byte_ctrl_dbg_detail),
    .O_REQ_VALID  (l_mem_req_valid),
    .I_REQ_READY  (l_mem_req_ready),
    .O_REQ_IS_WRITE(l_mem_req_is_write),
    .O_REQ_ADDR   (l_mem_req_addr),
    .O_REQ_WR_DATA(l_mem_req_wr_data),
    .O_REQ_WR_BE  (l_mem_req_wr_be),
    .I_RSP_VALID  (l_mem_rsp_valid),
    .O_RSP_READY  (l_mem_rsp_ready),
    .I_RSP_RD_DATA(l_mem_rsp_rd_data),
    .I_RSP_STATUS (l_mem_rsp_status)
  );

  sdram_open_word_ctrl u_sdram_open_word_ctrl (
    .I_CLK       (I_CLK),
    .I_RST_N     (I_RST_N),
    .I_INIT_DONE (l_init_done),
    .I_REQ_VALID (l_mem_req_valid),
    .O_REQ_READY (l_mem_req_ready),
    .I_REQ_IS_WRITE(l_mem_req_is_write),
    .I_REQ_ADDR  (l_mem_req_addr),
    .I_REQ_WR_DATA(l_mem_req_wr_data),
    .I_REQ_WR_BE (l_mem_req_wr_be),
    .O_RSP_VALID (l_mem_rsp_valid),
    .I_RSP_READY (l_mem_rsp_ready),
    .O_RSP_RD_DATA(l_mem_rsp_rd_data),
    .O_RSP_STATUS(l_mem_rsp_status),
    .O_DBG_SUMMARY(l_word_ctrl_dbg_summary),
    .O_DBG_DATA  (l_word_ctrl_dbg_data),
    .O_BYTE_REQ_VALID(l_byte_req_valid),
    .I_BYTE_REQ_READY(l_byte_req_ready),
    .O_BYTE_REQ_IS_WRITE(l_byte_req_is_write),
    .O_BYTE_REQ_ADDR(l_byte_req_addr),
    .O_BYTE_REQ_WR_DATA(l_byte_req_wr_data),
    .I_BYTE_RSP_VALID(l_byte_rsp_valid),
    .O_BYTE_RSP_READY(l_byte_rsp_ready),
    .I_BYTE_RSP_RD_DATA(l_byte_rsp_rd_data),
    .I_BYTE_RSP_STATUS(l_byte_rsp_status)
  );

  sdram_open_byte_ctrl u_sdram_open_byte_ctrl (
    .I_CLK       (I_CLK),
    .I_CLK_SDRAM (I_CLK_SDRAM),
    .I_RST_N     (I_RST_N),
    .I_REQ_VALID (l_byte_req_valid),
    .O_REQ_READY (l_byte_req_ready),
    .I_REQ_IS_WRITE(l_byte_req_is_write),
    .I_REQ_ADDR  (l_byte_req_addr),
    .I_REQ_WR_DATA(l_byte_req_wr_data),
    .O_RSP_VALID (l_byte_rsp_valid),
    .I_RSP_READY (l_byte_rsp_ready),
    .O_RSP_RD_DATA(l_byte_rsp_rd_data),
    .O_RSP_STATUS(l_byte_rsp_status),
    .O_INIT_DONE (l_init_done),
    .O_DBG_SUMMARY(l_byte_ctrl_dbg_summary),
    .O_DBG_DETAIL(l_byte_ctrl_dbg_detail),
    .O_sdram_clk (O_sdram_clk),
    .O_sdram_cke (O_sdram_cke),
    .O_sdram_cs_n(O_sdram_cs_n),
    .O_sdram_cas_n(O_sdram_cas_n),
    .O_sdram_ras_n(O_sdram_ras_n),
    .O_sdram_wen_n(O_sdram_wen_n),
    .O_sdram_dqm (O_sdram_dqm),
    .O_sdram_addr(O_sdram_addr),
    .O_sdram_ba  (O_sdram_ba),
    .IO_sdram_dq (IO_sdram_dq)
  );

  assign O_INIT_DONE = l_init_done;

endmodule
