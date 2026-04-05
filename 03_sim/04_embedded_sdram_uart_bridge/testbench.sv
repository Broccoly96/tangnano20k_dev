`timescale 1ns / 1ps

module testbench;

  import uart_log_cli_tb_pkg::*;
  import tb_log_pkg::*;

  localparam int unsigned CLK_100M_HZ = 100_000_000;
  localparam int unsigned BAUD        = 115_200;
  localparam int unsigned NUM_SRC     = 1;
  localparam time CLK_100M_PERIOD     = 10ns;
  localparam time UART_BIT_PERIOD     = 8681ns;
  localparam int unsigned DQ_BITS     = 16;
  localparam int unsigned DQS_BITS    = 2;
  localparam int unsigned NUM_DRAM    = 2;

  logic tb_clk_100m;
  logic tb_rst_100m_n;
  logic tb_uart_rx;
  logic tb_uart_tx;
  logic tb_mirror_valid;
  logic [7:0] tb_mirror_data;

  logic [NUM_SRC-1:0] tb_src_evt_valid;
  logic [NUM_SRC*8-1:0] tb_src_evt_id;
  logic [NUM_SRC*32-1:0] tb_src_arg0;
  logic [NUM_SRC*32-1:0] tb_src_arg1;
  logic [NUM_SRC*32-1:0] tb_src_arg2;
  logic [NUM_SRC-1:0] tb_src_evt_ready;
  logic [NUM_SRC-1:0] tb_src_enable;

  logic       tb_cli_rx_valid;
  logic [7:0] tb_cli_rx_data;
  logic       tb_bridge_evt_valid;
  logic [7:0] tb_bridge_evt_id;
  logic [31:0] tb_bridge_arg0;
  logic [31:0] tb_bridge_arg1;
  logic [31:0] tb_bridge_arg2;
  logic       tb_sdram_init_done;
  logic       tb_cmd_busy;

  logic        tb_sdram_clk;
  logic        tb_sdram_cke;
  logic        tb_sdram_cs_n;
  logic        tb_sdram_cas_n;
  logic        tb_sdram_ras_n;
  logic        tb_sdram_wen_n;
  logic [3:0]  tb_sdram_dqm;
  logic [10:0] tb_sdram_addr;
  logic [1:0]  tb_sdram_ba;
  wire  [31:0] tb_sdram_dq;

  assign tb_src_evt_valid[0] = tb_bridge_evt_valid;
  assign tb_src_evt_id[7:0]  = tb_bridge_evt_id;
  assign tb_src_arg0[31:0]   = tb_bridge_arg0;
  assign tb_src_arg1[31:0]   = tb_bridge_arg1;
  assign tb_src_arg2[31:0]   = tb_bridge_arg2;

  initial begin
    tb_log_pkg::configure_logging(tb_log_pkg::LOG_INFO);
    tb_clk_100m = 1'b0;
    forever #(CLK_100M_PERIOD / 2) tb_clk_100m = ~tb_clk_100m;
  end

  initial begin
    tb_rst_100m_n = 1'b0;
    tb_uart_rx    = 1'b1;
    repeat (64) @(posedge tb_clk_100m);
    tb_rst_100m_n = 1'b1;
  end

  initial begin
    #(20ms);
    $fatal(
      1,
      "embedded SDRAM UART bridge simulation timed out init=%0b busy=%0b cli_valid=%0b cli_data=0x%02h",
      tb_sdram_init_done,
      tb_cmd_busy,
      tb_cli_rx_valid,
      tb_cli_rx_data
    );
  end

  uart_log_cli #(
    .CLK_HZ (CLK_100M_HZ),
    .BAUD   (BAUD),
    .NUM_SRC(NUM_SRC)
  ) u_uart_log_cli (
    .I_CLK              (tb_clk_100m),
    .I_RST_N            (tb_rst_100m_n),
    .I_UART_RX          (tb_uart_rx),
    .O_UART_TX          (tb_uart_tx),
    .I_SRC_EVT_VALID    (tb_src_evt_valid),
    .I_SRC_EVT_ID       (tb_src_evt_id),
    .I_SRC_ARG0         (tb_src_arg0),
    .I_SRC_ARG1         (tb_src_arg1),
    .I_SRC_ARG2         (tb_src_arg2),
    .O_SRC_EVT_READY    (tb_src_evt_ready),
    .O_SRC_ENABLE       (tb_src_enable),
    .O_LOG_SRC_SEL      (),
    .O_SOFT_RESET_REQ   (),
    .O_STATUS_REQ_VALID (),
    .O_STATUS_REQ_KEY   (),
    .O_CLI_RX_VALID     (tb_cli_rx_valid),
    .O_CLI_RX_DATA      (tb_cli_rx_data),
    .O_MIRROR_VALID     (tb_mirror_valid),
    .O_MIRROR_DATA      (tb_mirror_data)
  );

  sdram_uart_bridge u_sdram_uart_bridge (
    .I_CLK         (tb_clk_100m),
    .I_RST_N       (tb_rst_100m_n),
    .I_CLI_RX_VALID(tb_cli_rx_valid),
    .I_CLI_RX_DATA (tb_cli_rx_data),
    .O_EVT_VALID   (tb_bridge_evt_valid),
    .O_EVT_ID      (tb_bridge_evt_id),
    .O_EVT_ARG0    (tb_bridge_arg0),
    .O_EVT_ARG1    (tb_bridge_arg1),
    .O_EVT_ARG2    (tb_bridge_arg2),
    .I_EVT_READY   (tb_src_evt_ready[0]),
    .O_INIT_DONE   (tb_sdram_init_done),
    .O_CMD_BUSY    (tb_cmd_busy),
    .O_sdram_clk   (tb_sdram_clk),
    .O_sdram_cke   (tb_sdram_cke),
    .O_sdram_cs_n  (tb_sdram_cs_n),
    .O_sdram_cas_n (tb_sdram_cas_n),
    .O_sdram_ras_n (tb_sdram_ras_n),
    .O_sdram_wen_n (tb_sdram_wen_n),
    .O_sdram_dqm   (tb_sdram_dqm),
    .O_sdram_addr  (tb_sdram_addr),
    .O_sdram_ba    (tb_sdram_ba),
    .IO_sdram_dq   (tb_sdram_dq)
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
