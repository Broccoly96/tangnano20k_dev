`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_access_engine.sv
// Description  : SDRAM access engine for the UART host path.
//                - Write requests remain single-word host writes.
//                - Read requests are serviced from a 26-word prefetch cache.
//                - Cache misses trigger a 26-word SDRAM burst read that starts
//                  at the requested address.
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_access_engine #(
  parameter int unsigned RESP_TIMEOUT_CYCLES = 256,
  parameter int unsigned WR_STREAM_CYCLES    = 4
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_REQ_VALID,
  output logic        O_REQ_READY,
  input  logic        I_REQ_IS_WRITE,
  input  logic [20:0] I_REQ_ADDR,
  input  logic [31:0] I_REQ_DATA,
  input  logic        I_SDRC_INIT_DONE,
  input  logic        I_SDRC_BUSY_N,
  input  logic        I_SDRC_RD_VALID,
  input  logic [31:0] I_SDRC_RD_DATA,
  output logic        O_SDRC_WR_N,
  output logic        O_SDRC_RD_N,
  output logic [20:0] O_SDRC_ADDR,
  output logic [7:0]  O_SDRC_DATA_LEN,
  output logic [3:0]  O_SDRC_DQM,
  output logic [31:0] O_SDRC_WR_DATA,
  output logic        O_RSP_VALID,
  input  logic        I_RSP_READY,
  output logic        O_RSP_IS_WRITE,
  output logic [20:0] O_RSP_ADDR,
  output logic [31:0] O_RSP_DATA,
  output logic [31:0] O_RSP_STATUS
);

  import sdram_uart_proto_pkg::*;
`ifdef SIM
  import tb_log_pkg::*;
  `define SDRAM_ACCESS_LOG_DEBUG(MSG) tb_log_pkg::log_debug("SDRAM ACCESS ENG", MSG)
  `define SDRAM_ACCESS_LOG_TRACE(MSG) tb_log_pkg::log_trace("SDRAM ACCESS ENG", MSG)
`else
  `define SDRAM_ACCESS_LOG_DEBUG(MSG)
  `define SDRAM_ACCESS_LOG_TRACE(MSG)
`endif

  localparam int unsigned BURST_WORDS = 26;
  localparam int unsigned BURST_LEN_M1 = BURST_WORDS - 1;
  localparam int unsigned TIMEOUT_W = (RESP_TIMEOUT_CYCLES <= 1) ? 1 :
                                      $clog2(RESP_TIMEOUT_CYCLES + 1);
  localparam int unsigned WR_CYCLE_W = (WR_STREAM_CYCLES <= 1) ? 1 :
                                       $clog2(WR_STREAM_CYCLES + 1);
  localparam int unsigned BURST_CNT_W = $clog2(BURST_WORDS + 1);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_WRITE_REQ,
    ST_WRITE_WAIT,
    ST_READ_REQ,
    ST_READ_WAIT,
    ST_RESPOND
  } st_state_e;

  st_state_e st_state;
  st_state_e r_prev_state;

  logic        r_req_is_write;
  logic [20:0] r_req_addr;
  logic [31:0] r_req_data;
  logic [20:0] r_read_burst_addr;
  logic [31:0] r_wr_stream_data;
  logic [TIMEOUT_W-1:0] r_timeout_cnt;
  logic [WR_CYCLE_W-1:0] r_cycle_cnt;
  logic [BURST_CNT_W-1:0] r_read_word_count;
  logic        r_busy_seen_low;
  logic [31:0] r_first_read_data;

  logic        r_rsp_valid;
  logic        r_rsp_is_write;
  logic [20:0] r_rsp_addr;
  logic [31:0] r_rsp_data;
  logic [31:0] r_rsp_status;

  logic        r_cache_valid;
  logic [20:0] r_cache_base_addr;
  logic [31:0] r_cache_words [0:BURST_WORDS-1];

  logic        s_cache_hit;
  logic [20:0] s_cache_addr_limit;
  logic [4:0]  s_cache_index;

  assign s_cache_addr_limit = r_cache_base_addr + BURST_WORDS;
  assign s_cache_hit = r_cache_valid &&
                       (I_REQ_ADDR >= r_cache_base_addr) &&
                       (I_REQ_ADDR < s_cache_addr_limit);
  assign s_cache_index = I_REQ_ADDR - r_cache_base_addr;

  assign O_REQ_READY = (st_state == ST_IDLE) && !r_rsp_valid;
  assign O_SDRC_ADDR = (st_state == ST_READ_REQ || st_state == ST_READ_WAIT) ?
                       r_read_burst_addr : r_req_addr;
  assign O_SDRC_DATA_LEN = (st_state == ST_READ_REQ || st_state == ST_READ_WAIT) ?
                           8'(BURST_LEN_M1) : 8'h00;
  assign O_SDRC_DQM = 4'h0;
  assign O_SDRC_WR_DATA = r_wr_stream_data;
  assign O_SDRC_WR_N =
    (st_state == ST_WRITE_REQ && I_SDRC_BUSY_N) ? 1'b0 : 1'b1;
  assign O_SDRC_RD_N =
    (st_state == ST_READ_REQ && I_SDRC_BUSY_N) ? 1'b0 : 1'b1;

  assign O_RSP_VALID = r_rsp_valid;
  assign O_RSP_IS_WRITE = r_rsp_is_write;
  assign O_RSP_ADDR = r_rsp_addr;
  assign O_RSP_DATA = r_rsp_data;
  assign O_RSP_STATUS = r_rsp_status;

