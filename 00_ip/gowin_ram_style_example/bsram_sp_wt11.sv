// Example 2 is a memory with one write port, one read port and the
// same read and write address. When wre is 1, input data can be transferred
// directly to output, which can be synthesized to single-port BSRAM in
// normal write mode.

module wt11(data_out, data_in, addr, clk, wre,rst);

  output [31:0] data_out;
  input  [31:0] data_in;
  input  [6:0]  addr;
  input         clk,wre,rst;

reg [31:0] mem [127:0];
reg [31:0] data_out;

always@(posedge clk or posedge rst)
  if(rst)       data_out <= 0;
  else if(wre)  data_out <= data_in;
  else          data_out <= mem[addr];

always @(posedge clk)
  if (wre)      mem[addr] <= data_in;

endmodule