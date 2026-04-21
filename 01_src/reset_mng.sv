`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Name         : reset_mng.sv
// Description  : Reset Management
//////////////////////////////////////////////////////////////////////////////////

module reset_mng #(
    parameter int unsigned FPGA_INIT_WAIT = 240000,
    parameter int unsigned SOFT_RESET_HOLD_CYCLES = 1
) (
    input  logic I_CLK_24M,
    input  logic I_CLK_48M,
    input  logic I_PLL_LOCK,
    input  logic I_SOFT_RST_N,
    input  logic I_SOFT_RST_REQ,
    output logic O_RST_FPGA_24M_N,
    output logic O_RST_FPGA_48M_N
);

localparam int unsigned INIT_CNT_W                            = (FPGA_INIT_WAIT <= 1) ? 1 : $clog2(FPGA_INIT_WAIT + 1);
localparam int unsigned SOFT_RESET_CNT_W                      = (SOFT_RESET_HOLD_CYCLES <= 1) ? 1 : $clog2(SOFT_RESET_HOLD_CYCLES + 1);
localparam logic [INIT_CNT_W-1:0] FPGA_INIT_WAIT_VALUE        = FPGA_INIT_WAIT[INIT_CNT_W-1:0];
localparam logic [SOFT_RESET_CNT_W-1:0] SOFT_RESET_HOLD_VALUE = SOFT_RESET_HOLD_CYCLES[SOFT_RESET_CNT_W-1:0];

logic [INIT_CNT_W-1:0]        s_cnt;
logic [SOFT_RESET_CNT_W-1:0]  r_soft_reset_cnt;
logic                         r_global_reset_n;
logic                         r_reset_48m_sync1_n;

// FPGA Global Reset
// Holds both output resets while PLL lock is low, while an external active-low
// reset is asserted, during a requested soft-reset hold window, and during the
// post-reset FPGA initialization wait.
always_ff @(posedge I_CLK_24M or negedge I_SOFT_RST_N) begin
  if(~I_SOFT_RST_N) begin
    s_cnt            <= '0;
    r_soft_reset_cnt <= '0;
    r_global_reset_n <= 1'b0;
  end else if(~I_PLL_LOCK) begin
    s_cnt            <= '0;
    r_soft_reset_cnt <= '0;
    r_global_reset_n <= 1'b0;
  end else if(I_SOFT_RST_REQ) begin
    s_cnt            <= '0;
    r_soft_reset_cnt <= SOFT_RESET_HOLD_VALUE;
    r_global_reset_n <= 1'b0;
  end else if(r_soft_reset_cnt != 0) begin
    s_cnt            <= '0;
    r_soft_reset_cnt <= r_soft_reset_cnt - 1'b1;
    r_global_reset_n <= 1'b0;
  end else if(s_cnt >= FPGA_INIT_WAIT_VALUE) begin
    s_cnt            <= s_cnt;
    r_global_reset_n <= 1'b1;
  end else begin
    s_cnt            <= s_cnt + 1'b1;
    r_global_reset_n <= 1'b0;
  end
end

//--------------------------------------------------------------------------------------
// FPGA Reset
//--------------------------------------------------------------------------------------
always_ff @(posedge I_CLK_24M or negedge r_global_reset_n) begin
  if(~r_global_reset_n) O_RST_FPGA_24M_N <= 1'b0;
  else                  O_RST_FPGA_24M_N <= 1'b1;
end

//--------------------------------------------------------------------------------------
// FPGA Reset (48MHz domain synchronized release)
//--------------------------------------------------------------------------------------
always_ff @(posedge I_CLK_48M or negedge r_global_reset_n) begin
  if(~r_global_reset_n) begin
    r_reset_48m_sync1_n <= 1'b0;
    O_RST_FPGA_48M_N    <= 1'b0;
  end else begin
    r_reset_48m_sync1_n <= O_RST_FPGA_24M_N;
    O_RST_FPGA_48M_N    <= r_reset_48m_sync1_n;
  end
end





endmodule
