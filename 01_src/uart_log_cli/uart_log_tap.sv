`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_tap.sv
// Description  : Per-source log adapter with a fixed 2-entry FIFO.
//                Each accepted event is one 128-bit beat. The tap exports a
//                minimal AXI-Stream-like interface (TVALID/TREADY/TDATA).
//                If FIFO is full, incoming events are dropped (no drop event).
//
// Usage example:
//   uart_log_tap u_tap (
//     .I_CLK(clk), .I_RST_N(rst_n), .I_ENABLE(src_enable),
//     .I_EVT_VALID(src_evt_valid), .I_EVT_DATA(src_evt_payload),
//     .O_EVT_READY(src_evt_ready), .O_TVALID(tvalid),
//     .I_TREADY(tready), .O_TDATA(tdata)
//   );
//////////////////////////////////////////////////////////////////////////////////

module uart_log_tap (
  input  logic         I_CLK,
  input  logic         I_RST_N,
  input  logic         I_ENABLE,
  input  logic         I_EVT_VALID,
  input  logic [127:0] I_EVT_DATA,
  output logic         O_EVT_READY,
  output logic         O_TVALID,
  input  logic         I_TREADY,
  output logic [127:0] O_TDATA
);

  localparam int unsigned FIFO_DEPTH = 2;
  localparam int unsigned PTR_W = $clog2(FIFO_DEPTH);
  localparam int unsigned CNT_W = $clog2(FIFO_DEPTH + 1);

  logic [127:0] r_fifo_mem [0:FIFO_DEPTH-1];
  logic [PTR_W-1:0] r_wr_ptr;
  logic [PTR_W-1:0] r_rd_ptr;
  logic [CNT_W-1:0] r_count;

  logic s_push;
  logic s_pop;
  logic s_fifo_empty;
  logic s_fifo_full;

  assign s_fifo_empty = (r_count == 0);
  assign s_fifo_full  = (r_count == FIFO_DEPTH);

  // The source is only allowed to push when this tap is enabled and has room.
  assign O_EVT_READY = I_ENABLE && !s_fifo_full;

  // AXIS-like output side advertises one-beat availability.
  assign O_TVALID = !s_fifo_empty;
  assign O_TDATA  = s_fifo_empty ? 128'h0 : r_fifo_mem[r_rd_ptr];

  assign s_push = I_ENABLE && I_EVT_VALID && !s_fifo_full;
  assign s_pop  = O_TVALID && I_TREADY;

  //------------------------------------------------------------------------------
  // FIFO storage and pointer updates
  //------------------------------------------------------------------------------
  // This process handles all FIFO actions:
  //  - Push writes at wr_ptr and increments wr_ptr.
  //  - Pop increments rd_ptr.
  //  - Count reflects push/pop combinations.
  // Simultaneous push+pop is supported and keeps occupancy unchanged.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_wr_ptr <= '0;
      r_rd_ptr <= '0;
      r_count  <= '0;
      r_fifo_mem <= '{default: 128'h0};
    end else begin
      if (s_push) begin
        r_fifo_mem[r_wr_ptr] <= I_EVT_DATA;
        if (r_wr_ptr == FIFO_DEPTH - 1) begin
          r_wr_ptr <= '0;
        end else begin
          r_wr_ptr <= r_wr_ptr + 1'b1;
        end
      end

      if (s_pop) begin
        if (r_rd_ptr == FIFO_DEPTH - 1) begin
          r_rd_ptr <= '0;
        end else begin
          r_rd_ptr <= r_rd_ptr + 1'b1;
        end
      end

      case ({s_push, s_pop})
        2'b10: r_count <= r_count + 1'b1;
        2'b01: r_count <= r_count - 1'b1;
        default: r_count <= r_count;
      endcase
    end
  end

endmodule
