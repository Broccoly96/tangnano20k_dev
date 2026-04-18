`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_bridge_ctrl.sv
// Description  : SDRAM UART host controller on the native word request
//                interface.
//                - Parses ASCII R/W commands.
//                - Executes one single-word access at a time.
//                - Rejects BR/BW as unsupported commands.
//////////////////////////////////////////////////////////////////////////////////

module sdram_uart_bridge_ctrl (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_ENABLE,
  input  logic        I_CLI_RX_VALID,
  input  logic [7:0]  I_CLI_RX_DATA,
  output logic        O_RAW_RX_BYPASS,
  output logic        O_RAW_TX_MODE,
  output logic        O_RAW_TX_VALID,
  output logic [7:0]  O_RAW_TX_DATA,
  input  logic        I_RAW_TX_READY,
  input  logic        I_INIT_DONE,

  output logic        O_REQ_VALID,
  input  logic        I_REQ_READY,
  output logic        O_REQ_IS_WRITE,
  output logic [20:0] O_REQ_ADDR,
  output logic [31:0] O_REQ_WR_DATA,
  output logic [3:0]  O_REQ_WR_BE,

  input  logic        I_RSP_VALID,
  output logic        O_RSP_READY,
  input  logic [31:0] I_RSP_RD_DATA,
  input  logic [31:0] I_RSP_STATUS,

  output logic        O_EVT_VALID,
  output logic [7:0]  O_EVT_ID,
  output logic [31:0] O_EVT_ARG0,
  output logic [31:0] O_EVT_ARG1,
  output logic [31:0] O_EVT_ARG2,
  input  logic        I_EVT_READY,
  output logic        O_CMD_BUSY
);

  import sdram_uart_proto_pkg::*;

  localparam int unsigned EVT_FIFO_DEPTH = 8;
  localparam int unsigned EVT_FIFO_PTR_W = $clog2(EVT_FIFO_DEPTH);
  localparam int unsigned EVT_FIFO_CNT_W = $clog2(EVT_FIFO_DEPTH + 1);

  logic        s_ascii_cmd_valid;
  logic [1:0]  s_ascii_cmd_op;
  logic        s_ascii_cmd_bulk_is_read;
  logic [20:0] s_ascii_cmd_addr;
  logic [31:0] s_ascii_cmd_data;
  logic [20:0] s_ascii_cmd_words;
  logic        s_ascii_err_valid;
  logic [31:0] s_ascii_err_code;
  logic [31:0] s_ascii_err_detail;

  logic        r_ascii_cmd_ready;
  logic        r_req_valid;
  logic        r_req_is_write;
  logic [20:0] r_req_addr;
  logic [31:0] r_req_data;
  logic        r_req_inflight;
  logic [103:0] r_evt_fifo_mem [0:EVT_FIFO_DEPTH-1];
  logic [EVT_FIFO_PTR_W-1:0] r_evt_wr_ptr;
  logic [EVT_FIFO_PTR_W-1:0] r_evt_rd_ptr;
  logic [EVT_FIFO_CNT_W-1:0] r_evt_count;
  logic        r_evt_push_valid;
  logic [7:0]  r_evt_push_id;
  logic [31:0] r_evt_push_arg0;
  logic [31:0] r_evt_push_arg1;
  logic [31:0] r_evt_push_arg2;
  logic        s_evt_fifo_full;
  logic        s_evt_fifo_empty;
  logic        s_evt_push;
  logic        s_evt_pop;

  task automatic push_event(
    input logic [7:0]  evt_id,
    input logic [31:0] arg0,
    input logic [31:0] arg1,
    input logic [31:0] arg2
  );
    begin
      if (!s_evt_fifo_full) begin
        r_evt_push_valid <= 1'b1;
        r_evt_push_id    <= evt_id;
        r_evt_push_arg0  <= arg0;
        r_evt_push_arg1  <= arg1;
        r_evt_push_arg2  <= arg2;
      end
    end
  endtask

  assign O_RAW_RX_BYPASS = 1'b0;
  assign O_RAW_TX_MODE   = 1'b0;
  assign O_RAW_TX_VALID  = 1'b0;
  assign O_RAW_TX_DATA   = 8'h00;

  assign O_REQ_VALID    = r_req_valid;
  assign O_REQ_IS_WRITE = r_req_is_write;
  assign O_REQ_ADDR     = r_req_addr;
  assign O_REQ_WR_DATA  = r_req_data;
  assign O_REQ_WR_BE    = 4'hF;
  assign O_RSP_READY    = 1'b1;
  assign O_CMD_BUSY     = r_req_valid || r_req_inflight;

  assign s_evt_fifo_full  = (r_evt_count == EVT_FIFO_DEPTH);
  assign s_evt_fifo_empty = (r_evt_count == 0);
  assign s_evt_push       = r_evt_push_valid && !s_evt_fifo_full;
  assign s_evt_pop        = O_EVT_VALID && I_EVT_READY;

  assign O_EVT_VALID = !s_evt_fifo_empty;
  assign O_EVT_ID    = s_evt_fifo_empty ? 8'h00 : r_evt_fifo_mem[r_evt_rd_ptr][103:96];
  assign O_EVT_ARG0  = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][95:64];
  assign O_EVT_ARG1  = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][63:32];
  assign O_EVT_ARG2  = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][31:0];

  sdram_uart_ascii_ctrl u_sdram_uart_ascii_ctrl (
    .I_CLK             (I_CLK),
    .I_RST_N           (I_RST_N),
    .I_ENABLE          (I_ENABLE),
    .I_RX_VALID        (I_CLI_RX_VALID),
    .I_RX_DATA         (I_CLI_RX_DATA),
    .I_CMD_READY       (r_ascii_cmd_ready),
    .O_CMD_VALID       (s_ascii_cmd_valid),
    .O_CMD_OP          (s_ascii_cmd_op),
    .O_CMD_BULK_IS_READ(s_ascii_cmd_bulk_is_read),
    .O_CMD_ADDR        (s_ascii_cmd_addr),
    .O_CMD_DATA        (s_ascii_cmd_data),
    .O_CMD_WORDS       (s_ascii_cmd_words),
    .O_ERR_VALID       (s_ascii_err_valid),
    .O_ERR_CODE        (s_ascii_err_code),
    .O_ERR_DETAIL      (s_ascii_err_detail)
  );

  // Owns one outstanding host request and preserves command/result events.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_ascii_cmd_ready <= 1'b0;
      r_req_valid       <= 1'b0;
      r_req_is_write    <= 1'b0;
      r_req_addr        <= '0;
      r_req_data        <= 32'h0000_0000;
      r_req_inflight    <= 1'b0;
      r_evt_push_valid  <= 1'b0;
      r_evt_push_id     <= 8'h00;
      r_evt_push_arg0   <= 32'h0;
      r_evt_push_arg1   <= 32'h0;
      r_evt_push_arg2   <= 32'h0;
    end else begin
      r_ascii_cmd_ready <= 1'b0;
      r_evt_push_valid  <= 1'b0;

      if (r_req_valid && I_REQ_READY) begin
        r_req_valid    <= 1'b0;
        r_req_inflight <= 1'b1;
      end

      if (s_ascii_err_valid) begin
        push_event(EVT_CMD_ERR, s_ascii_err_code, s_ascii_err_detail, 32'h0000_0000);
      end

      if (s_ascii_cmd_valid && !r_ascii_cmd_ready) begin
        r_ascii_cmd_ready <= 1'b1;

        if (!I_ENABLE || !I_INIT_DONE || r_req_valid || r_req_inflight) begin
          push_event(EVT_CMD_ERR, ERR_BUSY, {11'h000, s_ascii_cmd_addr}, 32'h0000_0000);
        end else if (s_ascii_cmd_op == ASCII_OP_BULK) begin
          push_event(
            EVT_CMD_ERR,
            ERR_UNSUPPORTED,
            {11'h000, s_ascii_cmd_addr},
            {11'h000, s_ascii_cmd_words}
          );
        end else if ((s_ascii_cmd_op == ASCII_OP_READ) || (s_ascii_cmd_op == ASCII_OP_WRITE)) begin
          r_req_valid    <= 1'b1;
          r_req_is_write <= (s_ascii_cmd_op == ASCII_OP_WRITE);
          r_req_addr     <= s_ascii_cmd_addr;
          r_req_data     <= s_ascii_cmd_data;
        end else begin
          push_event(EVT_CMD_ERR, ERR_BAD_ASCII_CMD, 32'h0000_0000, 32'h0000_0000);
        end
      end

      if (I_RSP_VALID && r_req_inflight) begin
        r_req_inflight <= 1'b0;
        if (I_RSP_STATUS == 32'h0000_0000) begin
          push_event(
            r_req_is_write ? EVT_WRITE_ACK : EVT_READ_RSP,
            {11'h000, r_req_addr},
            r_req_is_write ? r_req_data : I_RSP_RD_DATA,
            32'h0000_0000
          );
        end else begin
          push_event(EVT_CMD_ERR, I_RSP_STATUS, {11'h000, r_req_addr}, 32'h0000_0000);
        end
      end
    end
  end

  // Event FIFO shared with uart_log_cli.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_evt_wr_ptr <= '0;
      r_evt_rd_ptr <= '0;
      r_evt_count  <= '0;
      for (int idx = 0; idx < EVT_FIFO_DEPTH; idx++) begin
        r_evt_fifo_mem[idx] <= '0;
      end
    end else begin
      if (s_evt_push) begin
        r_evt_fifo_mem[r_evt_wr_ptr] <= {
          r_evt_push_id,
          r_evt_push_arg0,
          r_evt_push_arg1,
          r_evt_push_arg2
        };
        r_evt_wr_ptr <= (r_evt_wr_ptr == EVT_FIFO_DEPTH - 1) ? '0 : (r_evt_wr_ptr + 1'b1);
      end

      if (s_evt_pop) begin
        r_evt_rd_ptr <= (r_evt_rd_ptr == EVT_FIFO_DEPTH - 1) ? '0 : (r_evt_rd_ptr + 1'b1);
      end

      case ({s_evt_push, s_evt_pop})
        2'b10: r_evt_count <= r_evt_count + 1'b1;
        2'b01: r_evt_count <= r_evt_count - 1'b1;
        default: r_evt_count <= r_evt_count;
      endcase
    end
  end

endmodule
