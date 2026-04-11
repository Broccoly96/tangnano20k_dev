`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_bulk_rx.sv
// Description  : Raw bulk-write block receiver for BW sessions.
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_bulk_rx (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_ENABLE,
  input  logic        I_RX_VALID,
  input  logic [7:0]  I_RX_DATA,
  output logic        O_WORD_VALID,
  output logic [31:0] O_WORD_DATA,
  output logic        O_WORD_LAST_IN_BLOCK,
  input  logic        I_WORD_READY,
  output logic        O_BLOCK_DONE,
  output logic [15:0] O_BLOCK_BYTES,
  output logic [7:0]  O_BLOCK_SEQ,
  output logic        O_ABORT_VALID,
  output logic [31:0] O_ABORT_CODE
);

  import sdram_uart_proto_pkg::*;

  typedef enum logic [3:0] {
    ST_SOF0,
    ST_SOF1,
    ST_TYPE,
    ST_SEQ,
    ST_LEN0,
    ST_LEN1,
    ST_PAYLOAD,
    ST_CRC0,
    ST_CRC1,
    ST_DRAIN
  } st_state_e;

  st_state_e st_state;
  logic [7:0] r_type;
  logic [7:0] r_seq;
  logic [15:0] r_len;
  logic [15:0] r_len_count;
  logic [15:0] r_crc_rx;
  logic [15:0] r_crc_calc;
  logic [7:0]  r_expect_seq;
  logic [MAX_BULK_PAYLOAD_BYTES*8-1:0] r_payload_bits;
  logic [5:0]  r_word_index;
  logic [5:0]  r_word_count;
  logic        r_block_done;
  logic [15:0] r_block_bytes;
  logic [7:0]  r_block_seq;
  logic        r_abort_valid;
  logic [31:0] r_abort_code;

  assign O_WORD_VALID = (st_state == ST_DRAIN) && (r_word_index < r_word_count);
  assign O_WORD_DATA = r_payload_bits[r_word_index*32 +: 32];
  assign O_WORD_LAST_IN_BLOCK = (r_word_index == (r_word_count - 1));
  assign O_BLOCK_DONE = r_block_done;
  assign O_BLOCK_BYTES = r_block_bytes;
  assign O_BLOCK_SEQ = r_block_seq;
  assign O_ABORT_VALID = r_abort_valid;
  assign O_ABORT_CODE = r_abort_code;

  // Parses one validated bulk write block and then drains the words.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state       <= ST_SOF0;
      r_type         <= 8'h00;
      r_seq          <= 8'h00;
      r_len          <= 16'h0;
      r_len_count    <= 16'h0;
      r_crc_rx       <= 16'h0;
      r_crc_calc     <= 16'hFFFF;
      r_expect_seq   <= 8'h00;
      r_word_index   <= '0;
      r_word_count   <= '0;
      r_block_done   <= 1'b0;
      r_block_bytes  <= '0;
      r_block_seq    <= '0;
      r_abort_valid  <= 1'b0;
      r_abort_code   <= '0;
      r_payload_bits <= '0;
    end else begin
      r_block_done  <= 1'b0;
      r_abort_valid <= 1'b0;

      if (!I_ENABLE) begin
        st_state     <= ST_SOF0;
        r_expect_seq <= 8'h00;
        r_word_index <= '0;
        r_word_count <= '0;
      end else begin
        case (st_state)
          ST_SOF0: begin
            if (I_RX_VALID && (I_RX_DATA == BULK_SOF0)) begin
              st_state <= ST_SOF1;
            end
          end

          ST_SOF1: begin
            if (I_RX_VALID) begin
              st_state <= (I_RX_DATA == BULK_SOF1) ? ST_TYPE : ST_SOF0;
            end
          end

          ST_TYPE: begin
            if (I_RX_VALID) begin
              r_type     <= I_RX_DATA;
              r_crc_calc <= crc16_ccitt_false_update(16'hFFFF, I_RX_DATA);
              st_state   <= ST_SEQ;
            end
          end

          ST_SEQ: begin
            if (I_RX_VALID) begin
              r_seq      <= I_RX_DATA;
              r_crc_calc <= crc16_ccitt_false_update(r_crc_calc, I_RX_DATA);
              st_state   <= ST_LEN0;
            end
          end

          ST_LEN0: begin
            if (I_RX_VALID) begin
              r_len[7:0] <= I_RX_DATA;
              r_crc_calc <= crc16_ccitt_false_update(r_crc_calc, I_RX_DATA);
              st_state   <= ST_LEN1;
            end
          end

          ST_LEN1: begin
            if (I_RX_VALID) begin
              r_len[15:8]   <= I_RX_DATA;
              r_len_count   <= 16'h0;
              r_crc_calc    <= crc16_ccitt_false_update(r_crc_calc, I_RX_DATA);
              r_payload_bits <= '0;
              if ({I_RX_DATA, r_len[7:0]} > MAX_BULK_PAYLOAD_BYTES) begin
                r_abort_valid <= 1'b1;
                r_abort_code  <= ERR_BULK_LEN;
                st_state      <= ST_SOF0;
              end else if ({I_RX_DATA, r_len[7:0]} == 0) begin
                st_state <= ST_CRC0;
              end else begin
                st_state <= ST_PAYLOAD;
              end
            end
          end

          ST_PAYLOAD: begin
            if (I_RX_VALID) begin
              r_payload_bits[r_len_count*8 +: 8] <= I_RX_DATA;
              r_crc_calc <= crc16_ccitt_false_update(r_crc_calc, I_RX_DATA);
              r_len_count <= r_len_count + 1'b1;
              if (r_len_count + 1'b1 == r_len) begin
                st_state <= ST_CRC0;
              end
            end
          end

          ST_CRC0: begin
            if (I_RX_VALID) begin
              r_crc_rx[7:0] <= I_RX_DATA;
              st_state <= ST_CRC1;
            end
          end

          ST_CRC1: begin
            if (I_RX_VALID) begin
              r_crc_rx[15:8] <= I_RX_DATA;
              if ({I_RX_DATA, r_crc_rx[7:0]} != r_crc_calc) begin
                r_abort_valid <= 1'b1;
                r_abort_code  <= ERR_BULK_CRC;
                st_state      <= ST_SOF0;
              end else if (r_seq != r_expect_seq) begin
                r_abort_valid <= 1'b1;
                r_abort_code  <= ERR_BULK_SEQ;
                st_state      <= ST_SOF0;
              end else if (r_type == BULK_ABORT) begin
                r_abort_valid <= 1'b1;
                r_abort_code  <= ERR_BULK_ABORT_REQ;
                r_expect_seq  <= r_expect_seq + 1'b1;
                st_state      <= ST_SOF0;
              end else if (r_type == BULK_WR_END) begin
                if (r_len != 0) begin
                  r_abort_valid <= 1'b1;
                  r_abort_code  <= ERR_BULK_LEN;
                end else begin
                  r_block_done  <= 1'b1;
                  r_block_bytes <= 16'h0;
                  r_block_seq   <= r_seq;
                  r_expect_seq  <= r_expect_seq + 1'b1;
                end
                st_state <= ST_SOF0;
              end else if (r_type != BULK_WR_DATA) begin
                r_abort_valid <= 1'b1;
                r_abort_code  <= ERR_BULK_TYPE;
                st_state      <= ST_SOF0;
              end else if (r_len[1:0] != 2'b00) begin
                r_abort_valid <= 1'b1;
                r_abort_code  <= ERR_BULK_LEN;
                st_state      <= ST_SOF0;
              end else begin
                r_word_index  <= '0;
                r_word_count  <= r_len[15:2];
                r_block_bytes <= r_len;
                r_block_seq   <= r_seq;
                r_expect_seq  <= r_expect_seq + 1'b1;
                st_state      <= ST_DRAIN;
              end
            end
          end

          ST_DRAIN: begin
            if (O_WORD_VALID && I_WORD_READY) begin
              if (r_word_index + 1'b1 == r_word_count) begin
                r_block_done <= 1'b1;
                st_state     <= ST_SOF0;
              end
              r_word_index <= r_word_index + 1'b1;
            end
          end

          default: begin
            st_state <= ST_SOF0;
          end
        endcase
      end
    end
  end

endmodule
