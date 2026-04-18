`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import sdram_uart_proto_pkg::*;

  localparam time CLK_HALF_PERIOD = 10416ps;
  localparam int unsigned DQ_BITS = 16;
  localparam int unsigned DQM_BITS = 2;
  localparam int unsigned NUM_DRAM = 2;

  logic        tb_clk;
  logic        tb_clk_sdram;
  logic        tb_rst_n;
  logic        tb_cli_rx_valid;
  logic [7:0]  tb_cli_rx_data;
  logic        tb_test_evt_valid;
  logic [7:0]  tb_test_evt_id;
  logic [31:0] tb_test_evt_arg0;
  logic [31:0] tb_test_evt_arg1;
  logic [31:0] tb_test_evt_arg2;
  logic        tb_host_evt_valid;
  logic [7:0]  tb_host_evt_id;
  logic [31:0] tb_host_evt_arg0;
  logic [31:0] tb_host_evt_arg1;
  logic [31:0] tb_host_evt_arg2;
  logic        tb_init_done;
  logic        tb_test_active;
  logic        tb_test_pass;
  logic        tb_test_fail;
  logic        tb_host_busy;
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
    configure_logging(LOG_INFO);
    tb_clk = 1'b0;
    forever #CLK_HALF_PERIOD tb_clk = ~tb_clk;
  end

  initial begin
    tb_clk_sdram = 1'b0;
    forever #CLK_HALF_PERIOD tb_clk_sdram = ~tb_clk_sdram;
  end

  initial begin
    tb_rst_n       = 1'b0;
    tb_cli_rx_valid= 1'b0;
    tb_cli_rx_data = 8'h00;
    repeat (32) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(40ms);
    log_fatal(1, "HOSTIF OPEN TB", "simulation timeout");
  end

  sdram_emb_hostif #(
    .MEMTEST_CLK_HZ(256),
    .MEMTEST_BURST_WORDS(64),
    .MEMTEST_TOTAL_WORDS(256),
    .MEMTEST_POST_INIT_WAIT_CYCLES(32),
    .MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES(8)
  ) u_dut (
    .I_CLK       (tb_clk),
    .I_CLK_SDRAM (tb_clk_sdram),
    .I_RST_N     (tb_rst_n),
    .I_CLI_RX_VALID(tb_cli_rx_valid),
    .I_CLI_RX_DATA(tb_cli_rx_data),
    .O_RAW_RX_BYPASS(),
    .O_RAW_TX_MODE(),
    .O_RAW_TX_VALID(),
    .O_RAW_TX_DATA(),
    .I_RAW_TX_READY(1'b1),
    .O_TEST_EVT_VALID(tb_test_evt_valid),
    .O_TEST_EVT_ID(tb_test_evt_id),
    .O_TEST_EVT_ARG0(tb_test_evt_arg0),
    .O_TEST_EVT_ARG1(tb_test_evt_arg1),
    .O_TEST_EVT_ARG2(tb_test_evt_arg2),
    .I_TEST_EVT_READY(1'b1),
    .O_HOST_EVT_VALID(tb_host_evt_valid),
    .O_HOST_EVT_ID(tb_host_evt_id),
    .O_HOST_EVT_ARG0(tb_host_evt_arg0),
    .O_HOST_EVT_ARG1(tb_host_evt_arg1),
    .O_HOST_EVT_ARG2(tb_host_evt_arg2),
    .I_HOST_EVT_READY(1'b1),
    .O_INIT_DONE(tb_init_done),
    .O_TEST_ACTIVE(tb_test_active),
    .O_TEST_PASS(tb_test_pass),
    .O_TEST_FAIL(tb_test_fail),
    .O_HOST_BUSY(tb_host_busy),
    .O_sdram_clk(tb_sdram_clk),
    .O_sdram_cke(tb_sdram_cke),
    .O_sdram_cs_n(tb_sdram_cs_n),
    .O_sdram_cas_n(tb_sdram_cas_n),
    .O_sdram_ras_n(tb_sdram_ras_n),
    .O_sdram_wen_n(tb_sdram_wen_n),
    .O_sdram_dqm(tb_sdram_dqm),
    .O_sdram_addr(tb_sdram_addr),
    .O_sdram_ba(tb_sdram_ba),
    .IO_sdram_dq(tb_sdram_dq)
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

  task automatic send_byte(input logic [7:0] byte_value);
    begin
      @(posedge tb_clk);
      tb_cli_rx_valid <= 1'b1;
      tb_cli_rx_data  <= byte_value;
      @(posedge tb_clk);
      tb_cli_rx_valid <= 1'b0;
      tb_cli_rx_data  <= 8'h00;
    end
  endtask

  task automatic send_text(input string text_value);
    int idx;
    begin
      for (idx = 0; idx < text_value.len(); idx++) begin
        send_byte(text_value[idx]);
      end
    end
  endtask

  task automatic expect_host_event(
    input logic [7:0]  exp_id,
    input logic [31:0] exp_arg0,
    input logic [31:0] exp_arg1,
    input logic [31:0] exp_arg2,
    input string       label
  );
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_host_evt_valid) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 8000) begin
          log_fatal(1, "HOSTIF OPEN TB", {"timeout waiting host event: ", label});
        end
      end

      if ((tb_host_evt_id !== exp_id) ||
          (tb_host_evt_arg0 !== exp_arg0) ||
          (tb_host_evt_arg1 !== exp_arg1) ||
          (tb_host_evt_arg2 !== exp_arg2)) begin
        log_fatal(
          1,
          "HOSTIF OPEN TB",
          $sformatf(
            "%s mismatch id=0x%02h arg0=0x%08h arg1=0x%08h arg2=0x%08h",
            label,
            tb_host_evt_id,
            tb_host_evt_arg0,
            tb_host_evt_arg1,
            tb_host_evt_arg2
          )
        );
      end

      @(posedge tb_clk);
    end
  endtask

`include "testcase_smoke.svh"

endmodule
