`timescale 1ns / 1ps

module testbench;

  import uart_log_cli_tb_pkg::*;
  import tb_log_pkg::*;

  localparam int unsigned CLK_24M_HZ = 24_000_000;
  localparam int unsigned CLK_100M_HZ = 48_000_000;
  localparam int unsigned BAUD = 115_200;
  localparam int unsigned NUM_SRC = 2;
  localparam int unsigned TESTSRC_PERIOD_CYCLES = 120_000;
  localparam time CLK_24M_PERIOD = 41667ps;
  localparam time CLK_100M_PERIOD = 20833ps;
  localparam time UART_BIT_PERIOD = 8681ns;

  logic tb_clk_24m;
  logic tb_clk_100m;
  logic tb_rst_24m_n;
  logic tb_rst_100m_n;
  logic tb_uart_rx;
  logic tb_uart_tx;
  logic tb_mirror_valid;
  logic [7:0] tb_mirror_data;
  logic tb_soft_reset_req;

  logic [NUM_SRC-1:0] tb_src_evt_valid;
  logic [NUM_SRC*8-1:0] tb_src_evt_id;
  logic [NUM_SRC*32-1:0] tb_src_arg0;
  logic [NUM_SRC*32-1:0] tb_src_arg1;
  logic [NUM_SRC*32-1:0] tb_src_arg2;
  logic [NUM_SRC-1:0] tb_src_evt_ready;
  logic [NUM_SRC-1:0] tb_src_enable;

  logic tb_src0_evt_valid_24m;
  logic [7:0] tb_src0_evt_id_24m;
  logic [31:0] tb_src0_arg0_24m;
  logic [31:0] tb_src0_arg1_24m;
  logic [31:0] tb_src0_arg2_24m;
  logic tb_src0_enable_24m;
  logic tb_src0_evt_ready_24m;
  logic tb_src0_evt_valid_100m;
  logic [7:0] tb_src0_evt_id_100m;
  logic [31:0] tb_src0_arg0_100m;
  logic [31:0] tb_src0_arg1_100m;
  logic [31:0] tb_src0_arg2_100m;
  logic tb_src1_evt_valid_100m;
  logic [7:0] tb_src1_evt_id_100m;
  logic [31:0] tb_src1_arg0_100m;
  logic [31:0] tb_src1_arg1_100m;
  logic [31:0] tb_src1_arg2_100m;
  logic tb_sdram_init_done;
  logic tb_sdram_test_active;
  logic tb_sdram_test_pass;
  logic tb_sdram_test_fail;
  logic tb_sdram_clk;
  logic tb_sdram_cke;
  logic tb_sdram_cs_n;
  logic tb_sdram_cas_n;
  logic tb_sdram_ras_n;
  logic tb_sdram_wen_n;
  logic [3:0] tb_sdram_dqm;
  logic [10:0] tb_sdram_addr;
  logic [1:0] tb_sdram_ba;
  wire [31:0] tb_sdram_dq;

  localparam int unsigned DQ_BITS = 16;
  localparam int unsigned DQS_BITS = 2;
  localparam int unsigned NUM_DRAM = 2;

  assign tb_src_evt_valid[0] = tb_src0_evt_valid_100m;
  assign tb_src_evt_valid[1] = tb_src1_evt_valid_100m;
  assign tb_src_evt_id[7:0] = tb_src0_evt_id_100m;
  assign tb_src_evt_id[15:8] = tb_src1_evt_id_100m;
  assign tb_src_arg0[31:0] = tb_src0_arg0_100m;
  assign tb_src_arg0[63:32] = tb_src1_arg0_100m;
  assign tb_src_arg1[31:0] = tb_src0_arg1_100m;
  assign tb_src_arg1[63:32] = tb_src1_arg1_100m;
  assign tb_src_arg2[31:0] = tb_src0_arg2_100m;
  assign tb_src_arg2[63:32] = tb_src1_arg2_100m;

  initial begin
    tb_log_pkg::configure_logging(tb_log_pkg::LOG_INFO);
    tb_clk_24m = 1'b0;
    forever #(CLK_24M_PERIOD / 2) tb_clk_24m = ~tb_clk_24m;
  end

  initial begin
    tb_clk_100m = 1'b0;
    forever #(CLK_100M_PERIOD / 2) tb_clk_100m = ~tb_clk_100m;
  end

  initial begin
    tb_rst_24m_n = 1'b0;
    tb_rst_100m_n = 1'b0;
    tb_uart_rx = 1'b1;
    repeat (32) @(posedge tb_clk_24m);
    tb_rst_24m_n = 1'b1;
    repeat (32) @(posedge tb_clk_100m);
    tb_rst_100m_n = 1'b1;
  end

  initial begin
    #(50ms);
    $display(
      "timeout debug: sel=%0d src_en=%b init=%0b active=%0b pass=%0b fail=%0b state=%0d busy_n=%0b wr_n=%0b rd_n=%0b wr_ack=%0b rd_valid=%0b addr=%h wr_data=%h rd_data=%h",
      u_uart_log_cli.r_log_src_sel,
      tb_src_enable,
      tb_sdram_init_done,
      tb_sdram_test_active,
      tb_sdram_test_pass,
      tb_sdram_test_fail,
      u_sdram_emb_selftest.u_sdram_memtest_ctrl.st_state,
      u_sdram_emb_selftest.l_sdrc_busy_n,
      u_sdram_emb_selftest.l_sdrc_wr_n,
      u_sdram_emb_selftest.l_sdrc_rd_n,
      u_sdram_emb_selftest.l_sdrc_wrd_ack,
      u_sdram_emb_selftest.l_sdrc_rd_valid,
      u_sdram_emb_selftest.l_sdrc_addr,
      u_sdram_emb_selftest.l_sdrc_wr_data,
      u_sdram_emb_selftest.l_sdrc_rd_data
    );
    $fatal(1, "embedded SDRAM self-test simulation timed out");
  end

  // Confirms the user-side protocol contract from the design specification.
  // These checks focus on request pulse width, legal request conditions, and
  // the documented request-to-ack / request-to-busy timing relationships.
  property p_no_dual_request;
    @(posedge tb_clk_100m)
    disable iff (!tb_rst_100m_n)
    !(~u_sdram_emb_selftest.l_sdrc_wr_n && ~u_sdram_emb_selftest.l_sdrc_rd_n);
  endproperty

  property p_wr_pulse_width_1;
    @(posedge tb_clk_100m)
    disable iff (!tb_rst_100m_n)
    (~u_sdram_emb_selftest.l_sdrc_wr_n) |=> u_sdram_emb_selftest.l_sdrc_wr_n;
  endproperty

  property p_rd_pulse_width_1;
    @(posedge tb_clk_100m)
    disable iff (!tb_rst_100m_n)
    (~u_sdram_emb_selftest.l_sdrc_rd_n) |=> u_sdram_emb_selftest.l_sdrc_rd_n;
  endproperty

  property p_request_only_after_init;
    @(posedge tb_clk_100m)
    disable iff (!tb_rst_100m_n)
    (~u_sdram_emb_selftest.l_sdrc_wr_n || ~u_sdram_emb_selftest.l_sdrc_rd_n)
      |-> tb_sdram_init_done;
  endproperty

  property p_request_only_when_idle;
    @(posedge tb_clk_100m)
    disable iff (!tb_rst_100m_n)
    (~u_sdram_emb_selftest.l_sdrc_wr_n || ~u_sdram_emb_selftest.l_sdrc_rd_n)
      |-> u_sdram_emb_selftest.l_sdrc_busy_n;
  endproperty

  property p_ack_after_2_cycles;
    @(posedge tb_clk_100m)
    disable iff (!tb_rst_100m_n)
    (~u_sdram_emb_selftest.l_sdrc_wr_n || ~u_sdram_emb_selftest.l_sdrc_rd_n)
      |-> ##2 u_sdram_emb_selftest.l_sdrc_wrd_ack;
  endproperty

  property p_ack_pulse_width_1;
    @(posedge tb_clk_100m)
    disable iff (!tb_rst_100m_n)
    u_sdram_emb_selftest.l_sdrc_wrd_ack |=> !u_sdram_emb_selftest.l_sdrc_wrd_ack;
  endproperty

  property p_busy_after_3_cycles;
    @(posedge tb_clk_100m)
    disable iff (!tb_rst_100m_n)
    (~u_sdram_emb_selftest.l_sdrc_wr_n || ~u_sdram_emb_selftest.l_sdrc_rd_n)
      |-> ##3 !u_sdram_emb_selftest.l_sdrc_busy_n;
  endproperty

  assert property (p_no_dual_request);
  assert property (p_wr_pulse_width_1);
  assert property (p_rd_pulse_width_1);
  assert property (p_request_only_after_init);
  assert property (p_request_only_when_idle);
  assert property (p_ack_after_2_cycles);
  assert property (p_ack_pulse_width_1);
  assert property (p_busy_after_3_cycles);

  uart_log_testsrc1 #(
    .CLK_HZ(CLK_24M_HZ),
    .PERIOD_CYCLES(TESTSRC_PERIOD_CYCLES)
  ) u_uart_log_testsrc1 (
    .I_CLK(tb_clk_24m),
    .I_RST_N(tb_rst_24m_n),
    .I_ENABLE(tb_src0_enable_24m),
    .I_EVT_READY(tb_src0_evt_ready_24m),
    .O_EVT_VALID(tb_src0_evt_valid_24m),
    .O_EVT_ID(tb_src0_evt_id_24m),
    .O_ARG0(tb_src0_arg0_24m),
    .O_ARG1(tb_src0_arg1_24m),
    .O_ARG2(tb_src0_arg2_24m)
  );

  uart_log_src_async_bridge u_uart_log_src_async_bridge (
    .I_SRC_CLK(tb_clk_24m),
    .I_SRC_RST_N(tb_rst_24m_n),
    .I_DST_CLK(tb_clk_100m),
    .I_DST_RST_N(tb_rst_100m_n),
    .I_DST_ENABLE(tb_src_enable[0]),
    .O_SRC_ENABLE(tb_src0_enable_24m),
    .I_SRC_EVT_VALID(tb_src0_evt_valid_24m),
    .I_SRC_EVT_ID(tb_src0_evt_id_24m),
    .I_SRC_ARG0(tb_src0_arg0_24m),
    .I_SRC_ARG1(tb_src0_arg1_24m),
    .I_SRC_ARG2(tb_src0_arg2_24m),
    .O_SRC_EVT_READY(tb_src0_evt_ready_24m),
    .O_DST_EVT_VALID(tb_src0_evt_valid_100m),
    .O_DST_EVT_ID(tb_src0_evt_id_100m),
    .O_DST_ARG0(tb_src0_arg0_100m),
    .O_DST_ARG1(tb_src0_arg1_100m),
    .O_DST_ARG2(tb_src0_arg2_100m),
    .I_DST_EVT_READY(tb_src_evt_ready[0])
  );

  sdram_emb_selftest #(
    .MEMTEST_BURST_WORDS(256),
    .MEMTEST_TOTAL_WORDS(1024)
  ) u_sdram_emb_selftest (
    .I_CLK(tb_clk_100m),
    .I_RST_N(tb_rst_100m_n),
    .O_EVT_VALID(tb_src1_evt_valid_100m),
    .O_EVT_ID(tb_src1_evt_id_100m),
    .O_EVT_ARG0(tb_src1_arg0_100m),
    .O_EVT_ARG1(tb_src1_arg1_100m),
    .O_EVT_ARG2(tb_src1_arg2_100m),
    .I_EVT_READY(tb_src_evt_ready[1]),
    .O_INIT_DONE(tb_sdram_init_done),
    .O_TEST_ACTIVE(tb_sdram_test_active),
    .O_TEST_PASS(tb_sdram_test_pass),
    .O_TEST_FAIL(tb_sdram_test_fail),
    .O_sdram_clk(tb_sdram_clk),
    .O_sdram_cke(tb_sdram_cke),
    .O_sdram_cs_n(tb_sdram_cs_n),
    .O_sdram_cas_n(tb_sdram_cas_n),
    .O_sdram_ras_n(tb_sdram_ras_n),
    .O_sdram_wen_n(tb_sdram_wen_n),
    .O_sdram_dqm(tb_sdram_dqm),
    .O_sdram_addr(tb_sdram_addr),
    .O_sdram_ba(tb_sdram_ba),
    .IO_sdram_dq(tb_sdram_dq)
  );

  uart_log_cli #(
    .CLK_HZ(CLK_100M_HZ),
    .BAUD(BAUD),
    .NUM_SRC(NUM_SRC)
  ) u_uart_log_cli (
    .I_CLK(tb_clk_100m),
    .I_RST_N(tb_rst_100m_n),
    .I_UART_RX(tb_uart_rx),
    .O_UART_TX(tb_uart_tx),
    .I_SRC_EVT_VALID(tb_src_evt_valid),
    .I_SRC_EVT_ID(tb_src_evt_id),
    .I_SRC_ARG0(tb_src_arg0),
    .I_SRC_ARG1(tb_src_arg1),
    .I_SRC_ARG2(tb_src_arg2),
    .O_SRC_EVT_READY(tb_src_evt_ready),
    .O_SRC_ENABLE(tb_src_enable),
    .O_LOG_SRC_SEL(),
    .O_SOFT_RESET_REQ(tb_soft_reset_req),
    .O_STATUS_REQ_VALID(),
    .O_STATUS_REQ_KEY(),
    .I_RAW_RX_BYPASS(1'b0),
    .I_RAW_TX_MODE(1'b0),
    .I_RAW_TX_VALID(1'b0),
    .I_RAW_TX_DATA(8'h00),
    .O_RAW_TX_READY(),
    .O_CLI_RX_VALID(),
    .O_CLI_RX_DATA(),
    .O_MIRROR_VALID(tb_mirror_valid),
    .O_MIRROR_DATA(tb_mirror_data)
  );

  generate
    genvar g_dram;
    for (g_dram = 0; g_dram < NUM_DRAM; g_dram++) begin : g_sdram_model
      MT48LC8M16A2 #(
        .addr_bits(11)
      ) u_sdram_sim_model (
        .dq   (tb_sdram_dq[((g_dram + 1) * DQ_BITS) - 1 -: DQ_BITS]),
        .addr (tb_sdram_addr),
        .ba   (tb_sdram_ba),
        .clk  (tb_sdram_clk),
        .cke  (tb_sdram_cke),
        .csb  (tb_sdram_cs_n),
        .rasb (tb_sdram_ras_n),
        .casb (tb_sdram_cas_n),
        .web  (tb_sdram_wen_n),
        .dqm  (tb_sdram_dqm[((g_dram + 1) * DQS_BITS) - 1 -: DQS_BITS])
      );
    end
  endgenerate

`include "testcase_smoke.svh"

endmodule