`ifdef SIM
  function automatic string state_to_string(input st_state_e state_value);
    case (state_value)
      ST_IDLE:       return "ST_IDLE";
      ST_WRITE_REQ:  return "ST_WRITE_REQ";
      ST_WRITE_WAIT: return "ST_WRITE_WAIT";
      ST_READ_REQ:   return "ST_READ_REQ";
      ST_READ_WAIT:  return "ST_READ_WAIT";
      ST_RESPOND:    return "ST_RESPOND";
      default:       return "ST_UNKNOWN";
    endcase
  endfunction
`endif

  // Holds the access engine state, response registers, and read cache.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state          <= ST_IDLE;
      r_prev_state      <= ST_IDLE;
      r_req_is_write    <= 1'b0;
      r_req_addr        <= '0;
      r_req_data        <= '0;
      r_read_burst_addr <= '0;
      r_wr_stream_data  <= 32'h0;
      r_timeout_cnt     <= '0;
      r_cycle_cnt       <= '0;
      r_read_word_count <= '0;
      r_busy_seen_low   <= 1'b0;
      r_first_read_data <= 32'h0;
      r_rsp_valid       <= 1'b0;
      r_rsp_is_write    <= 1'b0;
      r_rsp_addr        <= '0;
      r_rsp_data        <= '0;
      r_rsp_status      <= '0;
      r_cache_valid     <= 1'b0;
      r_cache_base_addr <= '0;
      for (int idx = 0; idx < BURST_WORDS; idx++) begin
        r_cache_words[idx] <= 32'h0;
      end
    end else begin
      r_prev_state <= st_state;

      if (r_rsp_valid && I_RSP_READY) begin
        r_rsp_valid <= 1'b0;
      end

      case (st_state)
        ST_IDLE: begin
          r_timeout_cnt     <= '0;
          r_cycle_cnt       <= '0;
          r_read_word_count <= '0;
          r_busy_seen_low   <= 1'b0;
          r_wr_stream_data  <= r_req_data;

          if (I_REQ_VALID && O_REQ_READY) begin
            r_req_is_write <= I_REQ_IS_WRITE;
            r_req_addr     <= I_REQ_ADDR;
            r_req_data     <= I_REQ_DATA;
            r_wr_stream_data <= I_REQ_DATA;

            `SDRAM_ACCESS_LOG_DEBUG(
              $sformatf(
                "accept_req type=%s addr=0x%05h data=0x%08h init_done=%0b busy_n=%0b cache_hit=%0b",
                I_REQ_IS_WRITE ? "WRITE" : "READ",
                I_REQ_ADDR,
                I_REQ_DATA,
                I_SDRC_INIT_DONE,
                I_SDRC_BUSY_N,
                !I_REQ_IS_WRITE && s_cache_hit
              )
            );

            if (I_REQ_IS_WRITE) begin
              r_cache_valid <= 1'b0;
            end

            if (!I_SDRC_INIT_DONE) begin
              r_rsp_valid    <= 1'b1;
              r_rsp_is_write <= I_REQ_IS_WRITE;
              r_rsp_addr     <= I_REQ_ADDR;
              r_rsp_data     <= I_REQ_DATA;
              r_rsp_status   <= I_REQ_IS_WRITE ? ERR_SDRAM_WR_TO : ERR_SDRAM_RD_TO;
              st_state       <= ST_RESPOND;
            end else if (!I_REQ_IS_WRITE && s_cache_hit) begin
              `SDRAM_ACCESS_LOG_DEBUG(
                $sformatf(
                  "cache_hit addr=0x%05h index=%0d data=0x%08h base=0x%05h",
                  I_REQ_ADDR,
                  s_cache_index,
                  r_cache_words[s_cache_index],
                  r_cache_base_addr
                )
              );
              r_rsp_valid    <= 1'b1;
              r_rsp_is_write <= 1'b0;
              r_rsp_addr     <= I_REQ_ADDR;
              r_rsp_data     <= r_cache_words[s_cache_index];
              r_rsp_status   <= 32'h0;
              st_state       <= ST_RESPOND;
            end else begin
              if (!I_REQ_IS_WRITE) begin
                r_read_burst_addr <= I_REQ_ADDR;
                r_first_read_data <= 32'h0;
              end
              st_state <= I_REQ_IS_WRITE ? ST_WRITE_REQ : ST_READ_REQ;
            end
          end
        end

        ST_WRITE_REQ: begin
          r_timeout_cnt    <= '0;
          r_cycle_cnt      <= '0;
          r_wr_stream_data <= r_req_data;
          if (I_SDRC_BUSY_N) begin
            `SDRAM_ACCESS_LOG_TRACE(
              $sformatf(
                "issue_write addr=0x%05h data=0x%08h len=1",
                r_req_addr,
                r_req_data
              )
            );
            st_state <= ST_WRITE_WAIT;
          end
        end

        ST_WRITE_WAIT: begin
          r_cycle_cnt <= r_cycle_cnt + 1'b1;
          if (r_cycle_cnt < WR_STREAM_CYCLES - 1) begin
            r_wr_stream_data <= r_wr_stream_data + 1'b1;
          end
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end

          if (r_busy_seen_low && I_SDRC_BUSY_N &&
              (r_cycle_cnt >= WR_STREAM_CYCLES - 1)) begin
            `SDRAM_ACCESS_LOG_DEBUG(
              $sformatf("write_done addr=0x%05h data=0x%08h", r_req_addr, r_req_data)
            );
            r_rsp_valid    <= 1'b1;
            r_rsp_is_write <= 1'b1;
            r_rsp_addr     <= r_req_addr;
            r_rsp_data     <= r_req_data;
            r_rsp_status   <= 32'h0;
            st_state       <= ST_RESPOND;
          end else if (r_timeout_cnt == RESP_TIMEOUT_CYCLES - 1) begin
            `SDRAM_ACCESS_LOG_DEBUG($sformatf("write_timeout addr=0x%05h", r_req_addr));
            r_rsp_valid    <= 1'b1;
            r_rsp_is_write <= 1'b1;
            r_rsp_addr     <= r_req_addr;
            r_rsp_data     <= r_req_data;
            r_rsp_status   <= ERR_SDRAM_WR_TO;
            st_state       <= ST_RESPOND;
          end else begin
            r_timeout_cnt <= r_timeout_cnt + 1'b1;
          end
        end

        ST_READ_REQ: begin
          r_timeout_cnt     <= '0;
          r_cycle_cnt       <= '0;
          r_read_word_count <= '0;
          if (I_SDRC_BUSY_N) begin
            `SDRAM_ACCESS_LOG_TRACE(
              $sformatf(
                "issue_read_burst addr=0x%05h len=%0d",
                r_read_burst_addr,
                BURST_WORDS
              )
            );
            st_state <= ST_READ_WAIT;
          end
        end

        ST_READ_WAIT: begin
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end

          if (I_SDRC_RD_VALID) begin
            if (r_read_word_count < BURST_WORDS) begin
              r_cache_words[r_read_word_count] <= I_SDRC_RD_DATA;
            end
            if (r_read_word_count == 0) begin
              r_first_read_data <= I_SDRC_RD_DATA;
            end
            `SDRAM_ACCESS_LOG_DEBUG(
              $sformatf(
                "read_burst_beat base=0x%05h beat=%0d data=0x%08h",
                r_read_burst_addr,
                r_read_word_count,
                I_SDRC_RD_DATA
              )
            );
            if (r_read_word_count < BURST_WORDS) begin
              r_read_word_count <= r_read_word_count + 1'b1;
            end
          end

          if (r_busy_seen_low && I_SDRC_BUSY_N &&
              (r_read_word_count >= BURST_WORDS)) begin
            `SDRAM_ACCESS_LOG_DEBUG(
              $sformatf(
                "read_burst_done base=0x%05h words=%0d first=0x%08h",
                r_read_burst_addr,
                r_read_word_count,
                r_first_read_data
              )
            );
            r_cache_valid     <= 1'b1;
            r_cache_base_addr <= r_read_burst_addr;
            r_rsp_valid       <= 1'b1;
            r_rsp_is_write    <= 1'b0;
            r_rsp_addr        <= r_req_addr;
            r_rsp_data        <= r_first_read_data;
            r_rsp_status      <= 32'h0;
            st_state          <= ST_RESPOND;
          end else if (r_timeout_cnt == RESP_TIMEOUT_CYCLES - 1) begin
            `SDRAM_ACCESS_LOG_DEBUG(
              $sformatf(
                "read_burst_timeout base=0x%05h count=%0d busy_n=%0b rd_valid=%0b",
                r_read_burst_addr,
                r_read_word_count,
                I_SDRC_BUSY_N,
                I_SDRC_RD_VALID
              )
            );
            r_rsp_valid       <= 1'b1;
            r_rsp_is_write    <= 1'b0;
            r_rsp_addr        <= r_req_addr;
            r_rsp_data        <= 32'h0;
            r_rsp_status      <= ERR_SDRAM_RD_TO;
            r_cache_valid     <= 1'b0;
            st_state          <= ST_RESPOND;
          end else begin
            r_timeout_cnt <= r_timeout_cnt + 1'b1;
          end
        end

        ST_RESPOND: begin
          if (!r_rsp_valid || I_RSP_READY) begin
            st_state <= ST_IDLE;
          end
        end

        default: begin
          st_state <= ST_IDLE;
        end
      endcase

`ifdef SIM
      if (st_state != r_prev_state) begin
        `SDRAM_ACCESS_LOG_TRACE(
          $sformatf(
            "state %s -> %s busy_n=%0b rd_valid=%0b timeout=%0d count=%0d",
            state_to_string(r_prev_state),
            state_to_string(st_state),
            I_SDRC_BUSY_N,
            I_SDRC_RD_VALID,
            r_timeout_cnt,
            r_read_word_count
          )
        );
      end
`endif
    end
  end

endmodule

`undef SDRAM_ACCESS_LOG_DEBUG
`undef SDRAM_ACCESS_LOG_TRACE
