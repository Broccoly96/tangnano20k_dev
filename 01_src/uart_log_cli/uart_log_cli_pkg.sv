`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_cli_pkg.sv
// Description  : Shared constants and helper functions for UART log CLI.
//                The package defines frame constants, command/event IDs,
//                payload pack helpers, CRC-8/ATM logic, and source-select
//                wrap helpers used by the uart_log_cli core and testbench.
//
// Usage example:
//   import uart_log_cli_pkg::*;
//   logic [127:0] payload;
//   payload = pack_event_payload(8'h01, 8'h10, 16'h1234, 32'h1, 32'h2, 32'h3);
//////////////////////////////////////////////////////////////////////////////////
`ifndef UART_LOG_CLI_PKG_SV
`define UART_LOG_CLI_PKG_SV

package uart_log_cli_pkg;

  // UART frame constants.
  localparam logic [7:0] UART_SYNC_BYTE = 8'h7E;
  localparam int unsigned FRAME_PAYLOAD_BYTES = 16;
  localparam int unsigned FRAME_TOTAL_BYTES = 19;  // SYNC + SEQ + 16B + CRC

  // System-reserved IDs.
  localparam logic [7:0] SYS_SRC_ID       = 8'h00;
  localparam logic [7:0] EV_MODE_CHANGE   = 8'h01;
  localparam logic [7:0] EV_HELP          = 8'h02;
  localparam logic [7:0] EV_RESET_ACK     = 8'h03;

  // CLI commands.
  localparam logic [7:0] CMD_HELP         = 8'h3F;  // '?'
  localparam logic [7:0] CMD_SOFT_RESET   = 8'h12;  // Ctrl+R
  localparam logic [7:0] CMD_NEXT_SRC     = 8'h06;  // Ctrl+F
  localparam logic [7:0] CMD_PREV_SRC     = 8'h04;  // Ctrl+D
  localparam logic [7:0] CMD_STATUS_REQ   = 8'h14;  // Ctrl+T
  localparam logic [7:0] CMD_LITERAL_NEXT = 8'h10;  // DLE

  //------------------------------------------------------------------------------
  // pack_event_payload
  //------------------------------------------------------------------------------
  // Builds a 16-byte payload from fixed fields:
  //   Word0 = {src_id, event_id, timestamp}
  //   Word1 = arg0
  //   Word2 = arg1
  //   Word3 = arg2
  // Byte order on UART is little-endian by word when consumers emit [7:0] first.
  // Packs source/event metadata and arguments into the common UART event payload.
  function automatic logic [127:0] pack_event_payload(
    input logic [7:0]  src_id,
    input logic [7:0]  event_id,
    input logic [15:0] timestamp,
    input logic [31:0] arg0,
    input logic [31:0] arg1,
    input logic [31:0] arg2
  );
    logic [31:0] word0;
    begin
      word0 = {src_id, event_id, timestamp};
      pack_event_payload = {arg2, arg1, arg0, word0};
    end
  endfunction

  //------------------------------------------------------------------------------
  // crc8_atm_update
  //------------------------------------------------------------------------------
  // Updates CRC-8/ATM state for one byte:
  //   poly   = 0x07
  //   init   = 0x00
  //   refin  = false
  //   refout = false
  //   xorout = 0x00
  // Updates the CRC-8/ATM accumulator with one input byte.
  function automatic logic [7:0] crc8_atm_update(
    input logic [7:0] crc_in,
    input logic [7:0] data_byte
  );
    logic [7:0] crc;
    begin
      crc = crc_in ^ data_byte;
      for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
        if (crc[7]) begin
          crc = (crc << 1) ^ 8'h07;
        end else begin
          crc = (crc << 1);
        end
      end
      crc8_atm_update = crc;
    end
  endfunction

  //------------------------------------------------------------------------------
  // calc_frame_crc
  //------------------------------------------------------------------------------
  // Calculates frame CRC over {SEQ, PAYLOAD[0], ... PAYLOAD[15]}.
  // SYNC is intentionally excluded by specification.
  // Calculates the frame CRC across sequence number and 128-bit payload.
  function automatic logic [7:0] calc_frame_crc(
    input logic [7:0]   seq,
    input logic [127:0] payload
  );
    logic [7:0] crc;
    begin
      crc = 8'h00;
      crc = crc8_atm_update(crc, seq);
      for (int byte_idx = 0; byte_idx < FRAME_PAYLOAD_BYTES; byte_idx++) begin
        crc = crc8_atm_update(crc, payload[byte_idx*8 +: 8]);
      end
      calc_frame_crc = crc;
    end
  endfunction

  //------------------------------------------------------------------------------
  // sel_next / sel_prev
  //------------------------------------------------------------------------------
  // Source-select helpers that never return invalid values, even when NUM_SRC
  // is not a power of two.
  // Advances the source selector and wraps at the active source count.
  function automatic int unsigned sel_next(
    input int unsigned current_sel,
    input int unsigned num_src
  );
    begin
      if (num_src <= 1) begin
        sel_next = 0;
      end else if (current_sel >= (num_src - 1)) begin
        sel_next = 0;
      end else begin
        sel_next = current_sel + 1;
      end
    end
  endfunction

  // Decrements the source selector and wraps at the active source count.
  function automatic int unsigned sel_prev(
    input int unsigned current_sel,
    input int unsigned num_src
  );
    begin
      if (num_src <= 1) begin
        sel_prev = 0;
      end else if (current_sel == 0) begin
        sel_prev = num_src - 1;
      end else begin
        sel_prev = current_sel - 1;
      end
    end
  endfunction

endpackage : uart_log_cli_pkg

`endif  // UART_LOG_CLI_PKG_SV
