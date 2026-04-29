`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : ssd1306_i2c_model.sv
// Description  : Behavioral SSD1306 write-only I2C model for unit simulation.
//                - ACKs address, control, command, and data bytes.
//                - Tracks command bytes and a 512-byte GDDRAM shadow.
//                - Supports the command subset used by the RTL controller.
//////////////////////////////////////////////////////////////////////////////////

module ssd1306_i2c_model #(
  parameter logic [6:0] SLAVE_ADDR = ssd1306_uart_proto_pkg::SSD1306_DEFAULT_SLAVE_ADDR
) (
  input  logic I_CLK,
  input  logic I_RST_N,
  input  logic I_SCL,
  input  logic I_SDA,
  output logic O_SDA_DRIVE_LOW
);

  import ssd1306_uart_proto_pkg::*;

  localparam int unsigned RX_LOG_MAX  = 2048;
  localparam int unsigned CMD_LOG_MAX = 256;

  logic [7:0] r_shift_rx;
  logic [2:0] r_rx_bit_idx;
  logic       r_receiving;
  logic       r_ack_pending;
  logic       r_ack_value;
  logic       r_ack_driving;
  logic       r_addr_seen;
  logic       r_control_seen;
  logic       r_control_co;
  logic       r_control_is_data;
  logic [7:0] r_pending_cmd;
  logic [1:0] r_pending_cmd_args;
  logic [1:0] r_pending_cmd_arg_idx;
  logic [1:0] r_addressing_mode;
  logic [7:0] r_col_start;
  logic [7:0] r_col_end;
  logic [2:0] r_page_start;
  logic [2:0] r_page_end;
  logic [7:0] r_curr_col;
  logic [2:0] r_curr_page;
  integer     r_rx_count;
  integer     r_cmd_count;
  logic [7:0] r_rx_bytes [0:RX_LOG_MAX-1];
  logic [7:0] r_cmd_bytes [0:CMD_LOG_MAX-1];
  logic [7:0] r_gddram [0:SSD1306_FRAME_BYTES-1];

  task automatic push_rx_byte(input logic [7:0] byte_value);
    begin
      if (r_rx_count < RX_LOG_MAX) begin
        r_rx_bytes[r_rx_count] = byte_value;
        r_rx_count = r_rx_count + 1;
      end
    end
  endtask

  task automatic push_cmd_byte(input logic [7:0] byte_value);
    begin
      if (r_cmd_count < CMD_LOG_MAX) begin
        r_cmd_bytes[r_cmd_count] = byte_value;
        r_cmd_count = r_cmd_count + 1;
      end
    end
  endtask

  task automatic advance_gddram_pointer;
    begin
      if (r_addressing_mode == 2'b00) begin
        if (r_curr_col < r_col_end) begin
          r_curr_col = r_curr_col + 1'b1;
        end else begin
          r_curr_col = r_col_start;
          if (r_curr_page < r_page_end) begin
            r_curr_page = r_curr_page + 1'b1;
          end else begin
            r_curr_page = r_page_start;
          end
        end
      end else begin
        if (r_curr_page < r_page_end) begin
          r_curr_page = r_curr_page + 1'b1;
        end else begin
          r_curr_page = r_page_start;
          if (r_curr_col < r_col_end) begin
            r_curr_col = r_curr_col + 1'b1;
          end else begin
            r_curr_col = r_col_start;
          end
        end
      end
    end
  endtask

  task automatic apply_command_arg(input logic [7:0] byte_value);
    begin
      case (r_pending_cmd)
        8'h20: begin
          r_addressing_mode = byte_value[1:0];
        end

        8'h21: begin
          if (r_pending_cmd_arg_idx == 0) begin
            r_col_start = byte_value;
            r_curr_col  = byte_value;
          end else begin
            r_col_end = byte_value;
          end
        end

        8'h22: begin
          if (r_pending_cmd_arg_idx == 0) begin
            r_page_start = byte_value[2:0];
            r_curr_page  = byte_value[2:0];
          end else begin
            r_page_end = byte_value[2:0];
          end
        end

        8'hB0,
        8'hB1,
        8'hB2,
        8'hB3,
        8'hB4,
        8'hB5,
        8'hB6,
        8'hB7: begin
          r_curr_page = r_pending_cmd[2:0];
        end

        default: begin
        end
      endcase
    end
  endtask

  function automatic logic [1:0] expected_arg_count(input logic [7:0] cmd_byte);
    begin
      case (cmd_byte)
        8'h20,
        8'h81,
        8'h8D,
        8'hA8,
        8'hD3,
        8'hD5,
        8'hD9,
        8'hDA,
        8'hDB: expected_arg_count = 2'd1;
        8'h21,
        8'h22: expected_arg_count = 2'd2;
        default: expected_arg_count = 2'd0;
      endcase
    end
  endfunction

  task automatic handle_command_byte(input logic [7:0] byte_value);
    begin
      push_cmd_byte(byte_value);

      if ((byte_value >= 8'hB0) && (byte_value <= 8'hB7)) begin
        r_curr_page = byte_value[2:0];
      end else if ((byte_value & 8'hF0) == 8'h00) begin
        r_curr_col[3:0] = byte_value[3:0];
      end else if ((byte_value & 8'hF0) == 8'h10) begin
        r_curr_col[7:4] = byte_value[3:0];
      end

      r_pending_cmd         = byte_value;
      r_pending_cmd_args    = expected_arg_count(byte_value);
      r_pending_cmd_arg_idx = 2'd0;
    end
  endtask

  task automatic handle_data_byte(input logic [7:0] byte_value);
    int unsigned gddram_idx;
    begin
      gddram_idx = (r_curr_page * SSD1306_WIDTH) + r_curr_col;
      if (gddram_idx < SSD1306_FRAME_BYTES) begin
        r_gddram[gddram_idx] = byte_value;
      end
      advance_gddram_pointer();
    end
  endtask

  task automatic complete_rx_byte(input logic [7:0] byte_value);
    begin
      push_rx_byte(byte_value);
      r_ack_value = 1'b0;

      if (!r_addr_seen) begin
        if ((byte_value[7:1] == SLAVE_ADDR) && (byte_value[0] == 1'b0)) begin
          r_addr_seen       = 1'b1;
          r_control_seen    = 1'b0;
          r_control_co      = 1'b0;
          r_control_is_data = 1'b0;
        end else begin
          r_ack_value = 1'b1;
        end
      end else if (!r_control_seen || r_control_co) begin
        r_control_seen    = 1'b1;
        r_control_co      = byte_value[7];
        r_control_is_data = byte_value[6];
      end else if (r_control_is_data) begin
        handle_data_byte(byte_value);
      end else if (r_pending_cmd_args != 0) begin
        apply_command_arg(byte_value);
        r_pending_cmd_arg_idx = r_pending_cmd_arg_idx + 1'b1;
        r_pending_cmd_args    = r_pending_cmd_args - 1'b1;
      end else begin
        handle_command_byte(byte_value);
      end

      r_ack_pending = 1'b1;
      r_ack_driving = 1'b0;
      r_receiving   = 1'b0;
    end
  endtask

  // START resets the transaction framing while preserving GDDRAM state.
  always @(negedge I_SDA) begin
    if (I_SCL === 1'b1) begin
      O_SDA_DRIVE_LOW   <= 1'b0;
      r_receiving       <= 1'b1;
      r_ack_pending     <= 1'b0;
      r_ack_driving     <= 1'b0;
      r_addr_seen       <= 1'b0;
      r_control_seen    <= 1'b0;
      r_control_co      <= 1'b0;
      r_control_is_data <= 1'b0;
      r_pending_cmd     <= 8'h00;
      r_pending_cmd_args<= 2'd0;
      r_pending_cmd_arg_idx <= 2'd0;
      r_rx_bit_idx      <= 3'd7;
      r_shift_rx        <= 8'h00;
    end
  end

  // STOP ends the current transaction and releases SDA.
  always @(posedge I_SDA) begin
    if (I_SCL === 1'b1) begin
      O_SDA_DRIVE_LOW <= 1'b0;
      r_receiving     <= 1'b0;
      r_ack_pending   <= 1'b0;
      r_ack_driving   <= 1'b0;
      r_addr_seen     <= 1'b0;
      r_control_seen  <= 1'b0;
      r_control_co    <= 1'b0;
    end
  end

  // Samples one byte from the master on SCL rising edges.
  always @(posedge I_SCL) begin
    if (r_receiving) begin
      r_shift_rx[r_rx_bit_idx] <= I_SDA;
      if (r_rx_bit_idx == 0) begin
        complete_rx_byte({r_shift_rx[7:1], I_SDA});
      end else begin
        r_rx_bit_idx <= r_rx_bit_idx - 1'b1;
      end
    end
  end

  // Drives the ACK bit low on the falling edge before the master samples it.
  always @(negedge I_SCL) begin
    if (r_ack_pending) begin
      if (!r_ack_driving) begin
        O_SDA_DRIVE_LOW <= !r_ack_value;
        r_ack_driving   <= 1'b1;
      end else begin
        O_SDA_DRIVE_LOW <= 1'b0;
        r_ack_pending   <= 1'b0;
        r_ack_driving   <= 1'b0;
        r_receiving     <= 1'b1;
        r_rx_bit_idx    <= 3'd7;
      end
    end
  end

  initial begin
    r_shift_rx            = 8'h00;
    r_rx_bit_idx          = 3'd7;
    r_receiving           = 1'b0;
    r_ack_pending         = 1'b0;
    r_ack_value           = 1'b0;
    r_ack_driving         = 1'b0;
    r_addr_seen           = 1'b0;
    r_control_seen        = 1'b0;
    r_control_co          = 1'b0;
    r_control_is_data     = 1'b0;
    r_pending_cmd         = 8'h00;
    r_pending_cmd_args    = 2'd0;
    r_pending_cmd_arg_idx = 2'd0;
    r_addressing_mode     = 2'b00;
    r_col_start           = 8'h00;
    r_col_end             = 8'h7F;
    r_page_start          = 3'd0;
    r_page_end            = 3'd3;
    r_curr_col            = 8'h00;
    r_curr_page           = 3'd0;
    r_rx_count            = 0;
    r_cmd_count           = 0;
    O_SDA_DRIVE_LOW       = 1'b0;
    for (int idx = 0; idx < RX_LOG_MAX; idx++) begin
      r_rx_bytes[idx] = 8'h00;
    end
    for (int idx = 0; idx < CMD_LOG_MAX; idx++) begin
      r_cmd_bytes[idx] = 8'h00;
    end
    for (int idx = 0; idx < SSD1306_FRAME_BYTES; idx++) begin
      r_gddram[idx] = 8'h00;
    end
  end

endmodule