`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Name         :
// Description  :
//////////////////////////////////////////////////////////////////////////////////

module uart_lite(
  input             I_CLK,
  input             I_RST_N,
  input             I_UART_RX,
  output            O_UART_TX,
  //
  input   [7:0]     I_TX_DATA,
  input             I_TX_START,
  output            O_TX_VALID,
  output            O_TX_BUSY,
  output  [7:0]     O_RX_DATA,
  output            O_RX_VALID
);


/*---------------------------------------------------------------------------------------------
  Parameters
---------------------------------------------------------------------------------------------*/
  parameter   C_BAUD_COUNT = 104;  // Baud count. 104 x 12Mhz = 115200 baud


/*---------------------------------------------------------------------------------------------
  Wires
---------------------------------------------------------------------------------------------*/
  wire [7:0]  s_tx_data;
  wire        s_tx_valid;
  wire        s_tx_start;
  wire        s_tx_busy;

  wire [7:0]  s_rx_data;
  wire        s_rx_valid;


/*---------------------------------------------------------------------------------------------
  UART TX
---------------------------------------------------------------------------------------------*/
  uart_tx_stream #(
    .C_BAUD_COUNT     (C_BAUD_COUNT)
  ) u0_uart_tx(
    .I_CLK          (I_CLK),
    .I_RST_N        (I_RST_N),
    .I_START        (I_TX_START),
    .I_DATA         (I_TX_DATA),
    .O_UART_TX      (O_UART_TX),
    .O_VALID        (O_TX_VALID),
    .O_BUSY         (O_TX_BUSY)
  );


/*---------------------------------------------------------------------------------------------
  UART RX
---------------------------------------------------------------------------------------------*/
  uart_rx_stream #(
    .C_BAUD_COUNT     (C_BAUD_COUNT)
  ) u0_uart_rx (
    .I_CLK          (I_CLK),
    .I_RST_N        (I_RST_N),
    .I_UART_RX      (I_UART_RX),
    .O_DATA         (O_RX_DATA),
    .O_VALID        (O_RX_VALID)
  );


/*---------------------------------------------------------------------------------------------
  Simulation
---------------------------------------------------------------------------------------------*/
`ifdef SIM

`timescale  1ns / 1ps

  always @(posedge I_CLK) if(s_tx_valid) $display($time,"  UART Lite"," TX sent    "," DATA: %2s", s_tx_data);
  always @(posedge I_CLK) if(s_rx_valid) $display($time,"  UART Lite"," RX received"," DATA: %2s", s_rx_data);

`endif


endmodule