`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_bulk_rx.sv
// Description  : Raw bulk-write block receiver for BW sessions.
//                The default implementation keeps the original FF payload
//                buffer. SDRAM callers can set USE_BSRAM_BUFFER to store the
//                validated payload in a 32-bit synchronous BSRAM buffer.
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_bulk_rx #(
  parameter bit USE_BSRAM_BUFFER = 1'b0
) (
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

  generate
    if (!USE_BSRAM_BUFFER) begin : g_ff_payload
      st_state_e st_state;
      logic [7:0]   r_type;
      logic [7:0]   r_seq;
      logic [15:0]  r_len;
      logic [15:0]  r_len_count;
      logic [15:0]  r_crc_rx;
      logic [15:0]  r_crc_calc;
      logic [7:0]   r_expect_seq;
      logic [5:0]   r_word_index;
      logic [5:0]   r_word_count;
      logic         r_block_done;
      logic [15:0]  r_block_bytes;
      logic [7:0]   r_block_seq;
      logic         r_abort_valid;
      logic [31:0]  r_abort_code;
      logic [MAX_BULK_PAYLOAD_BYTES*8-1:0] r_payload_bits;

      assign O_WORD_VALID         = (st_state == ST_DRAIN) && (r_word_index < r_word_count);
      assign O_WORD_DATA          = r_payload_bits[r_word_index*32 +: 32];
      assign O_WORD_LAST_IN_BLOCK = (r_word_index == (r_word_count - 1));
      assign O_BLOCK_DONE         = r_block_done;
      assign O_BLOCK_BYTES        = r_block_bytes;
      assign O_BLOCK_SEQ          = r_block_seq;
      assign O_ABORT_VALID        = r_abort_valid;
      assign O_ABORT_CODE         = r_abort_code;

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
                    r_word_count  <= r_len[7:2];
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
    end else begin : g_bram_payload
      st_state_e st_state;
      logic [7:0]  r_type;
      logic [7:0]  r_seq;
      logic [15:0] r_len;
      logic [15:0] r_len_count;
      logic [15:0] r_crc_rx;
      logic [15:0] r_crc_calc;
      logic [7:0]  r_expect_seq;
      logic [31:0] r_payload_word;
      logic [5:0]  r_word_count;
      logic [5:0]  r_read_issue_index;
      logic [5:0]  r_read_data_index;
      logic        r_read_data_valid;
      logic        r_block_done;
      logic [15:0] r_block_bytes;
      logic [7:0]  r_block_seq;
      logic        r_abort_valid;
      logic [31:0] r_abort_code;
      logic [31:0] s_payload_word_next;
      logic        s_payload_wr_en;
      logic [6:0]  s_payload_wr_addr;
      logic        s_payload_rd_en;
      logic [6:0]  s_payload_rd_addr;
      logic [31:0] s_payload_rd_data;
      logic        s_word_fire;

      function automatic [31:0] replace_payload_byte(
        input logic [31:0] word_value,
        input logic [1:0]  byte_lane,
        input logic [7:0]  byte_value
      );
        begin
          replace_payload_byte = word_value;
          unique case (byte_lane)
            2'd0:     replace_payload_byte[7:0]   = byte_value;
            2'd1:     replace_payload_byte[15:8]  = byte_value;
            2'd2:     replace_payload_byte[23:16] = byte_value;
            default:  replace_payload_byte[31:24] = byte_value;
          endcase
        end
      endfunction

      assign s_payload_word_next  = replace_payload_byte(r_payload_word, r_len_count[1:0], I_RX_DATA);
      assign s_payload_wr_en      = (st_state == ST_PAYLOAD) && I_RX_VALID && (r_len_count[1:0] == 2'd3);
      assign s_payload_wr_addr    = r_len_count[8:2];
      assign s_payload_rd_en      = (st_state == ST_DRAIN) && (!r_read_data_valid || s_word_fire) && (r_read_issue_index < r_word_count);
      assign s_payload_rd_addr    = {1'b0, r_read_issue_index};
      assign s_word_fire          = r_read_data_valid && I_WORD_READY;

      assign O_WORD_VALID         = r_read_data_valid;
      assign O_WORD_DATA          = s_payload_rd_data;
      assign O_WORD_LAST_IN_BLOCK = (r_read_data_index == (r_word_count - 1));
      assign O_BLOCK_DONE         = r_block_done;
      assign O_BLOCK_BYTES        = r_block_bytes;
      assign O_BLOCK_SEQ          = r_block_seq;
      assign O_ABORT_VALID        = r_abort_valid;
      assign O_ABORT_CODE         = r_abort_code;

      sdram_raw_word_bram #(
        .ADDR_W (7),
        .DEPTH  (128)
      ) u_payload_bram (
        .I_CLK     (I_CLK),
        .I_WR_EN   (s_payload_wr_en),
        .I_WR_ADDR (s_payload_wr_addr),
        .I_WR_DATA (s_payload_word_next),
        .I_RD_EN   (s_payload_rd_en),
        .I_RD_ADDR (s_payload_rd_addr),
        .O_RD_DATA (s_payload_rd_data)
      );

      // Parses one validated block, stores words in BSRAM, and drains them
      // through the original ready/valid output contract.
      always_ff @(posedge I_CLK or negedge I_RST_N) begin
        if (!I_RST_N) begin
          st_state            <= ST_SOF0;
          r_type              <= 8'h00;
          r_seq               <= 8'h00;
          r_len               <= 16'h0;
          r_len_count         <= 16'h0;
          r_crc_rx            <= 16'h0;
          r_crc_calc          <= 16'hFFFF;
          r_expect_seq        <= 8'h00;
          r_payload_word      <= 32'h0;
          r_word_count        <= '0;
          r_read_issue_index  <= '0;
          r_read_data_index   <= '0;
          r_read_data_valid   <= 1'b0;
          r_block_done        <= 1'b0;
          r_block_bytes       <= '0;
          r_block_seq         <= '0;
          r_abort_valid       <= 1'b0;
          r_abort_code        <= '0;
        end else begin
          r_block_done  <= 1'b0;
          r_abort_valid <= 1'b0;

          if (!I_ENABLE) begin
            st_state            <= ST_SOF0;
            r_expect_seq        <= 8'h00;
            r_read_issue_index  <= '0;
            r_read_data_valid   <= 1'b0;
          end else begin
            if (s_payload_rd_en) begin
              r_read_data_valid  <= 1'b1;
              r_read_data_index  <= r_read_issue_index;
              r_read_issue_index <= r_read_issue_index + 1'b1;
            end else if (s_word_fire) begin
              r_read_data_valid <= 1'b0;
            end

            case (st_state)
              ST_SOF0: begin
                r_read_data_valid <= 1'b0;
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
                  r_len[15:8] <= I_RX_DATA;
                  r_len_count <= 16'h0;
                  r_payload_word <= 32'h0;
                  r_crc_calc <= crc16_ccitt_false_update(r_crc_calc, I_RX_DATA);
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
                  r_payload_word <= (r_len_count[1:0] == 2'd3) ?
                                    32'h0 : s_payload_word_next;
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
                    r_word_count       <= r_len[7:2];
                    r_read_issue_index <= '0;
                    r_read_data_valid  <= 1'b0;
                    r_block_bytes      <= r_len;
                    r_block_seq        <= r_seq;
                    r_expect_seq       <= r_expect_seq + 1'b1;
                    st_state           <= ST_DRAIN;
                  end
                end
              end

              ST_DRAIN: begin
                if (s_word_fire && O_WORD_LAST_IN_BLOCK) begin
                  r_block_done      <= 1'b1;
                  r_read_data_valid <= 1'b0;
                  st_state          <= ST_SOF0;
                end
              end

              default: begin
                st_state <= ST_SOF0;
              end
            endcase
          end
        end
      end
    end
  endgenerate

endmodule
