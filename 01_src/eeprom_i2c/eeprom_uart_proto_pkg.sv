`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : eeprom_uart_proto_pkg.sv
// Description  : Shared constants and helpers for the 24FC1025 UART host path.
//////////////////////////////////////////////////////////////////////////////////
`ifndef EEPROM_UART_PROTO_PKG_SV
`define EEPROM_UART_PROTO_PKG_SV

package eeprom_uart_proto_pkg;

  localparam int unsigned EEPROM_ADDR_W            = 17;
  localparam int unsigned EEPROM_MAX_ADDR          = 17'h1_FFFF;
  localparam int unsigned EEPROM_BLOCK_BYTES       = 65_536;
  localparam int unsigned EEPROM_PAGE_BYTES        = 128;
  localparam int unsigned EEPROM_BULK_PROGRESS_BYTES = 8;
  localparam int unsigned MAX_BULK_PAYLOAD_BYTES   = 64;
  localparam int unsigned MAX_BULK_PAYLOAD_WORDS   = MAX_BULK_PAYLOAD_BYTES / 4;
  localparam logic [1:0]  EEPROM_CHIP_SELECT       = 2'b00;
  localparam logic [3:0]  EEPROM_I2C_CTRL_CODE     = 4'b1010;

  localparam logic [7:0] ASCII_CMD_R  = 8'h52;
  localparam logic [7:0] ASCII_CMD_W  = 8'h57;
  localparam logic [7:0] ASCII_CMD_B  = 8'h42;
  localparam logic [7:0] ASCII_CMD_LF = 8'h0A;
  localparam logic [7:0] ASCII_CMD_CR = 8'h0D;

  localparam logic [7:0] BULK_SOF0    = 8'h55;
  localparam logic [7:0] BULK_SOF1    = 8'hAA;
  localparam logic [7:0] BULK_WR_DATA = 8'h01;
  localparam logic [7:0] BULK_WR_END  = 8'h02;
  localparam logic [7:0] BULK_RD_DATA = 8'h81;
  localparam logic [7:0] BULK_RD_END  = 8'h82;
  localparam logic [7:0] BULK_ABORT   = 8'hE0;

  localparam logic [7:0] EVT_WRITE_ACK   = 8'h30;
  localparam logic [7:0] EVT_READ_RSP    = 8'h31;
  localparam logic [7:0] EVT_BULK_OK     = 8'h32;
  localparam logic [7:0] EVT_BULK_ERR    = 8'h33;
  localparam logic [7:0] EVT_BULK_PROG   = 8'h34;
  localparam logic [7:0] EVT_BULK_DONE   = 8'h35;
  localparam logic [7:0] EVT_BULK_ABORT  = 8'h36;
  localparam logic [7:0] EVT_CMD_ERR     = 8'h3E;

  localparam logic [31:0] ERR_BAD_ASCII_CMD   = 32'h0000_0001;
  localparam logic [31:0] ERR_BUSY            = 32'h0000_0002;
  localparam logic [31:0] ERR_I2C_TIMEOUT     = 32'h0000_0003;
  localparam logic [31:0] ERR_I2C_NACK        = 32'h0000_0004;
  localparam logic [31:0] ERR_BAD_ASCII_FIELD = 32'h0000_0005;
  localparam logic [31:0] ERR_ADDR_RANGE      = 32'h0000_0006;
  localparam logic [31:0] ERR_BYTE_COUNT      = 32'h0000_0007;
  localparam logic [31:0] ERR_BULK_CRC        = 32'h0000_0008;
  localparam logic [31:0] ERR_BULK_TYPE       = 32'h0000_0009;
  localparam logic [31:0] ERR_BULK_SEQ        = 32'h0000_000A;
  localparam logic [31:0] ERR_BULK_LEN        = 32'h0000_000B;
  localparam logic [31:0] ERR_BULK_ABORT_REQ  = 32'h0000_000C;
  localparam logic [31:0] ERR_UNSUPPORTED     = 32'h0000_000D;
  localparam logic [31:0] ERR_BULK_TIMEOUT    = 32'h0000_000E;

  typedef enum logic [1:0] {
    ASCII_OP_NONE  = 2'd0,
    ASCII_OP_READ  = 2'd1,
    ASCII_OP_WRITE = 2'd2,
    ASCII_OP_BULK  = 2'd3
  } ascii_op_e;

  function automatic logic is_ascii_hex(input logic [7:0] byte_value);
    begin
      is_ascii_hex =
        ((byte_value >= 8'h30) && (byte_value <= 8'h39)) ||
        ((byte_value >= 8'h41) && (byte_value <= 8'h46)) ||
        ((byte_value >= 8'h61) && (byte_value <= 8'h66));
    end
  endfunction

  function automatic logic [3:0] ascii_hex_to_nibble(input logic [7:0] byte_value);
    begin
      if ((byte_value >= 8'h30) && (byte_value <= 8'h39)) begin
        ascii_hex_to_nibble = byte_value[3:0];
      end else if ((byte_value >= 8'h41) && (byte_value <= 8'h46)) begin
        ascii_hex_to_nibble = byte_value - 8'h41 + 4'd10;
      end else begin
        ascii_hex_to_nibble = byte_value - 8'h61 + 4'd10;
      end
    end
  endfunction

  function automatic logic [15:0] crc16_ccitt_false_update(
    input logic [15:0] crc_in,
    input logic [7:0]  data_byte
  );
    logic [15:0] crc_value;
    begin
      crc_value = crc_in ^ {data_byte, 8'h00};
      for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
        if (crc_value[15]) begin
          crc_value = (crc_value << 1) ^ 16'h1021;
        end else begin
          crc_value = (crc_value << 1);
        end
      end
      crc16_ccitt_false_update = crc_value;
    end
  endfunction

  function automatic logic [15:0] calc_bulk_crc16(
    input logic [7:0] type_byte,
    input logic [7:0] seq_byte,
    input logic [15:0] payload_len,
    input logic [MAX_BULK_PAYLOAD_BYTES*8-1:0] payload_bits
  );
    logic [15:0] crc_value;
    begin
      crc_value = 16'hFFFF;
      crc_value = crc16_ccitt_false_update(crc_value, type_byte);
      crc_value = crc16_ccitt_false_update(crc_value, seq_byte);
      crc_value = crc16_ccitt_false_update(crc_value, payload_len[7:0]);
      crc_value = crc16_ccitt_false_update(crc_value, payload_len[15:8]);
      for (int byte_idx = 0; byte_idx < MAX_BULK_PAYLOAD_BYTES; byte_idx++) begin
        if (byte_idx < payload_len) begin
          crc_value = crc16_ccitt_false_update(
            crc_value,
            payload_bits[byte_idx*8 +: 8]
          );
        end
      end
      calc_bulk_crc16 = crc_value;
    end
  endfunction

  function automatic logic [7:0] eeprom_control_byte(
    input logic block_sel,
    input logic is_read
  );
    begin
      eeprom_control_byte = {
        EEPROM_I2C_CTRL_CODE,
        block_sel,
        EEPROM_CHIP_SELECT,
        is_read
      };
    end
  endfunction

  function automatic logic eeprom_crosses_block(
    input logic [16:0] addr,
    input int unsigned byte_count
  );
    int unsigned last_addr;
    begin
      if (byte_count == 0) begin
        eeprom_crosses_block = 1'b0;
      end else begin
        last_addr = addr + byte_count - 1;
        eeprom_crosses_block = addr[16] != last_addr[16];
      end
    end
  endfunction

  function automatic logic eeprom_crosses_page(
    input logic [16:0] addr,
    input int unsigned byte_count
  );
    int unsigned first_page;
    int unsigned last_page;
    begin
      if (byte_count == 0) begin
        eeprom_crosses_page = 1'b0;
      end else begin
        first_page = addr / EEPROM_PAGE_BYTES;
        last_page  = (addr + byte_count - 1) / EEPROM_PAGE_BYTES;
        eeprom_crosses_page = first_page != last_page;
      end
    end
  endfunction

  function automatic logic [31:0] pack_eeprom_bulk_progress_arg0(
    input logic [16:0] addr,
    input logic [7:0]  valid_bytes
  );
    begin
      pack_eeprom_bulk_progress_arg0 = {7'h00, valid_bytes, addr};
    end
  endfunction

endpackage : eeprom_uart_proto_pkg

`endif