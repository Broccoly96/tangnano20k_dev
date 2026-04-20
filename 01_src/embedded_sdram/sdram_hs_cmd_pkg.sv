`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_hs_cmd_pkg.sv
// Description  : Shared command and timing constants for the Gowin SDRAM
//                Controller HS native user interface.
//                Commands are encoded as {RAS#, CAS#, WE#}, matching IPUG756.
//////////////////////////////////////////////////////////////////////////////////

package sdram_hs_cmd_pkg;

  localparam int unsigned SDRAM_HS_DATA_WIDTH = 32;
  localparam int unsigned SDRAM_HS_BANK_WIDTH = 2;
  localparam int unsigned SDRAM_HS_ROW_WIDTH  = 11;
  localparam int unsigned SDRAM_HS_COL_WIDTH  = 8;
  localparam int unsigned SDRAM_HS_CL         = 3;
  localparam int unsigned SDRAM_HS_TRP        = 3;
  localparam int unsigned SDRAM_HS_TRFC       = 9;
  localparam int unsigned SDRAM_HS_TMRD       = 3;
  localparam int unsigned SDRAM_HS_TRCD       = 3;
  localparam int unsigned SDRAM_HS_TWR        = 3;
  localparam int unsigned SDRAM_HS_READ_DATA_LATENCY_CYCLES = SDRAM_HS_CL + 2;
  localparam int unsigned SDRAM_HS_REFRESH_INTERVAL_CYCLES  = 720;

  typedef enum logic [2:0] {
    SDRAM_HS_CMD_LOAD_MODE       = 3'b000,
    SDRAM_HS_CMD_AUTO_REFRESH    = 3'b001,
    SDRAM_HS_CMD_PRECHARGE       = 3'b010,
    SDRAM_HS_CMD_ACTIVE          = 3'b011,
    SDRAM_HS_CMD_WRITE           = 3'b100,
    SDRAM_HS_CMD_READ            = 3'b101,
    SDRAM_HS_CMD_BURST_TERMINATE = 3'b110,
    SDRAM_HS_CMD_NOP             = 3'b111
  } sdram_hs_cmd_e;

  function automatic logic [20:0] sdram_hs_pack_addr(
    input logic [1:0]  bank,
    input logic [10:0] row,
    input logic [7:0]  col
  );
    sdram_hs_pack_addr = {bank, row, col};
  endfunction

  function automatic logic sdram_hs_burst_crosses_page(
    input logic [20:0] addr,
    input logic [7:0]  data_len
  );
    logic [8:0] last_col;
    begin
      last_col = {1'b0, addr[7:0]} + {1'b0, data_len};
      sdram_hs_burst_crosses_page = last_col[8];
    end
  endfunction

  function automatic string sdram_hs_cmd_name(
    input logic [2:0] cmd
  );
    case (cmd)
      SDRAM_HS_CMD_LOAD_MODE:       sdram_hs_cmd_name = "LOAD_MODE";
      SDRAM_HS_CMD_AUTO_REFRESH:    sdram_hs_cmd_name = "AUTO_REFRESH";
      SDRAM_HS_CMD_PRECHARGE:       sdram_hs_cmd_name = "PRECHARGE";
      SDRAM_HS_CMD_ACTIVE:          sdram_hs_cmd_name = "ACTIVE";
      SDRAM_HS_CMD_WRITE:           sdram_hs_cmd_name = "WRITE";
      SDRAM_HS_CMD_READ:            sdram_hs_cmd_name = "READ";
      SDRAM_HS_CMD_BURST_TERMINATE: sdram_hs_cmd_name = "BURST_TERMINATE";
      SDRAM_HS_CMD_NOP:             sdram_hs_cmd_name = "NOP";
      default:                      sdram_hs_cmd_name = "UNKNOWN";
    endcase
  endfunction

endpackage : sdram_hs_cmd_pkg
