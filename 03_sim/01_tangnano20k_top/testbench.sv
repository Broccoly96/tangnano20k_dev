`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : testbench.sv
// Description  : TangNano20K SDRAM HS integration smoke test.
//                - Drives the HS-native SDRAM host/control layer at 48 MHz.
//                - Uses a compact behavioral HS command responder.
//                - Verifies startup self-test PASS and periodic AUTO_REFRESH.
// Usage        : cd 03_sim
//                python sim.py 01_tangnano20k_top\testbench.sv recompile
//////////////////////////////////////////////////////////////////////////////////

module testbench;

  import tb_log_pkg::*;
  import sdram_hs_cmd_pkg::*;

  localparam time CLK_HALF_PERIOD = 10417ps;
  localparam int unsigned TEST_WORDS = 4;
  localparam int unsigned CLEAR_WORDS = 4;

  logic        tb_clk;
  logic        tb_rst_n;
  logic        tb_cli_rx_valid;
  logic [7:0]  tb_cli_rx_data;
  uart_log_evt_if tb_test_evt_if ();
  uart_log_evt_if tb_host_evt_if ();
  logic [31:0] tb_sdrc_rd_data;
  logic        tb_sdrc_cmd_ack;
  logic        tb_sdrc_init_done;
  logic        tb_init_done;
  logic        tb_test_active;
  logic        tb_test_pass;
  logic        tb_test_fail;
  logic        tb_host_busy;
  logic        tb_sdrc_rst_n;
  logic        tb_sdrc_cmd_en;
  logic [2:0]  tb_sdrc_cmd;
  logic        tb_sdrc_precharge_ctrl;
  logic [20:0] tb_sdrc_addr;
  logic [7:0]  tb_sdrc_data_len;
  logic [3:0]  tb_sdrc_dqm;
  logic [31:0] tb_sdrc_wr_data;
  logic        tb_sdrc_read_sample_valid;

  logic [31:0] s_mem [0:CLEAR_WORDS-1];
  logic [20:0] s_active_addr;
  logic [20:0] s_read_addr;
  logic        s_active_open;
  int unsigned s_refresh_count;
  int unsigned s_cmd_count;

  assign tb_test_evt_if.evt_ready = 1'b1;
  assign tb_test_evt_if.enable    = 1'b1;
  assign tb_host_evt_if.evt_ready = 1'b1;
  assign tb_host_evt_if.enable    = 1'b1;

  initial begin
    tb_log_pkg::configure_logging(tb_log_pkg::LOG_INFO);
    tb_clk = 1'b0;
    forever #(CLK_HALF_PERIOD) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n = 1'b0;
    tb_cli_rx_valid = 1'b0;
    tb_cli_rx_data = 8'h00;
    tb_sdrc_init_done = 1'b0;
    repeat (16) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  // Behavioral HS responder.
  // ACTIVE opens a row/bank address, READ/WRITE must follow an ACTIVE, and
  // AUTO_REFRESH must not appear inside an active command pair.
  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      tb_sdrc_cmd_ack <= 1'b0;
      tb_sdrc_init_done <= 1'b0;
      s_active_addr <= '0;
      s_read_addr <= '0;
      s_active_open <= 1'b0;
      s_refresh_count <= 0;
      s_cmd_count <= 0;
      for (int idx = 0; idx < CLEAR_WORDS; idx++) begin
        s_mem[idx] <= 32'h0000_0000;
      end
    end else begin
      tb_sdrc_cmd_ack <= tb_sdrc_cmd_en;

      if (tb_sdrc_rst_n) begin
        tb_sdrc_init_done <= 1'b1;
      end else begin
        tb_sdrc_init_done <= 1'b0;
        s_active_open <= 1'b0;
      end

      if (tb_sdrc_cmd_en) begin
        s_cmd_count <= s_cmd_count + 1;
        tb_log_pkg::log_debug(
          "TOP HS SMOKE",
          $sformatf(
            "cmd=%s addr=0x%05h len=%0d wr=0x%08h sample=%0b",
            sdram_hs_cmd_name(tb_sdrc_cmd),
            tb_sdrc_addr,
            tb_sdrc_data_len + 1,
            tb_sdrc_wr_data,
            tb_sdrc_read_sample_valid
          )
        );
        case (tb_sdrc_cmd)
          SDRAM_HS_CMD_ACTIVE: begin
            if (s_active_open) begin
              tb_log_pkg::log_fatal(1, "TOP HS SMOKE", "ACTIVE while row is already open");
            end
            s_active_addr <= tb_sdrc_addr;
            s_active_open <= 1'b1;
          end

          SDRAM_HS_CMD_WRITE: begin
            if (!s_active_open) begin
              tb_log_pkg::log_fatal(1, "TOP HS SMOKE", "WRITE without preceding ACTIVE");
            end
            if (tb_sdrc_addr >= CLEAR_WORDS) begin
              tb_log_pkg::log_fatal(1, "TOP HS SMOKE", "WRITE address outside test memory");
            end
            s_mem[tb_sdrc_addr] <= tb_sdrc_wr_data;
            tb_log_pkg::log_debug(
              "TOP HS SMOKE",
              $sformatf("write mem[0x%05h] = 0x%08h", tb_sdrc_addr, tb_sdrc_wr_data)
            );
            s_active_open <= 1'b0;
          end

          SDRAM_HS_CMD_READ: begin
            if (!s_active_open) begin
              tb_log_pkg::log_fatal(1, "TOP HS SMOKE", "READ without preceding ACTIVE");
            end
            if (tb_sdrc_addr >= CLEAR_WORDS) begin
              tb_log_pkg::log_fatal(1, "TOP HS SMOKE", "READ address outside test memory");
            end
            s_read_addr <= tb_sdrc_addr;
            tb_log_pkg::log_debug(
              "TOP HS SMOKE",
              $sformatf("read request mem[0x%05h] -> 0x%08h", tb_sdrc_addr, s_mem[tb_sdrc_addr])
            );
            s_active_open <= 1'b0;
          end

          SDRAM_HS_CMD_AUTO_REFRESH: begin
            if (s_active_open) begin
              tb_log_pkg::log_fatal(1, "TOP HS SMOKE", "refresh inserted inside ACTIVE pair");
            end
            s_refresh_count <= s_refresh_count + 1;
          end

          default: begin
          end
        endcase
      end
    end
  end

  always_comb begin
    if (tb_sdrc_read_sample_valid && (s_read_addr < CLEAR_WORDS)) begin
      tb_sdrc_rd_data = s_mem[s_read_addr];
    end else begin
      tb_sdrc_rd_data = 32'h0000_0000;
    end
  end

  sdram_emb_hostif_ctrl #(
    .MEMTEST_BURST_WORDS(1),
    .MEMTEST_BURST_COUNT(TEST_WORDS),
    .MEMTEST_TEST_WORDS(TEST_WORDS),
    .MEMTEST_POST_INIT_WAIT_CYCLES(8),
    .MEMTEST_CLEAR_WORDS(CLEAR_WORDS),
    .SDRC_RESET_HOLD_CYCLES(8)
  ) u_sdram_emb_hostif_ctrl (
    .I_CLK(tb_clk),
    .I_RST_N(tb_rst_n),
    .I_CLI_RX_VALID(tb_cli_rx_valid),
    .I_CLI_RX_DATA(tb_cli_rx_data),
    .TEST_EVT_IF(tb_test_evt_if),
    .HOST_EVT_IF(tb_host_evt_if),
    .I_SDRC_RD_DATA(tb_sdrc_rd_data),
    .I_SDRC_CMD_ACK(tb_sdrc_cmd_ack),
    .I_SDRC_INIT_DONE(tb_sdrc_init_done),
    .O_INIT_DONE(tb_init_done),
    .O_TEST_ACTIVE(tb_test_active),
    .O_TEST_PASS(tb_test_pass),
    .O_TEST_FAIL(tb_test_fail),
    .O_HOST_BUSY(tb_host_busy),
    .O_SDRC_RST_N(tb_sdrc_rst_n),
    .O_SDRC_CMD_EN(tb_sdrc_cmd_en),
    .O_SDRC_CMD(tb_sdrc_cmd),
    .O_SDRC_PRECHARGE_CTRL(tb_sdrc_precharge_ctrl),
    .O_SDRC_ADDR(tb_sdrc_addr),
    .O_SDRC_DATA_LEN(tb_sdrc_data_len),
    .O_SDRC_DQM(tb_sdrc_dqm),
    .O_SDRC_WR_DATA(tb_sdrc_wr_data),
    .O_SDRC_READ_SAMPLE_VALID(tb_sdrc_read_sample_valid)
  );

  `include "testcase_hs_smoke.svh"

endmodule
