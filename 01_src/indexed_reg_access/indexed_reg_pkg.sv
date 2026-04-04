`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : indexed_reg_pkg.sv
// Description  : Package that owns the 16-bit indirect CONF index allocation.
//                index[15:8] is block_id and index[7:0] is reg_id.
//////////////////////////////////////////////////////////////////////////////////

package indexed_reg_pkg;

  localparam logic [7:0] CONF_BLOCK_TOP   = 8'h00;

  localparam logic [7:0] TOP_CONF_REG_ID        = 8'h00;
  localparam logic [7:0] TOP_CONF_REG_SCRATCH   = 8'h01;
  localparam logic [7:0] TOP_CONF_REG_WR_COUNT  = 8'h02;
  localparam logic [7:0] TOP_CONF_REG_LAST_DATA = 8'h03;
  localparam logic [7:0] TOP_CONF_REG_SNAPSHOT_REQ = 8'h04;
  localparam logic [7:0] TOP_CONF_REG_STATUS       = 8'h05;
  localparam logic [7:0] TOP_CONF_REG_UPTIME_LO     = 8'h06;
  localparam logic [7:0] TOP_CONF_REG_UPTIME_HI     = 8'h07;
  localparam logic [7:0] TOP_CONF_REG_SNAPSHOT_COUNT = 8'h08;

endpackage : indexed_reg_pkg
