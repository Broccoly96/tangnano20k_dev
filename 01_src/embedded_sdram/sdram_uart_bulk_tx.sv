`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_bulk_tx.sv
// Description  : Raw bulk-read block transmitter for BR sessions.
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_bulk_tx (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_ENABLE,
  input  logic        I_WORD_VALID,
  input  logic [31:0] I_WORD_DATA,
  input  logic        I_WORD_LAST,
  output logic        O_WORD_READY,
  input  logic        I_FINISH_VALID,
  output logic        O_FINISH_READY,
  output logic        O_TX_VALID,
  output logic [7:0]  O_TX_DATA,
  input  logic        I_TX_READY,
  output logic        O_ACTIVE
);

  import sdram_uart_proto_pkg::*;
`ifdef SIM
  import tb_log_pkg::*;
  `define SDRAM_BULK_TX_LOG_DEBUG(MSG) tb_log_pkg::log_debug("SDRAM BULK TX", MSG)
  `define SDRAM_BULK_TX_LOG_TRACE(MSG) tb_log_pkg::log_trace("SDRAM BULK TX", MSG)
`else
  `define SDRAM_BULK_TX_LOG_DEBUG(MSG)
  `define SDRAM_BULK_TX_LOG_TRACE(MSG)
`endif

  typedef enum logic [2:0] {
    ST_ACCUM,
    ST_CRC_DATA,
    ST_SEND_DATA,
    ST_SEND_END
  } st_state_e;

  st_state_e st_state;
  logic [MAX_BULK_PAYLOAD_BYTES*8-1:0] r_payload_bits;
  logic [MAX_BULK_PAYLOAD_BYTES*8-1:0] r_crc_shift_bits;
  logic [MAX_BULK_PAYLOAD_BYTES*8-1:0] r_send_shift_bits;
  logic [15:0] r_payload_len;
  logic [7:0]  r_seq;
  logic [7:0]  r_send_index;
  logic [7:0]  r_crc_index;
  logic [15:0] r_crc_value;
  logic [15:0] r_end_crc_value;
  logic        r_finish_pending;
  logic [15:0] s_next_payload_len;

  assign s_next_payload_len = r_payload_len + 16'd4;

  function automatic logic [15:0] calc_end_crc_for_seq(input logic [7:0] seq_value);
    logic [15:0] crc_value;
    begin
      crc_value = 16'hFFFF;
      crc_value = crc16_ccitt_false_update(crc_value, BULK_RD_END);
      crc_value = crc16_ccitt_false_update(crc_value, seq_value);
      crc_value = crc16_ccitt_false_update(crc_value, 8'h00);
      crc_value = crc16_ccitt_false_update(crc_value, 8'h00);
      calc_end_crc_for_seq = crc_value;
    end
  endfunction

  function automatic logic [7:0] data_block_byte_at(
    input logic [7:0] index_value,
    input logic [7:0] seq_value,
    input logic [15:0] payload_len,
    input logic [15:0] crc_value,
    input logic [7:0] payload_byte
  );
    begin
      case (index_value)
        8'd0: data_block_byte_at = BULK_SOF0;
        8'd1: data_block_byte_at = BULK_SOF1;
        8'd2: data_block_byte_at = BULK_RD_DATA;
        8'd3: data_block_byte_at = seq_value;
        8'd4: data_block_byte_at = payload_len[7:0];
        8'd5: data_block_byte_at = payload_len[15:8];
        default: begin
          if (index_value < (payload_len + 8'd6)) begin
            data_block_byte_at = payload_byte;
          end else if (index_value == (payload_len + 8'd6)) begin
            data_block_byte_at = crc_value[7:0];
          end else begin
            data_block_byte_at = crc_value[15:8];
          end
        end
      endcase
    end
  endfunction

  function automatic logic [7:0] end_block_byte_at(
    input logic [7:0] index_value,
    input logic [7:0] seq_value,
    input logic [15:0] crc_value
  );
    begin
      case (index_value)
        8'd0: end_block_byte_at = BULK_SOF0;
        8'd1: end_block_byte_at = BULK_SOF1;
        8'd2: end_block_byte_at = BULK_RD_END;
        8'd3: end_block_byte_at = seq_value;
        8'd4: end_block_byte_at = 8'h00;
        8'd5: end_block_byte_at = 8'h00;
        8'd6: end_block_byte_at = crc_value[7:0];
        default: end_block_byte_at = crc_value[15:8];
      endcase
    end
  endfunction

  assign O_ACTIVE = I_ENABLE &&
                    (
                      (st_state == ST_SEND_DATA) ||
                      (st_state == ST_SEND_END) ||
                      ((st_state == ST_ACCUM) && ((r_payload_len != 0) || r_finish_pending))
                    );
  assign O_WORD_READY = I_ENABLE && (st_state == ST_ACCUM) && !r_finish_pending &&
                        (r_payload_len <= (MAX_BULK_PAYLOAD_BYTES - 4));
  assign O_FINISH_READY = I_ENABLE && (st_state == ST_ACCUM) && (r_payload_len == 0);
  assign O_TX_VALID = I_ENABLE &&
                      (
                        (st_state == ST_SEND_DATA) ||
                        (st_state == ST_SEND_END)
                      );
  assign O_TX_DATA =
    (st_state == ST_SEND_DATA) ?
      data_block_byte_at(r_send_index, r_seq, r_payload_len, r_crc_value, r_send_shift_bits[7:0]) :
      end_block_byte_at(r_send_index, r_seq, r_end_crc_value);

  // Buffers words into blocks and emits the raw BR stream byte-by-byte.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state         <= ST_ACCUM;
      r_payload_bits   <= '0;
      r_crc_shift_bits <= '0;
      r_send_shift_bits <= '0;
      r_payload_len    <= '0;
      r_seq            <= 8'h00;
      r_send_index     <= '0;
      r_crc_index      <= '0;
      r_crc_value      <= 16'h0;
      r_end_crc_value  <= 16'h0;
      r_finish_pending <= 1'b0;
    end else begin
      if (!I_ENABLE) begin
        st_state         <= ST_ACCUM;
        r_payload_bits   <= '0;
        r_crc_shift_bits <= '0;
        r_send_shift_bits <= '0;
        r_payload_len    <= '0;
        r_send_index     <= '0;
        r_crc_index      <= '0;
        r_end_crc_value  <= 16'h0;
        r_finish_pending <= 1'b0;
      end else begin
        if ((st_state == ST_ACCUM) && r_finish_pending && (r_payload_len == 0)) begin
          `SDRAM_BULK_TX_LOG_DEBUG($sformatf("flush_pending_end seq=0x%02h", r_seq));
          st_state         <= ST_SEND_END;
          r_finish_pending <= 1'b0;
          r_send_index     <= '0;
          r_end_crc_value  <= calc_end_crc_for_seq(r_seq);
        end

        if (I_WORD_VALID && O_WORD_READY) begin
          `SDRAM_BULK_TX_LOG_DEBUG(
            $sformatf(
              "accept_word data=0x%08h last=%0b payload_len_next=%0d seq=0x%02h",
              I_WORD_DATA,
              I_WORD_LAST,
              r_payload_len + 16'd4,
              r_seq
            )
          );
          r_payload_bits[r_payload_len*8 +: 32] <= I_WORD_DATA;
          r_payload_len <= r_payload_len + 16'd4;
          if ((s_next_payload_len == MAX_BULK_PAYLOAD_BYTES) || I_WORD_LAST) begin
            `SDRAM_BULK_TX_LOG_DEBUG(
              $sformatf(
                "start_crc_data seq=0x%02h len=%0d last=%0b",
                r_seq,
                s_next_payload_len,
                I_WORD_LAST
              )
            );
            r_crc_value  <= crc16_ccitt_false_update(
              crc16_ccitt_false_update(
                crc16_ccitt_false_update(
                  crc16_ccitt_false_update(16'hFFFF, BULK_RD_DATA),
                  r_seq
                ),
                s_next_payload_len[7:0]
              ),
              s_next_payload_len[15:8]
            );
            r_crc_shift_bits <= r_payload_bits |
                                ({{(MAX_BULK_PAYLOAD_BYTES*8-32){1'b0}}, I_WORD_DATA} << (r_payload_len * 8));
            st_state         <= ST_CRC_DATA;
            r_crc_index      <= '0;
          end
        end

        if ((st_state == ST_ACCUM) && I_FINISH_VALID && O_FINISH_READY) begin
          `SDRAM_BULK_TX_LOG_DEBUG($sformatf("start_send_end seq=0x%02h", r_seq));
          st_state        <= ST_SEND_END;
          r_send_index    <= '0;
          r_end_crc_value <= calc_end_crc_for_seq(r_seq);
        end else if ((st_state == ST_ACCUM) && I_FINISH_VALID && !r_finish_pending) begin
          `SDRAM_BULK_TX_LOG_DEBUG(
            $sformatf("finish_pending seq=0x%02h payload_len=%0d", r_seq, r_payload_len)
          );
          r_finish_pending <= 1'b1;
        end

        if (st_state == ST_CRC_DATA) begin
          if (r_crc_index + 1'b1 == r_payload_len) begin
            `SDRAM_BULK_TX_LOG_DEBUG(
              $sformatf("start_send_data seq=0x%02h len=%0d", r_seq, r_payload_len)
            );
            st_state         <= ST_SEND_DATA;
            r_send_index     <= '0;
            r_send_shift_bits <= r_payload_bits;
          end
          r_crc_value <= crc16_ccitt_false_update(
            r_crc_value,
            r_crc_shift_bits[7:0]
          );
          r_crc_shift_bits <= r_crc_shift_bits >> 8;
          r_crc_index <= r_crc_index + 1'b1;
        end else if (O_TX_VALID && I_TX_READY) begin
          `SDRAM_BULK_TX_LOG_TRACE(
            $sformatf("tx_byte state=%0d idx=%0d data=0x%02h", st_state, r_send_index, O_TX_DATA)
          );
          case (st_state)
            ST_SEND_DATA: begin
              if ((r_send_index >= 8'd6) && (r_send_index < (r_payload_len + 8'd6))) begin
                r_send_shift_bits <= r_send_shift_bits >> 8;
              end
              if (r_send_index == (r_payload_len + 8'd7)) begin
                `SDRAM_BULK_TX_LOG_DEBUG($sformatf("send_data_done seq=0x%02h", r_seq));
                r_payload_bits <= '0;
                r_crc_shift_bits <= '0;
                r_send_shift_bits <= '0;
                r_payload_len  <= '0;
                r_seq          <= r_seq + 1'b1;
                if (r_finish_pending) begin
                  st_state         <= ST_SEND_END;
                  r_finish_pending <= 1'b0;
                  r_send_index     <= '0;
                  r_end_crc_value  <= calc_end_crc_for_seq(r_seq + 1'b1);
                end else begin
                  st_state <= ST_ACCUM;
                end
              end else begin
                r_send_index <= r_send_index + 1'b1;
              end
            end

            ST_SEND_END: begin
              if (r_send_index == 8'd7) begin
                `SDRAM_BULK_TX_LOG_DEBUG($sformatf("send_end_done seq=0x%02h", r_seq));
                st_state     <= ST_ACCUM;
                r_send_index <= '0;
                r_seq        <= r_seq + 1'b1;
              end else begin
                r_send_index <= r_send_index + 1'b1;
              end
            end

            default: begin
              st_state <= ST_ACCUM;
            end
          endcase
        end
      end
    end
  end

endmodule

`undef SDRAM_BULK_TX_LOG_DEBUG
`undef SDRAM_BULK_TX_LOG_TRACE
