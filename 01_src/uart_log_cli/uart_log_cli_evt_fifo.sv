`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_cli_evt_fifo.sv
// Description  : Shared event FIFO wrapper for uart_log_cli.
//                - Unified 128-bit payload FIFO interface for producer/consumer.
//                - Uses the common sync_fifo_ae_af implementation so simulation
//                  and synthesis share the same FIFO behavior in this repository.
//
// Usage example:
//   uart_log_cli_evt_fifo u_evt_fifo (
//     .I_CLK(clk), .I_RST_N(rst_n),
//     .I_WR_EN(wr_en), .I_WR_DATA(wr_data), .O_FULL(full),
//     .I_RD_EN(rd_en), .O_RD_DATA(rd_data), .O_EMPTY(empty)
//   );
//////////////////////////////////////////////////////////////////////////////////

module uart_log_cli_evt_fifo (
  input  logic         I_CLK,
  input  logic         I_RST_N,
  input  logic         I_WR_EN,
  input  logic [127:0] I_WR_DATA,
  output logic         O_FULL,
  input  logic         I_RD_EN,
  output logic [127:0] O_RD_DATA,
  output logic         O_EMPTY
);

  localparam int unsigned FIFO_DEPTH = 2048;
  localparam int unsigned AE_TH = 2;
  localparam int unsigned AF_TH = FIFO_DEPTH - 16;

  logic s_almost_empty;
  logic s_almost_full;

  //------------------------------------------------------------------------------
  // Shared FIFO model
  //------------------------------------------------------------------------------
  // sync_fifo_ae_af provides behavior-equivalent buffering for ModelSim flow.
  // The wrapper keeps the interface stable for uart_log_cli while remaining
  // self-contained for this repository.
  sync_fifo_ae_af #(
    .C_DATA_WIDTH             (128),
    .C_FIFO_DEPTH             (FIFO_DEPTH),
    .C_ALMOST_EMPTY_THRESHOLD (AE_TH),
    .C_ALMOST_FULL_THRESHOLD  (AF_TH)
  ) u_sim_fifo (
    .I_CLK               (I_CLK),
    .I_RST_N             (I_RST_N),
    .I_WRITE_EN          (I_WR_EN),
    .I_READ_EN           (I_RD_EN),
    .I_DATA_IN           (I_WR_DATA),
    .O_DATA_OUT          (O_RD_DATA),
    .O_FIFO_EMPTY        (O_EMPTY),
    .O_FIFO_FULL         (O_FULL),
    .O_FIFO_ALMOST_EMPTY (s_almost_empty),
    .O_FIFO_ALMOST_FULL  (s_almost_full)
  );

endmodule
