`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Name         :
// Description  :
//////////////////////////////////////////////////////////////////////////////////

module uart_lite_fifo(
  input             I_CLK,
  input             I_RST_N,
  input             I_UART_RX,
  output            O_UART_TX,
  //
  input   [7:0]     I_TX_DATA,
  input             I_TX_DATA_VALID,
  output            O_TX_FIFO_FULL,
  output            O_TX_FIFO_AFULL,
  output  [7:0]     O_RX_DATA,
  input             I_RX_DATA_RDEN,
  output            O_RX_DATA_AVAIL
);


/*---------------------------------------------------------------------------------------------
  Parameters
---------------------------------------------------------------------------------------------*/
  parameter   C_BAUD_COUNT = 104;  // Baud count. 104 x 12Mhz = 115200 baud
  parameter   C_FIFO_DEPTH = 128;
  localparam  C_FIFO_WIDTH = 8;
  localparam  C_ALMOST_EMPTY_THRESHOLD = 2;
  localparam  C_ALMOST_FULL_THRESHOLD  = C_FIFO_DEPTH - 20;


/*---------------------------------------------------------------------------------------------
  Wires
---------------------------------------------------------------------------------------------*/
  wire        s_tx_valid;
  wire        s_tx_busy;

  wire [7:0]  s_rx_data;
  wire        s_rx_valid;
  wire        s_rx_data_valid;
  wire        s_rx_fifo_empty;
  wire        s_rx_fifo_full;

  wire [7:0]  s_tx_fifo_data_o;
  wire        s_tx_fifo_empty;
  wire        s_tx_fifo_full ;

  reg         r_tx_fifo_rden;
  reg         r_tx_start, r_tx_start_q, r_tx_start_rise;


/*---------------------------------------------------------------------------------------------
  UART TX
---------------------------------------------------------------------------------------------*/
  uart_tx_stream #(
    .C_BAUD_COUNT     (C_BAUD_COUNT)
  ) u0_uart_tx(
    .I_CLK          (I_CLK),
    .I_RST_N        (I_RST_N),
    .I_START        (r_tx_start_rise),
    .I_DATA         (s_tx_fifo_data_o),
    .O_UART_TX      (O_UART_TX),
    .O_VALID        (s_tx_valid),
    .O_BUSY         (s_tx_busy)
  );

  // TX FIFO
  sync_fifo_ae_af #(
    .C_DATA_WIDTH             (C_FIFO_WIDTH),
    .C_FIFO_DEPTH             (C_FIFO_DEPTH),
    .C_ALMOST_EMPTY_THRESHOLD (C_ALMOST_EMPTY_THRESHOLD),
    .C_ALMOST_FULL_THRESHOLD  (C_ALMOST_FULL_THRESHOLD))
    u0_uart_tx_fifo (
    .I_CLK                (I_CLK),
    .I_RST_N              (I_RST_N),
    .I_WRITE_EN           (I_TX_DATA_VALID),
    .I_READ_EN            (r_tx_fifo_rden),
    .I_DATA_IN            (I_TX_DATA),
    .O_DATA_OUT           (s_tx_fifo_data_o),
    .O_FIFO_EMPTY         (s_tx_fifo_empty),
    .O_FIFO_FULL          (O_TX_FIFO_FULL),
    .O_FIFO_ALMOST_EMPTY  (),
    .O_FIFO_ALMOST_FULL   (O_TX_FIFO_AFULL)
  );

  always @(posedge I_CLK or negedge I_RST_N) begin
    if(~I_RST_N) begin
      r_tx_start      <= 1'b0;
      r_tx_start_q    <= 1'b0;
      r_tx_fifo_rden  <= 1'b0;
      r_tx_start_rise <= 1'b0;
    end else begin
      r_tx_start      <= (~s_tx_fifo_empty & ~s_tx_busy);
      r_tx_start_q    <= r_tx_start;
      r_tx_fifo_rden  <= r_tx_start & ~r_tx_start_q;
      r_tx_start_rise <= r_tx_fifo_rden;
    end
  end


/*---------------------------------------------------------------------------------------------
  UART RX
---------------------------------------------------------------------------------------------*/
  uart_rx_stream #(
    .C_BAUD_COUNT   (C_BAUD_COUNT)
  ) u0_uart_rx (
    .I_CLK          (I_CLK),
    .I_RST_N        (I_RST_N),
    .I_UART_RX      (I_UART_RX),
    .O_DATA         (s_rx_data),
    .O_VALID        (s_rx_valid)
  );

  // RX FIFO
  sync_fifo_ae_af #(
    .C_DATA_WIDTH             (C_FIFO_WIDTH),
    .C_FIFO_DEPTH             (C_FIFO_DEPTH),
    .C_ALMOST_EMPTY_THRESHOLD (C_ALMOST_EMPTY_THRESHOLD),
    .C_ALMOST_FULL_THRESHOLD  (C_ALMOST_FULL_THRESHOLD))
    u0_uart_rx_fifo (
    .I_CLK                (I_CLK),
    .I_RST_N              (I_RST_N),
    .I_WRITE_EN           (s_rx_valid),
    .I_READ_EN            (I_RX_DATA_RDEN),
    .I_DATA_IN            (s_rx_data),
    .O_DATA_OUT           (O_RX_DATA),
    .O_FIFO_EMPTY         (s_rx_fifo_empty),
    .O_FIFO_FULL          (s_rx_fifo_full),
    .O_FIFO_ALMOST_EMPTY  (),
    .O_FIFO_ALMOST_FULL   ()
  );

  assign O_RX_DATA_AVAIL = ~s_rx_fifo_empty;

/*---------------------------------------------------------------------------------------------
  Simulation
---------------------------------------------------------------------------------------------*/
`ifdef SIM

  import tb_log_pkg::*;

  always @(posedge s_tx_valid)      tb_log_pkg::log_trace("UART Lite", $sformatf("TX sent     DATA: 0x%02h", s_tx_fifo_data_o));
  always @(posedge s_rx_data_valid) tb_log_pkg::log_trace("UART Lite", $sformatf("RX received DATA: 0x%02h", s_rx_data));

`endif


endmodule
