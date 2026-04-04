`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Name         : reset_mng.sv
// Description  : Reset Management
//////////////////////////////////////////////////////////////////////////////////

module reset_mng(
// Input
    input           I_CLK_24M,
    input           I_PLL_LOCK,
    input           I_SOFT_RST_N,
// Output
    output reg      O_RST_FPGA_24M_N
);


parameter FPGA_INIT_WAIT = 12000; // wait time counter. Default is 1ms @12MHz.

reg [31:0]  s_cnt;
reg         r_global_reset_n;
reg         r_pcie_rst_n;

// FPGA Global Reset
always @(posedge I_CLK_24M or negedge I_SOFT_RST_N) begin
  if(~I_SOFT_RST_N) begin
    s_cnt             <= '0;
    r_global_reset_n  <= 1'b0;
  end else if(~I_PLL_LOCK) begin
    s_cnt             <= '0;
    r_global_reset_n  <= 1'b0;
  end else if(s_cnt == FPGA_INIT_WAIT) begin
    s_cnt             <= s_cnt;
    r_global_reset_n  <= 1'b1;
  end else begin
    s_cnt             <= s_cnt + 1'b1;
    r_global_reset_n  <= 1'b1;
  end
end

//--------------------------------------------------------------------------------------
// FPGA Reset
//--------------------------------------------------------------------------------------
always @(posedge I_CLK_24M or negedge r_global_reset_n) begin
  if(~r_global_reset_n) O_RST_FPGA_24M_N <= 1'b0;
  else                  O_RST_FPGA_24M_N <= 1'b1;
end





endmodule