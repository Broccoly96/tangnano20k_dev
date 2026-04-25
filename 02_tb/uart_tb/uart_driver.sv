//------------------------------------------------------------------------------
// uart_driver.sv
//------------------------------------------------------------------------------
// Overview:
//   Bit-bangs UART RX toward the DUT using the provided clock to time 8-N-1
//   frames (configurable data/stop bits). Designed for simple TB stimulus.
//
// Instantiation:
//   uart_if uart_bus (.CLK(tb_clk), .RST_N(tb_rst_n));
//   uart_driver #(
//     .CLOCK_FREQ_HZ(50_000_000),
//     .BAUD_RATE(115_200)
//   ) u_uart_drv (
//     .uart(uart_bus)
//   );
//
// Usage:
//   Call wait_reset_release(), then drive data with send_byte/string/bytes or
//   send_random(). Observe byte_sent event or query get_bytes_sent().
//------------------------------------------------------------------------------
`ifndef UART_DRIVER_SV
`define UART_DRIVER_SV

import tb_log_pkg::*;

// Simple UART stimulus driver (8-N-1 framing) that bit-bangs the RX pin of the
// DUT via uart_if. Timing is derived from the supplied clock frequency and baud.
module uart_driver #(
  parameter string       INSTANCE_NAME  = "UART_DRIVER",
  parameter int unsigned CLOCK_FREQ_HZ  = 50_000_000,
  parameter int unsigned BAUD_RATE      = 115_200,
  parameter int unsigned DATA_BITS      = 8,
  parameter int unsigned STOP_BITS      = 1,
  parameter bit          IDLE_LEVEL     = 1'b1
) (
  uart_if.driver uart
);

  // Number of clock cycles that make up a single UART bit period.
  localparam int unsigned BIT_TICKS =
      (BAUD_RATE == 0) ? 0 : ((CLOCK_FREQ_HZ + (BAUD_RATE/2)) / BAUD_RATE);

  event byte_sent;

  logic [DATA_BITS-1:0] last_byte;
  int unsigned          bytes_sent;

  //-------------------------------------------------------------------------
  // Helpers
  //-------------------------------------------------------------------------
  // Keep RX idle until reset deasserts so the DUT does not see spurious edges.
  task automatic wait_reset_release();
    while (!uart.RST_N) begin
      uart.rx <= IDLE_LEVEL;
      @(posedge uart.CLK);
    end
  endtask

  // Optional helper for inserting deterministic gaps between frames.
  task automatic idle_cycles(int unsigned cycles);
    repeat (cycles) @(posedge uart.CLK);
  endtask

  // Low-level routine that drives a constant for the requested bit time span.
  task automatic drive_for_ticks(bit value, int unsigned ticks);
    uart.rx <= value;
    repeat (ticks) @(posedge uart.CLK);
  endtask

  // Bit-level driver honoring the configured baud divider.
  task automatic drive_bit(bit value);
    drive_for_ticks(value, BIT_TICKS);
  endtask

  //-------------------------------------------------------------------------
  // API
  //-------------------------------------------------------------------------

  task automatic send_byte(input logic [DATA_BITS-1:0] data);
    wait_reset_release();

    tb_log_pkg::log_debug(INSTANCE_NAME,
      $sformatf("Sending UART byte 0x%0h (%0d)", data, data));

    // Start bit
    drive_bit(1'b0);

    // Data bits (LSB first)
    for (int bit_idx = 0; bit_idx < DATA_BITS; bit_idx++) begin
      drive_bit(data[bit_idx]);
    end

    // Stop bits
    for (int stop = 0; stop < STOP_BITS; stop++) begin
      drive_bit(1'b1);
    end

    last_byte  = data;
    bytes_sent++;
    -> byte_sent;
  endtask

  task automatic send_bytes(input logic [DATA_BITS-1:0] data_array[]);
    foreach (data_array[i]) begin
      send_byte(data_array[i]);
    end
  endtask

  task automatic send_string(input string message);
    for (int i = 0; i < message.len(); i++) begin
      byte ch = message.getc(i);
      send_byte(ch);
    end
  endtask

  task automatic send_random(
    input int unsigned count,
    input int unsigned seed = 32'h0
  );
    int unsigned local_seed;
    local_seed = (seed == 0) ? $urandom() : seed;
    for (int i = 0; i < count; i++) begin
      local_seed = $urandom(local_seed);
      send_byte(local_seed[DATA_BITS-1:0]);
    end
  endtask

  function int unsigned get_bytes_sent();
    return bytes_sent;
  endfunction

  function logic [DATA_BITS-1:0] get_last_byte();
    return last_byte;
  endfunction

  //-------------------------------------------------------------------------
  // Initialization / Guard rails
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

    uart.rx = IDLE_LEVEL;
    last_byte  = '0;
    bytes_sent = '0;
  end

endmodule

`endif  // UART_DRIVER_SV
