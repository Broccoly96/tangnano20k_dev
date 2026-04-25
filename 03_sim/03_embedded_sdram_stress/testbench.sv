`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import embedded_sdram_tb_pkg::*;

  localparam time CLK_100M_PERIOD = 10ns;
  localparam int unsigned NUM_DRAM = 2;
  localparam int unsigned DQ_BITS = 16;
  localparam int unsigned DQS_BITS = 2;

  logic tb_clk_100m;
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

  integer tb_cmd_count [0:9];
  sdram_cmd_e tb_last_cmd;

  initial begin
    tb_log_pkg::configure_logging(tb_log_pkg::LOG_INFO);
    tb_clk_100m = 1'b0;
    forever #(CLK_100M_PERIOD / 2) tb_clk_100m = ~tb_clk_100m;
  end

  initial begin
    tb_rst_n = 1'b0;
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
    repeat (32) @(posedge tb_clk_100m);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(5ms);
    tb_log_pkg::log_fatal(
      1,
      "SDRAM STRESS TB",
      $sformatf(
        "timeout init=%0b busy_n=%0b wr_n=%0b rd_n=%0b rd_valid=%0b addr=0x%05h",
        tb_sdrc_init_done,
        tb_sdrc_busy_n,
        tb_sdrc_wr_n,
        tb_sdrc_rd_n,
        tb_sdrc_rd_valid,
        tb_sdrc_addr
      )
    );
  end

  embedded_sdram u_embedded_sdram (
    .I_sdrc_rst_n       (tb_rst_n),
    .I_sdrc_clk         (tb_clk_100m),
    .I_sdram_clk        (tb_clk_100m),
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

  // Tracks which SDRAM-side commands the controller actually emits so the
  // stress test can confirm that initialization, accesses, and refresh paths
  // were all exercised.
  always_ff @(posedge tb_sdram_clk or negedge tb_rst_n) begin
    sdram_cmd_e cmd;
    if (!tb_rst_n) begin
      tb_last_cmd <= SDRAM_CMD_UNKNOWN;
      for (int cmd_idx = 0; cmd_idx <= 9; cmd_idx++) begin
        tb_cmd_count[cmd_idx] <= 0;
      end
    end else begin
      cmd = decode_sdram_cmd(
        tb_sdram_cke,
        tb_sdram_cs_n,
        tb_sdram_ras_n,
        tb_sdram_cas_n,
        tb_sdram_wen_n
      );
      if ((cmd != tb_last_cmd) && (cmd != SDRAM_CMD_UNKNOWN)) begin
        tb_log_pkg::log_trace(
          "SDRAM CMD",
          $sformatf(
            "cmd=%s ba=%0d addr=0x%03h cke=%0b",
            sdram_cmd_name(cmd),
            tb_sdram_ba,
            tb_sdram_addr,
            tb_sdram_cke
          )
        );
      end
      tb_last_cmd <= cmd;
      if (cmd != SDRAM_CMD_UNKNOWN) begin
        tb_cmd_count[cmd] <= tb_cmd_count[cmd] + 1;
      end
    end
  end

`include "testcase_stress.svh"

endmodule
