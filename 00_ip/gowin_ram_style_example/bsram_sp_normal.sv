// Example1 is a memory with one write port, one read port and the same
// read and write address, which can be synthesized to a single port BSRAM
// in normal mode

module normal(data_out, data_in, addr, clk,ce, wre,rst);
  output [7:0]  data_out;
  input  [7:0]  data_in;
  input  [7:0]  addr;
  input         clk,wre,ce,rst;

  reg [7:0] mem [255:0];
  reg [7:0] data_out;

  always@(posedge clk or posedge rst)
    if(rst)             data_out <= 0;
    else if(ce & !wre)  data_out <= mem[addr];

  always @(posedge clk)
    if (ce & wre)       mem[addr] <= data_in;

endmodule