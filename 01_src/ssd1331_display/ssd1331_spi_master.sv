`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : ssd1331_spi_master.sv
// Description  : Byte-oriented 4-wire SPI sender for SSD1331-style serial write.
//                - Drives SCLK idle low and changes SDIN while SCLK is low.
//                - SSD1331 samples SDIN on each rising edge of SCLK.
//                - Supports multi-byte frames by holding CS# low between bytes.
//////////////////////////////////////////////////////////////////////////////////

module ssd1331_spi_master #(
  parameter int unsigned CLK_DIV = 4
) (
  input  logic       I_CLK,
  input  logic       I_RST_N,
  input  logic       I_TX_VALID,
  output logic       O_TX_READY,
  input  logic [7:0] I_TX_DATA,
  input  logic       I_TX_DC,
  input  logic       I_TX_FIRST,
  input  logic       I_TX_LAST,
  output logic       O_TX_DONE,
  output logic       O_BUSY,
  output logic       O_SPI_CS_N,
  output logic       O_SPI_SCLK,
  output logic       O_SPI_SDIN,
  output logic       O_SPI_DC
);

  localparam int unsigned DIV_W = (CLK_DIV <= 1) ? 1 : $clog2(CLK_DIV);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_CLK_LOW,
    ST_CLK_HIGH,
    ST_WAIT_NEXT
  } st_state_e;

  st_state_e            st_state;
  logic [DIV_W-1:0]     r_div_cnt;
  logic [7:0]           r_shift;
  logic [2:0]           r_bit_idx;
  logic                 r_byte_last;
  logic                 r_spi_cs_n;
  logic                 r_spi_sclk;
  logic                 r_spi_sdin;
  logic                 r_spi_dc;
  logic                 r_tx_done;

  assign O_TX_READY  = (st_state == ST_IDLE) || (st_state == ST_WAIT_NEXT);
  assign O_TX_DONE   = r_tx_done;
  assign O_BUSY      = (st_state != ST_IDLE);
  assign O_SPI_CS_N  = r_spi_cs_n;
  assign O_SPI_SCLK  = r_spi_sclk;
  assign O_SPI_SDIN  = r_spi_sdin;
  assign O_SPI_DC    = r_spi_dc;

  function automatic logic [DIV_W-1:0] div_reload_value;
    begin
      if (CLK_DIV <= 1) begin
        div_reload_value = '0;
      end else begin
        div_reload_value = CLK_DIV - 1;
      end
    end
  endfunction

  task automatic start_byte(
    input logic [7:0] tx_data,
    input logic       tx_dc,
    input logic       tx_first,
    input logic       tx_last
  );
    begin
      r_shift     <= tx_data;
      r_bit_idx   <= 3'd7;
      r_byte_last <= tx_last;
      r_spi_sclk  <= 1'b0;
      r_spi_sdin  <= tx_data[7];
      r_spi_dc    <= tx_dc;
      if (tx_first || r_spi_cs_n) begin
        r_spi_cs_n <= 1'b0;
      end
      r_div_cnt   <= div_reload_value();
      st_state    <= ST_CLK_LOW;
    end
  endtask

  // Serial sender state. Data is only updated while SCLK is low so each rising
  // edge presents a stable SDIN bit to the SSD1331 input shift register.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state    <= ST_IDLE;
      r_div_cnt   <= '0;
      r_shift     <= 8'h00;
      r_bit_idx   <= 3'd0;
      r_byte_last <= 1'b1;
      r_spi_cs_n  <= 1'b1;
      r_spi_sclk  <= 1'b0;
      r_spi_sdin  <= 1'b0;
      r_spi_dc    <= 1'b0;
      r_tx_done   <= 1'b0;
    end else begin
      r_tx_done <= 1'b0;

      case (st_state)
        ST_IDLE: begin
          r_spi_cs_n <= 1'b1;
          r_spi_sclk <= 1'b0;
          if (I_TX_VALID) begin
            start_byte(I_TX_DATA, I_TX_DC, 1'b1, I_TX_LAST);
          end
        end

        ST_CLK_LOW: begin
          if (r_div_cnt != '0) begin
            r_div_cnt <= r_div_cnt - 1'b1;
          end else begin
            r_spi_sclk <= 1'b1;
            r_div_cnt  <= div_reload_value();
            st_state   <= ST_CLK_HIGH;
          end
        end

        ST_CLK_HIGH: begin
          if (r_div_cnt != '0) begin
            r_div_cnt <= r_div_cnt - 1'b1;
          end else begin
            r_spi_sclk <= 1'b0;
            if (r_bit_idx == 3'd0) begin
              r_tx_done <= 1'b1;
              if (r_byte_last) begin
                r_spi_cs_n <= 1'b1;
                st_state   <= ST_IDLE;
              end else begin
                st_state <= ST_WAIT_NEXT;
              end
            end else begin
              r_shift    <= {r_shift[6:0], 1'b0};
              r_bit_idx  <= r_bit_idx - 1'b1;
              r_spi_sdin <= r_shift[6];
              r_div_cnt  <= div_reload_value();
              st_state   <= ST_CLK_LOW;
            end
          end
        end

        ST_WAIT_NEXT: begin
          if (I_TX_VALID) begin
            start_byte(I_TX_DATA, I_TX_DC, I_TX_FIRST, I_TX_LAST);
          end
        end

        default: begin
          st_state <= ST_IDLE;
        end
      endcase
    end
  end

endmodule