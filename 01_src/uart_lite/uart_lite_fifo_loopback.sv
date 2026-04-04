`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Name         :
// Description  :
//////////////////////////////////////////////////////////////////////////////////

module uart_lite_fifo_loopback(
  input             I_CLK,
  input             I_RST_N,
  input             I_UART_RX,
  output            O_UART_TX,
  output  [7:0]     O_RX_DATA
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
  wire        s_rx_data_valid;
  wire        s_rx_fifo_empty;
  wire        s_rx_fifo_full;
  wire        s_rx_data_avail;
  reg         r_rx_data_rden;

  wire [7:0]  s_tx_fifo_data_o;
  wire        s_tx_fifo_empty;
  wire        s_tx_fifo_full;
  reg         r_tx_data_valid;

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
    .I_WRITE_EN           (r_tx_data_valid),
    .I_READ_EN            (r_tx_fifo_rden),
    .I_DATA_IN            (O_RX_DATA),
    .O_DATA_OUT           (s_tx_fifo_data_o),
    .O_FIFO_EMPTY         (s_tx_fifo_empty),
    .O_FIFO_FULL          (s_tx_fifo_full),
    .O_FIFO_ALMOST_EMPTY  (),
    .O_FIFO_ALMOST_FULL   ()
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
    .O_VALID        (s_rx_data_valid)
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
    .I_WRITE_EN           (s_rx_data_valid),
    .I_READ_EN            (r_rx_data_rden),
    .I_DATA_IN            (s_rx_data),
    .O_DATA_OUT           (O_RX_DATA),
    .O_FIFO_EMPTY         (s_rx_fifo_empty),
    .O_FIFO_FULL          (s_rx_fifo_full),
    .O_FIFO_ALMOST_EMPTY  (),
    .O_FIFO_ALMOST_FULL   ()
  );

  assign s_rx_data_avail = ~s_rx_fifo_empty;



/*---------------------------------------------------------------------------------------------
  UART Loopback
---------------------------------------------------------------------------------------------*/
  typedef enum reg [2:0] {IDLE, READ, LOOPBACK} uart_loopback;
  uart_loopback st_state, st_nextstate;

  //
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if(~I_RST_N)  st_state <= IDLE;
    else          st_state <= st_nextstate;
  end

  // Conditions
  always @(*) begin

    st_nextstate = st_state;

    case(st_state)
      IDLE:       if(s_rx_data_avail) st_nextstate = READ;
      READ:                           st_nextstate = LOOPBACK;
      LOOPBACK:                       st_nextstate = IDLE;
    endcase
  end

  // Actions
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if(~I_RST_N) begin
      r_rx_data_rden  <= 1'b0;
      r_tx_data_valid <= 1'b0;
    end else begin
      case(st_state)
        IDLE: begin
          r_rx_data_rden  <= 1'b0;
          r_tx_data_valid <= 1'b0;
        end
        READ: begin
          r_rx_data_rden  <= 1'b1;
          r_tx_data_valid <= 1'b0;
        end
        LOOPBACK: begin
          r_rx_data_rden  <= 1'b0;
          r_tx_data_valid <= 1'b1;
        end
      endcase
    end
  end


/*---------------------------------------------------------------------------------------------
  Simulation
---------------------------------------------------------------------------------------------*/
`ifdef SIM

  import tb_log_pkg::*;

  always @(posedge s_tx_valid)      tb_log_pkg::log_trace("UART Lite", $sformatf("TX sent     DATA: 0x%02h", s_tx_fifo_data_o));
  always @(posedge s_rx_data_valid) tb_log_pkg::log_trace("UART Lite", $sformatf("RX received DATA: 0x%02h", s_rx_data));

`endif


endmodule