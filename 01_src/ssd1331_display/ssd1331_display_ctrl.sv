`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : ssd1331_display_ctrl.sv
// Description  : Minimal SSD1331 command sequencer.
//                Supported operations:
//                  - init reset + recommended power-up sequence
//                  - clear full window
//                  - fill full screen with one color
//                  - RGB bar test pattern
//                  - all pixels on diagnostic mode
//                  - display on / display off
//////////////////////////////////////////////////////////////////////////////////

module ssd1331_display_ctrl #(
  parameter int unsigned SPI_CLK_DIV          = 4,
  parameter int unsigned RESET_ASSERT_CYCLES  = 256,
  parameter int unsigned RESET_RELEASE_CYCLES = 256
) (
  input  logic       I_CLK,
  input  logic       I_RST_N,
  input  logic       I_REQ_VALID,
  output logic       O_REQ_READY,
  input  logic [2:0] I_REQ_OP,
  input  logic [23:0] I_REQ_COLOR,
  output logic       O_DONE_VALID,
  output logic [2:0] O_DONE_OP,
  output logic       O_BUSY,
  output logic       O_DISP_CS_N,
  output logic       O_DISP_SCLK,
  output logic       O_DISP_SDIN,
  output logic       O_DISP_DC,
  output logic       O_DISP_RES_N
);

  import ssd1331_uart_proto_pkg::*;

  localparam int unsigned INIT_SEQ_LEN         = 39;
  localparam int unsigned CLEAR_SEQ_LEN        = 5;
  localparam int unsigned FILL_SEQ_LEN         = 13;
  localparam int unsigned RAM_PATTERN_PREFIX_LEN = 7;
  localparam int unsigned RAM_PATTERN_PIXELS   = 96 * 64;
  localparam int unsigned RAM_PATTERN_BYTES    = RAM_PATTERN_PIXELS * 2;
  localparam int unsigned PATTERN_SEQ_LEN      = RAM_PATTERN_PREFIX_LEN + RAM_PATTERN_BYTES;
  localparam int unsigned MAX_SEQ_LEN          = PATTERN_SEQ_LEN;
  localparam int unsigned MAX_WAIT_CYCLES =
    (RESET_ASSERT_CYCLES > RESET_RELEASE_CYCLES) ? RESET_ASSERT_CYCLES : RESET_RELEASE_CYCLES;
  localparam int unsigned WAIT_W = (MAX_WAIT_CYCLES <= 1) ? 1 : $clog2(MAX_WAIT_CYCLES + 1);
  localparam int unsigned STEP_W = (MAX_SEQ_LEN <= 1) ? 1 : $clog2(MAX_SEQ_LEN);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_RESET_ASSERT,
    ST_RESET_RELEASE,
    ST_SEND_BYTE,
    ST_WAIT_BYTE,
    ST_DONE
  } st_state_e;

  st_state_e         st_state;
  logic [2:0]        r_active_op;
  logic [23:0]       r_active_color;
  logic [STEP_W-1:0] r_step_idx;
  logic [WAIT_W-1:0] r_wait_cnt;
  logic              r_done_valid;
  logic [2:0]        r_done_op;
  logic              r_disp_res_n;
  logic              r_spi_tx_valid;
  logic [7:0]        r_spi_tx_data;
  logic              r_spi_tx_dc;

  logic              s_spi_tx_ready;
  logic              s_spi_tx_done;
  logic [7:0]        s_seq_byte;
  logic              s_seq_dc;

  assign O_REQ_READY   = (st_state == ST_IDLE);
  assign O_DONE_VALID  = r_done_valid;
  assign O_DONE_OP     = r_done_op;
  assign O_BUSY        = (st_state != ST_IDLE);
  assign O_DISP_RES_N  = r_disp_res_n;

  function automatic int unsigned seq_len(input logic [2:0] req_op);
    begin
      case (req_op)
        DISP_OP_INIT:    seq_len = INIT_SEQ_LEN;
        DISP_OP_CLEAR:   seq_len = CLEAR_SEQ_LEN;
        DISP_OP_FILL:    seq_len = FILL_SEQ_LEN;
        DISP_OP_PATTERN: seq_len = PATTERN_SEQ_LEN;
        DISP_OP_ON:      seq_len = 1;
        DISP_OP_OFF:     seq_len = 1;
        DISP_OP_ALL_ON:  seq_len = 1;
        default:         seq_len = 1;
      endcase
    end
  endfunction

  function automatic logic [7:0] color_red_cmd(input logic [23:0] rgb888);
    begin
      color_red_cmd = {2'b00, rgb888[23:19], 1'b0};
    end
  endfunction

  function automatic logic [7:0] color_green_cmd(input logic [23:0] rgb888);
    begin
      color_green_cmd = {2'b00, rgb888[15:10]};
    end
  endfunction

  function automatic logic [7:0] color_blue_cmd(input logic [23:0] rgb888);
    begin
      color_blue_cmd = {2'b00, rgb888[7:3], 1'b0};
    end
  endfunction

  function automatic logic [7:0] rect_seq_byte(
    input logic [3:0]  rect_step,
    input logic [23:0] rect_color,
    input logic [7:0]  x0,
    input logic [7:0]  y0,
    input logic [7:0]  x1,
    input logic [7:0]  y1
  );
    begin
      case (rect_step)
        4'd0:    rect_seq_byte = 8'h22;
        4'd1:    rect_seq_byte = x0;
        4'd2:    rect_seq_byte = y0;
        4'd3:    rect_seq_byte = x1;
        4'd4:    rect_seq_byte = y1;
        4'd5:    rect_seq_byte = color_red_cmd(rect_color);
        4'd6:    rect_seq_byte = color_green_cmd(rect_color);
        4'd7:    rect_seq_byte = color_blue_cmd(rect_color);
        4'd8:    rect_seq_byte = color_red_cmd(rect_color);
        4'd9:    rect_seq_byte = color_green_cmd(rect_color);
        4'd10:   rect_seq_byte = color_blue_cmd(rect_color);
        default: rect_seq_byte = 8'h00;
      endcase
    end
  endfunction

  function automatic logic rect_seq_dc(input logic [3:0] rect_step);
    begin
      rect_seq_dc = 1'b0;
    end
  endfunction

  function automatic logic [7:0] rgb565_bar_byte(input int unsigned data_idx);
    int unsigned pixel_idx;
    logic [15:0] rgb565_value;
    begin
      pixel_idx = data_idx >> 1;

      if (pixel_idx < (32 * 64)) begin
        rgb565_value = 16'hF800;
      end else if (pixel_idx < (64 * 64)) begin
        rgb565_value = 16'h07E0;
      end else begin
        rgb565_value = 16'h001F;
      end

      if (data_idx[0] == 1'b0) begin
        rgb565_bar_byte = rgb565_value[15:8];
      end else begin
        rgb565_bar_byte = rgb565_value[7:0];
      end
    end
  endfunction

  always_comb begin
    s_seq_byte = 8'h00;
    s_seq_dc   = 1'b0;

    case (r_active_op)
      DISP_OP_INIT: begin
        case (r_step_idx)
          6'd0:  begin s_seq_byte = 8'hFD; s_seq_dc = 1'b0; end
          6'd1:  begin s_seq_byte = 8'h12; s_seq_dc = 1'b0; end
          6'd2:  begin s_seq_byte = 8'hAE; s_seq_dc = 1'b0; end
          6'd3:  begin s_seq_byte = 8'hA0; s_seq_dc = 1'b0; end
          6'd4:  begin s_seq_byte = 8'h72; s_seq_dc = 1'b0; end
          6'd5:  begin s_seq_byte = 8'hA1; s_seq_dc = 1'b0; end
          6'd6:  begin s_seq_byte = 8'h00; s_seq_dc = 1'b0; end
          6'd7:  begin s_seq_byte = 8'hA2; s_seq_dc = 1'b0; end
          6'd8:  begin s_seq_byte = 8'h00; s_seq_dc = 1'b0; end
          6'd9:  begin s_seq_byte = 8'hA4; s_seq_dc = 1'b0; end
          6'd10: begin s_seq_byte = 8'hA8; s_seq_dc = 1'b0; end
          6'd11: begin s_seq_byte = 8'h3F; s_seq_dc = 1'b0; end
          6'd12: begin s_seq_byte = 8'hAD; s_seq_dc = 1'b0; end
          6'd13: begin s_seq_byte = 8'h8E; s_seq_dc = 1'b0; end
          6'd14: begin s_seq_byte = 8'hB0; s_seq_dc = 1'b0; end
          6'd15: begin s_seq_byte = 8'h0B; s_seq_dc = 1'b0; end
          6'd16: begin s_seq_byte = 8'hB1; s_seq_dc = 1'b0; end
          6'd17: begin s_seq_byte = 8'h31; s_seq_dc = 1'b0; end
          6'd18: begin s_seq_byte = 8'hB3; s_seq_dc = 1'b0; end
          6'd19: begin s_seq_byte = 8'hF0; s_seq_dc = 1'b0; end
          6'd20: begin s_seq_byte = 8'h8A; s_seq_dc = 1'b0; end
          6'd21: begin s_seq_byte = 8'h64; s_seq_dc = 1'b0; end
          6'd22: begin s_seq_byte = 8'h8B; s_seq_dc = 1'b0; end
          6'd23: begin s_seq_byte = 8'h78; s_seq_dc = 1'b0; end
          6'd24: begin s_seq_byte = 8'h8C; s_seq_dc = 1'b0; end
          6'd25: begin s_seq_byte = 8'h64; s_seq_dc = 1'b0; end
          6'd26: begin s_seq_byte = 8'hBB; s_seq_dc = 1'b0; end
          6'd27: begin s_seq_byte = 8'h3A; s_seq_dc = 1'b0; end
          6'd28: begin s_seq_byte = 8'hBE; s_seq_dc = 1'b0; end
          6'd29: begin s_seq_byte = 8'h3E; s_seq_dc = 1'b0; end
          6'd30: begin s_seq_byte = 8'h87; s_seq_dc = 1'b0; end
          6'd31: begin s_seq_byte = 8'h06; s_seq_dc = 1'b0; end
          6'd32: begin s_seq_byte = 8'h81; s_seq_dc = 1'b0; end
          6'd33: begin s_seq_byte = 8'h91; s_seq_dc = 1'b0; end
          6'd34: begin s_seq_byte = 8'h82; s_seq_dc = 1'b0; end
          6'd35: begin s_seq_byte = 8'h50; s_seq_dc = 1'b0; end
          6'd36: begin s_seq_byte = 8'h83; s_seq_dc = 1'b0; end
          6'd37: begin s_seq_byte = 8'h7D; s_seq_dc = 1'b0; end
          6'd38: begin s_seq_byte = 8'hAF; s_seq_dc = 1'b0; end
          default: begin s_seq_byte = 8'h00; s_seq_dc = 1'b0; end
        endcase
      end

      DISP_OP_CLEAR: begin
        case (r_step_idx)
          6'd0:    begin s_seq_byte = 8'h25; s_seq_dc = 1'b0; end
          6'd1:    begin s_seq_byte = 8'h00; s_seq_dc = 1'b0; end
          6'd2:    begin s_seq_byte = 8'h00; s_seq_dc = 1'b0; end
          6'd3:    begin s_seq_byte = 8'h5F; s_seq_dc = 1'b0; end
          6'd4:    begin s_seq_byte = 8'h3F; s_seq_dc = 1'b0; end
          default: begin s_seq_byte = 8'h00; s_seq_dc = 1'b0; end
        endcase
      end

      DISP_OP_FILL: begin
        case (r_step_idx)
          6'd0:    begin s_seq_byte = 8'h26; s_seq_dc = 1'b0; end
          6'd1:    begin s_seq_byte = 8'h01; s_seq_dc = 1'b0; end
          default: begin
            s_seq_byte = rect_seq_byte(r_step_idx - 6'd2, r_active_color, 8'd0, 8'd0, 8'd95, 8'd63);
            s_seq_dc   = rect_seq_dc(r_step_idx - 6'd2);
          end
        endcase
      end

      DISP_OP_PATTERN: begin
        if (r_step_idx == 14'd0) begin
          s_seq_byte = 8'h15;
          s_seq_dc   = 1'b0;
        end else if (r_step_idx == 14'd1) begin
          s_seq_byte = 8'h00;
          s_seq_dc   = 1'b0;
        end else if (r_step_idx == 14'd2) begin
          s_seq_byte = 8'h5F;
          s_seq_dc   = 1'b0;
        end else if (r_step_idx == 14'd3) begin
          s_seq_byte = 8'h75;
          s_seq_dc   = 1'b0;
        end else if (r_step_idx == 14'd4) begin
          s_seq_byte = 8'h00;
          s_seq_dc   = 1'b0;
        end else if (r_step_idx == 14'd5) begin
          s_seq_byte = 8'h3F;
          s_seq_dc   = 1'b0;
        end else if (r_step_idx == 14'd6) begin
          s_seq_byte = 8'h5C;
          s_seq_dc   = 1'b0;
        end else begin
          s_seq_byte = rgb565_bar_byte(r_step_idx - RAM_PATTERN_PREFIX_LEN);
          s_seq_dc   = 1'b1;
        end
      end

      DISP_OP_ON: begin
        s_seq_byte = 8'hAF;
        s_seq_dc   = 1'b0;
      end

      DISP_OP_OFF: begin
        s_seq_byte = 8'hAE;
        s_seq_dc   = 1'b0;
      end

      DISP_OP_ALL_ON: begin
        s_seq_byte = 8'hA5;
        s_seq_dc   = 1'b0;
      end

      default: begin
        s_seq_byte = 8'hAE;
        s_seq_dc   = 1'b0;
      end
    endcase
  end

  ssd1331_spi_master #(
    .CLK_DIV (SPI_CLK_DIV)
  ) u_ssd1331_spi_master (
    .I_CLK      (I_CLK),
    .I_RST_N    (I_RST_N),
    .I_TX_VALID (r_spi_tx_valid),
    .O_TX_READY (s_spi_tx_ready),
    .I_TX_DATA  (r_spi_tx_data),
    .I_TX_DC    (r_spi_tx_dc),
    .I_TX_FIRST (1'b1),
    .I_TX_LAST  (1'b1),
    .O_TX_DONE  (s_spi_tx_done),
    .O_BUSY     (),
    .O_SPI_CS_N (O_DISP_CS_N),
    .O_SPI_SCLK (O_DISP_SCLK),
    .O_SPI_SDIN (O_DISP_SDIN),
    .O_SPI_DC   (O_DISP_DC)
  );

  // Operation sequencer. Reset pulse timing is kept separate from byte sending
  // so each OLED request becomes one deterministic serial command script.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state       <= ST_IDLE;
      r_active_op    <= DISP_OP_OFF;
      r_active_color <= 24'h000000;
      r_step_idx     <= '0;
      r_wait_cnt     <= '0;
      r_done_valid   <= 1'b0;
      r_done_op      <= DISP_OP_OFF;
      r_disp_res_n   <= 1'b1;
      r_spi_tx_valid <= 1'b0;
      r_spi_tx_data  <= 8'h00;
      r_spi_tx_dc    <= 1'b0;
    end else begin
      r_done_valid   <= 1'b0;
      r_spi_tx_valid <= 1'b0;

      case (st_state)
        ST_IDLE: begin
          if (I_REQ_VALID) begin
            r_active_op    <= I_REQ_OP;
            r_active_color <= I_REQ_COLOR;
            r_step_idx     <= '0;
            if (I_REQ_OP == DISP_OP_INIT) begin
              r_disp_res_n <= 1'b0;
              if (RESET_ASSERT_CYCLES > 0) begin
                r_wait_cnt <= RESET_ASSERT_CYCLES - 1;
              end else begin
                r_wait_cnt <= '0;
              end
              st_state <= ST_RESET_ASSERT;
            end else begin
              st_state <= ST_SEND_BYTE;
            end
          end
        end

        ST_RESET_ASSERT: begin
          if (r_wait_cnt != '0) begin
            r_wait_cnt <= r_wait_cnt - 1'b1;
          end else begin
            r_disp_res_n <= 1'b1;
            if (RESET_RELEASE_CYCLES > 0) begin
              r_wait_cnt <= RESET_RELEASE_CYCLES - 1;
            end else begin
              r_wait_cnt <= '0;
            end
            st_state <= ST_RESET_RELEASE;
          end
        end

        ST_RESET_RELEASE: begin
          if (r_wait_cnt != '0) begin
            r_wait_cnt <= r_wait_cnt - 1'b1;
          end else begin
            st_state <= ST_SEND_BYTE;
          end
        end

        ST_SEND_BYTE: begin
          if (s_spi_tx_ready) begin
            r_spi_tx_valid <= 1'b1;
            r_spi_tx_data  <= s_seq_byte;
            r_spi_tx_dc    <= s_seq_dc;
            st_state       <= ST_WAIT_BYTE;
          end
        end

        ST_WAIT_BYTE: begin
          if (s_spi_tx_done) begin
            if ((r_step_idx + 1'b1) >= seq_len(r_active_op)) begin
              st_state <= ST_DONE;
            end else begin
              r_step_idx <= r_step_idx + 1'b1;
              st_state   <= ST_SEND_BYTE;
            end
          end
        end

        ST_DONE: begin
          r_done_valid <= 1'b1;
          r_done_op    <= r_active_op;
          st_state     <= ST_IDLE;
        end

        default: begin
          st_state <= ST_IDLE;
        end
      endcase
    end
  end

endmodule
