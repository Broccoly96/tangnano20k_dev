`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_raw_word_bram.sv
// Description  : Small 32-bit synchronous word RAM for SDRAM raw payload buffers.
//                The storage array is intentionally not reset so Gowin can infer
//                BSRAM. Read data is registered and valid one clock after read
//                enable/address are supplied.
//////////////////////////////////////////////////////////////////////////////////

module sdram_raw_word_bram #(
  parameter int unsigned ADDR_W = 7,
  parameter int unsigned DEPTH  = 128
) (
  input  logic              I_CLK,
  input  logic              I_WR_EN,
  input  logic [ADDR_W-1:0] I_WR_ADDR,
  input  logic [31:0]       I_WR_DATA,
  input  logic              I_RD_EN,
  input  logic [ADDR_W-1:0] I_RD_ADDR,
  output logic [31:0]       O_RD_DATA
);

  logic [31:0] r_mem [0:DEPTH-1];

  // BSRAM inference block:
  // - write port stores one 32-bit word when I_WR_EN is asserted.
  // - read port updates O_RD_DATA one cycle after I_RD_EN.
  // - memory contents are not reset because block RAM reset is not available.
  always_ff @(posedge I_CLK) begin
    if (I_WR_EN) begin
      r_mem[I_WR_ADDR] <= I_WR_DATA;
    end

    if (I_RD_EN) begin
      O_RD_DATA <= r_mem[I_RD_ADDR];
    end
  end

endmodule
