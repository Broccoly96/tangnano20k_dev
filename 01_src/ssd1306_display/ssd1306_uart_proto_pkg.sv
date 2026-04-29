`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : ssd1306_uart_proto_pkg.sv
// Description  : Shared constants and helpers for the SSD1306 UART host path.
//////////////////////////////////////////////////////////////////////////////////
`ifndef SSD1306_UART_PROTO_PKG_SV
`define SSD1306_UART_PROTO_PKG_SV

package ssd1306_uart_proto_pkg;

  localparam int unsigned SSD1306_WIDTH              = 128;
  localparam int unsigned SSD1306_HEIGHT             = 32;
  localparam int unsigned SSD1306_PAGE_COUNT         = SSD1306_HEIGHT / 8;
  localparam int unsigned SSD1306_FRAME_BYTES        = SSD1306_WIDTH * SSD1306_PAGE_COUNT;
  localparam logic [6:0]  SSD1306_DEFAULT_SLAVE_ADDR = 7'h3C;
  localparam logic [7:0]  SSD1306_CTRL_CMD           = 8'h00;
  localparam logic [7:0]  SSD1306_CTRL_DATA          = 8'h40;

  localparam int unsigned MAX_BULK_PAYLOAD_BYTES     = 64;
  localparam int unsigned MAX_BULK_PAYLOAD_WORDS     = MAX_BULK_PAYLOAD_BYTES / 4;
  localparam int unsigned SSD1306_FRAME_BLOCKS       =
    (SSD1306_FRAME_BYTES + MAX_BULK_PAYLOAD_BYTES - 1) / MAX_BULK_PAYLOAD_BYTES;

  typedef enum logic [2:0] {
    DISP_OP_INIT        = 3'd0,
    DISP_OP_CLEAR       = 3'd1,
    DISP_OP_FRAME_WRITE = 3'd2,
    DISP_OP_ON          = 3'd3,
    DISP_OP_OFF         = 3'd4
  } disp_op_e;

  localparam logic [7:0] ASCII_CMD_INIT  = 8'h49; // I
  localparam logic [7:0] ASCII_CMD_CLEAR = 8'h43; // C
  localparam logic [7:0] ASCII_CMD_ON    = 8'h4F; // O
  localparam logic [7:0] ASCII_CMD_OFF   = 8'h58; // X
  localparam logic [7:0] ASCII_CMD_WRITE = 8'h57; // W
  localparam logic [7:0] ASCII_CMD_LF    = 8'h0A;
  localparam logic [7:0] ASCII_CMD_CR    = 8'h0D;

  localparam logic [7:0] BULK_SOF0       = 8'h55;
  localparam logic [7:0] BULK_SOF1       = 8'hAA;
  localparam logic [7:0] BULK_WR_DATA    = 8'h01;
  localparam logic [7:0] BULK_WR_END     = 8'h02;
  localparam logic [7:0] BULK_ABORT      = 8'hE0;

  localparam logic [7:0] EVT_CMD_ACK     = 8'h30;
  localparam logic [7:0] EVT_FRAME_OK    = 8'h32;
  localparam logic [7:0] EVT_FRAME_ERR   = 8'h33;
  localparam logic [7:0] EVT_FRAME_PROG  = 8'h34;
  localparam logic [7:0] EVT_FRAME_DONE  = 8'h35;
  localparam logic [7:0] EVT_FRAME_ABORT = 8'h36;
  localparam logic [7:0] EVT_CMD_ERR     = 8'h3E;

  localparam logic [31:0] ERR_BAD_ASCII_FIELD = 32'h4436_0001;
  localparam logic [31:0] ERR_UNSUPPORTED_CMD = 32'h4436_0002;
  localparam logic [31:0] ERR_BUSY            = 32'h4436_0003;
  localparam logic [31:0] ERR_I2C_NACK        = 32'h4436_0004;
  localparam logic [31:0] ERR_FRAME_SIZE      = 32'h4436_0005;
  localparam logic [31:0] ERR_BULK_CRC        = 32'h4436_0006;
  localparam logic [31:0] ERR_BULK_TYPE       = 32'h4436_0007;
  localparam logic [31:0] ERR_BULK_SEQ        = 32'h4436_0008;
  localparam logic [31:0] ERR_BULK_LEN        = 32'h4436_0009;
  localparam logic [31:0] ERR_BULK_ABORT_REQ  = 32'h4436_000A;
  localparam logic [31:0] ERR_BULK_TIMEOUT    = 32'h4436_000B;

  function automatic logic [7:0] ssd1306_i2c_addr_byte(
    input logic [6:0] slave_addr,
    input logic       is_read
  );
    begin
      ssd1306_i2c_addr_byte = {slave_addr, is_read};
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

  function automatic logic [31:0] pack_frame_progress_arg0(
    input logic [7:0] chunk_index,
    input logic [7:0] chunk_bytes,
    input logic [15:0] total_bytes
  );
    begin
      pack_frame_progress_arg0 = {chunk_index, chunk_bytes, total_bytes};
    end
  endfunction

endpackage : ssd1306_uart_proto_pkg

`endif