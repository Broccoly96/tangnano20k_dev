`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_sim_model_wrapper.v
// Description  : Compatibility wrapper so the vendor-provided embedded SDRAM
//                testbench can instantiate `sdram_sim_model` while reusing the
//                Micron MT48LC8M16A2 behavioral model already stored in the IP
//                directory.
//////////////////////////////////////////////////////////////////////////////////

module sdram_sim_model (
  inout  [15:0] Dq,
  input  [10:0] Addr,
  input  [1:0]  Ba,
  input         Clk,
  input         Cke,
  input         Cs_n,
  input         Ras_n,
  input         Cas_n,
  input         We_n,
  input  [1:0]  Dqm
);

  MT48LC8M16A2 u_mt48lc8m16a2 (
    .dq   (Dq),
    .addr ({5'b0, Addr}),
    .ba   (Ba),
    .clk  (Clk),
    .cke  (Cke),
    .csb  (Cs_n),
    .rasb (Ras_n),
    .casb (Cas_n),
    .web  (We_n),
    .dqm  (Dqm)
  );

endmodule
