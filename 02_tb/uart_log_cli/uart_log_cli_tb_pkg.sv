`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_cli_tb_pkg.sv
// Description  : UART log CLI testbench helper package.
//                Provides frame/payload decode helpers, CRC re-calculation, and
//                ASCII(12-byte) extraction helpers for EV_HELP checks.
//
// Usage example:
//   import uart_log_cli_tb_pkg::*;
//   uart_log_payload_t payload;
//   payload = decode_payload(frame.payload);
//////////////////////////////////////////////////////////////////////////////////
`ifndef UART_LOG_CLI_TB_PKG_SV
`define UART_LOG_CLI_TB_PKG_SV

package uart_log_cli_tb_pkg;

  import uart_log_cli_pkg::*;

  typedef struct packed {
    logic [7:0]   sync;
    logic [7:0]   seq;
    logic [127:0] payload;
    logic [7:0]   crc;
  } uart_log_frame_t;

  typedef struct packed {
    logic [7:0]  src_id;
    logic [7:0]  event_id;
    logic [15:0] timestamp;
    logic [31:0] arg0;
    logic [31:0] arg1;
    logic [31:0] arg2;
  } uart_log_payload_t;

  localparam logic [7:0] UART_SYNC_BYTE = 8'h7E;

  //------------------------------------------------------------------------------
  // CRC helpers
  //------------------------------------------------------------------------------
  // Re-computes CRC8/ATM over {SEQ, PAYLOAD[0..15]} to verify frame integrity.
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
    input logic [7:0]   seq,
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

  //------------------------------------------------------------------------------
  // decode_payload
  //------------------------------------------------------------------------------
  // Splits the 16-byte payload into fixed fields:
  //   Word0 = {src_id, event_id, timestamp}
  //   Word1 = arg0
  //   Word2 = arg1
  //   Word3 = arg2
  function automatic uart_log_payload_t decode_payload(input logic [127:0] payload);
    uart_log_payload_t dec;
    begin
      dec.src_id    = payload[31:24];
      dec.event_id  = payload[23:16];
      dec.timestamp = payload[15:0];
      dec.arg0      = payload[63:32];
      dec.arg1      = payload[95:64];
      dec.arg2      = payload[127:96];
      decode_payload = dec;
    end
  endfunction

  //------------------------------------------------------------------------------
  // calc_expected_crc / is_crc_ok
  //------------------------------------------------------------------------------
  function automatic logic [7:0] calc_expected_crc(input uart_log_frame_t frame);
    begin
      calc_expected_crc = calc_frame_crc(frame.seq, frame.payload);
    end
  endfunction

  function automatic logic is_crc_ok(input uart_log_frame_t frame);
    begin
      is_crc_ok = (calc_expected_crc(frame) == frame.crc);
    end
  endfunction

  //------------------------------------------------------------------------------
  // extract_ascii12 / extract_ascii12_from_payload
  //------------------------------------------------------------------------------
  // Returns ASCII bytes [11:0] packed into 96 bits where:
  //   [7:0]   = first character,
  //   [15:8]  = second character, ...
  function automatic logic [95:0] extract_ascii12(
    input logic [31:0] arg0,
    input logic [31:0] arg1,
    input logic [31:0] arg2
  );
    logic [95:0] ascii12;
    begin
      ascii12[7:0]    = arg0[7:0];
      ascii12[15:8]   = arg0[15:8];
      ascii12[23:16]  = arg0[23:16];
      ascii12[31:24]  = arg0[31:24];
      ascii12[39:32]  = arg1[7:0];
      ascii12[47:40]  = arg1[15:8];
      ascii12[55:48]  = arg1[23:16];
      ascii12[63:56]  = arg1[31:24];
      ascii12[71:64]  = arg2[7:0];
      ascii12[79:72]  = arg2[15:8];
      ascii12[87:80]  = arg2[23:16];
      ascii12[95:88]  = arg2[31:24];
      extract_ascii12 = ascii12;
    end
  endfunction

  function automatic logic [95:0] extract_ascii12_from_payload(input logic [127:0] payload);
    uart_log_payload_t dec;
    begin
      dec = decode_payload(payload);
      extract_ascii12_from_payload = extract_ascii12(dec.arg0, dec.arg1, dec.arg2);
    end
  endfunction

  //------------------------------------------------------------------------------
  // UART / mirror frame transport helpers
  //------------------------------------------------------------------------------
  task automatic send_uart_byte(
    ref logic       uart_line,
    input time      bit_period,
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
    ref logic       uart_line,
    input time      bit_period,
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
    ref logic         uart_line,
    input time        bit_period,
    output logic [7:0]   seq,
    output logic [127:0] payload,
    output logic [7:0]   crc
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
    ref logic         mirror_valid,
    ref logic [7:0]   mirror_data,
    output logic [7:0]   seq,
    output logic [127:0] payload,
    output logic [7:0]   crc
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

endpackage : uart_log_cli_tb_pkg

`endif  // UART_LOG_CLI_TB_PKG_SV
