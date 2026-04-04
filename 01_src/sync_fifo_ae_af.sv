`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sync_fifo_ae_af.sv
// Description  : Generic single-clock FIFO with empty/full and almost-empty/
//                almost-full status outputs.
//////////////////////////////////////////////////////////////////////////////////

module sync_fifo_ae_af #(
  parameter int unsigned C_DATA_WIDTH = 8,
  parameter int unsigned C_FIFO_DEPTH = 16,
  parameter int unsigned C_ALMOST_EMPTY_THRESHOLD = 1,
  parameter int unsigned C_ALMOST_FULL_THRESHOLD = C_FIFO_DEPTH - 1
) (
  input  logic                        I_CLK,
  input  logic                        I_RST_N,
  input  logic                        I_WRITE_EN,
  input  logic                        I_READ_EN,
  input  logic [C_DATA_WIDTH-1:0]     I_DATA_IN,
  output logic [C_DATA_WIDTH-1:0]     O_DATA_OUT,
  output logic                        O_FIFO_EMPTY,
  output logic                        O_FIFO_FULL,
  output logic                        O_FIFO_ALMOST_EMPTY,
  output logic                        O_FIFO_ALMOST_FULL
);

  localparam int unsigned PTR_W = (C_FIFO_DEPTH <= 1) ? 1 : $clog2(C_FIFO_DEPTH);
  localparam int unsigned CNT_W = $clog2(C_FIFO_DEPTH + 1);

  logic [C_DATA_WIDTH-1:0] r_fifo_mem [0:C_FIFO_DEPTH-1];
  logic [PTR_W-1:0]        r_wr_ptr;
  logic [PTR_W-1:0]        r_rd_ptr;
  logic [CNT_W-1:0]        r_count;
  logic                    l_write_ok;
  logic                    l_read_ok;

  assign O_FIFO_EMPTY = (r_count == 0);
  assign O_FIFO_FULL  = (r_count == C_FIFO_DEPTH);
  assign O_FIFO_ALMOST_EMPTY = (r_count <= C_ALMOST_EMPTY_THRESHOLD);
  assign O_FIFO_ALMOST_FULL  = (r_count >= C_ALMOST_FULL_THRESHOLD);

  assign l_write_ok = I_WRITE_EN && !O_FIFO_FULL;
  assign l_read_ok  = I_READ_EN && !O_FIFO_EMPTY;

  // Provides one-cycle-latency synchronous read data while keeping memory
  // inference straightforward for synthesis.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_wr_ptr  <= '0;
      r_rd_ptr  <= '0;
      r_count   <= '0;
      O_DATA_OUT <= '0;
    end else begin
      if (l_write_ok) begin
        r_fifo_mem[r_wr_ptr] <= I_DATA_IN;
        if (r_wr_ptr == C_FIFO_DEPTH - 1) begin
          r_wr_ptr <= '0;
        end else begin
          r_wr_ptr <= r_wr_ptr + 1'b1;
        end
      end

      if (l_read_ok) begin
        O_DATA_OUT <= r_fifo_mem[r_rd_ptr];
        if (r_rd_ptr == C_FIFO_DEPTH - 1) begin
          r_rd_ptr <= '0;
        end else begin
          r_rd_ptr <= r_rd_ptr + 1'b1;
        end
      end

      case ({l_write_ok, l_read_ok})
        2'b10: r_count <= r_count + 1'b1;
        2'b01: r_count <= r_count - 1'b1;
        default: r_count <= r_count;
      endcase
    end
  end

endmodule
