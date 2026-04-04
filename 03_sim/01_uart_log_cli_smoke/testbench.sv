`timescale 1ns / 1ps

`include "../../01_src/uart_lite/uart_rx_stream.sv"
`include "../../01_src/uart_lite/uart_tx_stream.sv"
`include "../../01_src/sync_fifo_ae_af.sv"
`include "../../01_src/uart_log_cli/uart_log_cli_pkg.sv"
`include "../../01_src/uart_log_cli/uart_log_tap.sv"
`include "../../01_src/uart_log_cli/uart_log_cli_evt_fifo.sv"
`include "../../01_src/uart_log_cli/uart_log_testsrc1.sv"
`include "../../01_src/uart_log_cli/uart_log_cli.sv"
`include "../../02_tb/uart_log_cli/uart_log_cli_tb_pkg.sv"

module testbench;

  import uart_log_cli_tb_pkg::*;

  localparam int unsigned CLK_HZ = 1_000_000;
  localparam int unsigned BAUD = 100_000;
  localparam int unsigned NUM_SRC = 1;
  localparam int unsigned PERIOD_CYCLES = 4000;
  localparam int unsigned SOFT_RESET_HOLD_CYCLES = CLK_HZ / 1000;
  localparam time CLK_PERIOD = 1000ns;
  localparam time BIT_PERIOD = 10000ns;

  logic tb_clk;
  logic tb_rst_n;
  logic tb_uart_rx;
  logic tb_uart_tx;
  logic tb_soft_reset_req;
  logic tb_soft_rst_n;
  logic [$clog2(SOFT_RESET_HOLD_CYCLES + 1)-1:0] tb_soft_reset_cnt;
  logic tb_mirror_valid;
  logic [7:0] tb_mirror_data;

  logic [NUM_SRC-1:0] tb_src_evt_valid;
  logic [NUM_SRC*8-1:0] tb_src_evt_id;
  logic [NUM_SRC*32-1:0] tb_src_arg0;
  logic [NUM_SRC*32-1:0] tb_src_arg1;
  logic [NUM_SRC*32-1:0] tb_src_arg2;
  logic [NUM_SRC-1:0] tb_src_evt_ready;
  logic [NUM_SRC-1:0] tb_src_enable;

  logic tb_src0_evt_valid;
  logic [7:0] tb_src0_evt_id;
  logic [31:0] tb_src0_arg0;
  logic [31:0] tb_src0_arg1;
  logic [31:0] tb_src0_arg2;

  assign tb_src_evt_valid[0] = tb_src0_evt_valid;
  assign tb_src_evt_id[7:0]  = tb_src0_evt_id;
  assign tb_src_arg0[31:0]   = tb_src0_arg0;
  assign tb_src_arg1[31:0]   = tb_src0_arg1;
  assign tb_src_arg2[31:0]   = tb_src0_arg2;

  initial begin
    tb_clk = 1'b0;
    tb_rst_n = 1'b0;
    tb_uart_rx = 1'b1;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    #(60ms);
    $display("timeout debug: rst_n=%0b soft_rst_n=%0b src_valid=%0b src_ready=%0b src_enable=%0b mirror_valid=%0b frame_active=%0b shared_empty=%0b tap_valid=%0b pending=%0b tx_state=%0d frame_idx=%0d tx_busy=%0b tx_done=%0b tx_start=%0b",
      tb_rst_n,
      tb_soft_rst_n,
      tb_src0_evt_valid,
      tb_src_evt_ready[0],
      tb_src_enable[0],
      tb_mirror_valid,
      u_uart_log_cli.r_frame_active,
      u_uart_log_cli.s_shared_empty,
      u_uart_log_cli.s_tap_tvalid[0],
      u_uart_log_testsrc1.r_pending,
      u_uart_log_cli.r_tx_state,
      u_uart_log_cli.r_frame_byte_idx,
      u_uart_log_cli.s_uart_tx_busy,
      u_uart_log_cli.s_uart_tx_done,
      u_uart_log_cli.r_uart_tx_start
    );
    $fatal(1, "UART log smoke test timed out");
  end

  // Holds the DUT reset low for 1ms after Ctrl+R to mirror the top-level path.
  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      tb_soft_reset_cnt <= '0;
      tb_soft_rst_n     <= 1'b1;
    end else if (tb_soft_reset_req) begin
      tb_soft_reset_cnt <= SOFT_RESET_HOLD_CYCLES - 1;
      tb_soft_rst_n     <= 1'b0;
    end else if (tb_soft_reset_cnt != 0) begin
      tb_soft_reset_cnt <= tb_soft_reset_cnt - 1'b1;
      tb_soft_rst_n     <= 1'b0;
    end else begin
      tb_soft_reset_cnt <= '0;
      tb_soft_rst_n     <= 1'b1;
    end
  end

  uart_log_testsrc1 #(
    .CLK_HZ(CLK_HZ),
    .PERIOD_CYCLES(PERIOD_CYCLES)
  ) u_uart_log_testsrc1 (
    .I_CLK(tb_clk),
    .I_RST_N(tb_rst_n && tb_soft_rst_n),
    .I_ENABLE(tb_src_enable[0]),
    .I_EVT_READY(tb_src_evt_ready[0]),
    .O_EVT_VALID(tb_src0_evt_valid),
    .O_EVT_ID(tb_src0_evt_id),
    .O_ARG0(tb_src0_arg0),
    .O_ARG1(tb_src0_arg1),
    .O_ARG2(tb_src0_arg2)
  );

  uart_log_cli #(
    .CLK_HZ(CLK_HZ),
    .BAUD(BAUD),
    .NUM_SRC(NUM_SRC)
  ) u_uart_log_cli (
    .I_CLK(tb_clk),
    .I_RST_N(tb_rst_n && tb_soft_rst_n),
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
    .O_CLI_RX_VALID(),
    .O_CLI_RX_DATA(),
    .O_MIRROR_VALID(tb_mirror_valid),
    .O_MIRROR_DATA(tb_mirror_data)
  );

`include "testcase_smoke.svh"

endmodule
