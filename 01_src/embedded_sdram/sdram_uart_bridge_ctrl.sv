`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_bridge_ctrl.sv
// Description  : SDRAM UART host controller, single-access-only edition.
//                - Parses ASCII R/W commands.
//                - Executes one single-word SDRAM access at a time.
//                - Rejects BR/BW with CMD_ERR/ERR_UNSUPPORTED.
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
  output logic        O_EVT_VALID,
  output logic [7:0]  O_EVT_ID,
  output logic [31:0] O_EVT_ARG0,
  output logic [31:0] O_EVT_ARG1,
  output logic [31:0] O_EVT_ARG2,
  input  logic        I_EVT_READY,
  output logic        O_CMD_BUSY
);

  import sdram_uart_proto_pkg::*;

  `define SDRAM_BRIDGE_LOG_DEBUG(MSG)
  `define SDRAM_BRIDGE_LOG_TRACE(MSG)
// synthesis translate_off
`undef SDRAM_BRIDGE_LOG_DEBUG
`undef SDRAM_BRIDGE_LOG_TRACE
  import tb_log_pkg::*;
  `define SDRAM_BRIDGE_LOG_DEBUG(MSG) tb_log_pkg::log_debug("SDRAM UART BRIDGE", MSG)
  `define SDRAM_BRIDGE_LOG_TRACE(MSG) tb_log_pkg::log_trace("SDRAM UART BRIDGE", MSG)
// synthesis translate_on

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
  logic        r_single_inflight;

  logic        s_req_ready;
  logic        s_access_rsp_valid;
  logic        s_access_rsp_is_write;
  logic [20:0] s_access_rsp_addr;
  logic [31:0] s_access_rsp_data;
  logic [31:0] s_access_rsp_status;
  logic [103:0] r_evt_fifo_mem [0:EVT_FIFO_DEPTH-1];
  logic [EVT_FIFO_PTR_W-1:0] r_evt_wr_ptr;
  logic [EVT_FIFO_PTR_W-1:0] r_evt_rd_ptr;
  logic [EVT_FIFO_CNT_W-1:0] r_evt_count;
  logic        s_evt_fifo_full;
  logic        s_evt_fifo_empty;
  logic        r_evt_push_valid;
  logic [7:0]  r_evt_push_id;
  logic [31:0] r_evt_push_arg0;
  logic [31:0] r_evt_push_arg1;
  logic [31:0] r_evt_push_arg2;
  logic        s_evt_push;
  logic        s_evt_pop;

  assign O_RAW_RX_BYPASS = 1'b0;
  assign O_RAW_TX_MODE   = 1'b0;
  assign O_RAW_TX_VALID  = 1'b0;
  assign O_RAW_TX_DATA   = 8'h00;
  assign O_CMD_BUSY      = r_req_valid || r_single_inflight;

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

  sdram_uart_access_engine u_sdram_uart_access_engine (
    .I_CLK            (I_CLK),
    .I_RST_N          (I_RST_N),
    .I_REQ_VALID      (r_req_valid),
    .O_REQ_READY      (s_req_ready),
    .I_REQ_IS_WRITE   (r_req_is_write),
    .I_REQ_ADDR       (r_req_addr),
    .I_REQ_DATA       (r_req_data),
    .I_SDRC_INIT_DONE (I_SDRC_INIT_DONE),
    .I_SDRC_BUSY_N    (I_SDRC_BUSY_N),
    .I_SDRC_WRD_ACK   (I_SDRC_WRD_ACK),
    .I_SDRC_RD_VALID  (I_SDRC_RD_VALID),
    .I_SDRC_RD_DATA   (I_SDRC_RD_DATA),
    .O_SDRC_WR_N      (O_SDRC_WR_N),
    .O_SDRC_RD_N      (O_SDRC_RD_N),
    .O_SDRC_ADDR      (O_SDRC_ADDR),
    .O_SDRC_DATA_LEN  (O_SDRC_DATA_LEN),
    .O_SDRC_DQM       (O_SDRC_DQM),
    .O_SDRC_WR_DATA   (O_SDRC_WR_DATA),
    .O_RSP_VALID      (s_access_rsp_valid),
    .I_RSP_READY      (1'b1),
    .O_RSP_IS_WRITE   (s_access_rsp_is_write),
    .O_RSP_ADDR       (s_access_rsp_addr),
    .O_RSP_DATA       (s_access_rsp_data),
    .O_RSP_STATUS     (s_access_rsp_status)
  );

  task automatic push_event(
    input logic [7:0] evt_id,
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
        `SDRAM_BRIDGE_LOG_DEBUG(
          $sformatf(
            "queue_event id=0x%02h arg0=0x%08h arg1=0x%08h arg2=0x%08h depth=%0d",
            evt_id,
            arg0,
            arg1,
            arg2,
            r_evt_count
          )
        );
      end else begin
        `SDRAM_BRIDGE_LOG_DEBUG(
          $sformatf(
            "drop_event_fifo_full id=0x%02h arg0=0x%08h arg1=0x%08h arg2=0x%08h",
            evt_id,
            arg0,
            arg1,
            arg2
          )
        );
      end
    end
  endtask

  // Preserves host events until uart_log_cli drains them.
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
        `SDRAM_BRIDGE_LOG_TRACE(
          $sformatf(
            "fifo_push wr_ptr=%0d id=0x%02h depth_next=%0d",
            r_evt_wr_ptr,
            r_evt_push_id,
            r_evt_count + 1'b1
          )
        );
        r_evt_wr_ptr <= (r_evt_wr_ptr == EVT_FIFO_DEPTH - 1) ? '0 : (r_evt_wr_ptr + 1'b1);
      end

      if (s_evt_pop) begin
        `SDRAM_BRIDGE_LOG_TRACE(
          $sformatf(
            "fifo_pop rd_ptr=%0d id=0x%02h depth_next=%0d",
            r_evt_rd_ptr,
            O_EVT_ID,
            (r_evt_count == 0) ? 0 : (r_evt_count - 1'b1)
          )
        );
        r_evt_rd_ptr <= (r_evt_rd_ptr == EVT_FIFO_DEPTH - 1) ? '0 : (r_evt_rd_ptr + 1'b1);
      end

      case ({s_evt_push, s_evt_pop})
        2'b10: r_evt_count <= r_evt_count + 1'b1;
        2'b01: r_evt_count <= r_evt_count - 1'b1;
        default: r_evt_count <= r_evt_count;
      endcase
    end
  end

  // Main single-access command/control path.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_ascii_cmd_ready <= 1'b0;
      r_req_valid       <= 1'b0;
      r_req_is_write    <= 1'b0;
      r_req_addr        <= '0;
      r_req_data        <= '0;
      r_single_inflight <= 1'b0;
      r_evt_push_valid  <= 1'b0;
      r_evt_push_id     <= 8'h00;
      r_evt_push_arg0   <= 32'h0;
      r_evt_push_arg1   <= 32'h0;
      r_evt_push_arg2   <= 32'h0;
    end else begin
      r_ascii_cmd_ready <= 1'b0;
      r_evt_push_valid  <= 1'b0;

      if (r_req_valid && s_req_ready) begin
        `SDRAM_BRIDGE_LOG_DEBUG(
          $sformatf(
            "req_accept type=%s addr=0x%05h data=0x%08h",
            r_req_is_write ? "WRITE" : "READ",
            r_req_addr,
            r_req_data
          )
        );
        r_req_valid       <= 1'b0;
        r_single_inflight <= 1'b1;
      end

      if (s_ascii_err_valid) begin
        `SDRAM_BRIDGE_LOG_DEBUG(
          $sformatf(
            "ascii_err code=0x%08h detail=0x%08h",
            s_ascii_err_code,
            s_ascii_err_detail
          )
        );
        push_event(EVT_CMD_ERR, s_ascii_err_code, s_ascii_err_detail, 32'h0);
      end

      if (s_ascii_cmd_valid && !r_ascii_cmd_ready) begin
        r_ascii_cmd_ready <= 1'b1;
        `SDRAM_BRIDGE_LOG_DEBUG(
          $sformatf(
            "ascii_cmd op=%0d bulk_read=%0b addr=0x%05h data=0x%08h words=0x%05h enable=%0b req_valid=%0b inflight=%0b",
            s_ascii_cmd_op,
            s_ascii_cmd_bulk_is_read,
            s_ascii_cmd_addr,
            s_ascii_cmd_data,
            s_ascii_cmd_words,
            I_ENABLE,
            r_req_valid,
            r_single_inflight
          )
        );
        if (!I_ENABLE || r_req_valid || r_single_inflight) begin
          push_event(EVT_CMD_ERR, ERR_BUSY, {11'h0, s_ascii_cmd_addr}, 32'h0);
        end else if (s_ascii_cmd_op == ASCII_OP_BULK) begin
          `SDRAM_BRIDGE_LOG_DEBUG(
            $sformatf(
              "reject_bulk single_only bulk_is_read=%0b addr=0x%05h words=0x%05h",
              s_ascii_cmd_bulk_is_read,
              s_ascii_cmd_addr,
              s_ascii_cmd_words
            )
          );
          push_event(
            EVT_CMD_ERR,
            ERR_UNSUPPORTED,
            {11'h0, s_ascii_cmd_addr},
            {11'h0, s_ascii_cmd_words}
          );
        end else if ((s_ascii_cmd_op == ASCII_OP_READ) || (s_ascii_cmd_op == ASCII_OP_WRITE)) begin
          r_req_valid    <= 1'b1;
          r_req_is_write <= (s_ascii_cmd_op == ASCII_OP_WRITE);
          r_req_addr     <= s_ascii_cmd_addr;
          r_req_data     <= s_ascii_cmd_data;
          `SDRAM_BRIDGE_LOG_TRACE(
            $sformatf(
              "issue_single_req type=%s addr=0x%05h data=0x%08h",
              (s_ascii_cmd_op == ASCII_OP_WRITE) ? "WRITE" : "READ",
              s_ascii_cmd_addr,
              s_ascii_cmd_data
            )
          );
        end else begin
          push_event(EVT_CMD_ERR, ERR_BAD_ASCII_CMD, 32'h0, 32'h0);
        end
      end

      if (s_access_rsp_valid && r_single_inflight) begin
        `SDRAM_BRIDGE_LOG_DEBUG(
          $sformatf(
            "access_rsp type=%s addr=0x%05h data=0x%08h status=0x%08h",
            s_access_rsp_is_write ? "WRITE" : "READ",
            s_access_rsp_addr,
            s_access_rsp_data,
            s_access_rsp_status
          )
        );
        r_single_inflight <= 1'b0;
        if (s_access_rsp_status == 32'h0) begin
          push_event(
            s_access_rsp_is_write ? EVT_WRITE_ACK : EVT_READ_RSP,
            {11'h0, s_access_rsp_addr},
            s_access_rsp_is_write ? r_req_data : s_access_rsp_data,
            32'h0
          );
        end else begin
          push_event(EVT_CMD_ERR, s_access_rsp_status, {11'h0, s_access_rsp_addr}, 32'h0);
        end
      end
    end
  end

endmodule

`undef SDRAM_BRIDGE_LOG_DEBUG
`undef SDRAM_BRIDGE_LOG_TRACE
