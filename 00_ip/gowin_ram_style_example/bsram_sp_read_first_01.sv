// Example 3 is a memory with one write port, one read port and the
// same read and write address. When wre is 1, input data is written to
// memory, which can be synthesized to single-port BSRAM in
// read-before-write mode.

module read_first_01(data_out, data_in, addr, clk, wre);
  output [31:0] data_out;
  input  [31:0] data_in;
  input  [6:0]  addr;
  input         clk,wre;

  reg [31:0] mem [127:0];
  reg [31:0] data_out;

always @(posedge clk) begin
  if(wre)  mem[addr] <= data_in;
  data_out <= mem[addr];
end

endmodule
