`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_host_mux.sv
// Description  : Small request arbiter between ASCII single-access commands and
//                bulk-session generated accesses.
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_host_mux (
  input  logic        I_BULK_ACTIVE,
  input  logic        I_ASCII_REQ_VALID,
  input  logic        I_ASCII_REQ_IS_WRITE,
  input  logic [20:0] I_ASCII_REQ_ADDR,
  input  logic [31:0] I_ASCII_REQ_DATA,
  output logic        O_ASCII_REQ_READY,
  input  logic        I_BULK_REQ_VALID,
  input  logic        I_BULK_REQ_IS_WRITE,
  input  logic [20:0] I_BULK_REQ_ADDR,
  input  logic [31:0] I_BULK_REQ_DATA,
  output logic        O_BULK_REQ_READY,
  output logic        O_REQ_VALID,
  output logic        O_REQ_IS_WRITE,
  output logic [20:0] O_REQ_ADDR,
  output logic [31:0] O_REQ_DATA,
  input  logic        I_REQ_READY
);

  always_comb begin
    O_ASCII_REQ_READY = 1'b0;
    O_BULK_REQ_READY  = 1'b0;
    O_REQ_VALID       = 1'b0;
    O_REQ_IS_WRITE    = 1'b0;
    O_REQ_ADDR        = '0;
    O_REQ_DATA        = '0;

    if (I_BULK_ACTIVE) begin
      O_REQ_VALID      = I_BULK_REQ_VALID;
      O_REQ_IS_WRITE   = I_BULK_REQ_IS_WRITE;
      O_REQ_ADDR       = I_BULK_REQ_ADDR;
      O_REQ_DATA       = I_BULK_REQ_DATA;
      O_BULK_REQ_READY = I_REQ_READY;
    end else begin
      O_REQ_VALID       = I_ASCII_REQ_VALID;
      O_REQ_IS_WRITE    = I_ASCII_REQ_IS_WRITE;
      O_REQ_ADDR        = I_ASCII_REQ_ADDR;
      O_REQ_DATA        = I_ASCII_REQ_DATA;
      O_ASCII_REQ_READY = I_REQ_READY;
    end
  end

endmodule
