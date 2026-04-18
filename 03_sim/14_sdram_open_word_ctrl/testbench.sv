`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import sdram_uart_proto_pkg::*;

  localparam time CLK_HALF_PERIOD = 10416ps;
  localparam int unsigned DQ_BITS = 16;
  localparam int unsigned DQM_BITS = 2;
  localparam int unsigned NUM_DRAM = 2;

  logic        tb_clk;
  logic        tb_clk_sdram_raw;
  logic        tb_clk_sdram_enable;
  wire         tb_clk_sdram = tb_clk_sdram_enable ? tb_clk_sdram_raw : 1'b0;
  logic        tb_rst_n;
  logic        tb_init_done;

  logic        tb_req_valid;
  logic        tb_req_ready;
  logic        tb_req_is_write;
  logic [20:0] tb_req_addr;
  logic [31:0] tb_req_wr_data;
  logic [3:0]  tb_req_wr_be;
  logic        tb_rsp_valid;
  logic        tb_rsp_ready;
  logic [31:0] tb_rsp_rd_data;
  logic [31:0] tb_rsp_status;

  logic        tb_byte_req_valid;
  logic        tb_byte_req_ready;
  logic        tb_byte_req_is_write;
  logic [22:0] tb_byte_req_addr;
  logic [7:0]  tb_byte_req_wr_data;
  logic        tb_byte_rsp_valid;
  logic        tb_byte_rsp_ready;
  logic [7:0]  tb_byte_rsp_rd_data;
  logic [31:0] tb_byte_rsp_status;

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
    tb_clk_sdram_raw = 1'b0;
    forever #CLK_HALF_PERIOD tb_clk_sdram_raw = ~tb_clk_sdram_raw;
  end

  initial begin
    tb_rst_n            = 1'b0;
    tb_clk_sdram_enable = 1'b1;
    tb_req_valid        = 1'b0;
    tb_req_is_write     = 1'b0;
    tb_req_addr         = '0;
    tb_req_wr_data      = 32'h0000_0000;
    tb_req_wr_be        = 4'h0;
    tb_rsp_ready        = 1'b1;
    repeat (32) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(30ms);
    log_fatal(1, "OPEN WORD TB", "simulation timeout");
  end

  sdram_open_word_ctrl u_word_ctrl (
    .I_CLK       (tb_clk),
    .I_RST_N     (tb_rst_n),
    .I_INIT_DONE (tb_init_done),
    .I_REQ_VALID (tb_req_valid),
    .O_REQ_READY (tb_req_ready),
    .I_REQ_IS_WRITE(tb_req_is_write),
    .I_REQ_ADDR  (tb_req_addr),
    .I_REQ_WR_DATA(tb_req_wr_data),
    .I_REQ_WR_BE (tb_req_wr_be),
    .O_RSP_VALID (tb_rsp_valid),
    .I_RSP_READY (tb_rsp_ready),
    .O_RSP_RD_DATA(tb_rsp_rd_data),
    .O_RSP_STATUS(tb_rsp_status),
    .O_BYTE_REQ_VALID(tb_byte_req_valid),
    .I_BYTE_REQ_READY(tb_byte_req_ready),
    .O_BYTE_REQ_IS_WRITE(tb_byte_req_is_write),
    .O_BYTE_REQ_ADDR(tb_byte_req_addr),
    .O_BYTE_REQ_WR_DATA(tb_byte_req_wr_data),
    .I_BYTE_RSP_VALID(tb_byte_rsp_valid),
    .O_BYTE_RSP_READY(tb_byte_rsp_ready),
    .I_BYTE_RSP_RD_DATA(tb_byte_rsp_rd_data),
    .I_BYTE_RSP_STATUS(tb_byte_rsp_status)
  );

  sdram_open_byte_ctrl #(
    .RESP_TIMEOUT_CYCLES(512)
  ) u_byte_ctrl (
    .I_CLK       (tb_clk),
    .I_CLK_SDRAM (tb_clk_sdram),
    .I_RST_N     (tb_rst_n),
    .I_REQ_VALID (tb_byte_req_valid),
    .O_REQ_READY (tb_byte_req_ready),
    .I_REQ_IS_WRITE(tb_byte_req_is_write),
    .I_REQ_ADDR  (tb_byte_req_addr),
    .I_REQ_WR_DATA(tb_byte_req_wr_data),
    .O_RSP_VALID (tb_byte_rsp_valid),
    .I_RSP_READY (tb_byte_rsp_ready),
    .O_RSP_RD_DATA(tb_byte_rsp_rd_data),
    .O_RSP_STATUS(tb_byte_rsp_status),
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

  task automatic issue_word_request(
    input logic        is_write,
    input logic [20:0] addr,
    input logic [31:0] wr_data,
    input logic [3:0]  wr_be
  );
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_req_ready) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 4000) begin
          log_fatal(1, "OPEN WORD TB", "timeout waiting request ready");
        end
      end

      @(posedge tb_clk);
      tb_req_valid    <= 1'b1;
      tb_req_is_write <= is_write;
      tb_req_addr     <= addr;
      tb_req_wr_data  <= wr_data;
      tb_req_wr_be    <= wr_be;
      @(posedge tb_clk);
      tb_req_valid    <= 1'b0;
      tb_req_is_write <= 1'b0;
      tb_req_addr     <= '0;
      tb_req_wr_data  <= 32'h0000_0000;
      tb_req_wr_be    <= 4'h0;
    end
  endtask

  task automatic expect_response(
    input logic [31:0] exp_status,
    input logic [31:0] exp_rd_data,
    input string       label
  );
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_rsp_valid) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 8000) begin
          log_fatal(1, "OPEN WORD TB", {"timeout waiting response: ", label});
        end
      end

      if (tb_rsp_status !== exp_status) begin
        log_fatal(
          1,
          "OPEN WORD TB",
          $sformatf("%s status mismatch exp=0x%08h act=0x%08h", label, exp_status, tb_rsp_status)
        );
      end

      if ((exp_status == 32'h0000_0000) && (tb_rsp_rd_data !== exp_rd_data)) begin
        log_fatal(
          1,
          "OPEN WORD TB",
          $sformatf("%s data mismatch exp=0x%08h act=0x%08h", label, exp_rd_data, tb_rsp_rd_data)
        );
      end

      @(posedge tb_clk);
    end
  endtask

`include "testcase_smoke.svh"

endmodule
