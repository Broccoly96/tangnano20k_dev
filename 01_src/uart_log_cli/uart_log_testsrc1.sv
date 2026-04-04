`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_testsrc1.sv
// Description  : Pseudo log source #1 for uart_log_cli integration testing.
//                Emits one event every PERIOD_CYCLES clocks with a fixed
//                event_id.
//
// Usage example:
//   uart_log_testsrc1 #(
//     .CLK_HZ(50_000_000),
//     .PERIOD_CYCLES(500_000_000)
//   ) u_src1 (...);
//////////////////////////////////////////////////////////////////////////////////

module uart_log_testsrc1 #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned PERIOD_CYCLES = CLK_HZ
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_ENABLE,
  input  logic        I_EVT_READY,
  output logic        O_EVT_VALID,
  output logic [7:0]  O_EVT_ID,
  output logic [31:0] O_ARG0,
  output logic [31:0] O_ARG1,
  output logic [31:0] O_ARG2
);

  localparam int unsigned CNT_W = $clog2(PERIOD_CYCLES);

  logic [CNT_W-1:0] r_period_cnt;
  logic             r_pending;
  logic [31:0]      r_heartbeat_count;

  //------------------------------------------------------------------------------
  // Periodic trigger and handshake FSM
  //------------------------------------------------------------------------------
  // Behavior:
  // - Raises pending once every PERIOD_CYCLES clocks.
  // - Emits O_EVT_VALID for exactly one cycle when selected source is enabled
  //   and downstream tap is ready.
  // Transition condition:
  // - pending clears only on successful handshake.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_period_cnt       <= '0;
      r_pending          <= 1'b0;
      r_heartbeat_count  <= 32'h0000_0000;
      O_EVT_VALID        <= 1'b0;
      O_EVT_ID           <= 8'h11;
      O_ARG0             <= 32'h0000_0000;
      O_ARG1             <= 32'h0000_0000;
      O_ARG2             <= 32'h0000_0000;
    end else begin
      O_EVT_VALID <= 1'b0;

      if (r_period_cnt == PERIOD_CYCLES - 1) begin
        r_period_cnt <= '0;
        r_pending    <= 1'b1;
      end else begin
        r_period_cnt <= r_period_cnt + 1'b1;
      end

      if (r_pending && I_ENABLE && I_EVT_READY) begin
        O_EVT_VALID       <= 1'b1;
        O_ARG0            <= r_heartbeat_count;
        r_heartbeat_count <= r_heartbeat_count + 1'b1;
        r_pending         <= 1'b0;
      end
    end
  end

endmodule
