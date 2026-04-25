`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : ssd1331_uart_proto_pkg.sv
// Description  : Shared SSD1331 display host protocol constants.
//////////////////////////////////////////////////////////////////////////////////

package ssd1331_uart_proto_pkg;

  typedef enum logic [2:0] {
    DISP_OP_INIT    = 3'd0,
    DISP_OP_CLEAR   = 3'd1,
    DISP_OP_FILL    = 3'd2,
    DISP_OP_PATTERN = 3'd3,
    DISP_OP_ON      = 3'd4,
    DISP_OP_OFF     = 3'd5
  } disp_op_e;

  localparam logic [7:0] ASCII_CMD_INIT    = 8'h49; // I
  localparam logic [7:0] ASCII_CMD_CLEAR   = 8'h43; // C
  localparam logic [7:0] ASCII_CMD_FILL    = 8'h46; // F
  localparam logic [7:0] ASCII_CMD_PATTERN = 8'h50; // P
  localparam logic [7:0] ASCII_CMD_ON      = 8'h4F; // O
  localparam logic [7:0] ASCII_CMD_OFF     = 8'h58; // X

  localparam logic [7:0] EVT_CMD_ACK       = 8'h30;
  localparam logic [7:0] EVT_CMD_ERR       = 8'h3E;

  localparam logic [31:0] ERR_BAD_ASCII_FIELD = 32'h4453_0001;
  localparam logic [31:0] ERR_UNSUPPORTED_CMD = 32'h4453_0002;
  localparam logic [31:0] ERR_BUSY             = 32'h4453_0003;

endpackage