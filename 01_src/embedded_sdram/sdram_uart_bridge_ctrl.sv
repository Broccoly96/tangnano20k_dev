`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_uart_bridge_ctrl.sv
// Description  : Read-only SDRAM debug register-map bridge for uart_log_cli.
//                - Parses ASCII host commands.
//                - Allows only 32-bit status-map reads from the 64-byte debug map.
//                - Rejects writes and bulk transfers with ERR_UNSUPPORTED.
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
  input  logic [31:0] I_STATUS_RD_DATA,
  output logic [15:0] O_STATUS_ADDR,
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

  localparam int unsigned EVT_FIFO_DEPTH = 8;
  localparam int unsigned EVT_FIFO_PTR_W = $clog2(EVT_FIFO_DEPTH);
  localparam int unsigned EVT_FIFO_CNT_W = $clog2(EVT_FIFO_DEPTH + 1);
  localparam logic [20:0] STATUS_ADDR_MAX = 21'h0003F;

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
  logic        r_cmd_busy;
  logic        r_read_rsp_pending;
  logic [20:0] r_read_addr;

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

  assign O_STATUS_ADDR   = r_read_addr[15:0];

  assign O_SDRC_WR_N     = 1'b1;
  assign O_SDRC_RD_N     = 1'b1;
  assign O_SDRC_ADDR     = 21'h00000;
  assign O_SDRC_DATA_LEN = 8'h00;
  assign O_SDRC_DQM      = 4'h0;
  assign O_SDRC_WR_DATA  = 32'h0000_0000;

  assign O_CMD_BUSY      = r_cmd_busy || r_read_rsp_pending;
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
      end
    end
  endtask

  // Preserves status-map response events until uart_log_cli drains them.
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

  // Decodes host commands and turns them into read-only status-map events.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_ascii_cmd_ready  <= 1'b0;
      r_cmd_busy         <= 1'b0;
      r_read_rsp_pending <= 1'b0;
      r_read_addr        <= '0;
      r_evt_push_valid   <= 1'b0;
      r_evt_push_id      <= 8'h00;
      r_evt_push_arg0    <= 32'h0;
      r_evt_push_arg1    <= 32'h0;
      r_evt_push_arg2    <= 32'h0;
    end else begin
      r_ascii_cmd_ready <= 1'b0;
      r_evt_push_valid  <= 1'b0;

      if (r_read_rsp_pending) begin
        push_event(
          EVT_READ_RSP,
          {11'h000, r_read_addr},
          I_STATUS_RD_DATA,
          32'h0000_0000
        );
        r_read_rsp_pending <= 1'b0;
        r_cmd_busy         <= 1'b0;
      end

      if (s_ascii_err_valid) begin
        push_event(EVT_CMD_ERR, s_ascii_err_code, s_ascii_err_detail, 32'h0000_0000);
      end

      if (s_ascii_cmd_valid && !r_ascii_cmd_ready) begin
        r_ascii_cmd_ready <= 1'b1;

        if (!I_ENABLE || r_cmd_busy || r_read_rsp_pending) begin
          push_event(EVT_CMD_ERR, ERR_BUSY, {11'h000, s_ascii_cmd_addr}, 32'h0000_0000);
        end else if (s_ascii_cmd_op == ASCII_OP_READ) begin
          if ((s_ascii_cmd_addr > STATUS_ADDR_MAX) || (s_ascii_cmd_addr[1:0] != 2'b00)) begin
            push_event(EVT_CMD_ERR, ERR_ADDR_RANGE, {11'h000, s_ascii_cmd_addr}, 32'h0000_0040);
          end else begin
            r_read_addr        <= s_ascii_cmd_addr;
            r_read_rsp_pending <= 1'b1;
            r_cmd_busy         <= 1'b1;
          end
        end else if (s_ascii_cmd_op == ASCII_OP_WRITE) begin
          push_event(
            EVT_CMD_ERR,
            ERR_UNSUPPORTED,
            {11'h000, s_ascii_cmd_addr},
            s_ascii_cmd_data
          );
        end else if (s_ascii_cmd_op == ASCII_OP_BULK) begin
          push_event(
            EVT_CMD_ERR,
            ERR_UNSUPPORTED,
            {11'h000, s_ascii_cmd_addr},
            {11'h000, s_ascii_cmd_words}
          );
        end else begin
          push_event(EVT_CMD_ERR, ERR_BAD_ASCII_CMD, 32'h0000_0000, 32'h0000_0000);
        end
      end
    end
  end

endmodule
