// Example 5 is a memory with one read port and one write port and
// different read and write addresses, which can be synthesized to
// semi-dual-port BSRAM in normal write mode or in bypass read mode.

module read_first_wp_pre_1(data_out, data_in, waddr, raddr, clk, rst,ce);
  output [10:0] data_out;
  input  [10:0] data_in;
  input  [6:0]  raddr,waddr;
  input         clk, rst,ce;

  reg [10:0] mem [127:0];
  reg [10:0] data_out;

  always@(posedge clk or posedge rst)
    if(rst)     data_out <= 0;
    else if(ce) data_out <= mem[raddr];

  always @(posedge clk)
    if (ce)     mem[waddr] <= data_in;

endmodule