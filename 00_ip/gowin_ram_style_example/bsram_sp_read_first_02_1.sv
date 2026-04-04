// Example 4 is a memory with two write ports and one read port. One of
// the two write ports has a wre signal and the other does not. The read port
// absorbs asynchronous reset register. This example can be synthesized to
// asynchronous reset dual-port BSRAM with A port in normal write mode and
// B port in read-before-write mode or in register output read mode.

module read_first_02_1(data_outa, data_ina, addra, clka, rsta, cea, wrea, ocea, data_inb, addrb, clkb, ceb );
  output [17:0] data_outa;
  input  [17:0] data_ina,data_inb;
  input  [6:0]  addra,addrb;
  input         clka, rsta, cea, wrea, ocea;
  input         clkb, ceb;

  reg [17:0] mem [127:0];
  reg [17:0] data_outa;
  reg [17:0] data_out_rega,data_out_regb;

always @(posedge clkb)
  if (ceb) mem[addrb] <= data_inb;

always@(posedge clka or posedge rsta)
  if(rsta)  data_out_rega <= 0;
  else begin
            data_out_rega <= mem[addra];
  end

always@(posedge clka or posedge rsta)
  if(rsta)        data_outa <= 0;
  else if (ocea)  data_outa <= data_out_rega;

always @(posedge clka)
  if (cea & wrea) mem[addra] <= data_ina;

endmodule