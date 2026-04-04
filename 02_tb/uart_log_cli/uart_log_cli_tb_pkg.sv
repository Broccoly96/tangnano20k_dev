`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_cli_tb_pkg.sv
// Description  : Common helper functions and tasks for uart_log_cli smoke tests.
//////////////////////////////////////////////////////////////////////////////////

package uart_log_cli_tb_pkg;

  localparam logic [7:0] UART_SYNC_BYTE = 8'h7E;

  function automatic logic [7:0] crc8_atm_update(
    input logic [7:0] crc_in,
    input logic [7:0] data_byte
  );
    logic [7:0] crc;
    begin
      crc = crc_in ^ data_byte;
      for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
        if (crc[7]) begin
          crc = (crc << 1) ^ 8'h07;
        end else begin
          crc = (crc << 1);
        end
      end
      crc8_atm_update = crc;
    end
  endfunction

  function automatic logic [7:0] calc_frame_crc(
    input logic [7:0] seq,
    input logic [127:0] payload
  );
    logic [7:0] crc;
    begin
      crc = 8'h00;
      crc = crc8_atm_update(crc, seq);
      for (int byte_idx = 0; byte_idx < 16; byte_idx++) begin
        crc = crc8_atm_update(crc, payload[byte_idx*8 +: 8]);
      end
      calc_frame_crc = crc;
    end
  endfunction

  task automatic send_uart_byte(
    ref logic uart_line,
    input time bit_period,
    input logic [7:0] tx_byte
  );
    begin
      uart_line = 1'b0;
      #(bit_period);
      for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
        uart_line = tx_byte[bit_idx];
        #(bit_period);
      end
      uart_line = 1'b1;
      #(bit_period);
    end
  endtask

  task automatic recv_uart_byte(
    ref logic uart_line,
    input time bit_period,
    output logic [7:0] rx_byte
  );
    begin
      @(negedge uart_line);
      #(bit_period + (bit_period / 2));
      for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
        rx_byte[bit_idx] = uart_line;
        #(bit_period);
      end
      #(bit_period);
    end
  endtask

  task automatic recv_uart_frame(
    ref logic uart_line,
    input time bit_period,
    output logic [7:0] seq,
    output logic [127:0] payload,
    output logic [7:0] crc
  );
    logic [7:0] rx_byte;
    begin
      payload = '0;
      crc = '0;
      do begin
        recv_uart_byte(uart_line, bit_period, rx_byte);
      end while (rx_byte != UART_SYNC_BYTE);

      recv_uart_byte(uart_line, bit_period, seq);
      for (int byte_idx = 0; byte_idx < 16; byte_idx++) begin
        recv_uart_byte(uart_line, bit_period, rx_byte);
        payload[byte_idx*8 +: 8] = rx_byte;
      end
      recv_uart_byte(uart_line, bit_period, crc);
    end
  endtask

  task automatic recv_mirror_frame(
    ref logic mirror_valid,
    ref logic [7:0] mirror_data,
    output logic [7:0] seq,
    output logic [127:0] payload,
    output logic [7:0] crc
  );
    logic [7:0] rx_byte;
    begin
      payload = '0;
      crc = '0;
      do begin
        @(posedge mirror_valid);
        rx_byte = mirror_data;
      end while (rx_byte != UART_SYNC_BYTE);

      @(posedge mirror_valid);
      seq = mirror_data;

      for (int byte_idx = 0; byte_idx < 16; byte_idx++) begin
        @(posedge mirror_valid);
        payload[byte_idx*8 +: 8] = mirror_data;
      end

      @(posedge mirror_valid);
      crc = mirror_data;
    end
  endtask

endpackage
