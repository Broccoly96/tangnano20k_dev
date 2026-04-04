`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_dual_tap.sv
// Description  : One-source event duplicator for UART and Ethernet consumers.
//                The producer sees a single ready signal.
//                Accepted events are always queued for Ethernet.
//                UART queueing is best-effort and may drop when its private
//                FIFO is full, but Ethernet capture remains prioritized.
//////////////////////////////////////////////////////////////////////////////////

module uart_log_dual_tap #(
  parameter int unsigned FIFO_DEPTH = 4
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic [7:0]  I_SRC_ID,
  input  logic        I_EVT_VALID,
  input  logic [7:0]  I_EVT_ID,
  input  logic [31:0] I_ARG0,
  input  logic [31:0] I_ARG1,
  input  logic [31:0] I_ARG2,
  output logic        O_EVT_READY,

  output logic        O_UART_EVT_VALID,
  output logic [7:0]  O_UART_EVT_ID,
  output logic [31:0] O_UART_ARG0,
  output logic [31:0] O_UART_ARG1,
  output logic [31:0] O_UART_ARG2,
  input  logic        I_UART_EVT_READY,

  output logic        O_ETH_TVALID,
  output logic [127:0] O_ETH_TDATA,
  input  logic        I_ETH_TREADY
);

  localparam int unsigned PTR_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
  localparam int unsigned CNT_W = $clog2(FIFO_DEPTH + 1);

  logic [127:0] r_uart_fifo_mem [0:FIFO_DEPTH-1];
  logic [127:0] r_eth_fifo_mem  [0:FIFO_DEPTH-1];
  logic [PTR_W-1:0] r_uart_wr_ptr;
  logic [PTR_W-1:0] r_uart_rd_ptr;
  logic [PTR_W-1:0] r_eth_wr_ptr;
  logic [PTR_W-1:0] r_eth_rd_ptr;
  logic [CNT_W-1:0] r_uart_count;
  logic [CNT_W-1:0] r_eth_count;

  logic [127:0] l_event_word;
  logic         l_uart_push;
  logic         l_uart_pop;
  logic         l_eth_push;
  logic         l_eth_pop;
  logic         l_uart_full;
  logic         l_uart_empty;
  logic         l_eth_full;
  logic         l_eth_empty;

  assign l_event_word = {
    I_ARG2,
    I_ARG1,
    I_ARG0,
    I_SRC_ID,
    I_EVT_ID,
    16'h0000
  };

  assign l_uart_full  = (r_uart_count == FIFO_DEPTH);
  assign l_uart_empty = (r_uart_count == 0);
  assign l_eth_full   = (r_eth_count == FIFO_DEPTH);
  assign l_eth_empty  = (r_eth_count == 0);

  assign O_EVT_READY = !l_eth_full;

  assign l_eth_push = I_EVT_VALID && O_EVT_READY;
  assign l_eth_pop  = O_ETH_TVALID && I_ETH_TREADY;
  assign l_uart_push = I_EVT_VALID && O_EVT_READY && !l_uart_full;
  assign l_uart_pop  = O_UART_EVT_VALID && I_UART_EVT_READY;

  assign O_ETH_TVALID = !l_eth_empty;
  assign O_ETH_TDATA  = l_eth_empty ? 128'h0 : r_eth_fifo_mem[r_eth_rd_ptr];

  assign O_UART_EVT_VALID = !l_uart_empty;
  assign O_UART_EVT_ID    = l_uart_empty ? 8'h00 : r_uart_fifo_mem[r_uart_rd_ptr][23:16];
  assign O_UART_ARG0      = l_uart_empty ? 32'h0000_0000 : r_uart_fifo_mem[r_uart_rd_ptr][63:32];
  assign O_UART_ARG1      = l_uart_empty ? 32'h0000_0000 : r_uart_fifo_mem[r_uart_rd_ptr][95:64];
  assign O_UART_ARG2      = l_uart_empty ? 32'h0000_0000 : r_uart_fifo_mem[r_uart_rd_ptr][127:96];

  //----------------------------------------------------------------------------
  // Independent UART / Ethernet event FIFOs
  //----------------------------------------------------------------------------
  // Ethernet acceptance is the producer-side backpressure source.
  // UART is best-effort and can silently drop if its FIFO is full while the
  // Ethernet FIFO still has room.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_uart_wr_ptr <= '0;
      r_uart_rd_ptr <= '0;
      r_eth_wr_ptr  <= '0;
      r_eth_rd_ptr  <= '0;
      r_uart_count  <= '0;
      r_eth_count   <= '0;
      r_uart_fifo_mem <= '{default: 128'h0};
      r_eth_fifo_mem  <= '{default: 128'h0};
    end else begin
      if (l_uart_push) begin
        r_uart_fifo_mem[r_uart_wr_ptr] <= l_event_word;
        if (r_uart_wr_ptr == FIFO_DEPTH - 1) begin
          r_uart_wr_ptr <= '0;
        end else begin
          r_uart_wr_ptr <= r_uart_wr_ptr + 1'b1;
        end
      end

      if (l_uart_pop) begin
        if (r_uart_rd_ptr == FIFO_DEPTH - 1) begin
          r_uart_rd_ptr <= '0;
        end else begin
          r_uart_rd_ptr <= r_uart_rd_ptr + 1'b1;
        end
      end

      case ({l_uart_push, l_uart_pop})
        2'b10: r_uart_count <= r_uart_count + 1'b1;
        2'b01: r_uart_count <= r_uart_count - 1'b1;
        default: r_uart_count <= r_uart_count;
      endcase

      if (l_eth_push) begin
        r_eth_fifo_mem[r_eth_wr_ptr] <= l_event_word;
        if (r_eth_wr_ptr == FIFO_DEPTH - 1) begin
          r_eth_wr_ptr <= '0;
        end else begin
          r_eth_wr_ptr <= r_eth_wr_ptr + 1'b1;
        end
      end

      if (l_eth_pop) begin
        if (r_eth_rd_ptr == FIFO_DEPTH - 1) begin
          r_eth_rd_ptr <= '0;
        end else begin
          r_eth_rd_ptr <= r_eth_rd_ptr + 1'b1;
        end
      end

      case ({l_eth_push, l_eth_pop})
        2'b10: r_eth_count <= r_eth_count + 1'b1;
        2'b01: r_eth_count <= r_eth_count - 1'b1;
        default: r_eth_count <= r_eth_count;
      endcase
    end
  end

endmodule
