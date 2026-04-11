`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_ascii_ctrl.sv
// Description  : Line-oriented ASCII parser for SDRAM UART host commands.
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
  output logic        O_CMD_BULK_IS_READ,
  output logic [20:0] O_CMD_ADDR,
  output logic [31:0] O_CMD_DATA,
  output logic [20:0] O_CMD_WORDS,
  output logic        O_ERR_VALID,
  output logic [31:0] O_ERR_CODE,
  output logic [31:0] O_ERR_DETAIL
);

  import sdram_uart_proto_pkg::*;
  `define SDRAM_ASCII_LOG_DEBUG(MSG)
  `define SDRAM_ASCII_LOG_TRACE(MSG)
// synthesis translate_off
`undef SDRAM_ASCII_LOG_DEBUG
`undef SDRAM_ASCII_LOG_TRACE
  import tb_log_pkg::*;
  `define SDRAM_ASCII_LOG_DEBUG(MSG) tb_log_pkg::log_debug("SDRAM ASCII", MSG)
  `define SDRAM_ASCII_LOG_TRACE(MSG) tb_log_pkg::log_trace("SDRAM ASCII", MSG)
// synthesis translate_on

  logic [7:0] r_line_mem [0:LINE_BYTES-1];
  logic [6:0] r_line_len;
  logic       r_cmd_valid;
  logic [1:0] r_cmd_op;
  logic       r_cmd_bulk_is_read;
  logic [20:0] r_cmd_addr;
  logic [31:0] r_cmd_data;
  logic [20:0] r_cmd_words;
  logic       r_err_valid;
  logic [31:0] r_err_code;
  logic [31:0] r_err_detail;

  function automatic logic is_ascii_printable(input logic [7:0] byte_value);
    begin
      is_ascii_printable = (byte_value >= 8'h20) && (byte_value <= 8'h7E);
    end
  endfunction

  function automatic int unsigned skip_spaces(
    input logic [7:0] line_mem [0:LINE_BYTES-1],
    input int unsigned start_idx,
    input int unsigned line_len
  );
    int unsigned idx;
    int unsigned iter;
    begin
      idx = start_idx;
      for (iter = 0; iter < LINE_BYTES; iter++) begin
        if ((idx < line_len) && (idx < LINE_BYTES) &&
            (line_mem[idx] == 8'h20)) begin
          idx++;
        end
      end
      skip_spaces = idx;
    end
  endfunction

  function automatic logic parse_hex_field(
    input logic [7:0] line_mem [0:LINE_BYTES-1],
    input int unsigned start_idx,
    input int unsigned line_len,
    input int unsigned max_nibbles,
    output logic [31:0] value_out,
    output int unsigned next_idx
  );
    int unsigned idx;
    int unsigned nibble_count;
    int unsigned iter;
    logic [31:0] value_accum;
    logic parse_ok;
    begin
      idx = start_idx;
      value_accum = 32'h0;
      nibble_count = 0;
      parse_ok = 1'b1;

      if ((idx + 1 < line_len) && (idx + 1 < LINE_BYTES) &&
          (line_mem[idx] == 8'h30) &&
          ((line_mem[idx + 1] == 8'h78) || (line_mem[idx + 1] == 8'h58))) begin
        idx += 2;
      end

      for (iter = 0; iter < LINE_BYTES; iter++) begin
        if ((idx < line_len) && (idx < LINE_BYTES) &&
            is_ascii_hex(line_mem[idx])) begin
          if (nibble_count >= max_nibbles) begin
            parse_ok = 1'b0;
          end
          if (parse_ok) begin
            value_accum = {value_accum[27:0], ascii_hex_to_nibble(line_mem[idx])};
            idx++;
            nibble_count++;
          end else begin
            idx = line_len;
          end
        end
      end

      parse_hex_field = parse_ok && (nibble_count != 0);
      value_out = value_accum;
      next_idx = idx;
    end
  endfunction

  task automatic decode_line(
    input  logic [7:0] line_mem [0:LINE_BYTES-1],
    input  int unsigned line_len,
    output logic        cmd_valid,
    output logic [1:0]  cmd_op,
    output logic        bulk_is_read,
    output logic [20:0] addr_value,
    output logic [31:0] data_value,
    output logic [20:0] words_value,
    output logic        err_valid,
    output logic [31:0] err_code,
    output logic [31:0] err_detail
  );
    int unsigned idx;
    int unsigned next_idx;
    logic [31:0] parsed0;
    logic [31:0] parsed1;
    logic [7:0] cmd_char0;
    logic [7:0] cmd_char1;
    begin
      cmd_valid = 1'b0;
      cmd_op = ASCII_OP_NONE;
      bulk_is_read = 1'b0;
      addr_value = '0;
      data_value = '0;
      words_value = '0;
      err_valid = 1'b0;
      err_code = 32'h0;
      err_detail = 32'h0;

      idx = skip_spaces(line_mem, 0, line_len);
      if (idx >= line_len) begin
        return;
      end

      cmd_char0 = line_mem[idx];
      cmd_char1 = ((idx + 1) < line_len) ? line_mem[idx + 1] : 8'h00;
      idx++;

      if ((cmd_char0 == 8'h42) && ((cmd_char1 == 8'h52) || (cmd_char1 == 8'h57))) begin
        bulk_is_read = (cmd_char1 == 8'h52);
        idx++;
        cmd_op = ASCII_OP_BULK;
      end else if (cmd_char0 == 8'h52) begin
        cmd_op = ASCII_OP_READ;
      end else if (cmd_char0 == 8'h57) begin
        cmd_op = ASCII_OP_WRITE;
      end else begin
        err_valid = 1'b1;
        err_code = ERR_BAD_ASCII_CMD;
        err_detail = {24'h0, cmd_char0};
        return;
      end

      idx = skip_spaces(line_mem, idx, line_len);
      if (!parse_hex_field(line_mem, idx, line_len, 6, parsed0, next_idx)) begin
        err_valid = 1'b1;
        err_code = ERR_BAD_ASCII_FIELD;
        err_detail = 32'h0000_0001;
        return;
      end
      if (parsed0 > 32'h001F_FFFF) begin
        err_valid = 1'b1;
        err_code = ERR_ADDR_RANGE;
        err_detail = parsed0;
        return;
      end
      addr_value = parsed0[20:0];
      idx = next_idx;

      case (cmd_op)
        ASCII_OP_READ: begin
          idx = skip_spaces(line_mem, idx, line_len);
          if (idx != line_len) begin
            err_valid = 1'b1;
            err_code = ERR_BAD_ASCII_FIELD;
            err_detail = 32'h0000_0002;
            return;
          end
          cmd_valid = 1'b1;
        end

        ASCII_OP_WRITE: begin
          idx = skip_spaces(line_mem, idx, line_len);
          if (!parse_hex_field(line_mem, idx, line_len, 8, parsed1, next_idx)) begin
            err_valid = 1'b1;
            err_code = ERR_BAD_ASCII_FIELD;
            err_detail = 32'h0000_0003;
            return;
          end
          data_value = parsed1;
          idx = skip_spaces(line_mem, next_idx, line_len);
          if (idx != line_len) begin
            err_valid = 1'b1;
            err_code = ERR_BAD_ASCII_FIELD;
            err_detail = 32'h0000_0004;
            return;
          end
          cmd_valid = 1'b1;
        end

        default: begin
          idx = skip_spaces(line_mem, idx, line_len);
          if (!parse_hex_field(line_mem, idx, line_len, 6, parsed1, next_idx)) begin
            err_valid = 1'b1;
            err_code = ERR_BAD_ASCII_FIELD;
            err_detail = 32'h0000_0005;
            return;
          end
          if ((parsed1 == 0) || (parsed1 > 32'h001F_FFFF)) begin
            err_valid = 1'b1;
            err_code = ERR_WORD_COUNT;
            err_detail = parsed1;
            return;
          end
          words_value = parsed1[20:0];
          idx = skip_spaces(line_mem, next_idx, line_len);
          if (idx != line_len) begin
            err_valid = 1'b1;
            err_code = ERR_BAD_ASCII_FIELD;
            err_detail = 32'h0000_0006;
            return;
          end
          cmd_valid = 1'b1;
        end
      endcase
    end
  endtask

  assign O_CMD_VALID = r_cmd_valid;
  assign O_CMD_OP = r_cmd_op;
  assign O_CMD_BULK_IS_READ = r_cmd_bulk_is_read;
  assign O_CMD_ADDR = r_cmd_addr;
  assign O_CMD_DATA = r_cmd_data;
  assign O_CMD_WORDS = r_cmd_words;
  assign O_ERR_VALID = r_err_valid;
  assign O_ERR_CODE = r_err_code;
  assign O_ERR_DETAIL = r_err_detail;

  // Collects one ASCII line and decodes it only at LF boundaries.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_line_len          <= '0;
      r_cmd_valid         <= 1'b0;
      r_cmd_op            <= ASCII_OP_NONE;
      r_cmd_bulk_is_read  <= 1'b0;
      r_cmd_addr          <= '0;
      r_cmd_data          <= '0;
      r_cmd_words         <= '0;
      r_err_valid         <= 1'b0;
      r_err_code          <= '0;
      r_err_detail        <= '0;
      for (int idx = 0; idx < LINE_BYTES; idx++) begin
        r_line_mem[idx] <= 8'h00;
      end
    end else begin
      if (I_CMD_READY) begin
        `SDRAM_ASCII_LOG_TRACE("cmd_consumed");
        r_cmd_valid <= 1'b0;
      end
      if (r_err_valid) begin
        `SDRAM_ASCII_LOG_TRACE(
          $sformatf("err_cleared code=0x%08h detail=0x%08h", r_err_code, r_err_detail)
        );
        r_err_valid <= 1'b0;
      end

      if (I_ENABLE && I_RX_VALID) begin
        if (I_RX_DATA == ASCII_CMD_CR) begin
          // Ignore CR and wait for LF.
        end else if (I_RX_DATA == ASCII_CMD_LF) begin
          if (r_line_len != 0) begin
            logic       dec_cmd_valid;
            logic [1:0] dec_cmd_op;
            logic       dec_bulk_is_read;
            logic [20:0] dec_addr;
            logic [31:0] dec_data;
            logic [20:0] dec_words;
            logic       dec_err_valid;
            logic [31:0] dec_err_code;
            logic [31:0] dec_err_detail;

            decode_line(
              r_line_mem,
              r_line_len,
              dec_cmd_valid,
              dec_cmd_op,
              dec_bulk_is_read,
              dec_addr,
              dec_data,
              dec_words,
              dec_err_valid,
              dec_err_code,
              dec_err_detail
            );

            `SDRAM_ASCII_LOG_DEBUG(
              $sformatf(
                "decode_line len=%0d cmd_valid=%0b op=%0d bulk_read=%0b addr=0x%05h data=0x%08h words=0x%05h err=%0b code=0x%08h detail=0x%08h",
                r_line_len,
                dec_cmd_valid,
                dec_cmd_op,
                dec_bulk_is_read,
                dec_addr,
                dec_data,
                dec_words,
                dec_err_valid,
                dec_err_code,
                dec_err_detail
              )
            );

            r_cmd_valid        <= dec_cmd_valid;
            r_cmd_op           <= dec_cmd_op;
            r_cmd_bulk_is_read <= dec_bulk_is_read;
            r_cmd_addr         <= dec_addr;
            r_cmd_data         <= dec_data;
            r_cmd_words        <= dec_words;
            r_err_valid        <= dec_err_valid;
            r_err_code         <= dec_err_code;
            r_err_detail       <= dec_err_detail;
          end
          `SDRAM_ASCII_LOG_TRACE($sformatf("line_end len=%0d", r_line_len));
          r_line_len <= '0;
        end else if (!is_ascii_printable(I_RX_DATA)) begin
          // Ignore CLI control bytes so source-select and other controls do not
          // contaminate the next ASCII command line.
          `SDRAM_ASCII_LOG_TRACE($sformatf("ignore_ctrl byte=0x%02h", I_RX_DATA));
        end else if (r_cmd_valid) begin
          // Ignore new input while the caller has not consumed the command yet.
          `SDRAM_ASCII_LOG_TRACE($sformatf("ignore_while_busy byte=0x%02h", I_RX_DATA));
        end else if (r_line_len >= LINE_BYTES) begin
          r_line_len   <= '0;
          r_err_valid  <= 1'b1;
          r_err_code   <= ERR_BAD_ASCII_FIELD;
          r_err_detail <= 32'hFFFF_FFFF;
          `SDRAM_ASCII_LOG_DEBUG("line_overflow");
        end else begin
          r_line_mem[r_line_len] <= I_RX_DATA;
          `SDRAM_ASCII_LOG_TRACE(
            $sformatf("append_char idx=%0d byte=0x%02h", r_line_len, I_RX_DATA)
          );
          r_line_len <= r_line_len + 1'b1;
        end
      end
    end
  end

endmodule

`undef SDRAM_ASCII_LOG_DEBUG
`undef SDRAM_ASCII_LOG_TRACE
