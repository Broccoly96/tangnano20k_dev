`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_access_engine.sv
// Description  : Native HS SDRAM access engine for UART host commands.
//                - Single R/W commands keep the legacy one-event response.
//                - BRT/BWT commands run an RTL-generated burst test.
//                - Burst writes generate word-index data inside RTL.
//                - Burst reads capture all returned words before emitting UART
//                  log events, so UART backpressure cannot disturb SDRAM beats.
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_access_engine #(
  parameter int unsigned RESP_TIMEOUT_CYCLES = 1024,
  parameter int unsigned HOST_BURST_WORDS = 1,
  parameter int unsigned READ_DATA_LATENCY_CYCLES =
    sdram_hs_cmd_pkg::SDRAM_HS_READ_DATA_LATENCY_CYCLES
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_REQ_VALID,
  output logic        O_REQ_READY,
  input  logic        I_REQ_IS_WRITE,
  input  logic        I_REQ_IS_BURST_TEST,
  input  logic        I_REQ_IS_RAW_BULK,
  input  logic [20:0] I_REQ_ADDR,
  input  logic [31:0] I_REQ_DATA,
  input  logic [8:0]  I_REQ_WORDS,
  input  logic [(sdram_uart_proto_pkg::MAX_BULK_PAYLOAD_WORDS*32)-1:0] I_REQ_RAW_WR_DATA,
  input  logic        I_SDRC_INIT_DONE,
  input  logic        I_SDRC_READY,
  input  logic        I_SDRC_CMD_ACK,
  input  logic [31:0] I_SDRC_RD_DATA,
  output logic        O_SDRC_CMD_EN,
  output logic [2:0]  O_SDRC_CMD,
  output logic        O_SDRC_PRECHARGE_CTRL,
  output logic [20:0] O_SDRC_ADDR,
  output logic [7:0]  O_SDRC_DATA_LEN,
  output logic [3:0]  O_SDRC_DQM,
  output logic [31:0] O_SDRC_WR_DATA,
  output logic        O_SDRC_PAIR_ACTIVE,
  output logic        O_READ_SAMPLE_VALID,
  output logic        O_EVT_VALID,
  input  logic        I_EVT_READY,
  output logic [7:0]  O_EVT_ID,
  output logic [31:0] O_EVT_ARG0,
  output logic [31:0] O_EVT_ARG1,
  output logic [31:0] O_EVT_ARG2,
  output logic        O_RAW_DONE,
  output logic        O_RAW_ERR_VALID,
  output logic [31:0] O_RAW_ERR_CODE,
  output logic [(sdram_uart_proto_pkg::MAX_BULK_PAYLOAD_WORDS*32)-1:0] O_RAW_RD_DATA,
  output logic        O_BUSY,
  output logic [31:0] O_DBG_HOST_SUMMARY,
  output logic [31:0] O_DBG_HOST_DETAIL,
  output logic [(HOST_BURST_WORDS*32)-1:0] O_DBG_HOST_RD_BEATS
);

  import sdram_hs_cmd_pkg::*;
  import sdram_uart_proto_pkg::*;

  localparam int unsigned TIMEOUT_W = (RESP_TIMEOUT_CYCLES <= 1) ? 1 :
                                      $clog2(RESP_TIMEOUT_CYCLES + 1);
  localparam int unsigned LAT_CNT_W = (READ_DATA_LATENCY_CYCLES <= 1) ? 1 :
                                      $clog2(READ_DATA_LATENCY_CYCLES + 1);
  localparam logic [LAT_CNT_W-1:0] READ_LATENCY_COUNTER_INIT =
    (READ_DATA_LATENCY_CYCLES <= 1) ? '0 :
      (READ_DATA_LATENCY_CYCLES - 1);

`ifndef SYNTHESIS
  initial begin
    if ((HOST_BURST_WORDS < 1) || (HOST_BURST_WORDS > 256)) begin
      $fatal(1, "HOST_BURST_WORDS must be in range 1..256, got %0d", HOST_BURST_WORDS);
    end
  end
