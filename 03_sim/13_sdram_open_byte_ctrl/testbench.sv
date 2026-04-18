`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;

  localparam time CLK_HALF_PERIOD = 10416ps;
  localparam int unsigned DQ_BITS = 16;
  localparam int unsigned DQM_BITS = 2;
  localparam int unsigned NUM_DRAM = 2;
  localparam int unsigned REFRESH_DEADLINE_CYCLES = 720;

  logic        tb_clk;
  logic        tb_clk_sdram;
  logic        tb_rst_n;
  logic        tb_req_valid;
  logic        tb_req_ready;
  logic        tb_req_is_write;
  logic [22:0] tb_req_addr;
  logic [7:0]  tb_req_wr_data;
  logic        tb_rsp_valid;
  logic        tb_rsp_ready;
  logic [7:0]  tb_rsp_rd_data;
  logic [31:0] tb_rsp_status;
  logic        tb_init_done;
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
  int unsigned tb_refresh_age;
  int unsigned tb_refresh_count;

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
    tb_req_valid   = 1'b0;
    tb_req_is_write= 1'b0;
    tb_req_addr    = '0;
    tb_req_wr_data = 8'h00;
    tb_rsp_ready   = 1'b1;
    repeat (32) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(20ms);
    log_fatal(1, "OPEN BYTE TB", "simulation timeout");
  end

  // Confirms the autonomous refresh scheduler never exceeds the 15us deadline.
  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n || !tb_init_done) begin
      tb_refresh_age   <= 0;
      tb_refresh_count <= 0;
    end else if (u_dut.l_ctrl_refresh) begin
      tb_refresh_age   <= 0;
      tb_refresh_count <= tb_refresh_count + 1;
    end else begin
      tb_refresh_age <= tb_refresh_age + 1;
      if (tb_refresh_age >= REFRESH_DEADLINE_CYCLES) begin
        log_fatal(1, "OPEN BYTE TB", "refresh spacing exceeded 15us deadline");
      end
    end
  end

  sdram_open_byte_ctrl u_dut (
    .I_CLK       (tb_clk),
    .I_CLK_SDRAM (tb_clk_sdram),
    .I_RST_N     (tb_rst_n),
    .I_REQ_VALID (tb_req_valid),
    .O_REQ_READY (tb_req_ready),
    .I_REQ_IS_WRITE(tb_req_is_write),
    .I_REQ_ADDR  (tb_req_addr),
    .I_REQ_WR_DATA(tb_req_wr_data),
    .O_RSP_VALID (tb_rsp_valid),
    .I_RSP_READY (tb_rsp_ready),
    .O_RSP_RD_DATA(tb_rsp_rd_data),
    .O_RSP_STATUS(tb_rsp_status),
    .O_INIT_DONE (tb_init_done),
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

  task automatic issue_write_byte(
    input logic [22:0] addr,
    input logic [7:0]  data_value
  );
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_req_ready) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 2000) begin
          log_fatal(1, "OPEN BYTE TB", "timeout waiting request ready");
        end
      end

      @(posedge tb_clk);
      tb_req_valid    <= 1'b1;
      tb_req_is_write <= 1'b1;
      tb_req_addr     <= addr;
      tb_req_wr_data  <= data_value;
      @(posedge tb_clk);
      tb_req_valid    <= 1'b0;
      tb_req_is_write <= 1'b0;
      tb_req_addr     <= '0;
      tb_req_wr_data  <= 8'h00;

      wait_cycles = 0;
      while (!tb_rsp_valid) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 4000) begin
          log_fatal(1, "OPEN BYTE TB", "timeout waiting write response");
        end
      end

      if (tb_rsp_status !== 32'h0000_0000) begin
        log_fatal(1, "OPEN BYTE TB", $sformatf("write status mismatch 0x%08h", tb_rsp_status));
      end

      @(posedge tb_clk);
    end
  endtask

  task automatic issue_read_byte(
    input logic [22:0] addr,
    input logic [7:0]  exp_data
  );
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_req_ready) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 2000) begin
          log_fatal(1, "OPEN BYTE TB", "timeout waiting request ready");
        end
      end

      @(posedge tb_clk);
      tb_req_valid    <= 1'b1;
      tb_req_is_write <= 1'b0;
      tb_req_addr     <= addr;
      @(posedge tb_clk);
      tb_req_valid <= 1'b0;
      tb_req_addr  <= '0;

      wait_cycles = 0;
      while (!tb_rsp_valid) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 4000) begin
          log_fatal(1, "OPEN BYTE TB", "timeout waiting read response");
        end
      end

      if (tb_rsp_status !== 32'h0000_0000) begin
        log_fatal(1, "OPEN BYTE TB", $sformatf("read status mismatch 0x%08h", tb_rsp_status));
      end
      if (tb_rsp_rd_data !== exp_data) begin
        log_fatal(
          1,
          "OPEN BYTE TB",
          $sformatf("read data mismatch addr=0x%06h exp=0x%02h act=0x%02h", addr, exp_data, tb_rsp_rd_data)
        );
      end

      @(posedge tb_clk);
    end
  endtask

`include "testcase_smoke.svh"

endmodule
