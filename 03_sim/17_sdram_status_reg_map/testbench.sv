`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;

  logic [15:0] tb_addr;
  logic        tb_init_done;
  logic        tb_test_active;
  logic        tb_test_pass;
  logic        tb_test_fail;
  logic        tb_host_busy;
  logic        tb_sdrc_reset_active;
  logic        tb_sdrc_cmd_en;
  logic [2:0]  tb_sdrc_cmd;
  logic        tb_sdrc_cmd_ack;
  logic        tb_sdrc_read_sample_valid;
  logic [31:0] tb_sdrc_refresh_status;
  logic [31:0] tb_sdrc_rd_data;
  logic [31:0] tb_memtest_summary;
  logic [7:0]  tb_memtest_state;
  logic [7:0]  tb_memtest_fail_reason;
  logic [20:0] tb_memtest_curr_addr;
  logic [31:0] tb_memtest_expected;
  logic [31:0] tb_memtest_last_read;
  logic [31:0] tb_memtest_last_status;
  logic [31:0] tb_memtest_fail_addr;
  logic [31:0] tb_memtest_fail_expected;
  logic [31:0] tb_memtest_fail_actual;
  logic [31:0] tb_memtest_retry_summary;
  logic [31:0] tb_memtest_retry_data1;
  logic [31:0] tb_memtest_retry_data2;
  logic [31:0] tb_memtest_ctrl_summary;
  logic [31:0] tb_memtest_ctrl_detail;
  logic [31:0] tb_host_dbg_summary;
  logic [31:0] tb_host_dbg_detail;
  logic [31:0] tb_host_dbg_rd_beats;
  logic [31:0] tb_rd_data;

  initial begin
    configure_logging(LOG_DEBUG);
  end

  sdram_status_reg_map u_dut (
    .I_ADDR                  (tb_addr),
    .I_INIT_DONE             (tb_init_done),
    .I_TEST_ACTIVE           (tb_test_active),
    .I_TEST_PASS             (tb_test_pass),
    .I_TEST_FAIL             (tb_test_fail),
    .I_HOST_BUSY             (tb_host_busy),
    .I_SDRC_RESET_ACTIVE     (tb_sdrc_reset_active),
    .I_SDRC_CMD_EN           (tb_sdrc_cmd_en),
    .I_SDRC_CMD              (tb_sdrc_cmd),
    .I_SDRC_CMD_ACK          (tb_sdrc_cmd_ack),
    .I_SDRC_READ_SAMPLE_VALID(tb_sdrc_read_sample_valid),
    .I_SDRC_REFRESH_STATUS   (tb_sdrc_refresh_status),
    .I_SDRC_RD_DATA          (tb_sdrc_rd_data),
    .I_MEMTEST_SUMMARY       (tb_memtest_summary),
    .I_MEMTEST_STATE         (tb_memtest_state),
    .I_MEMTEST_FAIL_REASON   (tb_memtest_fail_reason),
    .I_MEMTEST_CURR_ADDR     (tb_memtest_curr_addr),
    .I_MEMTEST_EXPECTED      (tb_memtest_expected),
    .I_MEMTEST_LAST_READ     (tb_memtest_last_read),
    .I_MEMTEST_LAST_STATUS   (tb_memtest_last_status),
    .I_MEMTEST_FAIL_ADDR     (tb_memtest_fail_addr),
    .I_MEMTEST_FAIL_EXPECTED (tb_memtest_fail_expected),
    .I_MEMTEST_FAIL_ACTUAL   (tb_memtest_fail_actual),
    .I_MEMTEST_RETRY_SUMMARY (tb_memtest_retry_summary),
    .I_MEMTEST_RETRY_DATA1   (tb_memtest_retry_data1),
    .I_MEMTEST_RETRY_DATA2   (tb_memtest_retry_data2),
    .I_MEMTEST_CTRL_SUMMARY  (tb_memtest_ctrl_summary),
    .I_MEMTEST_CTRL_DETAIL   (tb_memtest_ctrl_detail),
    .I_HOST_DBG_SUMMARY      (tb_host_dbg_summary),
    .I_HOST_DBG_DETAIL       (tb_host_dbg_detail),
    .I_HOST_DBG_RD_BEATS     (tb_host_dbg_rd_beats),
    .O_RD_DATA               (tb_rd_data)
  );

  task automatic expect_word(
    input logic [15:0] addr,
    input logic [31:0] exp_data,
    input string       label
  );
    begin
      tb_addr = addr;
      #1ns;
      if (tb_rd_data !== exp_data) begin
        log_fatal(
          1,
          "STATUS MAP TB",
          $sformatf(
            "word mismatch %s addr=0x%04h act=0x%08h exp=0x%08h",
            label,
            addr,
            tb_rd_data,
            exp_data
          )
        );
      end
      log_info("STATUS MAP TB", {"word ok: ", label});
    end
  endtask

`include "testcase_smoke.svh"

endmodule
