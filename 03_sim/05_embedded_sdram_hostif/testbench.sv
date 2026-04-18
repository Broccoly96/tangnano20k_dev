`timescale 1ns / 1ps

module testbench;

  import uart_log_cli_tb_pkg::*;
  import tb_log_pkg::*;
  import sdram_uart_proto_pkg::*;

  localparam int unsigned CLK_24M_HZ = 24_000_000;
  localparam int unsigned CLK_96M_HZ = 96_000_000;
  localparam int unsigned BAUD = 115_200;
  localparam int unsigned NUM_SRC = 3;
  localparam int unsigned TESTSRC_PERIOD_CYCLES = 120_000;
  localparam int unsigned UART_BAUD_CNT = (BAUD == 0) ? 1 : ((CLK_24M_HZ + (BAUD/2)) / BAUD);
  localparam time CLK_24M_HALF_PERIOD = 20833ps;
  localparam time CLK_96M_HALF_PERIOD = 5208ps;
  localparam time UART_BIT_PERIOD = (CLK_24M_HALF_PERIOD * 2 * UART_BAUD_CNT);
  localparam int unsigned DQ_BITS = 16;
  localparam int unsigned DQS_BITS = 2;
  localparam int unsigned NUM_DRAM = 2;

  logic tb_clk_96m;
  logic tb_clk_24m;
  logic tb_rst_24m_n;
  logic tb_rst_96m_sync1_n;
  logic tb_rst_96m_n;
  logic tb_uart_rx;
  logic tb_uart_tx;
  logic tb_mirror_valid;
  logic [7:0] tb_mirror_data;

  logic [NUM_SRC-1:0]      tb_src_evt_valid;
  logic [NUM_SRC*8-1:0]    tb_src_evt_id;
  logic [NUM_SRC*32-1:0]   tb_src_arg0;
  logic [NUM_SRC*32-1:0]   tb_src_arg1;
  logic [NUM_SRC*32-1:0]   tb_src_arg2;
  logic [NUM_SRC-1:0]      tb_src_evt_ready;
  logic [NUM_SRC-1:0]      tb_src_enable;

  logic                    tb_src0_evt_valid_24m;
  logic [7:0]              tb_src0_evt_id_24m;
  logic [31:0]             tb_src0_arg0_24m;
  logic [31:0]             tb_src0_arg1_24m;
  logic [31:0]             tb_src0_arg2_24m;
  logic                    tb_src0_enable_24m;
  logic                    tb_src0_evt_ready_24m;

  logic                    tb_src1_evt_valid_24m;
  logic [7:0]              tb_src1_evt_id_24m;
  logic [31:0]             tb_src1_arg0_24m;
  logic [31:0]             tb_src1_arg1_24m;
  logic [31:0]             tb_src1_arg2_24m;
  logic                    tb_src1_evt_valid_96m;
  logic [7:0]              tb_src1_evt_id_96m;
  logic [31:0]             tb_src1_arg0_96m;
  logic [31:0]             tb_src1_arg1_96m;
  logic [31:0]             tb_src1_arg2_96m;
  logic                    tb_src1_evt_ready_96m;
  logic                    tb_src2_evt_valid_24m;
  logic [7:0]              tb_src2_evt_id_24m;
  logic [31:0]             tb_src2_arg0_24m;
  logic [31:0]             tb_src2_arg1_24m;
  logic [31:0]             tb_src2_arg2_24m;
  logic                    tb_src2_evt_valid_96m;
  logic [7:0]              tb_src2_evt_id_96m;
  logic [31:0]             tb_src2_arg0_96m;
  logic [31:0]             tb_src2_arg1_96m;
  logic [31:0]             tb_src2_arg2_96m;
  logic                    tb_src2_evt_ready_96m;

  logic                    tb_cli_rx_valid_24m;
  logic [7:0]              tb_cli_rx_data_24m;
  logic                    tb_cli_rx_valid_96m;
  logic [7:0]              tb_cli_rx_data_96m;
  logic                    tb_raw_rx_bypass_24m;
  logic                    tb_raw_tx_mode_24m;
  logic                    tb_raw_tx_valid_24m;
  logic [7:0]              tb_raw_tx_data_24m;
  logic                    tb_raw_tx_ready_24m;
  logic                    tb_sdram_init_done;
  logic                    tb_sdram_test_active;
  logic                    tb_sdram_test_pass;
  logic                    tb_sdram_test_fail;
  logic                    tb_sdram_host_busy;

  logic                    tb_sdram_clk;
  logic                    tb_sdram_cke;
  logic                    tb_sdram_cs_n;
  logic                    tb_sdram_cas_n;
  logic                    tb_sdram_ras_n;
  logic                    tb_sdram_wen_n;
  logic [3:0]              tb_sdram_dqm;
  logic [10:0]             tb_sdram_addr;
  logic [1:0]              tb_sdram_ba;
  wire  [31:0]             tb_sdram_dq;

  logic                    tb_sdrc_wr_n;
  logic                    tb_sdrc_rd_n;
  logic                    tb_sdrc_rst_n;
  logic [20:0]             tb_sdrc_addr;
  logic [7:0]              tb_sdrc_data_len;
  logic [3:0]              tb_sdrc_dqm;
  logic [31:0]             tb_sdrc_wr_data;
  logic [31:0]             tb_sdrc_rd_data;
  logic                    tb_sdrc_busy_n;
  logic                    tb_sdrc_rd_valid;
  logic                    tb_sdrc_wrd_ack;

  integer tb_cli_rx_count;
  integer tb_cli_rx_96m_count;
  integer tb_host_evt_count;
  integer tb_mirror_count;
  logic tb_raw_rx_bypass_q;
  logic tb_raw_tx_mode_q;

  assign tb_src_evt_valid[0] = tb_src0_evt_valid_24m;
  assign tb_src_evt_valid[1] = tb_src1_evt_valid_24m;
  assign tb_src_evt_valid[2] = tb_src2_evt_valid_24m;
  assign tb_src_evt_id[7:0] = tb_src0_evt_id_24m;
  assign tb_src_evt_id[15:8] = tb_src1_evt_id_24m;
  assign tb_src_evt_id[23:16] = tb_src2_evt_id_24m;
  assign tb_src_arg0[31:0] = tb_src0_arg0_24m;
  assign tb_src_arg0[63:32] = tb_src1_arg0_24m;
  assign tb_src_arg0[95:64] = tb_src2_arg0_24m;
  assign tb_src_arg1[31:0] = tb_src0_arg1_24m;
  assign tb_src_arg1[63:32] = tb_src1_arg1_24m;
  assign tb_src_arg1[95:64] = tb_src2_arg1_24m;
  assign tb_src_arg2[31:0] = tb_src0_arg2_24m;
  assign tb_src_arg2[63:32] = tb_src1_arg2_24m;
  assign tb_src_arg2[95:64] = tb_src2_arg2_24m;

  initial begin
    tb_log_pkg::configure_logging(tb_log_pkg::LOG_DEBUG);
    tb_clk_96m = 1'b0;
    forever #(CLK_96M_HALF_PERIOD) tb_clk_96m = ~tb_clk_96m;
  end

  initial begin
    tb_clk_24m = 1'b0;
    forever #(CLK_24M_HALF_PERIOD) tb_clk_24m = ~tb_clk_24m;
  end

  initial begin
    tb_rst_24m_n = 1'b0;
    tb_uart_rx = 1'b1;
    repeat (32) @(posedge tb_clk_24m);
    tb_rst_24m_n = 1'b1;
    tb_cli_rx_count = 0;
    tb_cli_rx_96m_count = 0;
    tb_host_evt_count = 0;
    tb_mirror_count = 0;
    tb_raw_rx_bypass_q = 1'b0;
    tb_raw_tx_mode_q = 1'b0;
  end

  always_ff @(posedge tb_clk_96m or negedge tb_rst_24m_n) begin
    if (!tb_rst_24m_n) begin
      tb_rst_96m_sync1_n <= 1'b0;
      tb_rst_96m_n       <= 1'b0;
    end else begin
      tb_rst_96m_sync1_n <= 1'b1;
      tb_rst_96m_n       <= tb_rst_96m_sync1_n;
    end
  end

  always_ff @(posedge tb_clk_24m) begin
    if (tb_cli_rx_valid_24m) begin
      tb_cli_rx_count <= tb_cli_rx_count + 1;
      tb_log_pkg::log_debug(
        "SDRAM HOSTIF TB",
        $sformatf(
          "cli_rx_24m data=0x%02h raw_rx_bypass=%0b raw_tx_mode=%0b host_busy=%0b count=%0d",
          tb_cli_rx_data_24m,
          tb_raw_rx_bypass_24m,
          tb_raw_tx_mode_24m,
          tb_sdram_host_busy,
          tb_cli_rx_count + 1
        )
      );
    end
    if (tb_src2_evt_valid_24m && tb_src_evt_ready[2]) begin
      tb_host_evt_count <= tb_host_evt_count + 1;
      tb_log_pkg::log_debug(
        "SDRAM HOSTIF TB",
        $sformatf(
          "host_evt id=0x%02h arg0=0x%08h arg1=0x%08h arg2=0x%08h count=%0d",
          tb_src2_evt_id_24m,
          tb_src2_arg0_24m,
          tb_src2_arg1_24m,
          tb_src2_arg2_24m,
          tb_host_evt_count + 1
        )
      );
    end
    if (tb_mirror_valid) begin
      tb_mirror_count <= tb_mirror_count + 1;
      tb_log_pkg::log_trace(
        "SDRAM HOSTIF TB",
        $sformatf("mirror_byte data=0x%02h count=%0d", tb_mirror_data, tb_mirror_count + 1)
      );
    end
    if (tb_raw_tx_valid_24m && tb_raw_tx_ready_24m) begin
      tb_log_pkg::log_trace(
        "SDRAM HOSTIF TB",
        $sformatf("raw_tx data=0x%02h", tb_raw_tx_data_24m)
      );
    end
    if (tb_raw_rx_bypass_24m != tb_raw_rx_bypass_q) begin
      tb_log_pkg::log_debug(
        "SDRAM HOSTIF TB",
        $sformatf("raw_rx_bypass -> %0b", tb_raw_rx_bypass_24m)
      );
      tb_raw_rx_bypass_q <= tb_raw_rx_bypass_24m;
    end
    if (tb_raw_tx_mode_24m != tb_raw_tx_mode_q) begin
      tb_log_pkg::log_debug(
        "SDRAM HOSTIF TB",
        $sformatf("raw_tx_mode -> %0b", tb_raw_tx_mode_24m)
      );
      tb_raw_tx_mode_q <= tb_raw_tx_mode_24m;
    end
  end

  always_ff @(posedge tb_clk_96m) begin
    if (tb_cli_rx_valid_96m) begin
      tb_cli_rx_96m_count <= tb_cli_rx_96m_count + 1;
      tb_log_pkg::log_debug(
        "SDRAM HOSTIF TB",
        $sformatf(
          "cli_rx_96m data=0x%02h host_busy=%0b count=%0d",
          tb_cli_rx_data_96m,
          tb_sdram_host_busy,
          tb_cli_rx_96m_count + 1
        )
      );
    end
  end

  initial begin
    #(120ms);
    $fatal(
      1,
      "embedded SDRAM hostif simulation timed out pass=%0b fail=%0b host_busy=%0b sel=%0d cli_rx=%0d host_evt=%0d mirror=%0d last_cli=0x%02h raw_rx_bypass=%0b raw_tx_mode=%0b",
      tb_sdram_test_pass,
      tb_sdram_test_fail,
      tb_sdram_host_busy,
      u_uart_log_cli.r_log_src_sel,
      tb_cli_rx_count,
      tb_host_evt_count,
      tb_mirror_count,
      tb_cli_rx_data_24m,
      tb_raw_rx_bypass_24m,
      tb_raw_tx_mode_24m
    );
  end

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

  assign tb_raw_rx_bypass_24m = 1'b0;
  assign tb_raw_tx_mode_24m   = 1'b0;
  assign tb_raw_tx_valid_24m  = 1'b0;
  assign tb_raw_tx_data_24m   = 8'h00;

  uart_log_src_async_bridge u_sdram_test_evt_bridge (
    .I_SRC_CLK(tb_clk_96m),
    .I_SRC_RST_N(tb_rst_96m_n),
    .I_DST_CLK(tb_clk_24m),
    .I_DST_RST_N(tb_rst_24m_n),
    .I_DST_ENABLE(tb_src_enable[1]),
    .O_SRC_ENABLE(),
    .I_SRC_EVT_VALID(tb_src1_evt_valid_96m),
    .I_SRC_EVT_ID(tb_src1_evt_id_96m),
    .I_SRC_ARG0(tb_src1_arg0_96m),
    .I_SRC_ARG1(tb_src1_arg1_96m),
    .I_SRC_ARG2(tb_src1_arg2_96m),
    .O_SRC_EVT_READY(tb_src1_evt_ready_96m),
    .O_DST_EVT_VALID(tb_src1_evt_valid_24m),
    .O_DST_EVT_ID(tb_src1_evt_id_24m),
    .O_DST_ARG0(tb_src1_arg0_24m),
    .O_DST_ARG1(tb_src1_arg1_24m),
    .O_DST_ARG2(tb_src1_arg2_24m),
    .I_DST_EVT_READY(tb_src_evt_ready[1])
  );

  uart_log_src_async_bridge u_sdram_host_evt_bridge (
    .I_SRC_CLK(tb_clk_96m),
    .I_SRC_RST_N(tb_rst_96m_n),
    .I_DST_CLK(tb_clk_24m),
    .I_DST_RST_N(tb_rst_24m_n),
    .I_DST_ENABLE(tb_src_enable[2]),
    .O_SRC_ENABLE(),
    .I_SRC_EVT_VALID(tb_src2_evt_valid_96m),
    .I_SRC_EVT_ID(tb_src2_evt_id_96m),
    .I_SRC_ARG0(tb_src2_arg0_96m),
    .I_SRC_ARG1(tb_src2_arg1_96m),
    .I_SRC_ARG2(tb_src2_arg2_96m),
    .O_SRC_EVT_READY(tb_src2_evt_ready_96m),
    .O_DST_EVT_VALID(tb_src2_evt_valid_24m),
    .O_DST_EVT_ID(tb_src2_evt_id_24m),
    .O_DST_ARG0(tb_src2_arg0_24m),
    .O_DST_ARG1(tb_src2_arg1_24m),
    .O_DST_ARG2(tb_src2_arg2_24m),
    .I_DST_EVT_READY(tb_src_evt_ready[2])
  );

  uart_log_cli_byte_async_bridge u_cli_rx_bridge (
    .I_SRC_CLK(tb_clk_24m),
    .I_SRC_RST_N(tb_rst_24m_n),
    .I_DST_CLK(tb_clk_96m),
    .I_DST_RST_N(tb_rst_96m_n),
    .I_SRC_VALID(tb_cli_rx_valid_24m),
    .I_SRC_DATA(tb_cli_rx_data_24m),
    .O_SRC_READY(),
    .O_DST_VALID(tb_cli_rx_valid_96m),
    .O_DST_DATA(tb_cli_rx_data_96m),
    .I_DST_READY(1'b1)
  );

  sdram_emb_hostif_ctrl #(
    .MEMTEST_CLEAR_WORDS(1024)
  ) u_sdram_emb_hostif_ctrl (
    .I_CLK(tb_clk_96m),
    .I_RST_N(tb_rst_96m_n),
    .I_CLI_RX_VALID(tb_cli_rx_valid_96m),
    .I_CLI_RX_DATA(tb_cli_rx_data_96m),
    .O_RAW_RX_BYPASS(),
    .O_RAW_TX_MODE(),
    .O_RAW_TX_VALID(),
    .O_RAW_TX_DATA(),
    .I_RAW_TX_READY(1'b1),
    .O_TEST_EVT_VALID(tb_src1_evt_valid_96m),
    .O_TEST_EVT_ID(tb_src1_evt_id_96m),
    .O_TEST_EVT_ARG0(tb_src1_arg0_96m),
    .O_TEST_EVT_ARG1(tb_src1_arg1_96m),
    .O_TEST_EVT_ARG2(tb_src1_arg2_96m),
    .I_TEST_EVT_READY(tb_src1_evt_ready_96m),
    .O_HOST_EVT_VALID(tb_src2_evt_valid_96m),
    .O_HOST_EVT_ID(tb_src2_evt_id_96m),
    .O_HOST_EVT_ARG0(tb_src2_arg0_96m),
    .O_HOST_EVT_ARG1(tb_src2_arg1_96m),
    .O_HOST_EVT_ARG2(tb_src2_arg2_96m),
    .I_HOST_EVT_READY(tb_src2_evt_ready_96m),
    .I_SDRC_RD_DATA(tb_sdrc_rd_data),
    .I_SDRC_BUSY_N(tb_sdrc_busy_n),
    .I_SDRC_RD_VALID(tb_sdrc_rd_valid),
    .I_SDRC_WRD_ACK(tb_sdrc_wrd_ack),
    .I_SDRC_INIT_DONE(tb_sdram_init_done),
    .O_INIT_DONE(),
    .O_TEST_ACTIVE(tb_sdram_test_active),
    .O_TEST_PASS(tb_sdram_test_pass),
    .O_TEST_FAIL(tb_sdram_test_fail),
    .O_HOST_BUSY(tb_sdram_host_busy),
    .O_SDRC_RST_N(tb_sdrc_rst_n),
    .O_SDRC_WR_N(tb_sdrc_wr_n),
    .O_SDRC_RD_N(tb_sdrc_rd_n),
    .O_SDRC_ADDR(tb_sdrc_addr),
    .O_SDRC_DATA_LEN(tb_sdrc_data_len),
    .O_SDRC_DQM(tb_sdrc_dqm),
    .O_SDRC_WR_DATA(tb_sdrc_wr_data)
  );

  embedded_sdram u_embedded_sdram (
    .O_sdram_clk(tb_sdram_clk),
    .O_sdram_cke(tb_sdram_cke),
    .O_sdram_cs_n(tb_sdram_cs_n),
    .O_sdram_cas_n(tb_sdram_cas_n),
    .O_sdram_ras_n(tb_sdram_ras_n),
    .O_sdram_wen_n(tb_sdram_wen_n),
    .O_sdram_dqm(tb_sdram_dqm),
    .O_sdram_addr(tb_sdram_addr),
    .O_sdram_ba(tb_sdram_ba),
    .IO_sdram_dq(tb_sdram_dq),
    .I_sdrc_rst_n(tb_sdrc_rst_n),
    .I_sdrc_clk(tb_clk_96m),
    .I_sdram_clk(tb_clk_96m),
    .I_sdrc_selfrefresh(1'b0),
    .I_sdrc_power_down(1'b0),
    .I_sdrc_wr_n(tb_sdrc_wr_n),
    .I_sdrc_rd_n(tb_sdrc_rd_n),
    .I_sdrc_addr(tb_sdrc_addr),
    .I_sdrc_data_len(tb_sdrc_data_len),
    .I_sdrc_dqm(tb_sdrc_dqm),
    .I_sdrc_data(tb_sdrc_wr_data),
    .O_sdrc_data(tb_sdrc_rd_data),
    .O_sdrc_init_done(tb_sdram_init_done),
    .O_sdrc_busy_n(tb_sdrc_busy_n),
    .O_sdrc_rd_valid(tb_sdrc_rd_valid),
    .O_sdrc_wrd_ack(tb_sdrc_wrd_ack)
  );

  uart_log_cli #(
    .CLK_HZ(CLK_24M_HZ),
    .BAUD(BAUD),
    .NUM_SRC(NUM_SRC)
  ) u_uart_log_cli (
    .I_CLK(tb_clk_24m),
    .I_RST_N(tb_rst_24m_n),
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
    .O_SOFT_RESET_REQ(),
    .O_STATUS_REQ_VALID(),
    .O_STATUS_REQ_KEY(),
    .I_RAW_RX_BYPASS(tb_raw_rx_bypass_24m),
    .I_RAW_TX_MODE(tb_raw_tx_mode_24m),
    .I_RAW_TX_VALID(tb_raw_tx_valid_24m),
    .I_RAW_TX_DATA(tb_raw_tx_data_24m),
    .O_RAW_TX_READY(tb_raw_tx_ready_24m),
    .O_CLI_RX_VALID(tb_cli_rx_valid_24m),
    .O_CLI_RX_DATA(tb_cli_rx_data_24m),
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
