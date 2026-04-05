//------------------------------------------------------------------------------
// uart_if.sv
//------------------------------------------------------------------------------

interface uart_if #(
  parameter bit RESET_IDLE_LEVEL = 1'b1  // Idle level driven onto RX while reset
) (
  input  logic CLK,
  input  logic RST_N
);

  // Physical UART pins (full-duplex, no flow control)
  logic tx;  // Driven by DUT, observed by TB
  logic rx;  // Driven by TB, observed by DUT

  // Ensure RX sits at a legal idle value during reset.
  initial begin
    rx = RESET_IDLE_LEVEL;
  end

  // Convenience modport for DUT instantiation.
  modport dut (
    input  CLK,
    input  RST_N,
    input  rx,
    output tx
  );

  // Active driver: pushes traffic into the DUT over RX.
  modport driver (
    input  CLK,
    input  RST_N,
    output rx,
    input  tx
  );

  // Passive receiver: samples the DUT TX line.
  modport receiver (
    input  CLK,
    input  RST_N,
    input  tx
  );

  // Passive monitor for scoreboards or coverage.
  modport monitor (
    input CLK,
    input RST_N,
    input tx,
    input rx
  );

endinterface
