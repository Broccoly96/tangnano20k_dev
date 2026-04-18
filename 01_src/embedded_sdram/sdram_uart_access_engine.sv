`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_access_engine.sv
// Description  : SDRAM access engine for the UART host path.
//                - Write requests are converted into a 26-word read-modify-
//                  write burst through the shared SDRC executor.
//                - Read requests are served from a 26-word cache when possible
//                  and otherwise trigger one executor-backed read burst.
//                - This block no longer drives SDRC pins directly.
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_access_engine #(
  parameter int unsigned RESP_TIMEOUT_CYCLES = 256
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_REQ_VALID,
  output logic        O_REQ_READY,
  input  logic        I_REQ_IS_WRITE,
  input  logic [20:0] I_REQ_ADDR,
  input  logic [31:0] I_REQ_DATA,
  input  logic        I_SDRC_INIT_DONE,

  output logic        O_EXEC_REQ_VALID,
  input  logic        I_EXEC_REQ_READY,
  output logic        O_EXEC_REQ_IS_WRITE,
  output logic [20:0] O_EXEC_REQ_ADDR,
  output logic [8:0]  O_EXEC_REQ_WORDS,
  output logic [31:0] O_EXEC_WR_BEAT_DATA,
  output logic        O_EXEC_WR_BEAT_VALID,
  input  logic [7:0]  I_EXEC_WR_BEAT_INDEX,

  input  logic        I_EXEC_RSP_VALID,
  output logic        O_EXEC_RSP_READY,
  input  logic [31:0] I_EXEC_RSP_STATUS,
  input  logic        I_EXEC_RD_BEAT_VALID,
  input  logic [31:0] I_EXEC_RD_BEAT_DATA,
  input  logic [7:0]  I_EXEC_RD_BEAT_INDEX,
  input  logic        I_EXEC_RSP_DONE,

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
`else
  `define SDRAM_ACCESS_LOG_DEBUG(MSG)
`endif

  localparam int unsigned BURST_WORDS = 26;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_WRITE_FILL_REQ,
    ST_WRITE_FILL_WAIT,
    ST_WRITE_BURST_REQ,
    ST_WRITE_BURST_RUN,
    ST_READ_REQ,
    ST_READ_WAIT,
    ST_RESPOND
  } st_state_e;

  st_state_e st_state;

  logic        r_req_is_write;
  logic [20:0] r_req_addr;
  logic [31:0] r_req_data;
  logic [20:0] r_read_burst_addr;
  logic [31:0] r_first_read_data;
  logic [4:0]  r_write_update_index;

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

  assign O_EXEC_REQ_VALID = (st_state == ST_WRITE_FILL_REQ) ||
                            (st_state == ST_WRITE_BURST_REQ) ||
                            (st_state == ST_READ_REQ);
  assign O_EXEC_REQ_IS_WRITE = (st_state == ST_WRITE_BURST_REQ);
  assign O_EXEC_REQ_ADDR = r_read_burst_addr;
  assign O_EXEC_REQ_WORDS = BURST_WORDS;
  assign O_EXEC_WR_BEAT_DATA = r_cache_words[I_EXEC_WR_BEAT_INDEX];
  assign O_EXEC_WR_BEAT_VALID = (st_state == ST_WRITE_BURST_REQ) ||
                                (st_state == ST_WRITE_BURST_RUN);
  assign O_EXEC_RSP_READY = 1'b1;

  assign O_RSP_VALID = r_rsp_valid;
  assign O_RSP_IS_WRITE = r_rsp_is_write;
  assign O_RSP_ADDR = r_rsp_addr;
  assign O_RSP_DATA = r_rsp_data;
  assign O_RSP_STATUS = r_rsp_status;

  // Access engine FSM.
  // Flow:
  //   IDLE -> WRITE_FILL_REQ/WAIT -> WRITE_BURST_REQ/RUN -> RESPOND
  //   IDLE -> READ_REQ/WAIT -> RESPOND
  // The shared executor owns all SDRC timing.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state           <= ST_IDLE;
      r_req_is_write     <= 1'b0;
      r_req_addr         <= '0;
      r_req_data         <= '0;
      r_read_burst_addr  <= '0;
      r_first_read_data  <= 32'h0000_0000;
      r_write_update_index <= '0;
      r_rsp_valid        <= 1'b0;
      r_rsp_is_write     <= 1'b0;
      r_rsp_addr         <= '0;
      r_rsp_data         <= '0;
      r_rsp_status       <= '0;
      r_cache_valid      <= 1'b0;
      r_cache_base_addr  <= '0;
      for (int idx = 0; idx < BURST_WORDS; idx++) begin
        r_cache_words[idx] <= 32'h0000_0000;
      end
    end else begin
      if (r_rsp_valid && I_RSP_READY) begin
        r_rsp_valid <= 1'b0;
      end

      if (I_EXEC_RD_BEAT_VALID) begin
        if (I_EXEC_RD_BEAT_INDEX < BURST_WORDS) begin
          r_cache_words[I_EXEC_RD_BEAT_INDEX] <= I_EXEC_RD_BEAT_DATA;
        end
        if (I_EXEC_RD_BEAT_INDEX == 0) begin
          r_first_read_data <= I_EXEC_RD_BEAT_DATA;
        end
      end

      case (st_state)
        ST_IDLE: begin
          if (I_REQ_VALID && O_REQ_READY) begin
            r_req_is_write <= I_REQ_IS_WRITE;
            r_req_addr     <= I_REQ_ADDR;
            r_req_data     <= I_REQ_DATA;
            r_first_read_data <= 32'h0000_0000;

            if (!I_SDRC_INIT_DONE) begin
              r_rsp_valid    <= 1'b1;
              r_rsp_is_write <= I_REQ_IS_WRITE;
              r_rsp_addr     <= I_REQ_ADDR;
              r_rsp_data     <= I_REQ_DATA;
              r_rsp_status   <= I_REQ_IS_WRITE ? ERR_SDRAM_WR_TO : ERR_SDRAM_RD_TO;
              st_state       <= ST_RESPOND;
            end else if (!I_REQ_IS_WRITE && s_cache_hit) begin
              r_rsp_valid    <= 1'b1;
              r_rsp_is_write <= 1'b0;
              r_rsp_addr     <= I_REQ_ADDR;
              r_rsp_data     <= r_cache_words[s_cache_index];
              r_rsp_status   <= 32'h0000_0000;
              st_state       <= ST_RESPOND;
            end else begin
              if (I_REQ_IS_WRITE) begin
                if (s_cache_hit) begin
                  r_read_burst_addr    <= r_cache_base_addr;
                  r_write_update_index <= s_cache_index;
                  r_cache_words[s_cache_index] <= I_REQ_DATA;
                  st_state             <= ST_WRITE_BURST_REQ;
                end else begin
                  r_read_burst_addr    <= I_REQ_ADDR;
                  r_write_update_index <= 5'd0;
                  st_state             <= ST_WRITE_FILL_REQ;
                end
              end else begin
                r_read_burst_addr <= I_REQ_ADDR;
                st_state          <= ST_READ_REQ;
              end
            end
          end
        end

        ST_WRITE_FILL_REQ: begin
          if (I_EXEC_REQ_READY) begin
            st_state <= ST_WRITE_FILL_WAIT;
          end
        end

        ST_WRITE_FILL_WAIT: begin
          if (I_EXEC_RSP_VALID) begin
            if (I_EXEC_RSP_STATUS != 32'h0000_0000) begin
              r_rsp_valid    <= 1'b1;
              r_rsp_is_write <= 1'b1;
              r_rsp_addr     <= r_req_addr;
              r_rsp_data     <= r_req_data;
              r_rsp_status   <= I_EXEC_RSP_STATUS;
              r_cache_valid  <= 1'b0;
              st_state       <= ST_RESPOND;
            end else begin
              r_cache_valid <= 1'b1;
              r_cache_base_addr <= r_read_burst_addr;
              r_cache_words[r_write_update_index] <= r_req_data;
              st_state <= ST_WRITE_BURST_REQ;
            end
          end
        end

        ST_WRITE_BURST_REQ: begin
          if (I_EXEC_REQ_READY) begin
            st_state <= ST_WRITE_BURST_RUN;
          end
        end

        ST_WRITE_BURST_RUN: begin
          if (I_EXEC_RSP_VALID) begin
            r_rsp_valid    <= 1'b1;
            r_rsp_is_write <= 1'b1;
            r_rsp_addr     <= r_req_addr;
            r_rsp_data     <= r_req_data;
            r_rsp_status   <= I_EXEC_RSP_STATUS;
            if (I_EXEC_RSP_STATUS != 32'h0000_0000) begin
              r_cache_valid <= 1'b0;
            end
            st_state <= ST_RESPOND;
          end
        end

        ST_READ_REQ: begin
          if (I_EXEC_REQ_READY) begin
            st_state <= ST_READ_WAIT;
          end
        end

        ST_READ_WAIT: begin
          if (I_EXEC_RSP_VALID) begin
            r_rsp_valid    <= 1'b1;
            r_rsp_is_write <= 1'b0;
            r_rsp_addr     <= r_req_addr;
            r_rsp_data     <= (I_EXEC_RSP_STATUS == 32'h0000_0000) ? r_first_read_data : 32'h0000_0000;
            r_rsp_status   <= I_EXEC_RSP_STATUS;
            if (I_EXEC_RSP_STATUS == 32'h0000_0000) begin
              r_cache_valid <= 1'b1;
              r_cache_base_addr <= r_read_burst_addr;
            end else begin
              r_cache_valid <= 1'b0;
            end
            st_state <= ST_RESPOND;
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
    end
  end

endmodule

`undef SDRAM_ACCESS_LOG_DEBUG
