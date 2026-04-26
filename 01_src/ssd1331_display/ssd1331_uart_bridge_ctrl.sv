`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : ssd1331_uart_bridge_ctrl.sv
// Description  : Minimal UART ASCII bridge for SSD1331 display control.
//                Accepted command lines:
//                  I
//                  C
//                  P
//                  A
//                  O
//                  X
//                  F RRGGBB
//////////////////////////////////////////////////////////////////////////////////

module ssd1331_uart_bridge_ctrl #(
  parameter int unsigned SPI_CLK_DIV          = 4,
  parameter int unsigned RESET_ASSERT_CYCLES  = 256,
  parameter int unsigned RESET_RELEASE_CYCLES = 256,
  parameter int unsigned AUTO_INIT_ON_RESET   = 0,
  parameter int unsigned AUTO_ALL_ON_AFTER_INIT = 0,
  parameter int unsigned AUTO_PATTERN_AFTER_INIT = 0,
  parameter int unsigned AUTO_PATTERN_DELAY_CYCLES = 0
) (
  input  logic       I_CLK,
  input  logic       I_RST_N,
  input  logic       I_ENABLE,
  input  logic       I_CLI_RX_VALID,
  input  logic [7:0] I_CLI_RX_DATA,
  output logic       O_CMD_BUSY,
  output logic       O_DISP_CS_N,
  output logic       O_DISP_SCLK,
  output logic       O_DISP_SDIN,
  output logic       O_DISP_DC,
  output logic       O_DISP_RES_N,
  uart_log_evt_if.producer HOST_EVT_IF
);

  import ssd1331_uart_proto_pkg::*;

  localparam int unsigned MAX_LINE_BYTES = 16;
  localparam int unsigned EVT_FIFO_DEPTH = 4;
  localparam int unsigned EVT_FIFO_PTR_W = (EVT_FIFO_DEPTH <= 1) ? 1 : $clog2(EVT_FIFO_DEPTH);
  localparam int unsigned EVT_FIFO_CNT_W = $clog2(EVT_FIFO_DEPTH + 1);
  localparam int unsigned AUTO_DELAY_W =
    (AUTO_PATTERN_DELAY_CYCLES <= 1) ? 1 : $clog2(AUTO_PATTERN_DELAY_CYCLES + 1);

  typedef enum logic [2:0] {
    AUTO_DONE,
    AUTO_REQ_INIT,
    AUTO_WAIT_INIT,
    AUTO_DELAY_PATTERN,
    AUTO_REQ_PATTERN,
    AUTO_REQ_ALL_ON
  } st_auto_e;

  logic [7:0]  r_line [0:MAX_LINE_BYTES-1];
  logic [4:0]  r_line_len;
  logic        r_line_overflow;
  st_auto_e    st_auto;
  logic [AUTO_DELAY_W-1:0] r_auto_delay_cnt;

  logic        r_disp_req_valid;
  logic [2:0]  r_disp_req_op;
  logic [23:0] r_disp_req_color;
  logic [2:0]  r_last_req_op;
  logic [23:0] r_last_req_color;
  logic        s_disp_req_ready;
  logic        s_disp_req_fire;
  logic        s_disp_done_valid;
  logic [2:0]  s_disp_done_op;
  logic        s_disp_busy;

  logic [103:0] r_evt_fifo_mem [0:EVT_FIFO_DEPTH-1];
  logic [EVT_FIFO_PTR_W-1:0] r_evt_wr_ptr;
  logic [EVT_FIFO_PTR_W-1:0] r_evt_rd_ptr;
  logic [EVT_FIFO_CNT_W-1:0] r_evt_count;
  logic        s_evt_fifo_full;
  logic        s_evt_fifo_empty;
  logic        s_evt_pop;

  logic        r_evt_push_valid;
  logic [7:0]  r_evt_push_id;
  logic [31:0] r_evt_push_arg0;
  logic [31:0] r_evt_push_arg1;
  logic [31:0] r_evt_push_arg2;
  logic        s_evt_push_fire;
  logic        s_cli_enable;

  assign s_cli_enable   = I_ENABLE && (HOST_EVT_IF.enable || s_disp_busy || r_disp_req_valid);
  assign O_CMD_BUSY     = s_disp_busy || r_disp_req_valid;
  assign s_disp_req_fire = r_disp_req_valid && s_disp_req_ready;

  assign s_evt_fifo_full  = (r_evt_count == EVT_FIFO_DEPTH);
  assign s_evt_fifo_empty = (r_evt_count == 0);
  assign s_evt_pop        = HOST_EVT_IF.evt_valid && HOST_EVT_IF.evt_ready;
  assign s_evt_push_fire  = r_evt_push_valid && !s_evt_fifo_full;

  assign HOST_EVT_IF.evt_valid = !s_evt_fifo_empty;
  assign HOST_EVT_IF.evt_id    = s_evt_fifo_empty ? 8'h00 : r_evt_fifo_mem[r_evt_rd_ptr][103:96];
  assign HOST_EVT_IF.arg0      = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][95:64];
  assign HOST_EVT_IF.arg1      = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][63:32];
  assign HOST_EVT_IF.arg2      = s_evt_fifo_empty ? 32'h0 : r_evt_fifo_mem[r_evt_rd_ptr][31:0];

  function automatic logic is_hex_upper(input logic [7:0] byte_value);
    begin
      is_hex_upper =
        ((byte_value >= 8'h30) && (byte_value <= 8'h39)) ||
        ((byte_value >= 8'h41) && (byte_value <= 8'h46));
    end
  endfunction

  function automatic logic [3:0] hex_upper_to_nibble(input logic [7:0] byte_value);
    begin
      if ((byte_value >= 8'h30) && (byte_value <= 8'h39)) begin
        hex_upper_to_nibble = byte_value[3:0];
      end else begin
        hex_upper_to_nibble = byte_value[3:0] + 4'd9;
      end
    end
  endfunction

  function automatic logic fixed_hex6_ok(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4,
    input logic [7:0] b5
  );
    begin
      fixed_hex6_ok = is_hex_upper(b0) && is_hex_upper(b1) &&
                      is_hex_upper(b2) && is_hex_upper(b3) &&
                      is_hex_upper(b4) && is_hex_upper(b5);
    end
  endfunction

  function automatic logic [23:0] parse_hex6(
    input logic [7:0] b0,
    input logic [7:0] b1,
    input logic [7:0] b2,
    input logic [7:0] b3,
    input logic [7:0] b4,
    input logic [7:0] b5
  );
    begin
      parse_hex6 = {
        hex_upper_to_nibble(b0),
        hex_upper_to_nibble(b1),
        hex_upper_to_nibble(b2),
        hex_upper_to_nibble(b3),
        hex_upper_to_nibble(b4),
        hex_upper_to_nibble(b5)
      };
    end
  endfunction

  task automatic arm_event(
    input logic [7:0]  evt_id,
    input logic [31:0] evt_arg0,
    input logic [31:0] evt_arg1,
    input logic [31:0] evt_arg2
  );
    begin
      r_evt_push_valid <= 1'b1;
      r_evt_push_id    <= evt_id;
      r_evt_push_arg0  <= evt_arg0;
      r_evt_push_arg1  <= evt_arg1;
      r_evt_push_arg2  <= evt_arg2;
    end
  endtask

  task automatic issue_req(
    input logic [2:0]  req_op,
    input logic [23:0] req_color,
    input logic [31:0] req_detail
  );
    begin
      if (s_disp_busy || r_disp_req_valid) begin
        arm_event(EVT_CMD_ERR, ERR_BUSY, req_detail, 32'h0000_0000);
      end else begin
        r_disp_req_valid <= 1'b1;
        r_disp_req_op    <= req_op;
        r_disp_req_color <= req_color;
        r_last_req_op    <= req_op;
        r_last_req_color <= req_color;
      end
    end
  endtask

  task automatic decode_line;
    logic [23:0] decoded_color;
    logic [31:0] detail_word;
    begin
      detail_word = {24'h0, r_line[0]};
      if (r_line_overflow) begin
        arm_event(EVT_CMD_ERR, ERR_BAD_ASCII_FIELD, 32'hFFFF_FFFF, 32'h0000_0000);
      end else if (r_line_len == 0) begin
      end else if ((r_line_len == 1) && (r_line[0] == ASCII_CMD_INIT)) begin
        issue_req(DISP_OP_INIT, 24'h000000, detail_word);
      end else if ((r_line_len == 1) && (r_line[0] == ASCII_CMD_CLEAR)) begin
        issue_req(DISP_OP_CLEAR, 24'h000000, detail_word);
      end else if ((r_line_len == 1) && (r_line[0] == ASCII_CMD_PATTERN)) begin
        issue_req(DISP_OP_PATTERN, 24'h000000, detail_word);
      end else if ((r_line_len == 1) && (r_line[0] == ASCII_CMD_ALL_ON)) begin
        issue_req(DISP_OP_ALL_ON, 24'h000000, detail_word);
      end else if ((r_line_len == 1) && (r_line[0] == ASCII_CMD_ON)) begin
        issue_req(DISP_OP_ON, 24'h000000, detail_word);
      end else if ((r_line_len == 1) && (r_line[0] == ASCII_CMD_OFF)) begin
        issue_req(DISP_OP_OFF, 24'h000000, detail_word);
      end else if ((r_line_len == 8) &&
                   (r_line[0] == ASCII_CMD_FILL) &&
                   (r_line[1] == 8'h20) &&
                   fixed_hex6_ok(r_line[2], r_line[3], r_line[4], r_line[5], r_line[6], r_line[7])) begin
        decoded_color = parse_hex6(r_line[2], r_line[3], r_line[4], r_line[5], r_line[6], r_line[7]);
        issue_req(DISP_OP_FILL, decoded_color, {8'h00, decoded_color});
      end else if ((r_line_len == 8) && (r_line[0] == ASCII_CMD_FILL) && (r_line[1] == 8'h20)) begin
        arm_event(EVT_CMD_ERR, ERR_BAD_ASCII_FIELD, 32'h0000_0000, {8'h00, parse_hex6(8'h30, 8'h30, 8'h30, 8'h30, 8'h30, 8'h30)});
      end else begin
        arm_event(EVT_CMD_ERR, ERR_UNSUPPORTED_CMD, detail_word, {27'h0, r_line_len});
      end
    end
  endtask

  ssd1331_display_ctrl #(
    .SPI_CLK_DIV          (SPI_CLK_DIV),
    .RESET_ASSERT_CYCLES  (RESET_ASSERT_CYCLES),
    .RESET_RELEASE_CYCLES (RESET_RELEASE_CYCLES)
  ) u_ssd1331_display_ctrl (
    .I_CLK        (I_CLK),
    .I_RST_N      (I_RST_N),
    .I_REQ_VALID  (r_disp_req_valid),
    .O_REQ_READY  (s_disp_req_ready),
    .I_REQ_OP     (r_disp_req_op),
    .I_REQ_COLOR  (r_disp_req_color),
    .O_DONE_VALID (s_disp_done_valid),
    .O_DONE_OP    (s_disp_done_op),
    .O_BUSY       (s_disp_busy),
    .O_DISP_CS_N  (O_DISP_CS_N),
    .O_DISP_SCLK  (O_DISP_SCLK),
    .O_DISP_SDIN  (O_DISP_SDIN),
    .O_DISP_DC    (O_DISP_DC),
    .O_DISP_RES_N (O_DISP_RES_N)
  );

  function automatic st_auto_e auto_reset_state;
    begin
      if (AUTO_INIT_ON_RESET != 0) begin
        auto_reset_state = AUTO_REQ_INIT;
      end else begin
        auto_reset_state = AUTO_DONE;
      end
    end
  endfunction

  // Small event FIFO so command completion and parse errors can be surfaced
  // through uart_log_cli without forcing direct combinational backpressure.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_evt_wr_ptr <= '0;
      r_evt_rd_ptr <= '0;
      r_evt_count  <= '0;
    end else begin
      if (s_evt_push_fire) begin
        r_evt_fifo_mem[r_evt_wr_ptr] <= {r_evt_push_id, r_evt_push_arg0, r_evt_push_arg1, r_evt_push_arg2};
        if (r_evt_wr_ptr == EVT_FIFO_DEPTH-1) begin
          r_evt_wr_ptr <= '0;
        end else begin
          r_evt_wr_ptr <= r_evt_wr_ptr + 1'b1;
        end
      end

      if (s_evt_pop) begin
        if (r_evt_rd_ptr == EVT_FIFO_DEPTH-1) begin
          r_evt_rd_ptr <= '0;
        end else begin
          r_evt_rd_ptr <= r_evt_rd_ptr + 1'b1;
        end
      end

      case ({s_evt_push_fire, s_evt_pop})
        2'b10: r_evt_count <= r_evt_count + 1'b1;
        2'b01: r_evt_count <= r_evt_count - 1'b1;
        default: begin end
      endcase
    end
  end

  // ASCII parser, pending request register, and event arming logic.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    integer line_idx;
    if (!I_RST_N) begin
      r_line_len       <= '0;
      r_line_overflow  <= 1'b0;
      for (line_idx = 0; line_idx < MAX_LINE_BYTES; line_idx++) begin
        r_line[line_idx] <= 8'h00;
      end
      r_disp_req_valid <= 1'b0;
      r_disp_req_op    <= DISP_OP_OFF;
      r_disp_req_color <= 24'h000000;
      r_last_req_op    <= DISP_OP_OFF;
      r_last_req_color <= 24'h000000;
      r_evt_push_valid <= 1'b0;
      r_evt_push_id    <= 8'h00;
      r_evt_push_arg0  <= 32'h0;
      r_evt_push_arg1  <= 32'h0;
      r_evt_push_arg2  <= 32'h0;
      st_auto          <= auto_reset_state();
      r_auto_delay_cnt <= '0;
    end else begin
      if (s_disp_req_fire) begin
        r_disp_req_valid <= 1'b0;
      end

      if (s_evt_push_fire) begin
        r_evt_push_valid <= 1'b0;
      end

      if (s_disp_done_valid) begin
        arm_event(EVT_CMD_ACK, {29'h0, s_disp_done_op}, {8'h00, r_last_req_color}, 32'h0000_0000);
      end

      // Optional hardware bring-up path. When enabled by the top module, the
      // OLED is initialized after FPGA reset and can run a visible diagnostic
      // command without requiring a working UART console.
      case (st_auto)
        AUTO_REQ_INIT: begin
          if (!s_disp_busy && !r_disp_req_valid) begin
            issue_req(DISP_OP_INIT, 24'h000000, 32'hA001_0000);
            st_auto <= AUTO_WAIT_INIT;
          end
        end

        AUTO_WAIT_INIT: begin
          if (s_disp_done_valid && (s_disp_done_op == DISP_OP_INIT)) begin
            if ((AUTO_ALL_ON_AFTER_INIT != 0) || (AUTO_PATTERN_AFTER_INIT != 0)) begin
              if (AUTO_PATTERN_DELAY_CYCLES > 0) begin
                r_auto_delay_cnt <= AUTO_PATTERN_DELAY_CYCLES - 1;
              end else begin
                r_auto_delay_cnt <= '0;
              end
              st_auto <= AUTO_DELAY_PATTERN;
            end else begin
              st_auto <= AUTO_DONE;
            end
          end
        end

        AUTO_DELAY_PATTERN: begin
          if (r_auto_delay_cnt != '0) begin
            r_auto_delay_cnt <= r_auto_delay_cnt - 1'b1;
          end else if (AUTO_ALL_ON_AFTER_INIT != 0) begin
            st_auto <= AUTO_REQ_ALL_ON;
          end else begin
            st_auto <= AUTO_REQ_PATTERN;
          end
        end

        AUTO_REQ_ALL_ON: begin
          if (!s_disp_busy && !r_disp_req_valid) begin
            issue_req(DISP_OP_ALL_ON, 24'h000000, 32'hA001_0006);
            st_auto <= AUTO_DONE;
          end
        end

        AUTO_REQ_PATTERN: begin
          if (!s_disp_busy && !r_disp_req_valid) begin
            issue_req(DISP_OP_PATTERN, 24'h000000, 32'hA001_0003);
            st_auto <= AUTO_DONE;
          end
        end

        default: begin
          st_auto <= AUTO_DONE;
        end
      endcase

      if (s_cli_enable && I_CLI_RX_VALID) begin
        if (I_CLI_RX_DATA == 8'h0D) begin
        end else if (I_CLI_RX_DATA == 8'h0A) begin
          decode_line();
          r_line_len      <= '0;
          r_line_overflow <= 1'b0;
        end else if (r_line_len < MAX_LINE_BYTES) begin
          r_line[r_line_len] <= I_CLI_RX_DATA;
          r_line_len         <= r_line_len + 1'b1;
        end else begin
          r_line_overflow <= 1'b1;
        end
      end
    end
  end

endmodule
