`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_open_byte_ctrl.sv
// Description  : Byte-transaction wrapper for the open-source Tang Nano 20K
//                SDRAM controller.
//                - Owns the controller request pulses and initialization detect.
//                - Schedules SDRAM refresh autonomously.
//                - Exposes one byte request/response at a time to upper logic.
//
// Usage:
//   Drive one request at a time with `I_REQ_VALID`.
//   Wait for `O_REQ_READY`, then hold inputs stable for the accept cycle.
//   Read and write requests both return one response through
//   `O_RSP_VALID/O_RSP_STATUS`.
//////////////////////////////////////////////////////////////////////////////////

module sdram_open_byte_ctrl #(
  parameter int unsigned FREQ_HZ = 48_000_000,
  parameter logic [3:0]  SDRAM_CAS = 4'd3,
  parameter logic [3:0]  SDRAM_T_WR = 4'd2,
  parameter logic [3:0]  SDRAM_T_MRD = 4'd2,
  parameter logic [3:0]  SDRAM_T_RP = 4'd1,
  parameter logic [3:0]  SDRAM_T_RCD = 4'd1,
  parameter logic [3:0]  SDRAM_T_RC = 4'd4,
  parameter int unsigned REFRESH_INTERVAL_US = 12,
  parameter int unsigned REFRESH_DEADLINE_US = 15,
  parameter int unsigned RESP_TIMEOUT_CYCLES = 2048
) (
  input  logic        I_CLK,
  input  logic        I_CLK_SDRAM,
  input  logic        I_RST_N,

  input  logic        I_REQ_VALID,
  output logic        O_REQ_READY,
  input  logic        I_REQ_IS_WRITE,
  input  logic [22:0] I_REQ_ADDR,
  input  logic [7:0]  I_REQ_WR_DATA,

  output logic        O_RSP_VALID,
  input  logic        I_RSP_READY,
  output logic [7:0]  O_RSP_RD_DATA,
  output logic [31:0] O_RSP_STATUS,
  output logic        O_INIT_DONE,
  output logic [31:0] O_DBG_SUMMARY,
  output logic [31:0] O_DBG_DETAIL,

  output logic        O_sdram_clk,
  output logic        O_sdram_cke,
  output logic        O_sdram_cs_n,
  output logic        O_sdram_cas_n,
  output logic        O_sdram_ras_n,
  output logic        O_sdram_wen_n,
  output logic [3:0]  O_sdram_dqm,
  output logic [10:0] O_sdram_addr,
  output logic [1:0]  O_sdram_ba,
  inout  wire [31:0]  IO_sdram_dq
);

  import sdram_uart_proto_pkg::*;

  localparam int unsigned REFRESH_INTERVAL_CYCLES =
    (((FREQ_HZ / 1_000_000) * REFRESH_INTERVAL_US) <= 1) ? 1 :
    ((FREQ_HZ / 1_000_000) * REFRESH_INTERVAL_US);
  localparam int unsigned REFRESH_DEADLINE_CYCLES =
    (((FREQ_HZ / 1_000_000) * REFRESH_DEADLINE_US) <= 1) ? 1 :
    ((FREQ_HZ / 1_000_000) * REFRESH_DEADLINE_US);
  localparam int unsigned REFRESH_CNT_W =
    (REFRESH_DEADLINE_CYCLES <= 1) ? 1 :
    $clog2(REFRESH_DEADLINE_CYCLES + 1);
  localparam int unsigned TIMEOUT_W =
    (RESP_TIMEOUT_CYCLES <= 1) ? 1 :
    $clog2(RESP_TIMEOUT_CYCLES + 1);

  typedef enum logic [2:0] {
    ST_WAIT_INIT,
    ST_IDLE,
    ST_REFRESH_WAIT,
    ST_REQ_WAIT,
    ST_READ_COMPLETE,
    ST_RESPOND
  } st_state_e;

  st_state_e st_state;

  logic        r_req_is_write;
  logic [22:0] r_req_addr;
  logic [7:0]  r_req_wr_data;
  logic [7:0]  r_rsp_rd_data;
  logic [31:0] r_rsp_status;
  logic        r_rsp_valid;
  logic        r_req_seen_busy;
  logic        r_req_seen_data_ready;
  logic [31:0] r_last_ctrl_dout32;
  logic [REFRESH_CNT_W-1:0] r_refresh_age;
  logic [TIMEOUT_W-1:0]     r_timeout_cnt;

  logic        l_ctrl_rd;
  logic        l_ctrl_wr;
  logic        l_ctrl_refresh;
  logic [22:0] l_ctrl_addr;
  logic [7:0]  l_ctrl_din;
  logic [7:0]  l_ctrl_dout;
  logic [31:0] l_ctrl_dout32;
  logic        l_ctrl_data_ready;
  logic        l_ctrl_busy;
  logic        s_refresh_due;
  logic        s_refresh_issue;
  logic        s_req_accept;
  logic        s_req_done;
  logic        s_refresh_done;
  logic        s_req_timeout;
  logic [15:0] s_dbg_timeout_cnt;
  logic [15:0] s_dbg_refresh_age;

  function automatic logic [7:0] select_byte_from_word(
    input logic [31:0] word_value,
    input logic [1:0]  byte_offset
  );
    begin
      case (byte_offset)
        2'd0: select_byte_from_word = word_value[7:0];
        2'd1: select_byte_from_word = word_value[15:8];
        2'd2: select_byte_from_word = word_value[23:16];
        default: select_byte_from_word = word_value[31:24];
      endcase
    end
  endfunction

  assign s_refresh_due = O_INIT_DONE &&
                         (r_refresh_age >= (REFRESH_INTERVAL_CYCLES - 1));
  assign s_refresh_issue = (st_state == ST_IDLE) && s_refresh_due && !r_rsp_valid;
  assign s_req_accept = (st_state == ST_IDLE) && O_REQ_READY && I_REQ_VALID;
  assign s_req_done = r_req_seen_busy && !l_ctrl_busy &&
                      (r_req_is_write || r_req_seen_data_ready);
  assign s_refresh_done = r_req_seen_busy && !l_ctrl_busy;
  assign s_req_timeout = (r_timeout_cnt >= (RESP_TIMEOUT_CYCLES - 1));

  assign O_REQ_READY = (st_state == ST_IDLE) &&
                       O_INIT_DONE &&
                       !r_rsp_valid &&
                       !s_refresh_due;
  assign O_RSP_VALID = r_rsp_valid;
  assign O_RSP_RD_DATA = r_rsp_rd_data;
  assign O_RSP_STATUS = r_rsp_status;
  assign s_dbg_timeout_cnt = 16'(r_timeout_cnt);
  assign s_dbg_refresh_age = 16'(r_refresh_age);
  assign O_DBG_SUMMARY = {
    st_state,
    O_INIT_DONE,
    r_req_is_write,
    r_req_seen_busy,
    r_req_seen_data_ready,
    s_refresh_due,
    l_ctrl_busy,
    l_ctrl_data_ready,
    l_ctrl_rd,
    l_ctrl_wr,
    l_ctrl_refresh,
    r_rsp_valid,
    O_REQ_READY,
    r_req_addr[16:0]
  };
  assign O_DBG_DETAIL = r_last_ctrl_dout32;

  // Tracks request ownership, refresh cadence, and byte response completion.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state             <= ST_WAIT_INIT;
      r_req_is_write       <= 1'b0;
      r_req_addr           <= '0;
      r_req_wr_data        <= 8'h00;
      r_rsp_rd_data        <= 8'h00;
      r_rsp_status         <= 32'h0000_0000;
      r_rsp_valid          <= 1'b0;
      r_req_seen_busy      <= 1'b0;
      r_req_seen_data_ready<= 1'b0;
      r_last_ctrl_dout32   <= 32'h0000_0000;
      r_refresh_age        <= '0;
      r_timeout_cnt        <= '0;
      O_INIT_DONE          <= 1'b0;
    end else begin
      if (r_rsp_valid && I_RSP_READY) begin
        r_rsp_valid <= 1'b0;
      end

      if (!O_INIT_DONE) begin
        r_refresh_age <= '0;
      end else if (s_refresh_issue) begin
        r_refresh_age <= '0;
      end else if (r_refresh_age < REFRESH_DEADLINE_CYCLES) begin
        r_refresh_age <= r_refresh_age + 1'b1;
      end

      if (!O_INIT_DONE && !l_ctrl_busy) begin
        O_INIT_DONE <= 1'b1;
        st_state    <= ST_IDLE;
      end else begin
        case (st_state)
          ST_WAIT_INIT: begin
            r_req_seen_busy       <= 1'b0;
            r_req_seen_data_ready <= 1'b0;
            r_timeout_cnt         <= '0;
          end

          ST_IDLE: begin
            r_req_seen_busy       <= 1'b0;
            r_req_seen_data_ready <= 1'b0;
            r_timeout_cnt         <= '0;

            if (s_refresh_issue) begin
              st_state <= ST_REFRESH_WAIT;
            end else if (s_req_accept) begin
              r_req_is_write <= I_REQ_IS_WRITE;
              r_req_addr     <= I_REQ_ADDR;
              r_req_wr_data  <= I_REQ_WR_DATA;
              st_state       <= ST_REQ_WAIT;
            end
          end

          ST_REFRESH_WAIT: begin
            if (l_ctrl_busy) begin
              r_req_seen_busy <= 1'b1;
            end
            if (r_timeout_cnt < (RESP_TIMEOUT_CYCLES - 1)) begin
              r_timeout_cnt <= r_timeout_cnt + 1'b1;
            end

            if (s_refresh_done || s_req_timeout) begin
              if (s_req_timeout) begin
                r_rsp_status <= ERR_SDRAM_WR_TO;
                r_rsp_valid  <= 1'b1;
                st_state     <= ST_RESPOND;
              end else begin
                st_state <= ST_IDLE;
              end
            end
          end

          ST_REQ_WAIT: begin
            if (l_ctrl_busy) begin
              r_req_seen_busy <= 1'b1;
            end
            if (l_ctrl_data_ready) begin
              r_req_seen_data_ready <= 1'b1;
              r_rsp_rd_data         <= select_byte_from_word(l_ctrl_dout32, r_req_addr[1:0]);
              r_last_ctrl_dout32    <= l_ctrl_dout32;
            end
            if (r_timeout_cnt < (RESP_TIMEOUT_CYCLES - 1)) begin
              r_timeout_cnt <= r_timeout_cnt + 1'b1;
            end

            if (s_req_done) begin
              if (r_req_is_write) begin
                r_rsp_status <= 32'h0000_0000;
                r_rsp_valid  <= 1'b1;
                st_state     <= ST_RESPOND;
              end else begin
                st_state <= ST_READ_COMPLETE;
              end
            end else if (s_req_timeout) begin
              r_rsp_status <= r_req_is_write ? ERR_SDRAM_WR_TO : ERR_SDRAM_RD_TO;
              r_rsp_valid  <= 1'b1;
              st_state     <= ST_RESPOND;
            end
          end

          ST_READ_COMPLETE: begin
            r_rsp_status  <= 32'h0000_0000;
            r_rsp_valid   <= 1'b1;
            st_state      <= ST_RESPOND;
          end

          ST_RESPOND: begin
            if (!r_rsp_valid || I_RSP_READY) begin
              st_state <= ST_IDLE;
            end
          end

          default: begin
            st_state <= ST_WAIT_INIT;
          end
        endcase
      end
    end
  end

  // Generates one-cycle open-source controller command pulses.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      l_ctrl_rd      <= 1'b0;
      l_ctrl_wr      <= 1'b0;
      l_ctrl_refresh <= 1'b0;
      l_ctrl_addr    <= '0;
      l_ctrl_din     <= 8'h00;
    end else begin
      l_ctrl_rd      <= 1'b0;
      l_ctrl_wr      <= 1'b0;
      l_ctrl_refresh <= 1'b0;

      if (s_refresh_issue) begin
        l_ctrl_refresh <= 1'b1;
      end else if (s_req_accept) begin
        l_ctrl_addr <= I_REQ_ADDR;
        l_ctrl_din  <= I_REQ_WR_DATA;
        if (I_REQ_IS_WRITE) begin
          l_ctrl_wr <= 1'b1;
        end else begin
          l_ctrl_rd <= 1'b1;
        end
      end
    end
  end

  sdram #(
    .FREQ(FREQ_HZ),
    .CAS (SDRAM_CAS),
    .T_WR(SDRAM_T_WR),
    .T_MRD(SDRAM_T_MRD),
    .T_RP (SDRAM_T_RP),
    .T_RCD(SDRAM_T_RCD),
    .T_RC (SDRAM_T_RC)
  ) u_sdram (
    .clk        (I_CLK),
    .clk_sdram  (I_CLK_SDRAM),
    .resetn     (I_RST_N),
    .rd         (l_ctrl_rd),
    .wr         (l_ctrl_wr),
    .refresh    (l_ctrl_refresh),
    .addr       (l_ctrl_addr),
    .din        (l_ctrl_din),
    .dout       (l_ctrl_dout),
    .dout32     (l_ctrl_dout32),
    .data_ready (l_ctrl_data_ready),
    .busy       (l_ctrl_busy),
    .SDRAM_DQ   (IO_sdram_dq),
    .SDRAM_A    (O_sdram_addr),
    .SDRAM_BA   (O_sdram_ba),
    .SDRAM_nCS  (O_sdram_cs_n),
    .SDRAM_nWE  (O_sdram_wen_n),
    .SDRAM_nRAS (O_sdram_ras_n),
    .SDRAM_nCAS (O_sdram_cas_n),
    .SDRAM_CLK  (O_sdram_clk),
    .SDRAM_CKE  (O_sdram_cke),
    .SDRAM_DQM  (O_sdram_dqm)
  );

endmodule
