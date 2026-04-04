//////////////////////////////////////////////////////////////////////////////////
// Name         : uart_tx
// Description  : UART Transmit module.
//////////////////////////////////////////////////////////////////////////////////

module uart_tx_stream(
  input       I_CLK,
  input       I_RST_N,
  input       I_START,
  input [7:0] I_DATA,

  output reg  O_UART_TX,
  output reg  O_VALID,
  output reg  O_BUSY
);

//---------------------------------------------------------------------------------------------
// Parameters
//---------------------------------------------------------------------------------------------
parameter C_BAUD_COUNT = 104;  // Baud count. 208 x 12Mhz = 115200 baud

//---------------------------------------------------------------------------------------------
// Wires and Regs
//---------------------------------------------------------------------------------------------
reg         sr_send_flag;
reg [15:0]  sr_baud_cnt;  // 16bit counter
reg [3:0]   sr_send_cnt;
reg [7:0]   sr_data;


//---------------------------------------------------------------------------------------------
// State machine
//  Default state is IDLE.
//  If I_START=1 is detected, the FSM transitions to START and starts transmission.
//  When transmitting multiple bytes, I_START can stay 1 the entire time so transmission can
//  be executed continously. I_DATA_TX should be switched every time O_VALID is asserted.
//---------------------------------------------------------------------------------------------
typedef enum logic [2:0]{
  IDLE, START, DATA, STOP
} uart_states;
uart_states st_state, st_nextstate;

always @(posedge I_CLK or negedge I_RST_N) begin
  if(~I_RST_N)  st_state <= IDLE;           // Default State is IDLE
  else          st_state <= st_nextstate;   // Transition to nextstate at every clock
end

always @(*) begin
  // Keep same state when no conditions are met.
  st_nextstate = st_state;

  // State transit conditions
  case(st_state)
    IDLE:   if(I_START)                           st_nextstate = START;
    START:  if(sr_send_flag)                      st_nextstate = DATA;
    DATA:   if(sr_send_flag & sr_send_cnt==4'd7)  st_nextstate = STOP;
    STOP:   if(sr_send_flag)                      st_nextstate = IDLE;
  endcase
end


//---------------------------------------------------------------------------------------------
// Baud counter
//  Sends a 1clock-wide pulse when counter reaches specified Baudrate (default 115200).
//  The pulse is always generated whether the UART is sending or not.
//  The FSM transitions at the pulse edge.
//---------------------------------------------------------------------------------------------
always @(posedge I_CLK or negedge I_RST_N) begin
  if(~I_RST_N) begin
    sr_baud_cnt  <= '0;
    sr_send_flag <= '0;
  end else if(sr_baud_cnt == C_BAUD_COUNT - 1) begin
    sr_baud_cnt  <= '0;
    sr_send_flag <= 1'b1;
  end else if((st_state == IDLE) & I_START) begin
    sr_baud_cnt  <= '0;
    sr_send_flag <= 1'b0;
  end else begin
    sr_baud_cnt  <= sr_baud_cnt + 1'b1;
    sr_send_flag <= '0;
  end
end



//---------------------------------------------------------------------------------------------
// TX data
//---------------------------------------------------------------------------------------------
// TX data counter
always @(posedge I_CLK or negedge I_RST_N) begin
  if(~I_RST_N)                sr_send_cnt <= '0;
  else begin
    case(st_state)
      IDLE:                   sr_send_cnt <= '0;
      START:                  sr_send_cnt <= '0;
      DATA: if(sr_send_flag)  sr_send_cnt <= sr_send_cnt + 1'b1;
      STOP:                   sr_send_cnt <= '0;
    endcase
  end
end

// Keep the input while data is being send.
always @(posedge I_CLK or negedge I_RST_N) begin
  if(~I_RST_N)  sr_data <= '0;
  else begin
    case(st_state)
      IDLE:     sr_data <= '0;
      START:    sr_data <= I_DATA;
      DATA:     sr_data <= sr_data;
      STOP:     sr_data <= '0;
    endcase
  end
end


//---------------------------------------------------------------------------------------------
// UART TX output
//---------------------------------------------------------------------------------------------
always @(posedge I_CLK or negedge I_RST_N) begin
  if(~I_RST_N)  O_UART_TX <= 1'b1;
  else begin
    case(st_state)
      IDLE:     O_UART_TX <= 1'b1;
      START:    O_UART_TX <= '0;
      DATA:     O_UART_TX <= sr_data[sr_send_cnt];
      STOP:     O_UART_TX <= 1'b1;
    endcase
  end
end


//---------------------------------------------------------------------------------------------
// Done flag
//---------------------------------------------------------------------------------------------
always @(posedge I_CLK or negedge I_RST_N) begin
  if(~I_RST_N)  O_VALID <= '0;
  else begin
    case(st_state)
      IDLE:     O_VALID <= '0;
      START:    O_VALID <= '0;
      DATA:     O_VALID <= '0;
      STOP:     O_VALID <= sr_send_flag;
    endcase
  end
end


//---------------------------------------------------------------------------------------------
// Busy flag
//---------------------------------------------------------------------------------------------
assign O_BUSY = (st_state != IDLE);


endmodule