`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_sdrc_burst_exec.sv
// Description  : Shared SDRC burst executor.
//                - This is the only block that directly drives the SDRC user
//                  interface signals.
//                - Accepts one burst request at a time from a higher-level
//                  client and converts it into the documented SDRC launch,
//                  stream, and completion sequence.
//                - Write bursts launch beat 0 in the same cycle as `wr_n=0`
//                  and then stream one beat per clock until all requested
//                  beats have been presented.
//                - Read bursts launch `rd_n=0`, capture beats only on
//                  `rd_valid`, and complete only after the expected beat count
//                  has been received and `busy_n` has returned high.
//
// Usage:
//   A client supplies one request at a time.
//   `I_REQ_WORDS` is the actual beat count in the range 1..256.
//   For write requests, the client drives `I_REQ_WR_BEAT_DATA` as a
//   combinational function of `O_REQ_WR_BEAT_INDEX`.
//////////////////////////////////////////////////////////////////////////////////

module sdram_sdrc_burst_exec #(
  parameter int unsigned RESP_TIMEOUT_CYCLES = 2048
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,

  input  logic        I_REQ_VALID,
  output logic        O_REQ_READY,
  input  logic        I_REQ_IS_WRITE,
  input  logic [20:0] I_REQ_ADDR,
  input  logic [8:0]  I_REQ_WORDS,
  input  logic [31:0] I_REQ_WR_BEAT_DATA,
  input  logic        I_REQ_WR_BEAT_VALID,
  output logic [7:0]  O_REQ_WR_BEAT_INDEX,

  output logic        O_RSP_VALID,
  input  logic        I_RSP_READY,
  output logic [31:0] O_RSP_STATUS,
  output logic        O_RSP_RD_BEAT_VALID,
  output logic [31:0] O_RSP_RD_BEAT_DATA,
  output logic [7:0]  O_RSP_RD_BEAT_INDEX,
  output logic        O_RSP_DONE,

  input  logic        I_SDRC_BUSY_N,
  input  logic        I_SDRC_WRD_ACK,
  input  logic        I_SDRC_RD_VALID,
  input  logic [31:0] I_SDRC_RD_DATA,
  output logic        O_SDRC_WR_N,
  output logic        O_SDRC_RD_N,
  output logic [20:0] O_SDRC_ADDR,
  output logic [7:0]  O_SDRC_DATA_LEN,
  output logic [3:0]  O_SDRC_DQM,
  output logic [31:0] O_SDRC_WR_DATA
);

  import sdram_uart_proto_pkg::*;

  localparam int unsigned TIMEOUT_W = (RESP_TIMEOUT_CYCLES <= 1) ? 1 :
                                      $clog2(RESP_TIMEOUT_CYCLES + 1);

  typedef enum logic [2:0] {
    IDLE,
    WRITE_REQ,
    WRITE_RUN,
    READ_REQ,
    READ_RUN,
    RESPOND
  } st_state_e;

  st_state_e st_state;

  logic        r_req_is_write;
  logic [20:0] r_req_addr;
  logic [8:0]  r_req_words;
  logic [7:0]  r_wr_beat_index;
  logic [8:0]  r_wr_beats_launched;
  logic [8:0]  r_rd_beats_seen;
  logic        r_busy_seen_low;
  logic        r_wrd_ack_seen;
  logic [TIMEOUT_W-1:0] r_timeout_cnt;

  logic        r_rsp_valid;
  logic [31:0] r_rsp_status;
  logic        r_rsp_done;

  logic s_req_accept;
  logic s_write_done;
  logic s_read_done;
  logic s_write_timeout;
  logic s_read_timeout;

  assign O_REQ_READY = (st_state == IDLE) && !r_rsp_valid;
  assign s_req_accept = I_REQ_VALID && O_REQ_READY &&
                        (I_REQ_WORDS != 0) &&
                        (!I_REQ_IS_WRITE || I_REQ_WR_BEAT_VALID);

  assign O_SDRC_ADDR = r_req_addr;
  assign O_SDRC_DATA_LEN = (r_req_words == 0) ? 8'h00 : r_req_words[7:0] - 1'b1;
  assign O_SDRC_DQM = 4'h0;
  assign O_SDRC_WR_DATA = I_REQ_WR_BEAT_DATA;
  assign O_SDRC_WR_N = ((st_state == WRITE_REQ) && I_SDRC_BUSY_N) ? 1'b0 : 1'b1;
  assign O_SDRC_RD_N = ((st_state == READ_REQ)  && I_SDRC_BUSY_N) ? 1'b0 : 1'b1;

  assign O_REQ_WR_BEAT_INDEX = r_wr_beat_index;

  assign O_RSP_VALID = r_rsp_valid;
  assign O_RSP_STATUS = r_rsp_status;
  assign O_RSP_DONE = r_rsp_done;
  assign O_RSP_RD_BEAT_VALID = (st_state == READ_RUN) && I_SDRC_RD_VALID;
  assign O_RSP_RD_BEAT_DATA = I_SDRC_RD_DATA;
  assign O_RSP_RD_BEAT_INDEX = r_rd_beats_seen[7:0];

  assign s_write_done = (r_wr_beats_launched >= r_req_words) &&
                        r_wrd_ack_seen &&
                        r_busy_seen_low &&
                        I_SDRC_BUSY_N;
  assign s_read_done = (r_rd_beats_seen >= r_req_words) &&
                       r_busy_seen_low &&
                       I_SDRC_BUSY_N;
  assign s_write_timeout = (r_timeout_cnt == RESP_TIMEOUT_CYCLES - 1);
  assign s_read_timeout = (r_timeout_cnt == RESP_TIMEOUT_CYCLES - 1);

  // Executor FSM.
  // Flow:
  //   IDLE -> WRITE_REQ -> WRITE_RUN -> RESPOND -> IDLE
  //   IDLE -> READ_REQ  -> READ_RUN  -> RESPOND -> IDLE
  // Completion is accepted only after the documented busy low/high cycle
  // has been observed.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state          <= IDLE;
      r_req_is_write    <= 1'b0;
      r_req_addr        <= '0;
      r_req_words       <= '0;
      r_wr_beat_index   <= '0;
      r_wr_beats_launched <= '0;
      r_rd_beats_seen   <= '0;
      r_busy_seen_low   <= 1'b0;
      r_wrd_ack_seen    <= 1'b0;
      r_timeout_cnt     <= '0;
      r_rsp_valid       <= 1'b0;
      r_rsp_status      <= 32'h0000_0000;
      r_rsp_done        <= 1'b0;
    end else begin
      r_rsp_done <= 1'b0;

      if (r_rsp_valid && I_RSP_READY) begin
        r_rsp_valid <= 1'b0;
      end

      case (st_state)
        IDLE: begin
          r_wr_beat_index     <= '0;
          r_wr_beats_launched <= '0;
          r_rd_beats_seen     <= '0;
          r_busy_seen_low     <= 1'b0;
          r_wrd_ack_seen      <= 1'b0;
          r_timeout_cnt       <= '0;

          if (s_req_accept) begin
            r_req_is_write <= I_REQ_IS_WRITE;
            r_req_addr     <= I_REQ_ADDR;
            r_req_words    <= I_REQ_WORDS;
            if (I_REQ_IS_WRITE) begin
              st_state <= WRITE_REQ;
            end else begin
              st_state <= READ_REQ;
            end
          end
        end

        WRITE_REQ: begin
          r_timeout_cnt <= '0;
          if (I_SDRC_BUSY_N) begin
            r_wr_beats_launched <= 9'd1;
            if (r_req_words > 1) begin
              r_wr_beat_index <= 8'd1;
            end
            st_state <= WRITE_RUN;
          end
        end

        WRITE_RUN: begin
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end
          if (I_SDRC_WRD_ACK) begin
            r_wrd_ack_seen <= 1'b1;
          end

          if (r_timeout_cnt < RESP_TIMEOUT_CYCLES - 1) begin
            r_timeout_cnt <= r_timeout_cnt + 1'b1;
          end

          if (r_wr_beats_launched < r_req_words) begin
            r_wr_beats_launched <= r_wr_beats_launched + 1'b1;
            if ((r_wr_beats_launched + 1'b1) < r_req_words) begin
              r_wr_beat_index <= r_wr_beat_index + 1'b1;
            end
          end

          if (s_write_done) begin
            r_rsp_valid  <= 1'b1;
            r_rsp_status <= 32'h0000_0000;
            r_rsp_done   <= 1'b1;
            st_state     <= RESPOND;
          end else if (s_write_timeout) begin
            r_rsp_valid  <= 1'b1;
            r_rsp_status <= ERR_SDRAM_WR_TO;
            r_rsp_done   <= 1'b1;
            st_state     <= RESPOND;
          end
        end

        READ_REQ: begin
          r_timeout_cnt <= '0;
          if (I_SDRC_BUSY_N) begin
            st_state <= READ_RUN;
          end
        end

        READ_RUN: begin
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end

          if (r_timeout_cnt < RESP_TIMEOUT_CYCLES - 1) begin
            r_timeout_cnt <= r_timeout_cnt + 1'b1;
          end

          if (I_SDRC_RD_VALID && (r_rd_beats_seen < r_req_words)) begin
            r_rd_beats_seen <= r_rd_beats_seen + 1'b1;
          end

          if (s_read_done) begin
            r_rsp_valid  <= 1'b1;
            r_rsp_status <= 32'h0000_0000;
            r_rsp_done   <= 1'b1;
            st_state     <= RESPOND;
          end else if (s_read_timeout) begin
            r_rsp_valid  <= 1'b1;
            r_rsp_status <= ERR_SDRAM_RD_TO;
            r_rsp_done   <= 1'b1;
            st_state     <= RESPOND;
          end
        end

        RESPOND: begin
          if (!r_rsp_valid || I_RSP_READY) begin
            st_state <= IDLE;
          end
        end

        default: begin
          st_state <= IDLE;
        end
      endcase
    end
  end

endmodule
