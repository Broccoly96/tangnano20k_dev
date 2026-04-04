// Example 6 is a memory with one read port and an initial value, which
// can be synthesized to asynchronous set read-only memory in bypass read
// mode.

module test_invce (clock,ce,oce,reset,addr,dataout) ;
  input         clock,ce,oce,reset;
  input  [5:0]  addr;
  output [7:0]  dataout;

  reg [7:0] dataout;

  always @(posedge clock or posedge reset)
    if(reset) begin
      dataout <= 0;
    end else begin
      if (ce & oce) begin
        case (addr)
          6'b000000: dataout <= 32'h87654321;
          6'b000001: dataout <= 32'h18765432;
          6'b000010: dataout <= 32'h21876543;
          // .......
          6'b111110: dataout <= 32'hdef89aba;
          6'b111111: dataout <= 32'hef89abce;
          default:   dataout <= 32'hf89abcde;
        endcase
      end
    end

endmodule