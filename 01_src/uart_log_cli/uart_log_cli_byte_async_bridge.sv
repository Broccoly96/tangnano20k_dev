`timescale 1ns / 1ps
`ifndef UART_LOG_CLI_BYTE_ASYNC_BRIDGE_SV
`define UART_LOG_CLI_BYTE_ASYNC_BRIDGE_SV
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_cli_byte_async_bridge.sv
// Description  : Dual-clock byte FIFO used to carry CLI RX bytes from the
//                uart_log_cli clock domain into the SDRAM host-interface domain.
//////////////////////////////////////////////////////////////////////////////////

module uart_log_cli_byte_async_bridge #(
  parameter int unsigned FIFO_DEPTH = 16
) (
  input  logic       I_SRC_CLK,
  input  logic       I_SRC_RST_N,
  input  logic       I_DST_CLK,
  input  logic       I_DST_RST_N,
  input  logic       I_SRC_VALID,
  input  logic [7:0] I_SRC_DATA,
  output logic       O_SRC_READY,
  output logic       O_DST_VALID,
  output logic [7:0] O_DST_DATA,
  input  logic       I_DST_READY
);

  localparam int unsigned ADDR_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
  localparam int unsigned PTR_W  = ADDR_W + 1;

  logic [7:0]         r_fifo_mem [0:FIFO_DEPTH-1];
  logic [PTR_W-1:0]   r_wr_ptr_bin;
  logic [PTR_W-1:0]   r_wr_ptr_gray;
  logic [PTR_W-1:0]   r_rd_ptr_bin;
  logic [PTR_W-1:0]   r_rd_ptr_gray;
  logic [PTR_W-1:0]   r_rd_ptr_gray_sync1_src;
  logic [PTR_W-1:0]   r_rd_ptr_gray_sync2_src;
  logic [PTR_W-1:0]   r_wr_ptr_gray_sync1_dst;
  logic [PTR_W-1:0]   r_wr_ptr_gray_sync2_dst;
  logic               s_fifo_full;
  logic               s_fifo_empty;
  logic               s_src_push;
  logic               s_dst_pop;
  logic [PTR_W-1:0]   s_wr_ptr_bin_next;
  logic [PTR_W-1:0]   s_wr_ptr_gray_next;

  function automatic logic [PTR_W-1:0] bin_to_gray(
    input logic [PTR_W-1:0] bin_value
  );
    begin
      bin_to_gray = (bin_value >> 1) ^ bin_value;
    end
  endfunction

  assign s_wr_ptr_bin_next  = r_wr_ptr_bin + 1'b1;
  assign s_wr_ptr_gray_next = bin_to_gray(s_wr_ptr_bin_next);
  assign s_fifo_full = (
    s_wr_ptr_gray_next ==
    {~r_rd_ptr_gray_sync2_src[PTR_W-1:PTR_W-2],
      r_rd_ptr_gray_sync2_src[PTR_W-3:0]}
  );
  assign s_fifo_empty = (r_rd_ptr_gray == r_wr_ptr_gray_sync2_dst);
  assign s_src_push   = I_SRC_VALID && !s_fifo_full;
  assign O_SRC_READY  = !s_fifo_full;
  assign O_DST_VALID  = !s_fifo_empty;
  assign O_DST_DATA   = r_fifo_mem[r_rd_ptr_bin[ADDR_W-1:0]];
  assign s_dst_pop    = O_DST_VALID && I_DST_READY;

  // Tracks the destination read pointer in the source clock domain so the write
  // side can determine when the FIFO is full.
  always_ff @(posedge I_SRC_CLK or negedge I_SRC_RST_N) begin
    if (!I_SRC_RST_N) begin
      r_wr_ptr_bin          <= '0;
      r_wr_ptr_gray         <= '0;
      r_rd_ptr_gray_sync1_src <= '0;
      r_rd_ptr_gray_sync2_src <= '0;
    end else begin
      r_rd_ptr_gray_sync1_src <= r_rd_ptr_gray;
      r_rd_ptr_gray_sync2_src <= r_rd_ptr_gray_sync1_src;

      if (s_src_push) begin
        r_fifo_mem[r_wr_ptr_bin[ADDR_W-1:0]] <= I_SRC_DATA;
        r_wr_ptr_bin  <= s_wr_ptr_bin_next;
        r_wr_ptr_gray <= s_wr_ptr_gray_next;
      end
    end
  end

  // Tracks the source write pointer in the destination clock domain so the read
  // side can determine when a byte is available.
  always_ff @(posedge I_DST_CLK or negedge I_DST_RST_N) begin
    if (!I_DST_RST_N) begin
      r_rd_ptr_bin          <= '0;
      r_rd_ptr_gray         <= '0;
      r_wr_ptr_gray_sync1_dst <= '0;
      r_wr_ptr_gray_sync2_dst <= '0;
    end else begin
      r_wr_ptr_gray_sync1_dst <= r_wr_ptr_gray;
      r_wr_ptr_gray_sync2_dst <= r_wr_ptr_gray_sync1_dst;

      if (s_dst_pop) begin
        r_rd_ptr_bin  <= r_rd_ptr_bin + 1'b1;
        r_rd_ptr_gray <= bin_to_gray(r_rd_ptr_bin + 1'b1);
      end
    end
  end

endmodule
`endif
