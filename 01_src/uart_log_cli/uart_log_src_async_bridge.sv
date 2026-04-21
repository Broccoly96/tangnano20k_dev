`timescale 1ns / 1ps
`ifndef UART_LOG_SRC_ASYNC_BRIDGE_SV
`define UART_LOG_SRC_ASYNC_BRIDGE_SV
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_src_async_bridge.sv
// Description  : Dual-clock event bridge from a slow log source domain into the
//                uart_log_cli source interface domain.
//////////////////////////////////////////////////////////////////////////////////

module uart_log_src_async_bridge #(
  parameter int unsigned FIFO_DEPTH = 4
) (
  input  logic              I_SRC_CLK,
  input  logic              I_SRC_RST_N,
  input  logic              I_DST_CLK,
  input  logic              I_DST_RST_N,
  uart_log_evt_if.consumer  SRC_IF,
  uart_log_evt_if.producer  DST_IF
);

  localparam int unsigned DATA_W = 104;
  localparam int unsigned ADDR_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
  localparam int unsigned PTR_W  = ADDR_W + 1;

  // Binary to gray encoder
  //    gray = (bin *right-shifted by 1*) XOR bin
  function automatic logic [PTR_W-1:0] bin_to_gray(
    input logic [PTR_W-1:0] bin_value
  );
    begin
      bin_to_gray = (bin_value >> 1) ^ bin_value;
    end
  endfunction


  logic [DATA_W-1:0] r_fifo_mem [0:FIFO_DEPTH-1];
  logic [PTR_W-1:0]  r_wr_ptr_bin;
  logic [PTR_W-1:0]  r_wr_ptr_gray;
  logic [PTR_W-1:0]  r_rd_ptr_bin;
  logic [PTR_W-1:0]  r_rd_ptr_gray;
  logic [PTR_W-1:0]  r_rd_ptr_gray_sync1_src;
  logic [PTR_W-1:0]  r_rd_ptr_gray_sync2_src;
  logic [PTR_W-1:0]  r_wr_ptr_gray_sync1_dst;
  logic [PTR_W-1:0]  r_wr_ptr_gray_sync2_dst;
  logic              r_dst_enable_sync1_src;
  logic              r_dst_enable_sync2_src;
  logic              s_fifo_full;
  logic              s_fifo_empty;
  logic              s_src_push;
  logic              s_dst_pop;
  logic [PTR_W-1:0]  s_wr_ptr_bin_next;
  logic [PTR_W-1:0]  s_wr_ptr_gray_next;
  logic [DATA_W-1:0] s_dst_payload;


  assign SRC_IF.enable      = r_dst_enable_sync2_src;
  assign SRC_IF.evt_ready   = r_dst_enable_sync2_src && !s_fifo_full;
  assign s_src_push         = SRC_IF.evt_valid && SRC_IF.evt_ready;

  assign DST_IF.evt_valid   = !s_fifo_empty;
  assign DST_IF.evt_id      = s_dst_payload[103:96];
  assign DST_IF.arg0        = s_dst_payload[95:64];
  assign DST_IF.arg1        = s_dst_payload[63:32];
  assign DST_IF.arg2        = s_dst_payload[31:0];
  assign s_dst_pop          = DST_IF.evt_valid && DST_IF.evt_ready;
  assign s_dst_payload      = r_fifo_mem[r_rd_ptr_bin[ADDR_W-1:0]];


  //--------------------------------------------------------------------------------------
  // FIFO logic
  //--------------------------------------------------------------------------------------
  assign s_wr_ptr_bin_next  = r_wr_ptr_bin + 1'b1;
  assign s_wr_ptr_gray_next = bin_to_gray(s_wr_ptr_bin_next);

  assign s_fifo_full        = s_wr_ptr_gray_next == {~r_rd_ptr_gray_sync2_src[PTR_W-1:PTR_W-2], r_rd_ptr_gray_sync2_src[PTR_W-3:0]};
  assign s_fifo_empty       = r_rd_ptr_gray == r_wr_ptr_gray_sync2_dst;

  // Synchronizes the currently-selected source enable into the source domain.
  always_ff @(posedge I_SRC_CLK or negedge I_SRC_RST_N) begin
    if (!I_SRC_RST_N) begin
      r_dst_enable_sync1_src <= 1'b0;
      r_dst_enable_sync2_src <= 1'b0;
    end else begin
      r_dst_enable_sync1_src <= DST_IF.enable;
      r_dst_enable_sync2_src <= r_dst_enable_sync1_src;
    end
  end

  // Source-clock write side.
  always_ff @(posedge I_SRC_CLK or negedge I_SRC_RST_N) begin
    if (!I_SRC_RST_N) begin
      r_wr_ptr_bin            <= '0;
      r_wr_ptr_gray           <= '0;
      r_rd_ptr_gray_sync1_src <= '0;
      r_rd_ptr_gray_sync2_src <= '0;
    end else begin
      r_rd_ptr_gray_sync1_src <= r_rd_ptr_gray;
      r_rd_ptr_gray_sync2_src <= r_rd_ptr_gray_sync1_src;

      if (s_src_push) begin
        r_fifo_mem[r_wr_ptr_bin[ADDR_W-1:0]] <= {
          SRC_IF.evt_id,
          SRC_IF.arg0,
          SRC_IF.arg1,
          SRC_IF.arg2
        };
        r_wr_ptr_bin  <= s_wr_ptr_bin_next;
        r_wr_ptr_gray <= s_wr_ptr_gray_next;
      end
    end
  end

  // Destination-clock read side.
  always_ff @(posedge I_DST_CLK or negedge I_DST_RST_N) begin
    if (!I_DST_RST_N) begin
      r_rd_ptr_bin            <= '0;
      r_rd_ptr_gray           <= '0;
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
