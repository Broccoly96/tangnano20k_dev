`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : eeprom_i2c_byte_ctrl.sv
// Description  : Open-drain I2C byte controller for EEPROM transactions.
//                - Generates START/STOP conditions.
//                - Writes one byte and samples slave ACK.
//                - Reads one byte and returns it after sending master ACK/NACK.
//////////////////////////////////////////////////////////////////////////////////

module eeprom_i2c_byte_ctrl #(
  parameter int unsigned CLK_HZ          = 48_000_000,
  parameter int unsigned I2C_BIT_RATE_HZ = 100_000
) (
  input  logic       I_CLK,
  input  logic       I_RST_N,
  input  logic       I_OP_VALID,
  output logic       O_OP_READY,
  input  logic [1:0] I_OP,
  input  logic [7:0] I_WR_DATA,
  input  logic       I_RD_SEND_ACK,
  input  logic       I_SDA_IN,
  input  logic       I_SCL_IN,
  output logic       O_SDA_DRIVE_LOW,
  output logic       O_SCL_DRIVE_LOW,
  output logic       O_DONE,
  output logic       O_ACK_OK,
  output logic [7:0] O_RD_DATA,
  output logic       O_BUSY
);

  localparam logic [1:0] OP_START = 2'd1;
  localparam logic [1:0] OP_STOP  = 2'd2;
  localparam logic [1:0] OP_WRITE = 2'd3;
  localparam logic [1:0] OP_READ  = 2'd0;
  localparam int unsigned HALF_PERIOD_CYCLES =
    (CLK_HZ < (I2C_BIT_RATE_HZ * 2)) ? 1 : (CLK_HZ / (I2C_BIT_RATE_HZ * 2));
  localparam int unsigned DIV_W =
    (HALF_PERIOD_CYCLES <= 1) ? 1 : $clog2(HALF_PERIOD_CYCLES);

  logic [1:0] r_op;
  logic [7:0] r_shift_reg;
  logic [2:0] r_bit_idx;
  logic [2:0] r_phase;
  logic [DIV_W-1:0] r_div_cnt;
  logic       r_busy;
  logic       r_sda_drive_low;
  logic       r_scl_drive_low;
  logic       r_rd_send_ack;
  logic       r_ack_ok;
  logic [7:0] r_rd_data;

  assign O_OP_READY       = !r_busy;
  assign O_SDA_DRIVE_LOW  = r_sda_drive_low;
  assign O_SCL_DRIVE_LOW  = r_scl_drive_low;
  assign O_BUSY           = r_busy;
  assign O_ACK_OK         = r_ack_ok;
  assign O_RD_DATA        = r_rd_data;

  // Advances the low-level SCL/SDA waveforms one half-period at a time.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_op             <= OP_READ;
      r_shift_reg      <= 8'h00;
      r_bit_idx        <= 3'd7;
      r_phase          <= 3'd0;
      r_div_cnt        <= '0;
      r_busy           <= 1'b0;
      r_sda_drive_low  <= 1'b0;
      r_scl_drive_low  <= 1'b0;
      r_rd_send_ack    <= 1'b0;
      r_ack_ok         <= 1'b0;
      r_rd_data        <= 8'h00;
      O_DONE           <= 1'b0;
    end else begin
      O_DONE <= 1'b0;

      if (!r_busy) begin
        if (I_OP_VALID) begin
          r_busy        <= 1'b1;
          r_op          <= I_OP;
          r_shift_reg   <= I_WR_DATA;
          r_bit_idx     <= 3'd7;
          r_phase       <= 3'd0;
          r_div_cnt     <= HALF_PERIOD_CYCLES - 1;
          r_rd_send_ack <= I_RD_SEND_ACK;
          r_ack_ok      <= 1'b0;
          r_rd_data     <= 8'h00;

          case (I_OP)
            OP_START: begin
              r_sda_drive_low <= 1'b0;
              r_scl_drive_low <= 1'b0;
            end

            OP_STOP: begin
              r_sda_drive_low <= 1'b1;
              r_scl_drive_low <= 1'b1;
            end

            OP_WRITE: begin
              r_sda_drive_low <= !I_WR_DATA[7];
              r_scl_drive_low <= 1'b1;
            end

            default: begin
              r_sda_drive_low <= 1'b0;
              r_scl_drive_low <= 1'b1;
            end
          endcase
        end
      end else if (r_div_cnt != 0) begin
        r_div_cnt <= r_div_cnt - 1'b1;
      end else begin
        r_div_cnt <= HALF_PERIOD_CYCLES - 1;

        unique case (r_op)
          OP_START: begin
            case (r_phase)
              3'd0: begin
                r_sda_drive_low <= 1'b1;
                r_phase <= 3'd1;
              end

              3'd1: begin
                r_scl_drive_low <= 1'b1;
                r_phase <= 3'd2;
              end

              default: begin
                r_busy <= 1'b0;
                O_DONE <= 1'b1;
              end
            endcase
          end

          OP_STOP: begin
            case (r_phase)
              3'd0: begin
                r_scl_drive_low <= 1'b0;
                r_phase <= 3'd1;
              end

              3'd1: begin
                r_sda_drive_low <= 1'b0;
                r_phase <= 3'd2;
              end

              default: begin
                r_busy <= 1'b0;
                O_DONE <= 1'b1;
              end
            endcase
          end

          OP_WRITE: begin
            case (r_phase)
              3'd0: begin
                r_scl_drive_low <= 1'b0;
                r_phase <= 3'd1;
              end

              3'd1: begin
                r_phase <= 3'd2;
              end

              3'd2: begin
                r_scl_drive_low <= 1'b1;
                if (r_bit_idx != 0) begin
                  r_bit_idx <= r_bit_idx - 1'b1;
                  r_sda_drive_low <= !r_shift_reg[r_bit_idx - 1'b1];
                  r_phase <= 3'd0;
                end else begin
                  r_sda_drive_low <= 1'b0;
                  r_phase <= 3'd3;
                end
              end

              3'd3: begin
                r_scl_drive_low <= 1'b0;
                r_phase <= 3'd4;
              end

              3'd4: begin
                r_ack_ok <= !I_SDA_IN;
                r_phase <= 3'd5;
              end

              3'd5: begin
                r_scl_drive_low <= 1'b1;
                r_phase <= 3'd6;
              end

              default: begin
                r_busy <= 1'b0;
                O_DONE <= 1'b1;
              end
            endcase
          end

          default: begin
            case (r_phase)
              3'd0: begin
                r_scl_drive_low <= 1'b0;
                r_phase <= 3'd1;
              end

              3'd1: begin
                r_rd_data[r_bit_idx] <= I_SDA_IN;
                r_phase <= 3'd2;
              end

              3'd2: begin
                r_scl_drive_low <= 1'b1;
                if (r_bit_idx != 0) begin
                  r_bit_idx <= r_bit_idx - 1'b1;
                  r_phase <= 3'd0;
                end else begin
                  r_sda_drive_low <= r_rd_send_ack;
                  r_phase <= 3'd3;
                end
              end

              3'd3: begin
                r_scl_drive_low <= 1'b0;
                r_phase <= 3'd4;
              end

              3'd4: begin
                r_phase <= 3'd5;
              end

              3'd5: begin
                r_scl_drive_low <= 1'b1;
                r_sda_drive_low <= 1'b0;
                r_phase <= 3'd6;
              end

              default: begin
                r_busy <= 1'b0;
                O_DONE <= 1'b1;
              end
            endcase
          end
        endcase
      end
    end
  end

endmodule