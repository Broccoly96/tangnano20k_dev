`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_emb_hostif.sv
// Description  : Shared embedded SDRAM wrapper for
//                - startup self-test source
//                - UART host read/write source
//                One SDRAM IP instance is shared between the two controllers.
//////////////////////////////////////////////////////////////////////////////////

module sdram_emb_hostif (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_CLI_RX_VALID,
  input  logic [7:0]  I_CLI_RX_DATA,
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

  logic        l_test_wr_n;
  logic        l_test_rd_n;
  logic [20:0] l_test_addr;
  logic [7:0]  l_test_data_len;
  logic [3:0]  l_test_dqm;
  logic [31:0] l_test_wr_data;

  logic        l_host_wr_n;
  logic        l_host_rd_n;
  logic [20:0] l_host_addr;
  logic [7:0]  l_host_data_len;
  logic [3:0]  l_host_dqm;
  logic [31:0] l_host_wr_data;

  logic [31:0] l_sdrc_rd_data;
  logic        l_sdrc_busy_n;
  logic        l_sdrc_rd_valid;
  logic        l_sdrc_wrd_ack;

  logic        l_host_enable;

  assign l_host_enable = O_TEST_PASS || O_TEST_FAIL;

  sdram_memtest_ctrl u_sdram_memtest_ctrl (
    .I_CLK           (I_CLK),
    .I_RST_N         (I_RST_N),
    .I_SDRC_INIT_DONE(O_INIT_DONE),
    .I_SDRC_BUSY_N   (l_sdrc_busy_n),
    .I_SDRC_WRD_ACK  (l_sdrc_wrd_ack),
    .I_SDRC_RD_VALID (l_sdrc_rd_valid),
    .I_SDRC_RD_DATA  (l_sdrc_rd_data),
    .O_SDRC_WR_N     (l_test_wr_n),
    .O_SDRC_RD_N     (l_test_rd_n),
    .O_SDRC_ADDR     (l_test_addr),
    .O_SDRC_DATA_LEN (l_test_data_len),
    .O_SDRC_DQM      (l_test_dqm),
    .O_SDRC_WR_DATA  (l_test_wr_data),
    .O_TEST_ACTIVE   (O_TEST_ACTIVE),
    .O_TEST_PASS     (O_TEST_PASS),
    .O_TEST_FAIL     (O_TEST_FAIL),
    .O_EVT_VALID     (O_TEST_EVT_VALID),
    .O_EVT_ID        (O_TEST_EVT_ID),
    .O_EVT_ARG0      (O_TEST_EVT_ARG0),
    .O_EVT_ARG1      (O_TEST_EVT_ARG1),
    .O_EVT_ARG2      (O_TEST_EVT_ARG2)
  );

  sdram_uart_bridge_ctrl u_sdram_uart_bridge_ctrl (
    .I_CLK           (I_CLK),
    .I_RST_N         (I_RST_N),
    .I_ENABLE        (l_host_enable),
    .I_CLI_RX_VALID  (I_CLI_RX_VALID),
    .I_CLI_RX_DATA   (I_CLI_RX_DATA),
    .I_SDRC_INIT_DONE(O_INIT_DONE),
    .I_SDRC_BUSY_N   (l_sdrc_busy_n),
    .I_SDRC_RD_VALID (l_sdrc_rd_valid),
    .I_SDRC_RD_DATA  (l_sdrc_rd_data),
    .O_SDRC_WR_N     (l_host_wr_n),
    .O_SDRC_RD_N     (l_host_rd_n),
    .O_SDRC_ADDR     (l_host_addr),
    .O_SDRC_DATA_LEN (l_host_data_len),
    .O_SDRC_DQM      (l_host_dqm),
    .O_SDRC_WR_DATA  (l_host_wr_data),
    .O_EVT_VALID     (O_HOST_EVT_VALID),
    .O_EVT_ID        (O_HOST_EVT_ID),
    .O_EVT_ARG0      (O_HOST_EVT_ARG0),
    .O_EVT_ARG1      (O_HOST_EVT_ARG1),
    .O_EVT_ARG2      (O_HOST_EVT_ARG2),
    .I_EVT_READY     (I_HOST_EVT_READY),
    .O_CMD_BUSY      (O_HOST_BUSY)
  );

  embedded_sdram u_embedded_sdram (
    .O_sdram_clk        (O_sdram_clk),
    .O_sdram_cke        (O_sdram_cke),
    .O_sdram_cs_n       (O_sdram_cs_n),
    .O_sdram_cas_n      (O_sdram_cas_n),
    .O_sdram_ras_n      (O_sdram_ras_n),
    .O_sdram_wen_n      (O_sdram_wen_n),
    .O_sdram_dqm        (O_sdram_dqm),
    .O_sdram_addr       (O_sdram_addr),
    .O_sdram_ba         (O_sdram_ba),
    .IO_sdram_dq        (IO_sdram_dq),
    .I_sdrc_rst_n       (I_RST_N),
    .I_sdrc_clk         (I_CLK),
    .I_sdram_clk        (I_CLK),
    .I_sdrc_selfrefresh (1'b0),
    .I_sdrc_power_down  (1'b0),
    .I_sdrc_wr_n        (l_host_enable ? l_host_wr_n : l_test_wr_n),
    .I_sdrc_rd_n        (l_host_enable ? l_host_rd_n : l_test_rd_n),
    .I_sdrc_addr        (l_host_enable ? l_host_addr : l_test_addr),
    .I_sdrc_data_len    (l_host_enable ? l_host_data_len : l_test_data_len),
    .I_sdrc_dqm         (l_host_enable ? l_host_dqm : l_test_dqm),
    .I_sdrc_data        (l_host_enable ? l_host_wr_data : l_test_wr_data),
    .O_sdrc_data        (l_sdrc_rd_data),
    .O_sdrc_init_done   (O_INIT_DONE),
    .O_sdrc_busy_n      (l_sdrc_busy_n),
    .O_sdrc_rd_valid    (l_sdrc_rd_valid),
    .O_sdrc_wrd_ack     (l_sdrc_wrd_ack)
  );

endmodule
