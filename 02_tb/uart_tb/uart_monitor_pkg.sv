//------------------------------------------------------------------------------
// uart_monitor_pkg.sv
//------------------------------------------------------------------------------
// Overview:
//   Common UART monitor types shared between the uart_monitor BFM and
//   testbenches. Provides transaction direction enums and a transaction record
//   struct used for scoreboarding and logging.
//
// Usage example:
//   import uart_monitor_pkg::*;
//
//   uart_monitor_pkg::uart_transaction_t txn;
//   u_uart_mon.get_transaction(txn);
//   $display("[%0t] %s byte=0x%02h err=%0b latency=%0t",
//            txn.end_time,
//            (txn.direction == UART_DIR_FROM_DUT) ? "TX" : "RX",
//            txn.data, txn.framing_error, txn.end_time - txn.start_time);
//------------------------------------------------------------------------------
`ifndef UART_MONITOR_PKG_SV
`define UART_MONITOR_PKG_SV

package uart_monitor_pkg;

  typedef enum bit {
    UART_DIR_TO_DUT   = 1'b0,
    UART_DIR_FROM_DUT = 1'b1
  } uart_direction_e;

  typedef struct {
    bit              valid;
    uart_direction_e direction;
    logic [7:0]      data;
    bit              framing_error;
    time             start_time;
    time             end_time;
  } uart_transaction_t;

endpackage : uart_monitor_pkg

`endif  // UART_MONITOR_PKG_SV

