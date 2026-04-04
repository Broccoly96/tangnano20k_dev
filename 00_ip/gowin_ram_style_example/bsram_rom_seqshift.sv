// Example 7 is a memory with shift-register mode, which can be
// synthesized to simple-dual-port BSRAM in normal mode.

module seqshift_bsram (clk, din, dout);

  parameter SRL_WIDTH = 65;
  parameter SRL_DEPTH = 16;

  input                   clk;
  input  [SRL_WIDTH-1:0]  din;
  output [SRL_WIDTH-1:0]  dout;

  reg [SRL_WIDTH-1:0] regBank[SRL_DEPTH-1:0];
  integer i;

  always @(posedge clk) begin
    for (i=SRL_DEPTH-1; i>0; i=i-1) begin
      regBank[i] <= regBank[i-1];
    end
    regBank[0] <= din;
  end

  assign dout = regBank[SRL_DEPTH-1];

endmodule