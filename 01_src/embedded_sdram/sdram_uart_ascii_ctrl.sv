`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_ascii_ctrl.sv
// Description  : Fixed-format ASCII parser for SDRAM UART host commands.
//                The parser accepts only the command shapes emitted by the
//                uart_log_tool TUI:
//                  R AAAAA
//                  W AAAAA DDDDDDDD
//                  SR AAAAA
//                  SW AAAAA DDDDDDDD
//                  BRT AAAAA WWWWW
//                  BWT AAAAA WWWWW
//                Carriage return is ignored before line-feed termination.
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_ascii_ctrl #(
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
  output logic        O_CMD_IS_STATUS,
  output logic        O_CMD_BULK_IS_READ,
  output logic        O_CMD_BULK_IS_TEST,
  output logic [20:0] O_CMD_ADDR,
  output logic [31:0] O_CMD_DATA,
  output logic [20:0] O_CMD_WORDS,
  output logic        O_ERR_VALID,
  output logic [31:0] O_ERR_CODE,
  output logic [31:0] O_ERR_DETAIL
);

  import sdram_uart_proto_pkg::*;

  localparam int unsigned MAX_LINE_BYTES = 17;
  localparam int unsigned LEN_READ       = 7;
  localparam int unsigned LEN_READ6      = 8;
  localparam int unsigned LEN_WRITE      = 16;
  localparam int unsigned LEN_WRITE6     = 17;
  localparam int unsigned LEN_STATUS_RD  = 8;
  localparam int unsigned LEN_STATUS_WR  = 17;
  localparam int unsigned LEN_BULK       = 14;
  localparam int unsigned LEN_BURST_TEST = 15;

  logic [7:0]  r_line [0:MAX_LINE_BYTES-1];
  logic [4:0]  r_line_len;
  logic        r_overflow;

  logic        r_cmd_valid;
  logic [1:0]  r_cmd_op;
  logic        r_cmd_is_status;
  logic        r_cmd_bulk_is_read;
  logic        r_cmd_bulk_is_test;
  logic [20:0] r_cmd_addr;
  logic [31:0] r_cmd_data;
  logic [20:0] r_cmd_words;
  logic        r_err_valid;
  logic [31:0] r_err_code;
  logic [31:0] r_err_detail;

  assign O_CMD_VALID        = r_cmd_valid;
  assign O_CMD_OP           = r_cmd_op;
  assign O_CMD_IS_STATUS    = r_cmd_is_status;
  assign O_CMD_BULK_IS_READ = r_cmd_bulk_is_read;
  assign O_CMD_BULK_IS_TEST = r_cmd_bulk_is_test;
  assign O_CMD_ADDR         = r_cmd_addr;
  assign O_CMD_DATA         = r_cmd_data;
  assign O_CMD_WORDS        = r_cmd_words;
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

  function automatic logic fixed_hex6_ok(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4,
    input logic [7:0] b5
  );
    begin
      fixed_hex6_ok = is_hex_upper(b0) && is_hex_upper(b1) &&
                      is_hex_upper(b2) && is_hex_upper(b3) &&
                      is_hex_upper(b4) && is_hex_upper(b5);
    end
  endfunction

  function automatic logic fixed_addr6_ok(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4,
    input logic [7:0] b5
  );
    begin
      fixed_addr6_ok = fixed_hex6_ok(b0, b1, b2, b3, b4, b5) &&
                       (hex_upper_to_nibble(b0) <= 4'd1);
    end
  endfunction

  function automatic logic [20:0] parse_hex5(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4
  );
    begin
      parse_hex5 = {
        1'b0,
        hex_upper_to_nibble(b0),
        hex_upper_to_nibble(b1),
        hex_upper_to_nibble(b2),
        hex_upper_to_nibble(b3),
        hex_upper_to_nibble(b4)
      };
    end
  endfunction

  function automatic logic [20:0] parse_hex6(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4,
    input logic [7:0] b5
  );
    logic [3:0] top_nibble;
    begin
      top_nibble = hex_upper_to_nibble(b0);
      parse_hex6 = {
        top_nibble[0],
        hex_upper_to_nibble(b1),
        hex_upper_to_nibble(b2),
        hex_upper_to_nibble(b3),
        hex_upper_to_nibble(b4),
        hex_upper_to_nibble(b5)
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

  function automatic logic [31:0] parse_hex6_32(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4,
    input logic [7:0] b5
  );
    begin
      parse_hex6_32 = {
        8'h00,
        hex_upper_to_nibble(b0),
        hex_upper_to_nibble(b1),
        hex_upper_to_nibble(b2),
        hex_upper_to_nibble(b3),
        hex_upper_to_nibble(b4),
        hex_upper_to_nibble(b5)
      };
    end
  endfunction

  task automatic emit_cmd(
    input logic [1:0]  cmd_op,
    input logic        cmd_is_status,
    input logic        cmd_bulk_is_read,
    input logic        cmd_bulk_is_test,
    input logic [20:0] cmd_addr,
    input logic [31:0] cmd_data,
    input logic [20:0] cmd_words
  );
    begin
      r_cmd_valid         <= 1'b1;
      r_cmd_op            <= cmd_op;
      r_cmd_is_status     <= cmd_is_status;
      r_cmd_bulk_is_read  <= cmd_bulk_is_read;
      r_cmd_bulk_is_test  <= cmd_bulk_is_test;
      r_cmd_addr          <= cmd_addr;
      r_cmd_data          <= cmd_data;
      r_cmd_words         <= cmd_words;
    end
  endtask

  task automatic emit_err(
    input logic [31:0] err_code,
    input logic [31:0] err_detail
  );
    begin
      r_err_valid <= 1'b1;
      r_err_code  <= err_code;
      r_err_detail<= err_detail;
    end
  endtask

  task automatic decode_line;
    logic [20:0] decoded_addr;
    logic [31:0] decoded_data;
    logic [20:0] decoded_words;
    begin
      if (r_overflow) begin
        emit_err(ERR_BAD_ASCII_FIELD, 32'hFFFF_FFFF);
      end else if (r_line_len == 0) begin
        // Empty lines are ignored.
      end else if ((r_line_len == LEN_READ) &&
                   (r_line[0] == ASCII_CMD_R) &&
                   (r_line[1] == 8'h20) &&
                   fixed_hex5_ok(r_line[2], r_line[3], r_line[4],
                                 r_line[5], r_line[6])) begin
        decoded_addr = parse_hex5(r_line[2], r_line[3], r_line[4],
                                  r_line[5], r_line[6]);
        emit_cmd(ASCII_OP_READ, 1'b0, 1'b0, 1'b0, decoded_addr, 32'h0, 21'h0);
      end else if ((r_line_len == LEN_READ6) &&
                   (r_line[0] == ASCII_CMD_R) &&
                   (r_line[1] == 8'h20) &&
                   fixed_addr6_ok(r_line[2], r_line[3], r_line[4],
                                  r_line[5], r_line[6], r_line[7])) begin
        decoded_addr = parse_hex6(r_line[2], r_line[3], r_line[4],
                                  r_line[5], r_line[6], r_line[7]);
        emit_cmd(ASCII_OP_READ, 1'b0, 1'b0, 1'b0, decoded_addr, 32'h0, 21'h0);
      end else if ((r_line_len == LEN_READ6) &&
                   (r_line[0] == ASCII_CMD_R) &&
                   (r_line[1] == 8'h20) &&
                   fixed_hex6_ok(r_line[2], r_line[3], r_line[4],
                                 r_line[5], r_line[6], r_line[7])) begin
        emit_err(
          ERR_ADDR_RANGE,
          parse_hex6_32(r_line[2], r_line[3], r_line[4],
                        r_line[5], r_line[6], r_line[7])
        );
      end else if ((r_line_len == LEN_WRITE) &&
                   (r_line[0] == ASCII_CMD_W) &&
                   (r_line[1] == 8'h20) &&
                   (r_line[7] == 8'h20) &&
                   fixed_hex5_ok(r_line[2], r_line[3], r_line[4],
                                 r_line[5], r_line[6]) &&
                   fixed_hex8_ok(r_line[8], r_line[9], r_line[10], r_line[11],
                                 r_line[12], r_line[13], r_line[14], r_line[15])) begin
        decoded_addr = parse_hex5(r_line[2], r_line[3], r_line[4],
                                  r_line[5], r_line[6]);
        decoded_data = parse_hex8(r_line[8], r_line[9], r_line[10], r_line[11],
                                  r_line[12], r_line[13], r_line[14], r_line[15]);
        emit_cmd(ASCII_OP_WRITE, 1'b0, 1'b0, 1'b0, decoded_addr, decoded_data, 21'h0);
      end else if ((r_line_len == LEN_WRITE6) &&
                   (r_line[0] == ASCII_CMD_W) &&
                   (r_line[1] == 8'h20) &&
                   (r_line[8] == 8'h20) &&
                   fixed_addr6_ok(r_line[2], r_line[3], r_line[4],
                                  r_line[5], r_line[6], r_line[7]) &&
                   fixed_hex8_ok(r_line[9], r_line[10], r_line[11], r_line[12],
                                 r_line[13], r_line[14], r_line[15], r_line[16])) begin
        decoded_addr = parse_hex6(r_line[2], r_line[3], r_line[4],
                                  r_line[5], r_line[6], r_line[7]);
        decoded_data = parse_hex8(r_line[9], r_line[10], r_line[11], r_line[12],
                                  r_line[13], r_line[14], r_line[15], r_line[16]);
        emit_cmd(ASCII_OP_WRITE, 1'b0, 1'b0, 1'b0, decoded_addr, decoded_data, 21'h0);
      end else if ((r_line_len == LEN_STATUS_RD) &&
                   (r_line[0] == ASCII_CMD_S) &&
                   (r_line[1] == ASCII_CMD_R) &&
                   (r_line[2] == 8'h20) &&
                   fixed_hex5_ok(r_line[3], r_line[4], r_line[5],
                                 r_line[6], r_line[7])) begin
        decoded_addr = parse_hex5(r_line[3], r_line[4], r_line[5],
                                  r_line[6], r_line[7]);
        emit_cmd(ASCII_OP_READ, 1'b1, 1'b0, 1'b0, decoded_addr, 32'h0, 21'h0);
      end else if ((r_line_len == LEN_STATUS_WR) &&
                   (r_line[0] == ASCII_CMD_S) &&
                   (r_line[1] == ASCII_CMD_W) &&
                   (r_line[2] == 8'h20) &&
                   (r_line[8] == 8'h20) &&
                   fixed_hex5_ok(r_line[3], r_line[4], r_line[5],
                                 r_line[6], r_line[7]) &&
                   fixed_hex8_ok(r_line[9], r_line[10], r_line[11], r_line[12],
                                 r_line[13], r_line[14], r_line[15], r_line[16])) begin
        decoded_addr = parse_hex5(r_line[3], r_line[4], r_line[5],
                                  r_line[6], r_line[7]);
        decoded_data = parse_hex8(r_line[9], r_line[10], r_line[11], r_line[12],
                                  r_line[13], r_line[14], r_line[15], r_line[16]);
        emit_cmd(ASCII_OP_WRITE, 1'b1, 1'b0, 1'b0, decoded_addr, decoded_data, 21'h0);
      end else if ((r_line_len == LEN_BULK) &&
                   (r_line[0] == ASCII_CMD_B) &&
                   (r_line[1] == ASCII_CMD_R) &&
                   (r_line[2] == 8'h20) &&
                   (r_line[8] == 8'h20) &&
                   fixed_hex5_ok(r_line[3], r_line[4], r_line[5],
                                 r_line[6], r_line[7]) &&
                   fixed_hex5_ok(r_line[9], r_line[10], r_line[11],
                                 r_line[12], r_line[13])) begin
        decoded_addr  = parse_hex5(r_line[3], r_line[4], r_line[5],
                                   r_line[6], r_line[7]);
        decoded_words = parse_hex5(r_line[9], r_line[10], r_line[11],
                                   r_line[12], r_line[13]);
        emit_cmd(ASCII_OP_BULK, 1'b0, 1'b1, 1'b0, decoded_addr, 32'h0, decoded_words);
      end else if ((r_line_len == (LEN_BULK + 1)) &&
                   (r_line[0] == ASCII_CMD_B) &&
                   (r_line[1] == ASCII_CMD_R) &&
                   (r_line[2] == 8'h20) &&
                   (r_line[9] == 8'h20) &&
                   fixed_addr6_ok(r_line[3], r_line[4], r_line[5],
                                  r_line[6], r_line[7], r_line[8]) &&
                   fixed_hex5_ok(r_line[10], r_line[11], r_line[12],
                                 r_line[13], r_line[14])) begin
        decoded_addr  = parse_hex6(r_line[3], r_line[4], r_line[5],
                                   r_line[6], r_line[7], r_line[8]);
        decoded_words = parse_hex5(r_line[10], r_line[11], r_line[12],
                                   r_line[13], r_line[14]);
        emit_cmd(ASCII_OP_BULK, 1'b0, 1'b1, 1'b0, decoded_addr, 32'h0, decoded_words);
      end else if ((r_line_len == LEN_BULK) &&
                   (r_line[0] == ASCII_CMD_B) &&
                   (r_line[1] == ASCII_CMD_W) &&
                   (r_line[2] == 8'h20) &&
                   (r_line[8] == 8'h20) &&
                   fixed_hex5_ok(r_line[3], r_line[4], r_line[5],
                                 r_line[6], r_line[7]) &&
                   fixed_hex5_ok(r_line[9], r_line[10], r_line[11],
                                 r_line[12], r_line[13])) begin
        decoded_addr  = parse_hex5(r_line[3], r_line[4], r_line[5],
                                   r_line[6], r_line[7]);
        decoded_words = parse_hex5(r_line[9], r_line[10], r_line[11],
                                   r_line[12], r_line[13]);
        emit_cmd(ASCII_OP_BULK, 1'b0, 1'b0, 1'b0, decoded_addr, 32'h0, decoded_words);
      end else if ((r_line_len == (LEN_BULK + 1)) &&
                   (r_line[0] == ASCII_CMD_B) &&
                   (r_line[1] == ASCII_CMD_W) &&
                   (r_line[2] == 8'h20) &&
                   (r_line[9] == 8'h20) &&
                   fixed_addr6_ok(r_line[3], r_line[4], r_line[5],
                                  r_line[6], r_line[7], r_line[8]) &&
                   fixed_hex5_ok(r_line[10], r_line[11], r_line[12],
                                 r_line[13], r_line[14])) begin
        decoded_addr  = parse_hex6(r_line[3], r_line[4], r_line[5],
                                   r_line[6], r_line[7], r_line[8]);
        decoded_words = parse_hex5(r_line[10], r_line[11], r_line[12],
                                   r_line[13], r_line[14]);
        emit_cmd(ASCII_OP_BULK, 1'b0, 1'b0, 1'b0, decoded_addr, 32'h0, decoded_words);
      end else if ((r_line_len == LEN_BURST_TEST) &&
                   (r_line[0] == ASCII_CMD_B) &&
                   (r_line[1] == ASCII_CMD_R) &&
                   (r_line[2] == ASCII_CMD_T) &&
                   (r_line[3] == 8'h20) &&
                   (r_line[9] == 8'h20) &&
                   fixed_hex5_ok(r_line[4], r_line[5], r_line[6],
                                 r_line[7], r_line[8]) &&
                   fixed_hex5_ok(r_line[10], r_line[11], r_line[12],
                                 r_line[13], r_line[14])) begin
        decoded_addr  = parse_hex5(r_line[4], r_line[5], r_line[6],
                                   r_line[7], r_line[8]);
        decoded_words = parse_hex5(r_line[10], r_line[11], r_line[12],
                                   r_line[13], r_line[14]);
        emit_cmd(ASCII_OP_BULK, 1'b0, 1'b1, 1'b1, decoded_addr, 32'h0, decoded_words);
      end else if ((r_line_len == (LEN_BURST_TEST + 1)) &&
                   (r_line[0] == ASCII_CMD_B) &&
                   (r_line[1] == ASCII_CMD_R) &&
                   (r_line[2] == ASCII_CMD_T) &&
                   (r_line[3] == 8'h20) &&
                   (r_line[10] == 8'h20) &&
                   fixed_addr6_ok(r_line[4], r_line[5], r_line[6],
                                  r_line[7], r_line[8], r_line[9]) &&
                   fixed_hex5_ok(r_line[11], r_line[12], r_line[13],
                                 r_line[14], r_line[15])) begin
        decoded_addr  = parse_hex6(r_line[4], r_line[5], r_line[6],
                                   r_line[7], r_line[8], r_line[9]);
        decoded_words = parse_hex5(r_line[11], r_line[12], r_line[13],
                                   r_line[14], r_line[15]);
        emit_cmd(ASCII_OP_BULK, 1'b0, 1'b1, 1'b1, decoded_addr, 32'h0, decoded_words);
      end else if ((r_line_len == LEN_BURST_TEST) &&
                   (r_line[0] == ASCII_CMD_B) &&
                   (r_line[1] == ASCII_CMD_W) &&
                   (r_line[2] == ASCII_CMD_T) &&
                   (r_line[3] == 8'h20) &&
                   (r_line[9] == 8'h20) &&
                   fixed_hex5_ok(r_line[4], r_line[5], r_line[6],
                                 r_line[7], r_line[8]) &&
                   fixed_hex5_ok(r_line[10], r_line[11], r_line[12],
                                 r_line[13], r_line[14])) begin
        decoded_addr  = parse_hex5(r_line[4], r_line[5], r_line[6],
                                   r_line[7], r_line[8]);
        decoded_words = parse_hex5(r_line[10], r_line[11], r_line[12],
                                   r_line[13], r_line[14]);
        emit_cmd(ASCII_OP_BULK, 1'b0, 1'b0, 1'b1, decoded_addr, 32'h0, decoded_words);
      end else if ((r_line_len == (LEN_BURST_TEST + 1)) &&
                   (r_line[0] == ASCII_CMD_B) &&
                   (r_line[1] == ASCII_CMD_W) &&
                   (r_line[2] == ASCII_CMD_T) &&
                   (r_line[3] == 8'h20) &&
                   (r_line[10] == 8'h20) &&
                   fixed_addr6_ok(r_line[4], r_line[5], r_line[6],
                                  r_line[7], r_line[8], r_line[9]) &&
                   fixed_hex5_ok(r_line[11], r_line[12], r_line[13],
                                 r_line[14], r_line[15])) begin
        decoded_addr  = parse_hex6(r_line[4], r_line[5], r_line[6],
                                   r_line[7], r_line[8], r_line[9]);
        decoded_words = parse_hex5(r_line[11], r_line[12], r_line[13],
                                   r_line[14], r_line[15]);
        emit_cmd(ASCII_OP_BULK, 1'b0, 1'b0, 1'b1, decoded_addr, 32'h0, decoded_words);
      end else if ((r_line_len >= 2) &&
                   (r_line[0] == ASCII_CMD_B) &&
                   ((r_line[1] == ASCII_CMD_R) || (r_line[1] == ASCII_CMD_W))) begin
        emit_cmd(
          ASCII_OP_BULK,
          1'b0,
          (r_line[1] == ASCII_CMD_R),
          1'b0,
          21'h0,
          32'h0,
          21'h0
        );
      end else begin
        emit_err(ERR_BAD_ASCII_CMD, {24'h0, r_line[0]});
      end
    end
  endtask

  // The line collector ignores CR, terminates on LF, and holds decoded commands
  // until the downstream bridge accepts them through I_CMD_READY.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_line              <= '{default: 8'h00};
      r_line_len          <= '0;
      r_overflow          <= 1'b0;
      r_cmd_valid         <= 1'b0;
      r_cmd_op            <= ASCII_OP_NONE;
      r_cmd_is_status     <= 1'b0;
      r_cmd_bulk_is_read  <= 1'b0;
      r_cmd_bulk_is_test  <= 1'b0;
      r_cmd_addr          <= '0;
      r_cmd_data          <= '0;
      r_cmd_words         <= '0;
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
          // Ignore CR so the parser accepts both LF and CRLF line endings.
        end else if (I_RX_DATA == ASCII_CMD_LF) begin
          decode_line();
          r_line_len <= '0;
          r_overflow <= 1'b0;
        end else if (I_RX_DATA < 8'h20) begin
          // uart_log_cli forwards source-select control keys to this stream.
          // They are not SDRAM commands and must not poison the next line.
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
