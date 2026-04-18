`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;

  localparam time CLK_HALF_PERIOD = 10416ps;
  localparam int unsigned DQ_BITS = 16;
  localparam int unsigned DQM_BITS = 2;
  localparam int unsigned NUM_DRAM = 2;

  logic        tb_clk;
  logic        tb_clk_sdram;
  logic        tb_rst_n;
  logic        tb_evt_valid;
  logic [7:0]  tb_evt_id;
  logic [31:0] tb_evt_arg0;
  logic [31:0] tb_evt_arg1;
  logic [31:0] tb_evt_arg2;
  logic        tb_evt_ready;
  logic        tb_init_done;
  logic        tb_test_active;
  logic        tb_test_pass;
  logic        tb_test_fail;
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

  int unsigned tb_evt_pass_count;
  int unsigned tb_evt_fail_count;
  int unsigned tb_evt_fail_ctx_count;
  int unsigned tb_run_index;

  initial begin
    configure_logging(LOG_INFO);
    tb_clk = 1'b0;
    forever #CLK_HALF_PERIOD tb_clk = ~tb_clk;
  end

  initial begin
    tb_clk_sdram = 1'b0;
    forever #CLK_HALF_PERIOD tb_clk_sdram = ~tb_clk_sdram;
  end

  initial begin
    tb_rst_n     = 1'b0;
    tb_evt_ready = 1'b1;
    tb_run_index = 0;
    repeat (32) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(30ms);
    log_fatal(1, "SELFTEST OPEN TB", "simulation timeout");
  end

  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      tb_evt_pass_count     <= 0;
      tb_evt_fail_count     <= 0;
      tb_evt_fail_ctx_count <= 0;
    end else if (tb_evt_valid && tb_evt_ready) begin
      if (tb_evt_id == 8'h22) begin
        tb_evt_pass_count <= tb_evt_pass_count + 1;
      end
      if (tb_evt_id == 8'h23) begin
        tb_evt_fail_count <= tb_evt_fail_count + 1;
      end
      if (tb_evt_id == 8'h24) begin
        tb_evt_fail_ctx_count <= tb_evt_fail_ctx_count + 1;
      end
      log_info(
        "SELFTEST OPEN TB",
        $sformatf(
          "evt id=0x%02h arg0=0x%08h arg1=0x%08h arg2=0x%08h",
          tb_evt_id,
          tb_evt_arg0,
          tb_evt_arg1,
          tb_evt_arg2
        )
      );
    end
  end

  sdram_emb_selftest #(
    .MEMTEST_CLK_HZ(256),
    .MEMTEST_BURST_WORDS(64),
    .MEMTEST_TOTAL_WORDS(512),
    .MEMTEST_POST_INIT_WAIT_CYCLES(32),
    .MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES(8)
  ) u_dut (
    .I_CLK       (tb_clk),
    .I_CLK_SDRAM (tb_clk_sdram),
    .I_RST_N     (tb_rst_n),
    .O_EVT_VALID (tb_evt_valid),
    .O_EVT_ID    (tb_evt_id),
    .O_EVT_ARG0  (tb_evt_arg0),
    .O_EVT_ARG1  (tb_evt_arg1),
    .O_EVT_ARG2  (tb_evt_arg2),
    .I_EVT_READY (tb_evt_ready),
    .O_INIT_DONE (tb_init_done),
    .O_TEST_ACTIVE(tb_test_active),
    .O_TEST_PASS (tb_test_pass),
    .O_TEST_FAIL (tb_test_fail),
    .O_sdram_clk (tb_sdram_clk),
    .O_sdram_cke (tb_sdram_cke),
    .O_sdram_cs_n(tb_sdram_cs_n),
    .O_sdram_cas_n(tb_sdram_cas_n),
    .O_sdram_ras_n(tb_sdram_ras_n),
    .O_sdram_wen_n(tb_sdram_wen_n),
    .O_sdram_dqm (tb_sdram_dqm),
    .O_sdram_addr(tb_sdram_addr),
    .O_sdram_ba  (tb_sdram_ba),
    .IO_sdram_dq (tb_sdram_dq)
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
        .dqm  (tb_sdram_dqm[((g_dram + 1) * DQM_BITS) - 1 -: DQM_BITS])
      );
    end
  endgenerate

`include "testcase_smoke.svh"

endmodule
