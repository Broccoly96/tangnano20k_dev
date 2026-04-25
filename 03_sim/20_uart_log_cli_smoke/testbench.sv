`timescale 1ns / 1ps

`include "../../01_src/uart_lite/uart_rx_stream.sv"
`include "../../01_src/uart_lite/uart_tx_stream.sv"
`include "../../01_src/sync_fifo_ae_af.sv"
`include "../../01_src/uart_log_cli/uart_log_cli_pkg.sv"
`include "../../01_src/uart_log_cli/uart_log_evt_if.sv"
`include "../../01_src/uart_log_cli/uart_log_tap.sv"
`include "../../01_src/uart_log_cli/uart_log_cli_evt_fifo.sv"
`include "../../01_src/uart_log_cli/uart_log_cli.sv"
`include "../../02_tb/uart_log_cli/uart_log_cli_tb_pkg.sv"

module testbench;

  import uart_log_cli_tb_pkg::*;

  localparam int unsigned CLK_HZ = 1_000_000;
  localparam int unsigned BAUD = 100_000;
  localparam int unsigned NUM_SRC = 3;
  localparam int unsigned SOFT_RESET_HOLD_CYCLES = CLK_HZ / 1000;
  localparam time CLK_PERIOD = 1000ns;
  localparam time BIT_PERIOD = 10000ns;

  logic tb_clk;
  logic tb_rst_n;
  logic tb_uart_rx;
  logic tb_uart_tx;
  logic tb_soft_reset_req;
  logic tb_cli_rx_valid;
  logic [7:0] tb_cli_rx_data;
  logic tb_soft_rst_n;
  logic [$clog2(SOFT_RESET_HOLD_CYCLES + 1)-1:0] tb_soft_reset_cnt;

  uart_log_evt_if tb_src_if [NUM_SRC] ();

  logic [NUM_SRC-1:0] tb_src_evt_valid;
  logic [NUM_SRC-1:0] tb_src_evt_ready;
  logic [NUM_SRC-1:0] tb_src_enable;
  logic [7:0]         tb_src_evt_id [NUM_SRC];
  logic [31:0]        tb_src_arg0 [NUM_SRC];
  logic [31:0]        tb_src_arg1 [NUM_SRC];
  logic [31:0]        tb_src_arg2 [NUM_SRC];

  genvar g_src_conn;
  generate
    for (g_src_conn = 0; g_src_conn < NUM_SRC; g_src_conn++) begin : g_src_conn_blk
      assign tb_src_if[g_src_conn].evt_valid = tb_src_evt_valid[g_src_conn];
      assign tb_src_if[g_src_conn].evt_id    = tb_src_evt_id[g_src_conn];
      assign tb_src_if[g_src_conn].arg0      = tb_src_arg0[g_src_conn];
      assign tb_src_if[g_src_conn].arg1      = tb_src_arg1[g_src_conn];
      assign tb_src_if[g_src_conn].arg2      = tb_src_arg2[g_src_conn];
      assign tb_src_evt_ready[g_src_conn]    = tb_src_if[g_src_conn].evt_ready;
      assign tb_src_enable[g_src_conn]       = tb_src_if[g_src_conn].enable;
    end
  endgenerate

  initial begin
    tb_clk = 1'b0;
    tb_rst_n = 1'b0;
    tb_uart_rx = 1'b1;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    #(60ms);
    $display("timeout debug: rst_n=%0b soft_rst_n=%0b src_valid=%0b src_ready=%0b src_enable=%0b frame_active=%0b shared_empty=%0b tap_valid=%0b tx_state=%0d frame_idx=%0d tx_busy=%0b tx_done=%0b tx_start=%0b",
      tb_rst_n,
      tb_soft_rst_n,
      tb_src_evt_valid[0],
      tb_src_if[0].evt_ready,
      tb_src_if[0].enable,
      u_uart_log_cli.r_frame_active,
      u_uart_log_cli.s_shared_empty,
      u_uart_log_cli.s_tap_tvalid[0],
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

  uart_log_cli #(
    .CLK_HZ(CLK_HZ),
    .BAUD(BAUD),
    .NUM_SRC(NUM_SRC)
  ) u_uart_log_cli (
    .I_CLK(tb_clk),
    .I_RST_N(tb_rst_n),
    .I_UART_RX(tb_uart_rx),
    .O_UART_TX(tb_uart_tx),
    .SRC_IF(tb_src_if),
    .O_SOFT_RESET_REQ(tb_soft_reset_req),
    .O_CLI_RX_VALID(tb_cli_rx_valid),
    .O_CLI_RX_DATA(tb_cli_rx_data)
  );

  task automatic emit_source_event(
    input int unsigned src_idx,
    input logic [7:0]  evt_id,
    input logic [31:0] arg0,
    input logic [31:0] arg1,
    input logic [31:0] arg2
  );
    begin
      if (src_idx >= NUM_SRC) begin
        $fatal(1, "source index out of range");
      end

      @(negedge tb_clk);
      tb_src_evt_valid[src_idx] = 1'b1;
      tb_src_evt_id[src_idx]    = evt_id;
      tb_src_arg0[src_idx]      = arg0;
      tb_src_arg1[src_idx]      = arg1;
      tb_src_arg2[src_idx]      = arg2;

      do begin
        @(posedge tb_clk);
      end while (!tb_src_evt_ready[src_idx]);

      @(negedge tb_clk);
      tb_src_evt_valid[src_idx] = 1'b0;
      tb_src_evt_id[src_idx]    = 8'h00;
      tb_src_arg0[src_idx]      = 32'h0;
      tb_src_arg1[src_idx]      = 32'h0;
      tb_src_arg2[src_idx]      = 32'h0;
    end
  endtask

  task automatic expect_uart_event(
    input logic [7:0]  exp_src_id,
    input logic [7:0]  exp_evt_id,
    input logic [31:0] exp_arg0,
    input logic [31:0] exp_arg1,
    input logic [31:0] exp_arg2,
    input string       label
  );
    logic [7:0] seq;
    logic [127:0] payload;
    logic [7:0] crc;
    uart_log_payload_t decoded;
    begin
      while (u_uart_log_cli.r_frame_active) begin
        @(posedge tb_clk);
      end
      while (!u_uart_log_cli.r_frame_active) begin
        @(posedge tb_clk);
      end

      seq = u_uart_log_cli.r_frame_seq;
      payload = u_uart_log_cli.r_frame_payload;
      crc = u_uart_log_cli.r_frame_crc;
      decoded = decode_payload(payload);

      if (calc_frame_crc(seq, payload) != crc) begin
        $fatal(
          1,
          "CRC mismatch for %s seq=0x%02h calc=0x%02h crc=0x%02h payload=0x%032h",
          label,
          seq,
          calc_frame_crc(seq, payload),
          crc,
          payload
        );
      end
      if ((decoded.src_id !== exp_src_id) ||
          (decoded.event_id !== exp_evt_id) ||
          (decoded.arg0 !== exp_arg0) ||
          (decoded.arg1 !== exp_arg1) ||
          (decoded.arg2 !== exp_arg2)) begin
        $fatal(
          1,
          "event mismatch %s src=0x%02h evt=0x%02h arg0=0x%08h arg1=0x%08h arg2=0x%08h",
          label,
          decoded.src_id,
          decoded.event_id,
          decoded.arg0,
          decoded.arg1,
          decoded.arg2
        );
      end
    end
  endtask

  task automatic wait_cli_forward(input logic [7:0] exp_data, input string label);
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_cli_rx_valid) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 1000) begin
          $fatal(1, "timeout waiting CLI forward: %s", label);
        end
      end
      if (tb_cli_rx_data !== exp_data) begin
        $fatal(1, "CLI forward mismatch %s data=0x%02h", label, tb_cli_rx_data);
      end
    end
  endtask

  task automatic wait_soft_reset_pulse;
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_soft_reset_req) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 1000) begin
          $fatal(1, "timeout waiting soft reset pulse");
        end
      end
    end
  endtask

`include "testcase_smoke.svh"

endmodule
