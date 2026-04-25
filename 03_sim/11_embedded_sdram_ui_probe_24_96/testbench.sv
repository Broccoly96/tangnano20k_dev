`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import embedded_sdram_tb_pkg::*;

  localparam time CLK_96M_HALF_PERIOD = 5208ps;
  localparam int unsigned NUM_DRAM = 2;
  localparam int unsigned DQ_BITS = 16;
  localparam int unsigned DQS_BITS = 2;

  logic tb_clk_96m;
  logic tb_clk_24m;
  logic [1:0] tb_clkdiv4_cnt;
  logic tb_rst_n;

  logic        tb_sdrc_selfrefresh;
  logic        tb_sdrc_power_down;
  logic        tb_sdrc_wr_n;
  logic        tb_sdrc_rd_n;
  logic [20:0] tb_sdrc_addr;
  logic [7:0]  tb_sdrc_data_len;
  logic [3:0]  tb_sdrc_dqm;
  logic [31:0] tb_sdrc_wr_data;
  logic [31:0] tb_sdrc_rd_data;
  logic        tb_sdrc_init_done;
  logic        tb_sdrc_busy_n;
  logic        tb_sdrc_rd_valid;
  logic        tb_sdrc_wrd_ack;

  logic        tb_sdram_clk;
  logic        tb_sdram_cke;
  logic        tb_sdram_cs_n;
  logic        tb_sdram_cas_n;
  logic        tb_sdram_ras_n;
  logic        tb_sdram_wen_n;
  logic [3:0]  tb_sdram_dqm;
  logic [10:0] tb_sdram_addr;
  logic [1:0]  tb_sdram_ba;
  wire  [31:0] tb_sdram_dq;

  initial begin
    tb_log_pkg::configure_logging(tb_log_pkg::LOG_DEBUG);
    tb_clk_96m = 1'b0;
    forever #(CLK_96M_HALF_PERIOD) tb_clk_96m = ~tb_clk_96m;
  end

  always_ff @(posedge tb_clk_96m or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      tb_clkdiv4_cnt <= 2'd0;
      tb_clk_24m     <= 1'b0;
    end else if (tb_clkdiv4_cnt == 2'd1) begin
      tb_clkdiv4_cnt <= 2'd0;
      tb_clk_24m     <= ~tb_clk_24m;
    end else begin
      tb_clkdiv4_cnt <= tb_clkdiv4_cnt + 1'b1;
    end
  end

  initial begin
    tb_rst_n = 1'b0;
    tb_clk_24m = 1'b0;
    tb_clkdiv4_cnt = 2'd0;
    sdrc_init_driver(
      tb_sdrc_wr_n,
      tb_sdrc_rd_n,
      tb_sdrc_addr,
      tb_sdrc_data_len,
      tb_sdrc_dqm,
      tb_sdrc_wr_data,
      tb_sdrc_selfrefresh,
      tb_sdrc_power_down
    );
    repeat (64) @(posedge tb_clk_24m);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(1ms);
    tb_log_pkg::log_fatal(
      1,
      "SDRAM UI PROBE 24_96 TB",
      $sformatf(
        "timeout init=%0b busy_n=%0b wr_n=%0b rd_n=%0b rd_valid=%0b addr=0x%05h len=%0d",
        tb_sdrc_init_done,
        tb_sdrc_busy_n,
        tb_sdrc_wr_n,
        tb_sdrc_rd_n,
        tb_sdrc_rd_valid,
        tb_sdrc_addr,
        tb_sdrc_data_len + 1
      )
    );
  end

  embedded_sdram u_embedded_sdram (
    .I_sdrc_rst_n       (tb_rst_n),
    .I_sdrc_clk         (tb_clk_24m),
    .I_sdram_clk        (tb_clk_96m),
    .I_sdrc_selfrefresh (tb_sdrc_selfrefresh),
    .I_sdrc_power_down  (tb_sdrc_power_down),
    .I_sdrc_wr_n        (tb_sdrc_wr_n),
    .I_sdrc_rd_n        (tb_sdrc_rd_n),
    .I_sdrc_addr        (tb_sdrc_addr),
    .I_sdrc_data_len    (tb_sdrc_data_len),
    .I_sdrc_dqm         (tb_sdrc_dqm),
    .I_sdrc_data        (tb_sdrc_wr_data),
    .O_sdrc_data        (tb_sdrc_rd_data),
    .O_sdrc_init_done   (tb_sdrc_init_done),
    .O_sdrc_busy_n      (tb_sdrc_busy_n),
    .O_sdrc_rd_valid    (tb_sdrc_rd_valid),
    .O_sdrc_wrd_ack     (tb_sdrc_wrd_ack),
    .O_sdram_clk        (tb_sdram_clk),
    .O_sdram_cke        (tb_sdram_cke),
    .O_sdram_cs_n       (tb_sdram_cs_n),
    .O_sdram_cas_n      (tb_sdram_cas_n),
    .O_sdram_ras_n      (tb_sdram_ras_n),
    .O_sdram_wen_n      (tb_sdram_wen_n),
    .O_sdram_dqm        (tb_sdram_dqm),
    .O_sdram_addr       (tb_sdram_addr),
    .O_sdram_ba         (tb_sdram_ba),
    .IO_sdram_dq        (tb_sdram_dq)
  );

  generate
    genvar g_dram;
    for (g_dram = 0; g_dram < NUM_DRAM; g_dram++) begin : g_sdram_model
      MT48LC8M16A2 #(
        .addr_bits(11)
      ) u_sdram_sim_model (
        .dq   (tb_sdram_dq[((g_dram + 1) * DQ_BITS) - 1 -: DQ_BITS]),
        .addr (tb_sdram_addr),
        .ba   (tb_sdram_ba),
        .clk  (tb_sdram_clk),
        .cke  (tb_sdram_cke),
        .csb  (tb_sdram_cs_n),
        .rasb (tb_sdram_ras_n),
        .casb (tb_sdram_cas_n),
        .web  (tb_sdram_wen_n),
        .dqm  (tb_sdram_dqm[((g_dram + 1) * DQS_BITS) - 1 -: DQS_BITS])
      );
    end
  endgenerate

`include "testcase_probe.svh"

endmodule
