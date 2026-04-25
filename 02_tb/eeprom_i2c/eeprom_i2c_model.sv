`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : eeprom_i2c_model.sv
// Description  : Behavioral 24FC1025 model used by unit-level simulations.
//                - Supports byte/page write, random read, and sequential read.
//                - ACK polling NACKs while the internal write cycle is active.
//////////////////////////////////////////////////////////////////////////////////

module eeprom_i2c_model #(
  parameter logic [1:0] CHIP_SELECT        = 2'b00,
  parameter int unsigned WRITE_BUSY_CYCLES = 4096
) (
  input  logic I_CLK,
  input  logic I_RST_N,
  input  logic I_SCL,
  input  logic I_SDA,
  output logic O_SDA_DRIVE_LOW
);

  import eeprom_uart_proto_pkg::*;

  typedef enum logic [2:0] {
    ST_WAIT_CTRL,
    ST_WAIT_ADDR_HI,
    ST_WAIT_ADDR_LO,
    ST_WAIT_WRITE_DATA,
    ST_SEND_READ_DATA
  } st_state_e;

  st_state_e st_state;

  logic [7:0] r_shift_rx;
  logic [7:0] r_shift_tx;
  logic [2:0] r_rx_bit_idx;
  logic [2:0] r_tx_bit_idx;
  logic       r_receiving;
  logic       r_transmitting;
  logic       r_wait_master_ack;
  logic       r_ack_pending;
  logic       r_ack_value;
  logic       r_ack_driving;
  logic       r_block_sel;
  logic       r_have_pointer;
  logic       r_write_seen_data;
  logic [16:0] r_pointer_addr;
  logic [15:0] r_busy_countdown;
  logic [7:0]  r_mem [0:EEPROM_MAX_ADDR];

  function automatic logic control_byte_matches(input logic [7:0] byte_value);
    begin
      control_byte_matches =
        (byte_value[7:4] == EEPROM_I2C_CTRL_CODE) &&
        (byte_value[2:1] == CHIP_SELECT);
    end
  endfunction

  task automatic prepare_tx_byte;
    begin
      r_shift_tx        = r_mem[r_pointer_addr];
      r_tx_bit_idx      = 3'd7;
      r_transmitting    = 1'b1;
      r_wait_master_ack = 1'b0;
      O_SDA_DRIVE_LOW   = !r_mem[r_pointer_addr][7];
    end
  endtask

  task automatic advance_write_pointer;
    logic [6:0] next_page_offset;
    begin
      next_page_offset = r_pointer_addr[6:0] + 1'b1;
      r_pointer_addr   = {r_pointer_addr[16:7], next_page_offset};
    end
  endtask

  task automatic advance_read_pointer;
    logic [15:0] next_block_offset;
    begin
      next_block_offset = r_pointer_addr[15:0] + 1'b1;
      r_pointer_addr    = {r_pointer_addr[16], next_block_offset};
    end
  endtask

  task automatic complete_rx_byte(input logic [7:0] byte_value);
    begin
      r_ack_value = 1'b0;

      case (st_state)
        ST_WAIT_CTRL: begin
          if (control_byte_matches(byte_value) && (r_busy_countdown == 0)) begin
            r_block_sel = byte_value[3];
            if (byte_value[0]) begin
              if (r_have_pointer) begin
                st_state = ST_SEND_READ_DATA;
              end
            end else begin
              st_state = ST_WAIT_ADDR_HI;
            end
          end else begin
            r_ack_value = 1'b1;
          end
        end

        ST_WAIT_ADDR_HI: begin
          r_pointer_addr[16]   = r_block_sel;
          r_pointer_addr[15:8] = byte_value;
          st_state             = ST_WAIT_ADDR_LO;
        end

        ST_WAIT_ADDR_LO: begin
          r_pointer_addr[7:0] = byte_value;
          r_have_pointer      = 1'b1;
          st_state            = ST_WAIT_WRITE_DATA;
        end

        ST_WAIT_WRITE_DATA: begin
          r_mem[r_pointer_addr] = byte_value;
          r_write_seen_data     = 1'b1;
          advance_write_pointer();
        end

        default: begin
        end
      endcase

      r_ack_pending = 1'b1;
      r_ack_driving = 1'b0;
      r_receiving   = 1'b0;
    end
  endtask

  // Models the EEPROM write-cycle busy window after a STOP.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_busy_countdown <= '0;
      for (int idx = 0; idx <= EEPROM_MAX_ADDR; idx++) begin
        r_mem[idx] <= idx[7:0];
      end
    end else if (r_busy_countdown != 0) begin
      r_busy_countdown <= r_busy_countdown - 1'b1;
    end
  end

  // START resets the byte framing state but preserves the current memory pointer
  // so repeated-start random reads can reuse the just-written address bytes.
  always @(negedge I_SDA) begin
    if (I_SCL === 1'b1) begin
      O_SDA_DRIVE_LOW  <= 1'b0;
      r_receiving      <= 1'b1;
      r_transmitting   <= 1'b0;
      r_wait_master_ack<= 1'b0;
      r_ack_pending    <= 1'b0;
      r_ack_driving    <= 1'b0;
      r_rx_bit_idx     <= 3'd7;
      r_shift_rx       <= 8'h00;
      st_state         <= ST_WAIT_CTRL;
    end
  end

  // STOP ends the current transaction and starts the internal write cycle when
  // any page-write data bytes were accepted.
  always @(posedge I_SDA) begin
    if (I_SCL === 1'b1) begin
      O_SDA_DRIVE_LOW   <= 1'b0;
      r_receiving       <= 1'b0;
      r_transmitting    <= 1'b0;
      r_wait_master_ack <= 1'b0;
      r_ack_pending     <= 1'b0;
      r_ack_driving     <= 1'b0;
      if (r_write_seen_data) begin
        r_busy_countdown <= WRITE_BUSY_CYCLES[15:0];
      end
      r_write_seen_data <= 1'b0;
    end
  end

  // Samples bytes from the master and the master's ACK/NACK after slave reads.
  always @(posedge I_SCL) begin
    if (r_receiving) begin
      r_shift_rx[r_rx_bit_idx] <= I_SDA;
      if (r_rx_bit_idx == 0) begin
        complete_rx_byte({r_shift_rx[7:1], I_SDA});
      end else begin
        r_rx_bit_idx <= r_rx_bit_idx - 1'b1;
      end
    end else if (r_wait_master_ack) begin
      if (I_SDA == 1'b0) begin
        advance_read_pointer();
        prepare_tx_byte();
      end else begin
        r_wait_master_ack <= 1'b0;
        r_transmitting    <= 1'b0;
        O_SDA_DRIVE_LOW   <= 1'b0;
      end
    end else if (r_transmitting) begin
      if (r_tx_bit_idx == 0) begin
        r_transmitting    <= 1'b0;
        r_wait_master_ack <= 1'b1;
      end else begin
        r_tx_bit_idx <= r_tx_bit_idx - 1'b1;
      end
    end
  end

  // Updates SDA on falling SCL edges so bits are stable before the next sample.
  always @(negedge I_SCL) begin
    if (r_ack_pending) begin
      if (!r_ack_driving) begin
        O_SDA_DRIVE_LOW <= !r_ack_value;
        r_ack_driving   <= 1'b1;
      end else begin
        r_ack_pending   <= 1'b0;
        r_ack_driving   <= 1'b0;
        if ((st_state == ST_SEND_READ_DATA) && !r_ack_value) begin
          prepare_tx_byte();
        end else begin
          O_SDA_DRIVE_LOW <= 1'b0;
          r_receiving  <= 1'b1;
          r_rx_bit_idx <= 3'd7;
        end
      end
    end else if (r_wait_master_ack) begin
      O_SDA_DRIVE_LOW <= 1'b0;
    end else if (r_transmitting) begin
      O_SDA_DRIVE_LOW <= !r_shift_tx[r_tx_bit_idx];
    end
  end

  initial begin
    st_state          = ST_WAIT_CTRL;
    r_shift_rx        = 8'h00;
    r_shift_tx        = 8'h00;
    r_rx_bit_idx      = 3'd7;
    r_tx_bit_idx      = 3'd7;
    r_receiving       = 1'b0;
    r_transmitting    = 1'b0;
    r_wait_master_ack = 1'b0;
    r_ack_pending     = 1'b0;
    r_ack_value       = 1'b0;
    r_ack_driving     = 1'b0;
    r_block_sel       = 1'b0;
    r_have_pointer    = 1'b0;
    r_write_seen_data = 1'b0;
    r_pointer_addr    = '0;
    r_busy_countdown  = '0;
    O_SDA_DRIVE_LOW   = 1'b0;
  end

endmodule