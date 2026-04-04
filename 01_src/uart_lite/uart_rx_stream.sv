//////////////////////////////////////////////////////////////////////////////////
// Name         : uart_rx
// Description  : UART Receive module.
//////////////////////////////////////////////////////////////////////////////////

module uart_rx_stream (
    input I_CLK,
    input I_RST_N,
    input I_UART_RX,

    output reg [7:0] O_DATA,
    output reg       O_VALID
);

  //---------------------------------------------------------------------------------------------
  // Parameters
  //---------------------------------------------------------------------------------------------
  parameter C_BAUD_COUNT = 104;  // Baud count. 104 x 12Mhz = 115200 baud


  //---------------------------------------------------------------------------------------------
  // Wires and Regs
  //---------------------------------------------------------------------------------------------
  reg        sr_start_det;
  reg        sr_receive_flag;
  reg [ 4:0] sr_receive_cnt;
  reg [ 2:0] sr_uart_rx_buff;
  reg        sr_uart_rx_sync;
  reg [15:0] sr_baud_cnt;  // 16bit counter
  reg        sr_baud_edge;


  //---------------------------------------------------------------------------------------------
  // Sync UART_RX to clock
  //---------------------------------------------------------------------------------------------
  always @(posedge I_CLK or negedge I_RST_N) begin
    if (~I_RST_N) begin
      sr_uart_rx_buff <= 3'b111;
      sr_uart_rx_sync <= 1'b1;
    end else begin
      // Buffering
      sr_uart_rx_buff <= {sr_uart_rx_buff[1:0], I_UART_RX};
      // Synched
      sr_uart_rx_sync <= sr_uart_rx_buff[2];
    end
  end


  //---------------------------------------------------------------------------------------------
  // State machine
  //  Default state is IDLE.
  //---------------------------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    START,
    DATA,
    STOP
  } uart_states;
  uart_states st_state, st_nextstate;

  always @(posedge I_CLK or negedge I_RST_N) begin
    if (~I_RST_N) st_state <= IDLE;  // Default State is IDLE
    else st_state <= st_nextstate;  // Transition to nextstate at every clock
  end

  always @(*) begin
    // Keep same state when no conditions are met.
    st_nextstate = st_state;

    // State transit conditions
    case (st_state)
      IDLE:  if (sr_start_det) st_nextstate = START;
      START: if (sr_baud_edge) st_nextstate = DATA;
      DATA:  if (sr_baud_edge & sr_receive_cnt == 5'd8) st_nextstate = STOP;
      STOP:  if (sr_baud_edge) st_nextstate = IDLE;
    endcase
  end


  //---------------------------------------------------------------------------------------------
  // Baud counter
  //  Generates 1clock pulse when counter is reaches full Baudcount. For FSM transition.
  //  Generates 1clock pulse when counter is at half Baudcount. For receiving UART data.
  //---------------------------------------------------------------------------------------------
  always @(posedge I_CLK or negedge I_RST_N) begin
    if (~I_RST_N) begin
      sr_baud_cnt     <= '0;
      sr_receive_flag <= '0;
      sr_baud_edge    <= '0;
    end else if (st_state == IDLE) begin
      sr_baud_cnt     <= '0;
      sr_receive_flag <= '0;
      sr_baud_edge    <= '0;
    end else if (sr_baud_cnt == C_BAUD_COUNT / 2 - 1) begin
      sr_baud_cnt     <= sr_baud_cnt + 1'b1;
      sr_receive_flag <= 1'b1;
    end else if (sr_baud_cnt == C_BAUD_COUNT - 1) begin
      sr_baud_cnt  <= '0;
      sr_baud_edge <= 1'b1;
    end else begin
      sr_baud_cnt     <= sr_baud_cnt + 1'b1;
      sr_receive_flag <= '0;
      sr_baud_edge    <= '0;
    end
  end

  //---------------------------------------------------------------------------------------------
  // TX data
  //---------------------------------------------------------------------------------------------
  // TX data counter
  always @(posedge I_CLK or negedge I_RST_N) begin
    if (~I_RST_N) sr_receive_cnt <= '0;
    else begin
      case (st_state)
        IDLE:  sr_receive_cnt <= '0;
        START: sr_receive_cnt <= '0;
        DATA:  if (sr_receive_flag) sr_receive_cnt <= sr_receive_cnt + 1'b1;
        STOP:  sr_receive_cnt <= '0;
      endcase
    end
  end


  //---------------------------------------------------------------------------------------------
  // START bit detect
  //---------------------------------------------------------------------------------------------
  always @(posedge I_CLK or negedge I_RST_N) begin
    if (~I_RST_N) sr_start_det <= '0;
    else begin
      case (st_state)
        IDLE:    sr_start_det <= ~sr_uart_rx_sync;
        default: sr_start_det <= '0;
      endcase
    end
  end


  //---------------------------------------------------------------------------------------------
  // Byte received done flag
  //---------------------------------------------------------------------------------------------
  always @(posedge I_CLK or negedge I_RST_N) begin
    if (~I_RST_N) O_VALID <= '0;
    else begin
      case (st_state)
        STOP:    O_VALID <= sr_baud_edge;
        default: O_VALID <= '0;
      endcase
    end
  end


  //---------------------------------------------------------------------------------------------
  // UART RX receive
  //---------------------------------------------------------------------------------------------
  always @(posedge I_CLK or negedge I_RST_N) begin
    if (~I_RST_N) O_DATA <= '0;
    else begin
      case (st_state)
        DATA:    if (sr_receive_flag) O_DATA[sr_receive_cnt] <= sr_uart_rx_sync;
        default: O_DATA <= O_DATA;
      endcase
    end
  end


endmodule
