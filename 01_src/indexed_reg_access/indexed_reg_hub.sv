`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : indexed_reg_hub.sv
// Description  : Top-level decoder for the indirect CONF window.
//                Only the selected block sees the write pulse.
//                Read data is a combinational mux of the selected block.
//////////////////////////////////////////////////////////////////////////////////

module indexed_reg_hub (
  input  logic [15:0] I_CONF_INDEX,
  input  logic        I_CONF_WR_EN,
  input  logic [31:0] I_CONF_WR_DATA,
  output logic [31:0] O_CONF_RD_DATA,

  output logic        O_TOP_SEL,
  output logic [7:0]  O_TOP_REG_ID,
  output logic        O_TOP_WR_EN,
  output logic [31:0] O_TOP_WR_DATA,
  input  logic [31:0] I_TOP_RD_DATA
);

  import indexed_reg_pkg::*;

  logic [7:0] l_block_id;

  assign l_block_id   = I_CONF_INDEX[15:8];
  assign O_TOP_SEL    = (l_block_id == CONF_BLOCK_TOP);
  assign O_TOP_REG_ID = I_CONF_INDEX[7:0];
  assign O_TOP_WR_EN  = I_CONF_WR_EN && O_TOP_SEL;
  assign O_TOP_WR_DATA = I_CONF_WR_DATA;

  always_comb begin
    if (O_TOP_SEL) begin
      O_CONF_RD_DATA = I_TOP_RD_DATA;
    end else begin
      O_CONF_RD_DATA = 32'h0000_0000;
    end
  end

endmodule