`endif

  // FSM flow:
  // IDLE accepts one host request.
  // ACTIVE_REQ/ACTIVE_ACK opens the selected SDRAM row.
  // WRITE_REQ/WRITE_ACK streams write data and waits for command completion.
  // READ_REQ/READ_SAMPLE captures read beats after the configured latency.
  // PREP/SEND_BURST_DATA drains captured read beats as two-word UART log
  // events after the RAM read data has been registered.
  // RESPOND waits until the final event has been accepted.
  typedef enum logic [3:0] {
    IDLE,
    ACTIVE_REQ,
    ACTIVE_ACK,
    WRITE_REQ,
    WRITE_ACK,
    READ_REQ,
    READ_SAMPLE,
    PREP_BURST_DATA,
    SEND_BURST_DATA,
    RESPOND
  } st_state_e;

  st_state_e st_state;

  logic [20:0] r_req_addr;
  logic [31:0] r_req_data;
  logic [8:0]  r_req_words;
  logic        r_req_is_write;
  logic        r_req_is_burst_test;
  logic        r_req_is_raw_bulk;
  logic [(MAX_BULK_PAYLOAD_WORDS*32)-1:0] r_req_raw_wr_data;
  logic [8:0]  r_write_word_idx;
  logic [8:0]  r_read_word_idx;
  logic [7:0]  r_send_packet_id;
  logic [7:0]  r_packet_count;
  logic [TIMEOUT_W-1:0] r_timeout_cnt;
  logic [LAT_CNT_W-1:0] r_lat_cnt;
  logic        r_evt_valid;
  logic [7:0]  r_evt_id;
  logic [31:0] r_evt_arg0;
  logic [31:0] r_evt_arg1;
  logic [31:0] r_evt_arg2;
  logic        r_raw_done;
  logic        r_raw_err_valid;
  logic [31:0] r_raw_err_code;
  logic [(MAX_BULK_PAYLOAD_WORDS*32)-1:0] r_raw_rd_data;
  logic [31:0] r_dbg_host_summary;
  logic [31:0] r_dbg_host_detail;
  logic [31:0] r_read_capture_lo [0:127];
  logic [31:0] r_read_capture_hi [0:127];
  logic [31:0] r_send_data0;
  logic [31:0] r_send_data1;

  logic [8:0] s_in_words;
  logic [8:0] s_in_words_m1;
  logic [7:0] s_in_data_len;
  logic       s_in_page_cross;
  logic [8:0] s_req_words_m1;
  logic [8:0] s_send_word_idx;
  logic       s_send_one_word;

  assign s_in_words      = (I_REQ_IS_BURST_TEST || I_REQ_IS_RAW_BULK) ? I_REQ_WORDS : 9'd1;
  assign s_in_words_m1   = s_in_words - 9'd1;
  assign s_in_data_len   = s_in_words_m1[7:0];
  assign s_in_page_cross = sdram_hs_burst_crosses_page(I_REQ_ADDR, s_in_data_len);
  assign s_req_words_m1  = r_req_words - 9'd1;
  assign s_send_word_idx = {1'b0, r_send_packet_id} << 1;
  assign s_send_one_word = (s_send_word_idx + 9'd1) >= r_req_words;

  assign O_REQ_READY = (st_state == IDLE) && !r_evt_valid && !r_raw_done && !r_raw_err_valid;
  assign O_SDRC_ADDR = r_req_addr;
  assign O_SDRC_DATA_LEN = s_req_words_m1[7:0];
  assign O_SDRC_DQM = 4'h0;
  assign O_SDRC_PRECHARGE_CTRL = (st_state == WRITE_REQ) || (st_state == READ_REQ);
  assign O_SDRC_PAIR_ACTIVE = !(st_state inside {IDLE, RESPOND, PREP_BURST_DATA,
                                                 SEND_BURST_DATA});
  assign O_READ_SAMPLE_VALID = (st_state == READ_SAMPLE) && (r_lat_cnt == 0);
  assign O_EVT_VALID = r_evt_valid;
  assign O_EVT_ID = r_evt_id;
  assign O_EVT_ARG0 = r_evt_arg0;
  assign O_EVT_ARG1 = r_evt_arg1;
  assign O_EVT_ARG2 = r_evt_arg2;
  assign O_RAW_DONE = r_raw_done;
  assign O_RAW_ERR_VALID = r_raw_err_valid;
  assign O_RAW_ERR_CODE = r_raw_err_code;
  assign O_RAW_RD_DATA = r_raw_rd_data;
  assign O_BUSY = (st_state != IDLE) || r_evt_valid || r_raw_done || r_raw_err_valid;
  assign O_DBG_HOST_SUMMARY = r_dbg_host_summary;
  assign O_DBG_HOST_DETAIL = r_dbg_host_detail;

  always_comb begin
    O_SDRC_WR_DATA = r_req_data;
    if (r_req_is_raw_bulk && r_req_is_write) begin
      O_SDRC_WR_DATA = r_req_raw_wr_data[r_write_word_idx*32 +: 32];
    end else if (r_req_is_burst_test && r_req_is_write) begin
      O_SDRC_WR_DATA = {23'h0, r_write_word_idx};
    end
  end

  always_comb begin
    O_DBG_HOST_RD_BEATS = '0;
    if (HOST_BURST_WORDS > 0) begin
      O_DBG_HOST_RD_BEATS[31:0] = r_send_data0;
    end
  end

  always_comb begin
    O_SDRC_CMD_EN = 1'b0;
    O_SDRC_CMD = SDRAM_HS_CMD_NOP;
    unique case (st_state)
      ACTIVE_REQ: begin
        O_SDRC_CMD_EN = I_SDRC_READY;
        O_SDRC_CMD = SDRAM_HS_CMD_ACTIVE;
      end
      WRITE_REQ: begin
        O_SDRC_CMD_EN = 1'b1;
        O_SDRC_CMD = SDRAM_HS_CMD_WRITE;
      end
      READ_REQ: begin
        O_SDRC_CMD_EN = 1'b1;
        O_SDRC_CMD = SDRAM_HS_CMD_READ;
      end
      default: begin
        O_SDRC_CMD_EN = 1'b0;
        O_SDRC_CMD = SDRAM_HS_CMD_NOP;
      end
    endcase
  end

  task automatic set_event(
    input logic [7:0]  evt_id,
    input logic [31:0] arg0,
    input logic [31:0] arg1,
    input logic [31:0] arg2
  );
    begin
      r_evt_valid <= 1'b1;
      r_evt_id    <= evt_id;
      r_evt_arg0  <= arg0;
      r_evt_arg1  <= arg1;
      r_evt_arg2  <= arg2;
    end
  endtask

  task automatic set_debug(
    input logic [7:0]  evt_id,
    input logic [31:0] detail
  );
    begin
      r_dbg_host_summary <= {
        8'h58,
        r_req_is_burst_test,
        r_req_is_write,
        I_SDRC_INIT_DONE,
        I_SDRC_READY,
        I_SDRC_CMD_ACK,
        O_READ_SAMPLE_VALID,
        st_state,
        O_SDRC_CMD,
        evt_id
      };
      r_dbg_host_detail <= detail;
    end
  endtask

  task automatic set_single_event(
    input logic [31:0] data,
    input logic [31:0] status
  );
    begin
      set_event(
        r_req_is_write ? EVT_WRITE_ACK : EVT_READ_RSP,
        {11'h000, r_req_addr},
        data,
        status
      );
      set_debug(r_req_is_write ? EVT_WRITE_ACK : EVT_READ_RSP, {11'h0, r_req_addr});
    end
  endtask

  task automatic set_burst_error(
    input logic [31:0] reason
  );
    begin
      set_event(
        EVT_BULK_ERR,
        reason,
        {11'h000, r_req_addr},
        {r_req_is_write ? 1'b0 : 1'b1, 15'h0, 7'h0, r_req_words}
      );
      set_debug(EVT_BULK_ERR, reason);
    end
  endtask

  task automatic set_raw_error(
    input logic [31:0] reason
  );
    begin
      r_raw_err_valid <= 1'b1;
      r_raw_err_code  <= reason;
      set_debug(EVT_BULK_ERR, reason);
    end
  endtask

  // Runs one native HS transaction and serializes completion events.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state <= IDLE;
      r_req_addr <= '0;
      r_req_data <= '0;
      r_req_words <= 9'd1;
      r_req_is_write <= 1'b0;
      r_req_is_burst_test <= 1'b0;
      r_req_is_raw_bulk <= 1'b0;
      r_req_raw_wr_data <= '0;
      r_write_word_idx <= '0;
      r_read_word_idx <= '0;
      r_send_packet_id <= '0;
      r_packet_count <= '0;
      r_timeout_cnt <= '0;
      r_lat_cnt <= '0;
      r_evt_valid <= 1'b0;
      r_evt_id <= 8'h00;
      r_evt_arg0 <= 32'h0;
      r_evt_arg1 <= 32'h0;
      r_evt_arg2 <= 32'h0;
      r_raw_done <= 1'b0;
      r_raw_err_valid <= 1'b0;
      r_raw_err_code <= 32'h0;
      r_raw_rd_data <= '0;
      r_dbg_host_summary <= '0;
      r_dbg_host_detail <= '0;
      r_send_data0 <= 32'h0;
      r_send_data1 <= 32'h0;
    end else begin
      r_raw_done <= 1'b0;
      r_raw_err_valid <= 1'b0;

      if (r_evt_valid && I_EVT_READY) begin
        r_evt_valid <= 1'b0;
      end

      if (st_state != IDLE && st_state != RESPOND &&
          st_state != PREP_BURST_DATA &&
          st_state != SEND_BURST_DATA &&
          r_timeout_cnt != RESP_TIMEOUT_CYCLES) begin
        r_timeout_cnt <= r_timeout_cnt + 1'b1;
      end

      case (st_state)
        IDLE: begin
          r_timeout_cnt <= '0;
          r_lat_cnt <= '0;
          r_send_packet_id <= '0;
          if (I_REQ_VALID && O_REQ_READY) begin
            r_req_addr <= I_REQ_ADDR;
            r_req_data <= I_REQ_DATA;
            r_req_words <= s_in_words;
            r_req_is_write <= I_REQ_IS_WRITE;
            r_req_is_burst_test <= I_REQ_IS_BURST_TEST;
            r_req_is_raw_bulk <= I_REQ_IS_RAW_BULK;
            r_req_raw_wr_data <= I_REQ_RAW_WR_DATA;
            r_write_word_idx <= '0;
            r_read_word_idx <= '0;
            r_packet_count <= '0;
            r_raw_rd_data <= '0;
            if (!I_SDRC_INIT_DONE) begin
              if (I_REQ_IS_RAW_BULK) begin
                set_raw_error(I_REQ_IS_WRITE ? ERR_SDRAM_WR_TO : ERR_SDRAM_RD_TO);
              end else if (I_REQ_IS_BURST_TEST) begin
                set_event(
                  EVT_BULK_ERR,
                  I_REQ_IS_WRITE ? ERR_SDRAM_WR_TO : ERR_SDRAM_RD_TO,
                  {11'h000, I_REQ_ADDR},
                  {I_REQ_IS_WRITE ? 1'b0 : 1'b1, 15'h0, 7'h0, s_in_words}
                );
                set_debug(EVT_BULK_ERR, I_REQ_IS_WRITE ? ERR_SDRAM_WR_TO : ERR_SDRAM_RD_TO);
              end else begin
                set_event(
                  I_REQ_IS_WRITE ? EVT_WRITE_ACK : EVT_READ_RSP,
                  {11'h000, I_REQ_ADDR},
                  I_REQ_DATA,
                  I_REQ_IS_WRITE ? ERR_SDRAM_WR_TO : ERR_SDRAM_RD_TO
                );
                set_debug(I_REQ_IS_WRITE ? EVT_WRITE_ACK : EVT_READ_RSP, {11'h000, I_REQ_ADDR});
              end
              st_state <= RESPOND;
            end else if (I_REQ_IS_RAW_BULK && ((I_REQ_WORDS == 9'd0) ||
                         (I_REQ_WORDS > MAX_BULK_PAYLOAD_WORDS))) begin
              set_raw_error(ERR_WORD_COUNT);
              st_state <= RESPOND;
            end else if (I_REQ_IS_BURST_TEST && ((I_REQ_WORDS == 9'd0) ||
                         (I_REQ_WORDS > 9'd256))) begin
              set_event(
                EVT_BULK_ERR,
                ERR_WORD_COUNT,
                {11'h000, I_REQ_ADDR},
                {I_REQ_IS_WRITE ? 1'b0 : 1'b1, 15'h0, 7'h0, I_REQ_WORDS}
              );
              set_debug(EVT_BULK_ERR, ERR_WORD_COUNT);
              st_state <= RESPOND;
            end else if (s_in_page_cross) begin
              if (I_REQ_IS_RAW_BULK) begin
                set_raw_error(ERR_ADDR_RANGE);
              end else if (I_REQ_IS_BURST_TEST) begin
                set_event(
                  EVT_BULK_ERR,
                  ERR_ADDR_RANGE,
                  {11'h000, I_REQ_ADDR},
                  {I_REQ_IS_WRITE ? 1'b0 : 1'b1, 15'h0, 7'h0, s_in_words}
                );
                set_debug(EVT_BULK_ERR, ERR_ADDR_RANGE);
              end else begin
                set_event(
                  I_REQ_IS_WRITE ? EVT_WRITE_ACK : EVT_READ_RSP,
                  {11'h000, I_REQ_ADDR},
                  I_REQ_DATA,
                  ERR_ADDR_RANGE
                );
                set_debug(I_REQ_IS_WRITE ? EVT_WRITE_ACK : EVT_READ_RSP, {11'h000, I_REQ_ADDR});
              end
              st_state <= RESPOND;
            end else begin
              st_state <= ACTIVE_REQ;
            end
          end
        end

        ACTIVE_REQ: begin
          if (I_SDRC_READY) begin
            st_state <= ACTIVE_ACK;
            r_timeout_cnt <= '0;
          end
        end

        ACTIVE_ACK: begin
          if (I_SDRC_CMD_ACK) begin
            st_state <= r_req_is_write ? WRITE_REQ : READ_REQ;
            r_timeout_cnt <= '0;
          end else if (r_timeout_cnt >= RESP_TIMEOUT_CYCLES - 1) begin
            if (r_req_is_raw_bulk) begin
              set_raw_error(r_req_is_write ? ERR_SDRAM_WR_TO : ERR_SDRAM_RD_TO);
            end else if (r_req_is_burst_test) begin
              set_burst_error(r_req_is_write ? ERR_SDRAM_WR_TO : ERR_SDRAM_RD_TO);
            end else begin
              set_single_event(r_req_data, r_req_is_write ? ERR_SDRAM_WR_TO : ERR_SDRAM_RD_TO);
            end
            st_state <= RESPOND;
          end
        end

        WRITE_REQ: begin
          st_state <= WRITE_ACK;
          r_timeout_cnt <= '0;
          r_write_word_idx <= (r_req_words == 9'd1) ? 9'd0 : 9'd1;
        end

        WRITE_ACK: begin
          if (r_write_word_idx < s_req_words_m1) begin
            r_write_word_idx <= r_write_word_idx + 1'b1;
          end
          if (I_SDRC_CMD_ACK) begin
            if (r_req_is_raw_bulk) begin
              r_raw_done <= 1'b1;
              set_debug(EVT_BULK_PROG, {11'h000, r_req_addr});
            end else if (r_req_is_burst_test) begin
              set_event(
                EVT_BURST_DONE,
                {11'h000, r_req_addr},
                {23'h0, r_req_words},
                {16'h0, r_packet_count}
              );
              set_debug(EVT_BURST_DONE, {11'h000, r_req_addr});
            end else begin
              set_single_event(r_req_data, 32'h0000_0000);
            end
            st_state <= RESPOND;
          end else if (r_timeout_cnt >= RESP_TIMEOUT_CYCLES - 1) begin
            if (r_req_is_raw_bulk) begin
              set_raw_error(ERR_SDRAM_WR_TO);
            end else if (r_req_is_burst_test) begin
              set_burst_error(ERR_SDRAM_WR_TO);
            end else begin
              set_single_event(r_req_data, ERR_SDRAM_WR_TO);
            end
            st_state <= RESPOND;
          end
        end

        READ_REQ: begin
          st_state <= READ_SAMPLE;
          r_read_word_idx <= '0;
          r_lat_cnt <= READ_LATENCY_COUNTER_INIT;
          r_timeout_cnt <= '0;
        end

        READ_SAMPLE: begin
          if (r_lat_cnt != 0) begin
            r_lat_cnt <= r_lat_cnt - 1'b1;
          end else begin
            if (r_read_word_idx < MAX_BULK_PAYLOAD_WORDS) begin
              r_raw_rd_data[r_read_word_idx*32 +: 32] <= I_SDRC_RD_DATA;
            end
            if (r_read_word_idx[0]) begin
              r_read_capture_hi[r_read_word_idx[8:1]] <= I_SDRC_RD_DATA;
            end else begin
              r_read_capture_lo[r_read_word_idx[8:1]] <= I_SDRC_RD_DATA;
            end
            if (r_read_word_idx >= s_req_words_m1) begin
              if (r_req_is_raw_bulk) begin
                r_raw_done <= 1'b1;
                set_debug(EVT_BULK_DONE, {11'h000, r_req_addr});
                st_state <= RESPOND;
              end else if (r_req_is_burst_test) begin
                r_packet_count <= r_req_words[8:1] + {7'h0, r_req_words[0]};
                r_send_packet_id <= '0;
                st_state <= PREP_BURST_DATA;
              end else begin
                set_single_event(I_SDRC_RD_DATA, 32'h0000_0000);
                st_state <= RESPOND;
              end
            end else begin
              r_read_word_idx <= r_read_word_idx + 1'b1;
            end
          end
        end

        PREP_BURST_DATA: begin
          if (!r_evt_valid) begin
            if (r_send_packet_id < r_packet_count) begin
              r_send_data0 <= r_read_capture_lo[r_send_packet_id];
              r_send_data1 <= r_read_capture_hi[r_send_packet_id];
              st_state <= SEND_BURST_DATA;
            end else begin
              set_event(
                EVT_BURST_DONE,
                {11'h000, r_req_addr},
                {23'h0, r_req_words},
                {1'b1, 15'h0, 8'h00, r_packet_count}
              );
              set_debug(EVT_BURST_DONE, {11'h000, r_req_addr});
              st_state <= RESPOND;
            end
          end
        end

        SEND_BURST_DATA: begin
          if (!r_evt_valid) begin
            set_event(
              EVT_BURST_DATA,
              {
                r_send_packet_id,
                r_packet_count,
                s_send_word_idx[7:0],
                s_send_one_word ? 8'd1 : 8'd2
              },
              r_send_data0,
              s_send_one_word ? 32'h0000_0000 : r_send_data1
            );
            set_debug(EVT_BURST_DATA, {23'h0, s_send_word_idx});
            r_send_packet_id <= r_send_packet_id + 1'b1;
            st_state <= PREP_BURST_DATA;
          end
        end

        RESPOND: begin
          if (!r_evt_valid || (r_evt_valid && I_EVT_READY)) begin
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
