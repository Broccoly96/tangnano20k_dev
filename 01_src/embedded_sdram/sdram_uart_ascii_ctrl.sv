`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_ascii_ctrl.sv
// Description  : Line-oriented ASCII parser for SDRAM UART host commands.
//                - Consumes one byte at a time with a small sequential FSM.
//                - Preserves the existing external command/error contract for
//                  sdram_uart_bridge_ctrl while avoiding whole-line decode.
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

  typedef enum logic [3:0] {
    ST_IDLE             = 4'd0,
    ST_CMD_AFTER_B      = 4'd1,
    ST_ADDR_START       = 4'd2,
    ST_ADDR_ZERO        = 4'd3,
    ST_ADDR_BODY        = 4'd4,
    ST_WRITE_DATA_START = 4'd5,
    ST_WRITE_DATA_ZERO  = 4'd6,
    ST_WRITE_DATA_BODY  = 4'd7,
    ST_BULK_WORDS_START = 4'd8,
    ST_BULK_WORDS_ZERO  = 4'd9,
    ST_BULK_WORDS_BODY  = 4'd10,
    ST_TRAIL_READ       = 4'd11,
    ST_TRAIL_WRITE      = 4'd12,
    ST_TRAIL_BULK       = 4'd13,
    ST_ERROR_SKIP       = 4'd14,
    ST_CMD_AFTER_S      = 4'd15
  } st_state_e;

  st_state_e   st_state;
  logic [6:0]  r_line_len;
  logic [1:0]  r_build_cmd_op;
  logic        r_build_is_status;
  logic        r_build_bulk_is_read;
  logic [31:0] r_build_addr;
  logic [31:0] r_build_data;
  logic [31:0] r_build_words;
  logic [2:0]  r_addr_nibbles;
  logic [3:0]  r_data_nibbles;
  logic [2:0]  r_words_nibbles;
  logic [31:0] r_skip_err_code;
  logic [31:0] r_skip_err_detail;

  logic        r_cmd_valid;
  logic [1:0]  r_cmd_op;
  logic        r_cmd_is_status;
  logic        r_cmd_bulk_is_read;
  logic [20:0] r_cmd_addr;
  logic [31:0] r_cmd_data;
  logic [20:0] r_cmd_words;
  logic        r_err_valid;
  logic [31:0] r_err_code;
  logic [31:0] r_err_detail;

  function automatic logic is_ascii_printable(input logic [7:0] byte_value);
    begin
      is_ascii_printable = (byte_value >= 8'h20) && (byte_value <= 8'h7E);
    end
  endfunction

  function automatic logic is_ascii_space(input logic [7:0] byte_value);
    begin
      is_ascii_space = (byte_value == 8'h20);
    end
  endfunction

  assign O_CMD_VALID        = r_cmd_valid;
  assign O_CMD_OP           = r_cmd_op;
  assign O_CMD_IS_STATUS    = r_cmd_is_status;
  assign O_CMD_BULK_IS_READ = r_cmd_bulk_is_read;
  assign O_CMD_ADDR         = r_cmd_addr;
  assign O_CMD_DATA         = r_cmd_data;
  assign O_CMD_WORDS        = r_cmd_words;
  assign O_ERR_VALID        = r_err_valid;
  assign O_ERR_CODE         = r_err_code;
  assign O_ERR_DETAIL       = r_err_detail;

  // Sequential byte parser.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    logic [7:0]  curr_byte;
    logic [31:0] next_value32;
    logic [31:0] next_value21;

    if (!I_RST_N) begin
      st_state            <= ST_IDLE;
      r_line_len          <= '0;
      r_build_cmd_op      <= ASCII_OP_NONE;
      r_build_is_status   <= 1'b0;
      r_build_bulk_is_read<= 1'b0;
      r_build_addr        <= '0;
      r_build_data        <= '0;
      r_build_words       <= '0;
      r_addr_nibbles      <= '0;
      r_data_nibbles      <= '0;
      r_words_nibbles     <= '0;
      r_skip_err_code     <= '0;
      r_skip_err_detail   <= '0;
      r_cmd_valid         <= 1'b0;
      r_cmd_op            <= ASCII_OP_NONE;
      r_cmd_is_status     <= 1'b0;
      r_cmd_bulk_is_read  <= 1'b0;
      r_cmd_addr          <= '0;
      r_cmd_data          <= '0;
      r_cmd_words         <= '0;
      r_err_valid         <= 1'b0;
      r_err_code          <= '0;
      r_err_detail        <= '0;
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

      if (I_ENABLE && I_RX_VALID && !r_cmd_valid) begin
        curr_byte = I_RX_DATA;

        if (curr_byte == ASCII_CMD_CR) begin
          `SDRAM_ASCII_LOG_TRACE("ignore_cr");
        end else if (curr_byte == ASCII_CMD_LF) begin
          case (st_state)
            ST_IDLE: begin
              r_line_len <= '0;
            end

            ST_ADDR_START,
            ST_ADDR_ZERO,
            ST_ADDR_BODY: begin
              if ((st_state == ST_ADDR_START) ||
                  ((st_state == ST_ADDR_BODY) && (r_addr_nibbles == 0))) begin
                r_err_valid  <= 1'b1;
                r_err_code   <= ERR_BAD_ASCII_FIELD;
                r_err_detail <= 32'h0000_0001;
                `SDRAM_ASCII_LOG_DEBUG("emit_err bad_addr_field");
              end else if (r_build_addr > 32'h001F_FFFF) begin
                r_err_valid  <= 1'b1;
                r_err_code   <= ERR_ADDR_RANGE;
                r_err_detail <= r_build_addr;
                `SDRAM_ASCII_LOG_DEBUG(
                  $sformatf("emit_err addr_range value=0x%08h", r_build_addr)
                );
              end else if (r_build_cmd_op == ASCII_OP_READ) begin
                r_cmd_valid        <= 1'b1;
                r_cmd_op           <= r_build_cmd_op;
                r_cmd_is_status    <= r_build_is_status;
                r_cmd_bulk_is_read <= r_build_bulk_is_read;
                r_cmd_addr         <= r_build_addr[20:0];
                r_cmd_data         <= 32'h0;
                r_cmd_words        <= 21'h0;
                `SDRAM_ASCII_LOG_DEBUG(
                  $sformatf("emit_cmd READ addr=0x%05h", r_build_addr[20:0])
                );
              end else if (r_build_cmd_op == ASCII_OP_WRITE) begin
                r_err_valid  <= 1'b1;
                r_err_code   <= ERR_BAD_ASCII_FIELD;
                r_err_detail <= 32'h0000_0003;
                `SDRAM_ASCII_LOG_DEBUG("emit_err missing_write_data");
              end else begin
                r_err_valid  <= 1'b1;
                r_err_code   <= ERR_BAD_ASCII_FIELD;
                r_err_detail <= 32'h0000_0005;
                `SDRAM_ASCII_LOG_DEBUG("emit_err missing_bulk_words");
              end
              st_state             <= ST_IDLE;
              r_line_len           <= '0;
              r_build_cmd_op       <= ASCII_OP_NONE;
              r_build_bulk_is_read <= 1'b0;
              r_build_addr         <= '0;
              r_build_data         <= '0;
              r_build_words        <= '0;
              r_addr_nibbles       <= '0;
              r_data_nibbles       <= '0;
              r_words_nibbles      <= '0;
            end

            ST_WRITE_DATA_START,
            ST_WRITE_DATA_ZERO,
            ST_WRITE_DATA_BODY: begin
              if ((st_state == ST_WRITE_DATA_START) ||
                  ((st_state == ST_WRITE_DATA_BODY) && (r_data_nibbles == 0))) begin
                r_err_valid  <= 1'b1;
                r_err_code   <= ERR_BAD_ASCII_FIELD;
                r_err_detail <= 32'h0000_0003;
                `SDRAM_ASCII_LOG_DEBUG("emit_err bad_write_data");
              end else begin
                r_cmd_valid        <= 1'b1;
                r_cmd_op           <= r_build_cmd_op;
                r_cmd_is_status    <= r_build_is_status;
                r_cmd_bulk_is_read <= r_build_bulk_is_read;
                r_cmd_addr         <= r_build_addr[20:0];
                r_cmd_data         <= r_build_data;
                r_cmd_words        <= 21'h0;
                `SDRAM_ASCII_LOG_DEBUG(
                  $sformatf(
                    "emit_cmd WRITE addr=0x%05h data=0x%08h",
                    r_build_addr[20:0],
                    r_build_data
                  )
                );
              end
              st_state             <= ST_IDLE;
              r_line_len           <= '0;
              r_build_cmd_op       <= ASCII_OP_NONE;
              r_build_bulk_is_read <= 1'b0;
              r_build_addr         <= '0;
              r_build_data         <= '0;
              r_build_words        <= '0;
              r_addr_nibbles       <= '0;
              r_data_nibbles       <= '0;
              r_words_nibbles      <= '0;
            end

            ST_BULK_WORDS_START,
            ST_BULK_WORDS_ZERO,
            ST_BULK_WORDS_BODY: begin
              if ((st_state == ST_BULK_WORDS_START) ||
                  ((st_state == ST_BULK_WORDS_BODY) && (r_words_nibbles == 0))) begin
                r_err_valid  <= 1'b1;
                r_err_code   <= ERR_BAD_ASCII_FIELD;
                r_err_detail <= 32'h0000_0005;
                `SDRAM_ASCII_LOG_DEBUG("emit_err bad_bulk_words");
              end else if ((r_build_words == 0) || (r_build_words > 32'h001F_FFFF)) begin
                r_err_valid  <= 1'b1;
                r_err_code   <= ERR_WORD_COUNT;
                r_err_detail <= r_build_words;
                `SDRAM_ASCII_LOG_DEBUG(
                  $sformatf("emit_err word_count value=0x%08h", r_build_words)
                );
              end else begin
                r_cmd_valid        <= 1'b1;
                r_cmd_op           <= r_build_cmd_op;
                r_cmd_is_status    <= r_build_is_status;
                r_cmd_bulk_is_read <= r_build_bulk_is_read;
                r_cmd_addr         <= r_build_addr[20:0];
                r_cmd_data         <= 32'h0;
                r_cmd_words        <= r_build_words[20:0];
                `SDRAM_ASCII_LOG_DEBUG(
                  $sformatf(
                    "emit_cmd BULK addr=0x%05h words=0x%05h bulk_read=%0b",
                    r_build_addr[20:0],
                    r_build_words[20:0],
                    r_build_bulk_is_read
                  )
                );
              end
              st_state             <= ST_IDLE;
              r_line_len           <= '0;
              r_build_cmd_op       <= ASCII_OP_NONE;
              r_build_bulk_is_read <= 1'b0;
              r_build_addr         <= '0;
              r_build_data         <= '0;
              r_build_words        <= '0;
              r_addr_nibbles       <= '0;
              r_data_nibbles       <= '0;
              r_words_nibbles      <= '0;
            end

            ST_TRAIL_READ: begin
              r_cmd_valid        <= 1'b1;
              r_cmd_op           <= r_build_cmd_op;
              r_cmd_is_status    <= r_build_is_status;
              r_cmd_bulk_is_read <= r_build_bulk_is_read;
              r_cmd_addr         <= r_build_addr[20:0];
              r_cmd_data         <= 32'h0;
              r_cmd_words        <= 21'h0;
              `SDRAM_ASCII_LOG_DEBUG(
                $sformatf("emit_cmd READ addr=0x%05h", r_build_addr[20:0])
              );
              st_state             <= ST_IDLE;
              r_line_len           <= '0;
              r_build_cmd_op       <= ASCII_OP_NONE;
              r_build_bulk_is_read <= 1'b0;
              r_build_addr         <= '0;
              r_build_data         <= '0;
              r_build_words        <= '0;
              r_addr_nibbles       <= '0;
              r_data_nibbles       <= '0;
              r_words_nibbles      <= '0;
            end

            ST_TRAIL_WRITE: begin
              r_cmd_valid        <= 1'b1;
              r_cmd_op           <= r_build_cmd_op;
              r_cmd_is_status    <= r_build_is_status;
              r_cmd_bulk_is_read <= r_build_bulk_is_read;
              r_cmd_addr         <= r_build_addr[20:0];
              r_cmd_data         <= r_build_data;
              r_cmd_words        <= 21'h0;
              `SDRAM_ASCII_LOG_DEBUG(
                $sformatf(
                  "emit_cmd WRITE addr=0x%05h data=0x%08h",
                  r_build_addr[20:0],
                  r_build_data
                )
              );
              st_state             <= ST_IDLE;
              r_line_len           <= '0;
              r_build_cmd_op       <= ASCII_OP_NONE;
              r_build_bulk_is_read <= 1'b0;
              r_build_addr         <= '0;
              r_build_data         <= '0;
              r_build_words        <= '0;
              r_addr_nibbles       <= '0;
              r_data_nibbles       <= '0;
              r_words_nibbles      <= '0;
            end

            ST_TRAIL_BULK: begin
              if ((r_build_words == 0) || (r_build_words > 32'h001F_FFFF)) begin
                r_err_valid  <= 1'b1;
                r_err_code   <= ERR_WORD_COUNT;
                r_err_detail <= r_build_words;
                `SDRAM_ASCII_LOG_DEBUG(
                  $sformatf("emit_err word_count value=0x%08h", r_build_words)
                );
              end else begin
                r_cmd_valid        <= 1'b1;
                r_cmd_op           <= r_build_cmd_op;
                r_cmd_is_status    <= r_build_is_status;
                r_cmd_bulk_is_read <= r_build_bulk_is_read;
                r_cmd_addr         <= r_build_addr[20:0];
                r_cmd_data         <= 32'h0;
                r_cmd_words        <= r_build_words[20:0];
                `SDRAM_ASCII_LOG_DEBUG(
                  $sformatf(
                    "emit_cmd BULK addr=0x%05h words=0x%05h bulk_read=%0b",
                    r_build_addr[20:0],
                    r_build_words[20:0],
                    r_build_bulk_is_read
                  )
                );
              end
              st_state             <= ST_IDLE;
              r_line_len           <= '0;
              r_build_cmd_op       <= ASCII_OP_NONE;
              r_build_bulk_is_read <= 1'b0;
              r_build_addr         <= '0;
              r_build_data         <= '0;
              r_build_words        <= '0;
              r_addr_nibbles       <= '0;
              r_data_nibbles       <= '0;
              r_words_nibbles      <= '0;
            end

            ST_CMD_AFTER_S: begin
              r_err_valid  <= 1'b1;
              r_err_code   <= ERR_BAD_ASCII_FIELD;
              r_err_detail <= 32'h0000_0001;
              st_state             <= ST_IDLE;
              r_line_len           <= '0;
              r_build_cmd_op       <= ASCII_OP_NONE;
              r_build_is_status    <= 1'b0;
              r_build_bulk_is_read <= 1'b0;
              r_build_addr         <= '0;
              r_build_data         <= '0;
              r_build_words        <= '0;
              r_addr_nibbles       <= '0;
              r_data_nibbles       <= '0;
              r_words_nibbles      <= '0;
            end

            ST_ERROR_SKIP: begin
              r_err_valid  <= 1'b1;
              r_err_code   <= r_skip_err_code;
              r_err_detail <= r_skip_err_detail;
              `SDRAM_ASCII_LOG_DEBUG(
                $sformatf(
                  "emit_err code=0x%08h detail=0x%08h",
                  r_skip_err_code,
                  r_skip_err_detail
                )
              );
              st_state             <= ST_IDLE;
              r_line_len           <= '0;
              r_build_cmd_op       <= ASCII_OP_NONE;
              r_build_bulk_is_read <= 1'b0;
              r_build_addr         <= '0;
              r_build_data         <= '0;
              r_build_words        <= '0;
              r_addr_nibbles       <= '0;
              r_data_nibbles       <= '0;
              r_words_nibbles      <= '0;
              r_skip_err_code      <= '0;
              r_skip_err_detail    <= '0;
            end

            default: begin
              st_state             <= ST_IDLE;
              r_line_len           <= '0;
              r_build_cmd_op       <= ASCII_OP_NONE;
              r_build_bulk_is_read <= 1'b0;
              r_build_addr         <= '0;
              r_build_data         <= '0;
              r_build_words        <= '0;
              r_addr_nibbles       <= '0;
              r_data_nibbles       <= '0;
              r_words_nibbles      <= '0;
            end
          endcase
        end else if (!is_ascii_printable(curr_byte)) begin
          `SDRAM_ASCII_LOG_TRACE($sformatf("ignore_ctrl byte=0x%02h", curr_byte));
        end else begin
          if ((st_state != ST_ERROR_SKIP) && (r_line_len >= LINE_BYTES)) begin
            r_err_valid          <= 1'b1;
            r_err_code           <= ERR_BAD_ASCII_FIELD;
            r_err_detail         <= 32'hFFFF_FFFF;
            st_state             <= ST_IDLE;
            r_line_len           <= '0;
            r_build_cmd_op       <= ASCII_OP_NONE;
            r_build_bulk_is_read <= 1'b0;
            r_build_addr         <= '0;
            r_build_data         <= '0;
            r_build_words        <= '0;
            r_addr_nibbles       <= '0;
            r_data_nibbles       <= '0;
            r_words_nibbles      <= '0;
            r_skip_err_code      <= '0;
            r_skip_err_detail    <= '0;
            `SDRAM_ASCII_LOG_DEBUG("line_overflow");
          end else begin
            if (st_state != ST_ERROR_SKIP) begin
              r_line_len <= r_line_len + 1'b1;
            end

            case (st_state)
              ST_IDLE: begin
                if (is_ascii_space(curr_byte)) begin
                  st_state <= ST_IDLE;
                end else if (curr_byte == ASCII_CMD_R) begin
                  st_state             <= ST_ADDR_START;
                  r_build_cmd_op       <= ASCII_OP_READ;
                  r_build_is_status    <= 1'b0;
                  r_build_bulk_is_read <= 1'b0;
                  r_build_addr         <= '0;
                  r_build_data         <= '0;
                  r_build_words        <= '0;
                  r_addr_nibbles       <= '0;
                  r_data_nibbles       <= '0;
                  r_words_nibbles      <= '0;
                end else if (curr_byte == ASCII_CMD_W) begin
                  st_state             <= ST_ADDR_START;
                  r_build_cmd_op       <= ASCII_OP_WRITE;
                  r_build_is_status    <= 1'b0;
                  r_build_bulk_is_read <= 1'b0;
                  r_build_addr         <= '0;
                  r_build_data         <= '0;
                  r_build_words        <= '0;
                  r_addr_nibbles       <= '0;
                  r_data_nibbles       <= '0;
                  r_words_nibbles      <= '0;
                end else if (curr_byte == ASCII_CMD_B) begin
                  st_state <= ST_CMD_AFTER_B;
                end else if (curr_byte == ASCII_CMD_S) begin
                  st_state <= ST_CMD_AFTER_S;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_CMD;
                  r_skip_err_detail <= {24'h0, curr_byte};
                end
              end

              ST_CMD_AFTER_B: begin
                if (curr_byte == ASCII_CMD_R) begin
                  st_state             <= ST_ADDR_START;
                  r_build_cmd_op       <= ASCII_OP_BULK;
                  r_build_is_status    <= 1'b0;
                  r_build_bulk_is_read <= 1'b1;
                  r_build_addr         <= '0;
                  r_build_data         <= '0;
                  r_build_words        <= '0;
                  r_addr_nibbles       <= '0;
                  r_data_nibbles       <= '0;
                  r_words_nibbles      <= '0;
                end else if (curr_byte == ASCII_CMD_W) begin
                  st_state             <= ST_ADDR_START;
                  r_build_cmd_op       <= ASCII_OP_BULK;
                  r_build_is_status    <= 1'b0;
                  r_build_bulk_is_read <= 1'b0;
                  r_build_addr         <= '0;
                  r_build_data         <= '0;
                  r_build_words        <= '0;
                  r_addr_nibbles       <= '0;
                  r_data_nibbles       <= '0;
                  r_words_nibbles      <= '0;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_CMD;
                  r_skip_err_detail <= {24'h0, ASCII_CMD_B};
                end
              end

              ST_CMD_AFTER_S: begin
                if (curr_byte == ASCII_CMD_R) begin
                  st_state             <= ST_ADDR_START;
                  r_build_cmd_op       <= ASCII_OP_READ;
                  r_build_is_status    <= 1'b1;
                  r_build_bulk_is_read <= 1'b0;
                  r_build_addr         <= '0;
                  r_build_data         <= '0;
                  r_build_words        <= '0;
                  r_addr_nibbles       <= '0;
                  r_data_nibbles       <= '0;
                  r_words_nibbles      <= '0;
                end else if (curr_byte == ASCII_CMD_W) begin
                  st_state             <= ST_ADDR_START;
                  r_build_cmd_op       <= ASCII_OP_WRITE;
                  r_build_is_status    <= 1'b1;
                  r_build_bulk_is_read <= 1'b0;
                  r_build_addr         <= '0;
                  r_build_data         <= '0;
                  r_build_words        <= '0;
                  r_addr_nibbles       <= '0;
                  r_data_nibbles       <= '0;
                  r_words_nibbles      <= '0;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_CMD;
                  r_skip_err_detail <= {24'h0, curr_byte};
                end
              end

              ST_ADDR_START: begin
                if (is_ascii_space(curr_byte)) begin
                  st_state <= ST_ADDR_START;
                end else if (curr_byte == 8'h30) begin
                  st_state       <= ST_ADDR_ZERO;
                  r_build_addr   <= '0;
                  r_addr_nibbles <= '0;
                end else if (is_ascii_hex(curr_byte)) begin
                  st_state       <= ST_ADDR_BODY;
                  r_build_addr   <= {28'h0, ascii_hex_to_nibble(curr_byte)};
                  r_addr_nibbles <= 3'd1;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0001;
                end
              end

              ST_ADDR_ZERO: begin
                if ((curr_byte == 8'h78) || (curr_byte == 8'h58)) begin
                  st_state <= ST_ADDR_BODY;
                end else if (is_ascii_hex(curr_byte)) begin
                  next_value21     = {28'h0, ascii_hex_to_nibble(curr_byte)};
                  st_state         <= ST_ADDR_BODY;
                  r_build_addr     <= next_value21;
                  r_addr_nibbles   <= 3'd2;
                end else if (is_ascii_space(curr_byte)) begin
                  r_build_addr   <= '0;
                  r_addr_nibbles <= 3'd1;
                  if (r_build_cmd_op == ASCII_OP_READ) begin
                    st_state <= ST_TRAIL_READ;
                  end else if (r_build_cmd_op == ASCII_OP_WRITE) begin
                    st_state <= ST_WRITE_DATA_START;
                  end else begin
                    st_state <= ST_BULK_WORDS_START;
                  end
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0001;
                end
              end

              ST_ADDR_BODY: begin
                if (is_ascii_hex(curr_byte)) begin
                  if (r_addr_nibbles >= 3'd6) begin
                    st_state          <= ST_ERROR_SKIP;
                    r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                    r_skip_err_detail <= 32'h0000_0001;
                  end else begin
                    next_value21   = {r_build_addr[27:0], ascii_hex_to_nibble(curr_byte)};
                    r_build_addr   <= next_value21;
                    r_addr_nibbles <= r_addr_nibbles + 1'b1;
                  end
                end else if (is_ascii_space(curr_byte)) begin
                  if (r_addr_nibbles == 0) begin
                    st_state          <= ST_ERROR_SKIP;
                    r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                    r_skip_err_detail <= 32'h0000_0001;
                  end else if (r_build_addr > 32'h001F_FFFF) begin
                    st_state          <= ST_ERROR_SKIP;
                    r_skip_err_code   <= ERR_ADDR_RANGE;
                    r_skip_err_detail <= r_build_addr;
                  end else if (r_build_cmd_op == ASCII_OP_READ) begin
                    st_state <= ST_TRAIL_READ;
                  end else if (r_build_cmd_op == ASCII_OP_WRITE) begin
                    st_state <= ST_WRITE_DATA_START;
                  end else begin
                    st_state <= ST_BULK_WORDS_START;
                  end
                end else if (r_build_cmd_op == ASCII_OP_READ) begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0002;
                end else if (r_build_cmd_op == ASCII_OP_WRITE) begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0003;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0005;
                end
              end

              ST_WRITE_DATA_START: begin
                if (is_ascii_space(curr_byte)) begin
                  st_state <= ST_WRITE_DATA_START;
                end else if (curr_byte == 8'h30) begin
                  st_state       <= ST_WRITE_DATA_ZERO;
                  r_build_data   <= '0;
                  r_data_nibbles <= '0;
                end else if (is_ascii_hex(curr_byte)) begin
                  st_state       <= ST_WRITE_DATA_BODY;
                  r_build_data   <= {28'h0, ascii_hex_to_nibble(curr_byte)};
                  r_data_nibbles <= 4'd1;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0003;
                end
              end

              ST_WRITE_DATA_ZERO: begin
                if ((curr_byte == 8'h78) || (curr_byte == 8'h58)) begin
                  st_state <= ST_WRITE_DATA_BODY;
                end else if (is_ascii_hex(curr_byte)) begin
                  next_value32   = {28'h0, ascii_hex_to_nibble(curr_byte)};
                  st_state       <= ST_WRITE_DATA_BODY;
                  r_build_data   <= next_value32;
                  r_data_nibbles <= 4'd2;
                end else if (is_ascii_space(curr_byte)) begin
                  r_build_data   <= '0;
                  r_data_nibbles <= 4'd1;
                  st_state       <= ST_TRAIL_WRITE;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0004;
                end
              end

              ST_WRITE_DATA_BODY: begin
                if (is_ascii_hex(curr_byte)) begin
                  if (r_data_nibbles >= 4'd8) begin
                    st_state          <= ST_ERROR_SKIP;
                    r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                    r_skip_err_detail <= 32'h0000_0003;
                  end else begin
                    next_value32   = {r_build_data[27:0], ascii_hex_to_nibble(curr_byte)};
                    r_build_data   <= next_value32;
                    r_data_nibbles <= r_data_nibbles + 1'b1;
                  end
                end else if (is_ascii_space(curr_byte)) begin
                  if (r_data_nibbles == 0) begin
                    st_state          <= ST_ERROR_SKIP;
                    r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                    r_skip_err_detail <= 32'h0000_0003;
                  end else begin
                    st_state <= ST_TRAIL_WRITE;
                  end
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0004;
                end
              end

              ST_BULK_WORDS_START: begin
                if (is_ascii_space(curr_byte)) begin
                  st_state <= ST_BULK_WORDS_START;
                end else if (curr_byte == 8'h30) begin
                  st_state        <= ST_BULK_WORDS_ZERO;
                  r_build_words   <= '0;
                  r_words_nibbles <= '0;
                end else if (is_ascii_hex(curr_byte)) begin
                  st_state        <= ST_BULK_WORDS_BODY;
                  r_build_words   <= {28'h0, ascii_hex_to_nibble(curr_byte)};
                  r_words_nibbles <= 3'd1;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0005;
                end
              end

              ST_BULK_WORDS_ZERO: begin
                if ((curr_byte == 8'h78) || (curr_byte == 8'h58)) begin
                  st_state <= ST_BULK_WORDS_BODY;
                end else if (is_ascii_hex(curr_byte)) begin
                  next_value21     = {28'h0, ascii_hex_to_nibble(curr_byte)};
                  st_state         <= ST_BULK_WORDS_BODY;
                  r_build_words    <= next_value21;
                  r_words_nibbles  <= 3'd2;
                end else if (is_ascii_space(curr_byte)) begin
                  r_build_words   <= '0;
                  r_words_nibbles <= 3'd1;
                  st_state        <= ST_TRAIL_BULK;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0006;
                end
              end

              ST_BULK_WORDS_BODY: begin
                if (is_ascii_hex(curr_byte)) begin
                  if (r_words_nibbles >= 3'd6) begin
                    st_state          <= ST_ERROR_SKIP;
                    r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                    r_skip_err_detail <= 32'h0000_0005;
                  end else begin
                    next_value21     = {r_build_words[27:0], ascii_hex_to_nibble(curr_byte)};
                    r_build_words    <= next_value21;
                    r_words_nibbles  <= r_words_nibbles + 1'b1;
                  end
                end else if (is_ascii_space(curr_byte)) begin
                  if (r_words_nibbles == 0) begin
                    st_state          <= ST_ERROR_SKIP;
                    r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                    r_skip_err_detail <= 32'h0000_0005;
                  end else begin
                    st_state <= ST_TRAIL_BULK;
                  end
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0006;
                end
              end

              ST_TRAIL_READ: begin
                if (is_ascii_space(curr_byte)) begin
                  st_state <= ST_TRAIL_READ;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0002;
                end
              end

              ST_TRAIL_WRITE: begin
                if (is_ascii_space(curr_byte)) begin
                  st_state <= ST_TRAIL_WRITE;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0004;
                end
              end

              ST_TRAIL_BULK: begin
                if (is_ascii_space(curr_byte)) begin
                  st_state <= ST_TRAIL_BULK;
                end else begin
                  st_state          <= ST_ERROR_SKIP;
                  r_skip_err_code   <= ERR_BAD_ASCII_FIELD;
                  r_skip_err_detail <= 32'h0000_0006;
                end
              end

              ST_ERROR_SKIP: begin
                st_state <= ST_ERROR_SKIP;
              end

              default: begin
                st_state <= ST_IDLE;
              end
            endcase
          end
        end
      end else if (I_RX_VALID && r_cmd_valid) begin
        `SDRAM_ASCII_LOG_TRACE($sformatf("ignore_while_busy byte=0x%02h", I_RX_DATA));
      end
    end
  end

endmodule

`undef SDRAM_ASCII_LOG_DEBUG
`undef SDRAM_ASCII_LOG_TRACE
