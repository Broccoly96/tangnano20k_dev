`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_emb_hostif.sv
// Description  : Legacy wrapper shell kept for compatibility.
//                The active top-level path instantiates `embedded_sdram`
//                directly and uses `sdram_emb_hostif_ctrl` for control.
//                This wrapper keeps the same public ports but does not own a
//                vendor IP instance in the current debug-oriented flow.
//////////////////////////////////////////////////////////////////////////////////

module sdram_emb_hostif (
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

  logic [31:0] l_sdrc_rd_data;
  logic        l_sdrc_busy_n;
  logic        l_sdrc_rd_valid;
  logic        l_sdrc_wrd_ack;
  logic        l_sdrc_init_done;
  logic        l_sdrc_wr_n;
  logic        l_sdrc_rd_n;
  logic [20:0] l_sdrc_addr;
  logic [7:0]  l_sdrc_data_len;
  logic [3:0]  l_sdrc_dqm;
  logic [31:0] l_sdrc_wr_data;

  assign l_sdrc_rd_data  = 32'h0000_0000;
  assign l_sdrc_busy_n   = 1'b1;
  assign l_sdrc_rd_valid = 1'b0;
  assign l_sdrc_wrd_ack  = 1'b0;
  assign l_sdrc_init_done = 1'b0;

  assign O_sdram_clk   = 1'b0;
  assign O_sdram_cke   = 1'b0;
  assign O_sdram_cs_n  = 1'b1;
  assign O_sdram_cas_n = 1'b1;
  assign O_sdram_ras_n = 1'b1;
  assign O_sdram_wen_n = 1'b1;
  assign O_sdram_dqm   = 4'hF;
  assign O_sdram_addr  = 11'h000;
  assign O_sdram_ba    = 2'b00;
  assign IO_sdram_dq   = 32'hZZZZ_ZZZZ;

  sdram_emb_hostif_ctrl u_sdram_emb_hostif_ctrl (
    .I_CLK           (I_CLK),
    .I_RST_N         (I_RST_N),
    .I_CLI_RX_VALID  (I_CLI_RX_VALID),
    .I_CLI_RX_DATA   (I_CLI_RX_DATA),
    .O_RAW_RX_BYPASS (O_RAW_RX_BYPASS),
    .O_RAW_TX_MODE   (O_RAW_TX_MODE),
    .O_RAW_TX_VALID  (O_RAW_TX_VALID),
    .O_RAW_TX_DATA   (O_RAW_TX_DATA),
    .I_RAW_TX_READY  (I_RAW_TX_READY),
    .O_TEST_EVT_VALID(O_TEST_EVT_VALID),
    .O_TEST_EVT_ID   (O_TEST_EVT_ID),
    .O_TEST_EVT_ARG0 (O_TEST_EVT_ARG0),
    .O_TEST_EVT_ARG1 (O_TEST_EVT_ARG1),
    .O_TEST_EVT_ARG2 (O_TEST_EVT_ARG2),
    .I_TEST_EVT_READY(I_TEST_EVT_READY),
    .O_HOST_EVT_VALID(O_HOST_EVT_VALID),
    .O_HOST_EVT_ID   (O_HOST_EVT_ID),
    .O_HOST_EVT_ARG0 (O_HOST_EVT_ARG0),
    .O_HOST_EVT_ARG1 (O_HOST_EVT_ARG1),
    .O_HOST_EVT_ARG2 (O_HOST_EVT_ARG2),
    .I_HOST_EVT_READY(I_HOST_EVT_READY),
    .I_SDRC_RD_DATA  (l_sdrc_rd_data),
    .I_SDRC_BUSY_N   (l_sdrc_busy_n),
    .I_SDRC_RD_VALID (l_sdrc_rd_valid),
    .I_SDRC_WRD_ACK  (l_sdrc_wrd_ack),
    .I_SDRC_INIT_DONE(l_sdrc_init_done),
    .O_INIT_DONE     (O_INIT_DONE),
    .O_TEST_ACTIVE   (O_TEST_ACTIVE),
    .O_TEST_PASS     (O_TEST_PASS),
    .O_TEST_FAIL     (O_TEST_FAIL),
    .O_HOST_BUSY     (O_HOST_BUSY),
    .O_SDRC_WR_N     (l_sdrc_wr_n),
    .O_SDRC_RD_N     (l_sdrc_rd_n),
    .O_SDRC_ADDR     (l_sdrc_addr),
    .O_SDRC_DATA_LEN (l_sdrc_data_len),
    .O_SDRC_DQM      (l_sdrc_dqm),
    .O_SDRC_WR_DATA  (l_sdrc_wr_data)
  );

endmodule
