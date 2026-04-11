`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_proto_pkg.sv
// Description  : Shared constants and helpers for the SDRAM UART host protocol.
//////////////////////////////////////////////////////////////////////////////////
`ifndef SDRAM_UART_PROTO_PKG_SV
`define SDRAM_UART_PROTO_PKG_SV

package sdram_uart_proto_pkg;

  localparam int unsigned SDRAM_ADDR_W            = 21;
  localparam int unsigned LINE_WORDS              = 26;
  localparam int unsigned MAX_BULK_PAYLOAD_BYTES  = 104;
  localparam int unsigned MAX_BULK_PAYLOAD_WORDS  = MAX_BULK_PAYLOAD_BYTES / 4;

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
  localparam logic [31:0] ERR_SDRAM_RD_TO     = 32'h0000_0003;
  localparam logic [31:0] ERR_SDRAM_WR_TO     = 32'h0000_0004;
  localparam logic [31:0] ERR_BAD_ASCII_FIELD = 32'h0000_0005;
  localparam logic [31:0] ERR_ADDR_RANGE      = 32'h0000_0006;
  localparam logic [31:0] ERR_WORD_COUNT      = 32'h0000_0007;
  localparam logic [31:0] ERR_BULK_CRC        = 32'h0000_0008;
  localparam logic [31:0] ERR_BULK_TYPE       = 32'h0000_0009;
  localparam logic [31:0] ERR_BULK_SEQ        = 32'h0000_000A;
  localparam logic [31:0] ERR_BULK_LEN        = 32'h0000_000B;
  localparam logic [31:0] ERR_BULK_ABORT_REQ  = 32'h0000_000C;
  localparam logic [31:0] ERR_UNSUPPORTED     = 32'h0000_000D;

  typedef enum logic [1:0] {
    ASCII_OP_NONE = 2'd0,
    ASCII_OP_READ = 2'd1,
    ASCII_OP_WRITE = 2'd2,
    ASCII_OP_BULK = 2'd3
  } ascii_op_e;

  typedef enum logic [0:0] {
    BULK_DIR_WRITE = 1'b0,
    BULK_DIR_READ  = 1'b1
  } bulk_dir_e;

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

endpackage : sdram_uart_proto_pkg

`endif
