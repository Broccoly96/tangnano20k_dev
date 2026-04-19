`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_access_engine.sv
// Description  : Linear single-word SDRAM access engine for the UART host path.
//                - Accepts one read or write request at a 21-bit word address.
//                - Issues exactly one Gowin SDRC user request with data_len = 0.
//                - Returns one response event context to the UART bridge.
//
// FSM flow:
//   IDLE -> READ_REQ  -> READ_WAIT  -> RESPOND
//        -> WRITE_REQ -> WRITE_WAIT -> RESPOND
//        -> RESPOND on precondition/timeout failure
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
  input  logic        I_SDRC_BUSY_N,
  input  logic        I_SDRC_WRD_ACK,
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
  output logic [31:0] O_RSP_STATUS,
  output logic        O_BUSY
);

  import sdram_uart_proto_pkg::*;

  localparam int unsigned TIMEOUT_W = (RESP_TIMEOUT_CYCLES <= 1) ? 1 :
                                      $clog2(RESP_TIMEOUT_CYCLES + 1);

  typedef enum logic [2:0] {
    IDLE,
    READ_REQ,
    READ_WAIT,
    WRITE_REQ,
    WRITE_WAIT,
    RESPOND
  } st_state_e;

  st_state_e st_state;

  logic [20:0] r_req_addr;
  logic [31:0] r_req_data;
  logic        r_req_is_write;
  logic [TIMEOUT_W-1:0] r_timeout_cnt;
  logic        r_busy_seen_low;
  logic        r_wrd_ack_seen;
  logic        r_read_seen_valid;
  logic [31:0] r_read_data_latched;
  logic        s_read_busy_seen_now;
  logic        r_rsp_valid;
  logic        r_rsp_is_write;
  logic [20:0] r_rsp_addr;
  logic [31:0] r_rsp_data;
  logic [31:0] r_rsp_status;

  assign O_REQ_READY     = (st_state == IDLE) && !r_rsp_valid;
  assign O_SDRC_ADDR     = r_req_addr;
  assign O_SDRC_DATA_LEN = 8'h00;
  assign O_SDRC_DQM      = 4'h0;
  assign O_SDRC_WR_DATA  = r_req_data;
  assign O_SDRC_WR_N     = ((st_state == WRITE_REQ) && I_SDRC_BUSY_N) ? 1'b0 : 1'b1;
  assign O_SDRC_RD_N     = ((st_state == READ_REQ) && I_SDRC_BUSY_N) ? 1'b0 : 1'b1;
  assign O_RSP_VALID     = r_rsp_valid;
  assign O_RSP_IS_WRITE  = r_rsp_is_write;
  assign O_RSP_ADDR      = r_rsp_addr;
  assign O_RSP_DATA      = r_rsp_data;
  assign O_RSP_STATUS    = r_rsp_status;
  assign O_BUSY          = (st_state != IDLE) || r_rsp_valid;
  assign s_read_busy_seen_now = r_busy_seen_low || !I_SDRC_BUSY_N;

  // Holds the linear single-word transaction FSM and response registers.
  // A request is accepted only in IDLE. The engine waits for the Gowin SDRC
  // busy pulse to complete so the next host command cannot overlap the current
  // user-interface operation.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state       <= IDLE;
      r_req_addr     <= '0;
      r_req_data     <= '0;
      r_req_is_write <= 1'b0;
      r_timeout_cnt  <= '0;
      r_busy_seen_low<= 1'b0;
      r_wrd_ack_seen <= 1'b0;
      r_read_seen_valid <= 1'b0;
      r_read_data_latched <= '0;
      r_rsp_valid    <= 1'b0;
      r_rsp_is_write <= 1'b0;
      r_rsp_addr     <= '0;
      r_rsp_data     <= '0;
      r_rsp_status   <= '0;
    end else begin
      if (r_rsp_valid && I_RSP_READY) begin
        r_rsp_valid <= 1'b0;
        if (st_state == RESPOND) begin
          st_state <= IDLE;
        end
      end

      case (st_state)
        IDLE: begin
          r_timeout_cnt   <= '0;
          r_busy_seen_low <= 1'b0;
          r_wrd_ack_seen  <= 1'b0;
          r_read_seen_valid <= 1'b0;
          r_read_data_latched <= '0;

          if (I_REQ_VALID && O_REQ_READY) begin
            r_req_addr     <= I_REQ_ADDR;
            r_req_data     <= I_REQ_DATA;
            r_req_is_write <= I_REQ_IS_WRITE;

            if (!I_SDRC_INIT_DONE) begin
              r_rsp_valid    <= 1'b1;
              r_rsp_is_write <= I_REQ_IS_WRITE;
              r_rsp_addr     <= I_REQ_ADDR;
              r_rsp_data     <= I_REQ_DATA;
              r_rsp_status   <= I_REQ_IS_WRITE ? ERR_SDRAM_WR_TO : ERR_SDRAM_RD_TO;
              st_state       <= RESPOND;
            end else if (I_REQ_IS_WRITE) begin
              st_state <= WRITE_REQ;
            end else begin
              st_state <= READ_REQ;
            end
          end
        end

        READ_REQ: begin
          r_timeout_cnt   <= '0;
          r_busy_seen_low <= 1'b0;
          r_read_seen_valid <= 1'b0;
          r_read_data_latched <= '0;
          if (I_SDRC_BUSY_N) begin
            st_state <= READ_WAIT;
          end
        end

        READ_WAIT: begin
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end
          if (s_read_busy_seen_now && I_SDRC_RD_VALID) begin
            r_read_seen_valid  <= 1'b1;
            r_read_data_latched <= I_SDRC_RD_DATA;
          end

          if (r_read_seen_valid && r_busy_seen_low && I_SDRC_BUSY_N) begin
            r_rsp_valid    <= 1'b1;
            r_rsp_is_write <= 1'b0;
            r_rsp_addr     <= r_req_addr;
            r_rsp_data     <= r_read_data_latched;
            r_rsp_status   <= 32'h0000_0000;
            st_state       <= RESPOND;
          end else if (r_timeout_cnt == RESP_TIMEOUT_CYCLES - 1) begin
            r_rsp_valid    <= 1'b1;
            r_rsp_is_write <= 1'b0;
            r_rsp_addr     <= r_req_addr;
            r_rsp_data     <= 32'h0000_0000;
            r_rsp_status   <= ERR_SDRAM_RD_TO;
            st_state       <= RESPOND;
          end else begin
            r_timeout_cnt <= r_timeout_cnt + 1'b1;
          end
        end

        WRITE_REQ: begin
          r_timeout_cnt   <= '0;
          r_busy_seen_low <= 1'b0;
          r_wrd_ack_seen  <= 1'b0;
          if (I_SDRC_BUSY_N) begin
            st_state <= WRITE_WAIT;
          end
        end

        WRITE_WAIT: begin
          if (!I_SDRC_BUSY_N) begin
            r_busy_seen_low <= 1'b1;
          end
          if (I_SDRC_WRD_ACK) begin
            r_wrd_ack_seen <= 1'b1;
          end

          if (r_busy_seen_low && r_wrd_ack_seen && I_SDRC_BUSY_N) begin
            r_rsp_valid    <= 1'b1;
            r_rsp_is_write <= 1'b1;
            r_rsp_addr     <= r_req_addr;
            r_rsp_data     <= r_req_data;
            r_rsp_status   <= 32'h0000_0000;
            st_state       <= RESPOND;
          end else if (r_timeout_cnt == RESP_TIMEOUT_CYCLES - 1) begin
            r_rsp_valid    <= 1'b1;
            r_rsp_is_write <= 1'b1;
            r_rsp_addr     <= r_req_addr;
            r_rsp_data     <= r_req_data;
            r_rsp_status   <= ERR_SDRAM_WR_TO;
            st_state       <= RESPOND;
          end else begin
            r_timeout_cnt <= r_timeout_cnt + 1'b1;
          end
        end

        RESPOND: begin
          st_state <= r_rsp_valid ? RESPOND : IDLE;
        end

        default: begin
          st_state <= IDLE;
        end
      endcase
    end
  end

endmodule
