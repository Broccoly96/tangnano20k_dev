//------------------------------------------------------------------------------
// uart_monitor.sv
//------------------------------------------------------------------------------
// Overview:
//   Captures UART traffic flowing both into and out of the DUT, reconstructs
//   bytes, and records direction, timestamps, and framing status for scoreboards.
//
// Instantiation:
//   uart_if uart_bus (.CLK(tb_clk), .RST_N(tb_rst_n));
//   uart_monitor #(
//     .CLOCK_FREQ_HZ(50_000_000),
//     .BAUD_RATE(115_200)
//   ) u_uart_mon (
//     .uart(uart_bus)
//   );
//
// Usage:
//   Enable/disable sampling via set_enable(), pull decoded transactions from the
//   txn_mbx using get_transaction()/try_get_transaction(), or watch the
//   transaction_seen event for reactive checkers.
//------------------------------------------------------------------------------
`ifndef UART_MONITOR_SV
`define UART_MONITOR_SV

import tb_log_pkg::*;
import uart_monitor_pkg::*;

module uart_monitor #(
  parameter string       INSTANCE_NAME   = "UART_MONITOR",
  parameter bit          DEFAULT_ENABLE  = 1'b1,
  parameter int unsigned CLOCK_FREQ_HZ   = 50_000_000,
  parameter int unsigned BAUD_RATE       = 115_200,
  parameter int unsigned DATA_BITS       = 8,
  parameter int unsigned STOP_BITS       = 1
) (
  uart_if.monitor uart
);

  localparam int unsigned BIT_TICKS =
      (BAUD_RATE == 0) ? 0 : ((CLOCK_FREQ_HZ + (BAUD_RATE/2)) / BAUD_RATE);
  localparam int unsigned HALF_TICKS = (BIT_TICKS + 1) >> 1;

  typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_state_e;

  typedef struct {
    rx_state_e            state;
    int unsigned          tick_count;
    int unsigned          bit_index;
    int unsigned          stop_count;
    logic [DATA_BITS-1:0] shift_reg;
    bit                   framing_error;
    time                  start_time;
  } uart_line_state_t;

  uart_line_state_t tx_line;
  uart_line_state_t rx_line;

  mailbox #(uart_transaction_t) txn_mbx;
  event transaction_seen;

  bit monitor_enable;
  int unsigned dut_tx_count;
  int unsigned dut_rx_count;
  int unsigned error_count;

  task automatic set_enable(bit enable);
    monitor_enable = enable;
  endtask

  function int unsigned get_tx_count();
    return dut_tx_count;
  endfunction

  function int unsigned get_rx_count();
    return dut_rx_count;
  endfunction

  function int unsigned get_error_count();
    return error_count;
  endfunction

  task automatic get_transaction(output uart_transaction_t txn);
    // Bridge from internal representation to package-visible type.
    uart_transaction_t txn_local;
    txn_mbx.get(txn_local);
    txn = txn_local;
  endtask

  function bit try_get_transaction(output uart_transaction_t txn);
    uart_transaction_t txn_local;
    bit got;

    got = txn_mbx.try_get(txn_local);
    if (got) begin
      txn = txn_local;
    end
    return got;
  endfunction

  task automatic wait_reset_release();
    while (!uart.RST_N) begin
      @(posedge uart.CLK);
    end
  endtask

  //-------------------------------------------------------------------------
  // Implementation
  //-------------------------------------------------------------------------
  // Reinitialize one direction's sampling state machine.
  task automatic reset_line(ref uart_line_state_t line);
    line.state         = RX_IDLE;
    line.tick_count    = '0;
    line.bit_index     = '0;
    line.stop_count    = '0;
    line.shift_reg     = '0;
    line.framing_error = 1'b0;
    line.start_time    = '0;
  endtask

  // Package decoded information and publish it to consumers.
  task automatic push_transaction(
    input uart_direction_e direction,
    input logic [DATA_BITS-1:0] data,
    input bit framing_error,
    input time start_time
  );
    uart_transaction_t txn_local;
    txn_local.valid          = 1'b1;
    txn_local.direction      = direction;
    txn_local.data           = data[7:0];
    txn_local.framing_error  = framing_error;
    txn_local.start_time     = start_time;
    txn_local.end_time       = $time;

    txn_mbx.put(txn_local);
    if (direction == UART_DIR_FROM_DUT) begin
      dut_tx_count++;
    end else begin
      dut_rx_count++;
    end
    if (framing_error) begin
      error_count++;
      tb_log_pkg::log_warn(INSTANCE_NAME,
        $sformatf("%s framing error byte=0x%0h",
          direction == UART_DIR_FROM_DUT ? "TX" : "RX", data));
    end else begin
      tb_log_pkg::log_debug(INSTANCE_NAME,
        $sformatf("%s byte=0x%0h (%0d)",
          direction == UART_DIR_FROM_DUT ? "TX" : "RX", data, data));
    end
    -> transaction_seen;
  endtask

  // Common UART sampler used for both TX/RX directions.
  task automatic handle_line(
    inout uart_line_state_t line,
    input logic line_value,
    input uart_direction_e dir
  );
    case (line.state)
      RX_IDLE: begin
        // Await falling edge that indicates the start bit.
        line.tick_count    = '0;
        line.bit_index     = '0;
        line.stop_count    = '0;
        line.framing_error = 1'b0;
        if (line_value == 1'b0) begin
          line.state      = RX_START;
          line.tick_count = 1;
          line.start_time = $time;
        end
      end

      RX_START: begin
        // Confirm the start bit stayed low at its midpoint.
        line.tick_count++;
        if (line.tick_count >= HALF_TICKS) begin
          if (line_value == 1'b0) begin
            line.state      = RX_DATA;
            line.tick_count = '0;
            line.bit_index  = '0;
          end else begin
            line.state = RX_IDLE;
          end
        end
      end

      RX_DATA: begin
        // Shift in LSB-first data bits once every bit period.
        line.tick_count++;
        if (line.tick_count >= BIT_TICKS) begin
          line.tick_count = '0;
          line.shift_reg[line.bit_index] = line_value;
          line.bit_index++;
          if (line.bit_index >= DATA_BITS) begin
            line.state   = RX_STOP;
            line.stop_count = '0;
          end
        end
      end

      RX_STOP: begin
        // Stop-bit high level indicates clean framing.
        line.tick_count++;
        if (line.tick_count >= BIT_TICKS) begin
          line.tick_count = '0;
          line.stop_count++;
          if (line_value == 1'b0) begin
            line.framing_error = 1'b1;
          end
          if (line.stop_count >= STOP_BITS) begin
            push_transaction(dir, line.shift_reg, line.framing_error, line.start_time);
            line.state = RX_IDLE;
          end
        end
      end
    endcase
  endtask

  always_ff @(posedge uart.CLK or negedge uart.RST_N) begin
    if (!uart.RST_N) begin
      monitor_enable <= DEFAULT_ENABLE;
      dut_tx_count   <= '0;
      dut_rx_count   <= '0;
      error_count    <= '0;
      reset_line(tx_line);
      reset_line(rx_line);
    end else begin
      if (!monitor_enable) begin
        // When disabled, keep state machines idle to avoid partial samples.
        reset_line(tx_line);
        reset_line(rx_line);
      end else begin
        handle_line(tx_line, uart.tx, UART_DIR_FROM_DUT);
        handle_line(rx_line, uart.rx, UART_DIR_TO_DUT);
      end
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

    txn_mbx = new();
  end

endmodule

`endif  // UART_MONITOR_SV
