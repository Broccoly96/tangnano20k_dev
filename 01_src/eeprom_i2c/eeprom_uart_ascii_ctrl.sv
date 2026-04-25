`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : eeprom_uart_ascii_ctrl.sv
// Description  : Fixed-format ASCII parser for 24FC1025 UART host commands.
//                Accepted command shapes:
//                  R AAAAA
//                  W AAAAA DD
//                  W AAAAA DDDDDDDD
//                  BR AAAAA CCCCC
//                  BW AAAAA CCCCC
//////////////////////////////////////////////////////////////////////////////////

module eeprom_uart_ascii_ctrl #(
  parameter int unsigned LINE_BYTES = 64
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_ENABLE,
  input  logic        I_RX_VALID,
  input  logic [7:0]  I_RX_DATA,
  input  logic        I_CMD_READY,
  output logic        O_CMD_VALID,
  output logic [1:0]  O_CMD_OP,
  output logic        O_CMD_BULK_IS_READ,
  output logic [16:0] O_CMD_ADDR,
  output logic [7:0]  O_CMD_DATA,
  output logic [16:0] O_CMD_COUNT,
  output logic        O_ERR_VALID,
  output logic [31:0] O_ERR_CODE,
  output logic [31:0] O_ERR_DETAIL
);

  import eeprom_uart_proto_pkg::*;

  localparam int unsigned MAX_LINE_BYTES  = 16;
  localparam int unsigned LEN_READ        = 7;
  localparam int unsigned LEN_WRITE_BYTE  = 10;
  localparam int unsigned LEN_WRITE_WORD  = 16;
  localparam int unsigned LEN_BULK        = 14;

  logic [7:0]  r_line [0:MAX_LINE_BYTES-1];
  logic [4:0]  r_line_len;
  logic        r_overflow;

  logic        r_cmd_valid;
  logic [1:0]  r_cmd_op;
  logic        r_cmd_bulk_is_read;
  logic [16:0] r_cmd_addr;
  logic [7:0]  r_cmd_data;
  logic [16:0] r_cmd_count;
  logic        r_err_valid;
  logic [31:0] r_err_code;
  logic [31:0] r_err_detail;

  assign O_CMD_VALID        = r_cmd_valid;
  assign O_CMD_OP           = r_cmd_op;
  assign O_CMD_BULK_IS_READ = r_cmd_bulk_is_read;
  assign O_CMD_ADDR         = r_cmd_addr;
  assign O_CMD_DATA         = r_cmd_data;
  assign O_CMD_COUNT        = r_cmd_count;
  assign O_ERR_VALID        = r_err_valid;
  assign O_ERR_CODE         = r_err_code;
  assign O_ERR_DETAIL       = r_err_detail;

  function automatic logic is_hex_upper(input logic [7:0] byte_value);
    begin
      is_hex_upper =
        ((byte_value >= 8'h30) && (byte_value <= 8'h39)) ||
        ((byte_value >= 8'h41) && (byte_value <= 8'h46));
    end
  endfunction

  function automatic logic [3:0] hex_upper_to_nibble(input logic [7:0] byte_value);
    begin
      if ((byte_value >= 8'h30) && (byte_value <= 8'h39)) begin
        hex_upper_to_nibble = byte_value[3:0];
      end else begin
        hex_upper_to_nibble = byte_value[3:0] + 4'd9;
      end
    end
  endfunction

  function automatic logic fixed_hex2_ok(
    input logic [7:0] b0,
    input logic [7:0] b1
  );
    begin
      fixed_hex2_ok = is_hex_upper(b0) && is_hex_upper(b1);
    end
  endfunction

  function automatic logic fixed_hex5_ok(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4
  );
    begin
      fixed_hex5_ok = is_hex_upper(b0) && is_hex_upper(b1) &&
                      is_hex_upper(b2) && is_hex_upper(b3) &&
                      is_hex_upper(b4);
    end
  endfunction

  function automatic logic fixed_addr5_ok(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4
  );
    begin
      fixed_addr5_ok = fixed_hex5_ok(b0, b1, b2, b3, b4) &&
                       (hex_upper_to_nibble(b0) <= 4'd1);
    end
  endfunction

  function automatic logic fixed_hex8_ok(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4,
    input logic [7:0] b5,
    input logic [7:0] b6,
    input logic [7:0] b7
  );
    begin
      fixed_hex8_ok = is_hex_upper(b0) && is_hex_upper(b1) &&
                      is_hex_upper(b2) && is_hex_upper(b3) &&
                      is_hex_upper(b4) && is_hex_upper(b5) &&
                      is_hex_upper(b6) && is_hex_upper(b7);
    end
  endfunction

  function automatic logic [16:0] parse_hex5(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4
  );
    logic [31:0] parsed_value;
    begin
      parsed_value = parse_hex5_32(b0, b1, b2, b3, b4);
      parse_hex5 = parsed_value[16:0];
    end
  endfunction

  function automatic logic [7:0] parse_hex2(
    input logic [7:0] b0,
    input logic [7:0] b1
  );
    begin
      parse_hex2 = {
        hex_upper_to_nibble(b0),
        hex_upper_to_nibble(b1)
      };
    end
  endfunction

  function automatic logic [31:0] parse_hex5_32(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4
  );
    begin
      parse_hex5_32 = {
        12'h000,
        hex_upper_to_nibble(b0),
        hex_upper_to_nibble(b1),
        hex_upper_to_nibble(b2),
        hex_upper_to_nibble(b3),
        hex_upper_to_nibble(b4)
      };
    end
  endfunction

  function automatic logic [31:0] parse_hex8(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4,
    input logic [7:0] b5,
    input logic [7:0] b6,
    input logic [7:0] b7
  );
    begin
      parse_hex8 = {
        hex_upper_to_nibble(b0),
        hex_upper_to_nibble(b1),
        hex_upper_to_nibble(b2),
        hex_upper_to_nibble(b3),
        hex_upper_to_nibble(b4),
        hex_upper_to_nibble(b5),
        hex_upper_to_nibble(b6),
        hex_upper_to_nibble(b7)
      };
    end
  endfunction

  task automatic emit_cmd(
    input logic [1:0]  cmd_op,
    input logic        cmd_bulk_is_read,
    input logic [16:0] cmd_addr,
    input logic [7:0]  cmd_data,
    input logic [16:0] cmd_count
  );
    begin
      r_cmd_valid         <= 1'b1;
      r_cmd_op            <= cmd_op;
      r_cmd_bulk_is_read  <= cmd_bulk_is_read;
      r_cmd_addr          <= cmd_addr;
      r_cmd_data          <= cmd_data;
      r_cmd_count         <= cmd_count;
    end
  endtask

  task automatic emit_err(
    input logic [31:0] err_code,
    input logic [31:0] err_detail
  );
    begin
      r_err_valid   <= 1'b1;
      r_err_code    <= err_code;
      r_err_detail  <= err_detail;
    end
  endtask

  task automatic decode_line;
    logic [16:0] decoded_addr;
    logic [16:0] decoded_count;
    logic [31:0] decoded_data32;
    begin
      if (r_overflow) begin
        emit_err(ERR_BAD_ASCII_FIELD, 32'hFFFF_FFFF);
      end else if (r_line_len == 0) begin
      end else if ((r_line_len == LEN_READ) &&
                   (r_line[0] == ASCII_CMD_R) &&
                   (r_line[1] == 8'h20) &&
                   fixed_addr5_ok(r_line[2], r_line[3], r_line[4], r_line[5], r_line[6])) begin
        decoded_addr = parse_hex5(r_line[2], r_line[3], r_line[4], r_line[5], r_line[6]);
        emit_cmd(ASCII_OP_READ, 1'b0, decoded_addr, 8'h00, 17'h00000);
      end else if ((r_line_len == LEN_READ) &&
                   (r_line[0] == ASCII_CMD_R) &&
                   (r_line[1] == 8'h20) &&
                   fixed_hex5_ok(r_line[2], r_line[3], r_line[4], r_line[5], r_line[6])) begin
        emit_err(ERR_ADDR_RANGE, parse_hex5_32(r_line[2], r_line[3], r_line[4], r_line[5], r_line[6]));
      end else if ((r_line_len == LEN_WRITE_BYTE) &&
                   (r_line[0] == ASCII_CMD_W) &&
                   (r_line[1] == 8'h20) &&
                   (r_line[7] == 8'h20) &&
                   fixed_addr5_ok(r_line[2], r_line[3], r_line[4], r_line[5], r_line[6]) &&
                   fixed_hex2_ok(r_line[8], r_line[9])) begin
        decoded_addr = parse_hex5(r_line[2], r_line[3], r_line[4], r_line[5], r_line[6]);
        emit_cmd(ASCII_OP_WRITE, 1'b0, decoded_addr, parse_hex2(r_line[8], r_line[9]), 17'h00000);
      end else if ((r_line_len == LEN_WRITE_WORD) &&
                   (r_line[0] == ASCII_CMD_W) &&
                   (r_line[1] == 8'h20) &&
                   (r_line[7] == 8'h20) &&
                   fixed_addr5_ok(r_line[2], r_line[3], r_line[4], r_line[5], r_line[6]) &&
                   fixed_hex8_ok(r_line[8], r_line[9], r_line[10], r_line[11],
                                 r_line[12], r_line[13], r_line[14], r_line[15])) begin
        decoded_addr = parse_hex5(r_line[2], r_line[3], r_line[4], r_line[5], r_line[6]);
        decoded_data32 = parse_hex8(r_line[8], r_line[9], r_line[10], r_line[11],
                                    r_line[12], r_line[13], r_line[14], r_line[15]);
        emit_cmd(ASCII_OP_WRITE, 1'b0, decoded_addr, decoded_data32[7:0], 17'h00000);
      end else if ((r_line_len == LEN_BULK) &&
                   (r_line[0] == ASCII_CMD_B) &&
                   ((r_line[1] == ASCII_CMD_R) || (r_line[1] == ASCII_CMD_W)) &&
                   (r_line[2] == 8'h20) &&
                   (r_line[8] == 8'h20) &&
                   fixed_addr5_ok(r_line[3], r_line[4], r_line[5], r_line[6], r_line[7]) &&
                   fixed_hex5_ok(r_line[9], r_line[10], r_line[11], r_line[12], r_line[13])) begin
        decoded_addr = parse_hex5(r_line[3], r_line[4], r_line[5], r_line[6], r_line[7]);
        decoded_count = parse_hex5(r_line[9], r_line[10], r_line[11], r_line[12], r_line[13]);
        emit_cmd(ASCII_OP_BULK, (r_line[1] == ASCII_CMD_R), decoded_addr, 8'h00, decoded_count);
      end else begin
        emit_err(ERR_BAD_ASCII_CMD, {24'h000000, r_line[0]});
      end
    end
  endtask

  // Collects one line at a time and holds decoded results until the bridge
  // accepts them through I_CMD_READY.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_line              <= '{default: 8'h00};
      r_line_len          <= '0;
      r_overflow          <= 1'b0;
      r_cmd_valid         <= 1'b0;
      r_cmd_op            <= ASCII_OP_NONE;
      r_cmd_bulk_is_read  <= 1'b0;
      r_cmd_addr          <= '0;
      r_cmd_data          <= '0;
      r_cmd_count         <= '0;
      r_err_valid         <= 1'b0;
      r_err_code          <= '0;
      r_err_detail        <= '0;
    end else begin
      if (I_CMD_READY) begin
        r_cmd_valid <= 1'b0;
      end
      if (r_err_valid) begin
        r_err_valid <= 1'b0;
      end

      if (I_ENABLE && I_RX_VALID && !r_cmd_valid && !r_err_valid) begin
        if (I_RX_DATA == ASCII_CMD_CR) begin
        end else if (I_RX_DATA == ASCII_CMD_LF) begin
          decode_line();
          r_line_len <= '0;
          r_overflow <= 1'b0;
        end else if (I_RX_DATA < 8'h20) begin
        end else if (r_line_len < MAX_LINE_BYTES) begin
          r_line[r_line_len] <= I_RX_DATA;
          r_line_len         <= r_line_len + 1'b1;
        end else begin
          r_overflow <= 1'b1;
        end
      end
    end
  end

endmodule