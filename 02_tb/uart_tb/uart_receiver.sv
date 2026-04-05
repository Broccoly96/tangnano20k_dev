//------------------------------------------------------------------------------
// uart_receiver.sv
//------------------------------------------------------------------------------
// Overview:
//   Passive UART sink that samples the DUT TX pin, decodes bytes, and queues
//   results inside a mailbox while reporting framing errors.
//
// Instantiation:
//   uart_if uart_bus (.CLK(tb_clk), .RST_N(tb_rst_n));
//   uart_receiver #(
//     .CLOCK_FREQ_HZ(50_000_000),
//     .BAUD_RATE(115_200)
//   ) u_uart_rx (
//     .uart(uart_bus)
//   );
//
// Usage:
//   Call get_byte()/try_get_byte() to retrieve decoded data or watch the
//   byte_received event. pending_bytes() reports queue depth for checking.
//------------------------------------------------------------------------------
`ifndef UART_RECEIVER_SV
`define UART_RECEIVER_SV

import tb_log_pkg::*;

// Passive UART receiver that samples the DUT TX pin and reports decoded bytes.
module uart_receiver #(
  parameter string       INSTANCE_NAME  = "UART_RECEIVER",
  parameter int unsigned CLOCK_FREQ_HZ  = 50_000_000,
  parameter int unsigned BAUD_RATE      = 115_200,
  parameter int unsigned DATA_BITS      = 8,
  parameter int unsigned STOP_BITS      = 1
) (
  uart_if.receiver uart
);

  // Bit-time expressed in clock cycles.
  localparam int unsigned BIT_TICKS =
      (BAUD_RATE == 0) ? 0 : ((CLOCK_FREQ_HZ + (BAUD_RATE/2)) / BAUD_RATE);
  localparam int unsigned HALF_TICKS = (BIT_TICKS + 1) >> 1;

  typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_state_e;

  rx_state_e                rx_state;
  int unsigned              tick_count;
  int unsigned              bit_index;
  int unsigned              stop_count;
  logic [DATA_BITS-1:0]     shift_reg;
  bit                       framing_error;
  logic [DATA_BITS-1:0]     data_sample;

  mailbox #(logic [DATA_BITS-1:0]) rx_mbx;

  event                     byte_received;
  logic [DATA_BITS-1:0]     last_byte;
  int unsigned              bytes_seen;
  int unsigned              framing_errors;

  // Allow environments to block on reset release before expecting traffic.
  task automatic wait_reset_release();
    while (!uart.RST_N) begin
      @(posedge uart.CLK);
    end
  endtask

  task automatic get_byte(output logic [DATA_BITS-1:0] data);
    rx_mbx.get(data);
  endtask

  function bit try_get_byte(output logic [DATA_BITS-1:0] data);
    return rx_mbx.try_get(data);
  endfunction

  function int unsigned pending_bytes();
    return rx_mbx.num();
  endfunction

  function int unsigned get_framing_errors();
    return framing_errors;
  endfunction

  function logic [DATA_BITS-1:0] get_last_byte();
    return last_byte;
  endfunction

  //-------------------------------------------------------------------------
  // Sampling logic
  //-------------------------------------------------------------------------
  always_ff @(posedge uart.CLK or negedge uart.RST_N) begin
    if (!uart.RST_N) begin
      rx_state       <= RX_IDLE;
      tick_count     <= '0;
      bit_index      <= '0;
      stop_count     <= '0;
      shift_reg      <= '0;
      framing_error  <= 1'b0;
    end else begin
      case (rx_state)
        RX_IDLE: begin
          // Waiting for start bit (line pulled low).
          tick_count    <= '0;
          bit_index     <= '0;
          stop_count    <= '0;
          framing_error <= 1'b0;

          if (uart.tx == 1'b0) begin
            rx_state   <= RX_START;
            tick_count <= 1;
          end
        end

        RX_START: begin
          // Sample in the middle of the start bit to confirm it is stable.
          tick_count <= tick_count + 1;
          if (tick_count >= HALF_TICKS) begin
            if (uart.tx == 1'b0) begin
              rx_state   <= RX_DATA;
              tick_count <= '0;
              bit_index  <= '0;
            end else begin
              rx_state <= RX_IDLE;  // False start bit
            end
          end
        end

        RX_DATA: begin
          // Shift in DATA_BITS LSB-first samples once per bit period.
          tick_count <= tick_count + 1;
          if (tick_count >= BIT_TICKS) begin
            tick_count        <= '0;
            shift_reg[bit_index] <= uart.tx;
            bit_index         <= bit_index + 1;
            if (bit_index + 1 >= DATA_BITS) begin
              rx_state   <= RX_STOP;
              stop_count <= '0;
            end
          end
        end

        RX_STOP: begin
          // Verify stop bits remain high; flag framing_error if not.
          tick_count <= tick_count + 1;
          if (tick_count >= BIT_TICKS) begin
            tick_count <= '0;
            stop_count <= stop_count + 1;
            if (uart.tx != 1'b1) begin
              framing_error <= 1'b1;
            end
            if (stop_count + 1 >= STOP_BITS) begin
              rx_state   <= RX_IDLE;
              stop_count <= '0;

              data_sample = shift_reg;

              rx_mbx.put(data_sample);
              last_byte = data_sample;
              bytes_seen++;
              if (framing_error) begin
                framing_errors++;
                tb_log_pkg::log_warn(INSTANCE_NAME,
                  $sformatf("RX framing error byte=0x%0h (stop bit low)", data_sample));
              end else begin
                tb_log_pkg::log_info(INSTANCE_NAME,
                  $sformatf("RX byte=0x%0h (%0d)", data_sample, data_sample));
              end
              -> byte_received;
            end
          end
        end
      endcase
    end
  end

  //-------------------------------------------------------------------------
  // Initialization / Guards
  //-------------------------------------------------------------------------
  initial begin
    tb_log_pkg::configure_from_plusargs();

    if (BIT_TICKS == 0) begin
      tb_log_pkg::log_fatal(1, INSTANCE_NAME,
        $sformatf("Invalid configuration: CLOCK_FREQ_HZ=%0d BAUD_RATE=%0d results in zero BIT_TICKS.",
          CLOCK_FREQ_HZ, BAUD_RATE));
    end

    if (DATA_BITS == 0) begin
      tb_log_pkg::log_fatal(1, INSTANCE_NAME, "DATA_BITS must be >= 1.");
    end

    if (STOP_BITS == 0) begin
      tb_log_pkg::log_fatal(1, INSTANCE_NAME, "STOP_BITS must be >= 1.");
    end

    rx_mbx = new();
    bytes_seen = '0;
    framing_errors = '0;
    last_byte = '0;
  end

endmodule

`endif  // UART_RECEIVER_SV
