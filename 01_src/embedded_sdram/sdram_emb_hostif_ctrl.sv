`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_emb_hostif_ctrl.sv
// Description  : Shared embedded SDRAM host/test controller without SDRAM IP.
//                - Owns startup self-test on the vendor SDRC user interface.
//                - Exposes a debug status-map to uart_log_cli.
//                - Allows linear single-word host SDRAM read/write after PASS.
//                - Uses a write-only status-map control register to reset the
//                  vendor SDRC and rerun the self-test on demand.
//////////////////////////////////////////////////////////////////////////////////

module sdram_emb_hostif_ctrl #(
  parameter int unsigned MEMTEST_BURST_WORDS = 1,
  parameter int unsigned MEMTEST_BURST_COUNT = 8,
  parameter int unsigned MEMTEST_TEST_WORDS = MEMTEST_BURST_WORDS * MEMTEST_BURST_COUNT,
  parameter int unsigned MEMTEST_POST_INIT_WAIT_CYCLES = 20_000,
  parameter int unsigned MEMTEST_CLEAR_WORDS = MEMTEST_TEST_WORDS,
  parameter int unsigned SDRC_RESET_HOLD_CYCLES = 4096
) (
  input  logic              I_CLK,
  input  logic              I_RST_N,
  input  logic              I_CLI_RX_VALID,
  input  logic [7:0]        I_CLI_RX_DATA,
  input  logic [31:0]       I_SDRC_RD_DATA,
  input  logic              I_SDRC_CMD_ACK,
  input  logic              I_SDRC_INIT_DONE,
  output logic              O_INIT_DONE,
  output logic              O_TEST_ACTIVE,
  output logic              O_TEST_PASS,
  output logic              O_TEST_FAIL,
  output logic              O_HOST_BUSY,
  output logic              O_SDRC_RST_N,
  output logic              O_SDRC_CMD_EN,
  output logic [2:0]        O_SDRC_CMD,
  output logic              O_SDRC_PRECHARGE_CTRL,
  output logic [20:0]       O_SDRC_ADDR,
  output logic [7:0]        O_SDRC_DATA_LEN,
  output logic [3:0]        O_SDRC_DQM,
  output logic [31:0]       O_SDRC_WR_DATA,
  output logic              O_SDRC_READ_SAMPLE_VALID,
  uart_log_evt_if.producer  TEST_EVT_IF,
  uart_log_evt_if.producer  HOST_EVT_IF
);

  import sdram_hs_cmd_pkg::*;

  localparam int unsigned REFRESH_INTERVAL_CYCLES = sdram_hs_cmd_pkg::SDRAM_HS_REFRESH_INTERVAL_CYCLES;
  localparam int unsigned REFRESH_CNT_W           = $clog2(REFRESH_INTERVAL_CYCLES + 1);
  localparam int unsigned SDRC_RESET_CNT_W        = (SDRC_RESET_HOLD_CYCLES <= 1) ? 1 : $clog2(SDRC_RESET_HOLD_CYCLES + 1);

  logic        l_test_cmd_en;
  logic [2:0]  l_test_cmd;
  logic        l_test_precharge_ctrl;
  logic [20:0] l_test_addr;
  logic [7:0]  l_test_data_len;
  logic [3:0]  l_test_dqm;
  logic [31:0] l_test_wr_data;
  logic        l_test_pair_active;
  logic        l_test_read_sample_valid;
  logic        l_host_cmd_en;
  logic [2:0]  l_host_cmd;
  logic        l_host_precharge_ctrl;
  logic [20:0] l_host_addr;
  logic [7:0]  l_host_data_len;
  logic [3:0]  l_host_dqm;
  logic [31:0] l_host_wr_data;
  logic        l_host_pair_active;
  logic        l_host_read_sample_valid;
  logic        l_host_sdrc_active;
  logic        l_host_sdrc_selected;
  logic        l_host_access_enable;
  logic [31:0] l_host_dbg_summary;
  logic [31:0] l_host_dbg_detail;
  logic [31:0] l_host_dbg_rd_beats;

  logic [15:0] l_status_addr;
  logic [31:0] l_status_rd_data;

  logic [31:0] l_memtest_summary;
  logic [7:0]  l_memtest_state;
  logic [7:0]  l_memtest_fail_reason;
  logic [20:0] l_memtest_curr_addr;
  logic [31:0] l_memtest_expected;
  logic [31:0] l_memtest_last_read;
  logic [31:0] l_memtest_last_status;
  logic [31:0] l_memtest_fail_addr;
  logic [31:0] l_memtest_fail_expected;
  logic [31:0] l_memtest_fail_actual;
  logic [31:0] l_memtest_retry_summary;
  logic [31:0] l_memtest_retry_data1;
  logic [31:0] l_memtest_retry_data2;
  logic [31:0] l_memtest_ctrl_summary;
  logic [31:0] l_memtest_ctrl_detail;
  logic        l_memtest_test_active;
  logic        l_memtest_test_pass;
  logic        l_memtest_test_fail;
  logic        l_selftest_restart_req;
  logic        l_sdrc_local_rst_n;
  logic        l_sdrc_init_done_safe;
  logic        l_sdrc_reset_active;
  logic        l_manual_selftest_running;
  logic        r_manual_selftest_pending;
  logic        l_sdrc_ready_for_client;
  logic        l_any_pair_active;
  logic        l_refresh_can_start;
  logic        l_refresh_cmd_en;
  logic        l_test_cmd_ack;
  logic        l_host_cmd_ack;
  logic [31:0] l_refresh_status_word;

  logic [REFRESH_CNT_W-1:0]     r_refresh_cnt;
  logic                         r_refresh_due;
  logic                         r_refresh_active;
  logic                         r_refresh_cmd_sent;
  logic [7:0]                   r_refresh_defer_count;
  logic [SDRC_RESET_CNT_W-1:0]  r_sdrc_reset_cnt;

  assign l_sdrc_reset_active        = (r_sdrc_reset_cnt != 0);
  assign l_sdrc_local_rst_n         = I_RST_N && !l_sdrc_reset_active;
  assign l_sdrc_init_done_safe      = I_SDRC_INIT_DONE && l_sdrc_local_rst_n;
  assign l_manual_selftest_running  = r_manual_selftest_pending && !l_memtest_test_pass && !l_memtest_test_fail;
  assign l_host_access_enable       = l_sdrc_local_rst_n && l_sdrc_init_done_safe && l_memtest_test_pass && !l_memtest_test_active && !l_memtest_test_fail && !l_manual_selftest_running;

  assign O_INIT_DONE                = l_sdrc_init_done_safe;
  assign O_TEST_ACTIVE              = l_manual_selftest_running ? 1'b1 : l_memtest_test_active;
  assign O_TEST_PASS                = l_manual_selftest_running ? 1'b0 : l_memtest_test_pass;
  assign O_TEST_FAIL                = l_manual_selftest_running ? 1'b0 : l_memtest_test_fail;
  assign O_SDRC_RST_N               = l_sdrc_local_rst_n;
  assign l_any_pair_active          = l_test_pair_active || l_host_pair_active;
  assign l_host_sdrc_selected       = (l_host_sdrc_active == 1'b1);
  assign l_refresh_can_start        = l_sdrc_init_done_safe && r_refresh_due && !r_refresh_active && !l_any_pair_active;
  assign l_refresh_cmd_en           = r_refresh_active && !r_refresh_cmd_sent;
  assign l_sdrc_ready_for_client    = l_sdrc_local_rst_n && l_sdrc_init_done_safe && !r_refresh_active && (!r_refresh_due || l_any_pair_active);
  assign l_test_cmd_ack             = (!r_refresh_active && !l_host_sdrc_selected) ? I_SDRC_CMD_ACK : 1'b0;
  assign l_host_cmd_ack             = (!r_refresh_active && l_host_sdrc_selected) ? I_SDRC_CMD_ACK : 1'b0;


  // Self-test owns SDRC until PASS. Refresh can preempt only between
  // ACTIVE/read-write command pairs. After PASS, the UART host may issue
  // linear single-word SDRAM accesses through the bridge access engine.
  assign O_SDRC_CMD_EN            = !l_sdrc_local_rst_n ? 1'b0 :
                                    (l_refresh_cmd_en ? 1'b1 :
                                    (l_host_sdrc_selected ? l_host_cmd_en : l_test_cmd_en));
  assign O_SDRC_CMD               = !l_sdrc_local_rst_n ? SDRAM_HS_CMD_NOP :
                                    (l_refresh_cmd_en ? SDRAM_HS_CMD_AUTO_REFRESH :
                                    (l_host_sdrc_selected ? l_host_cmd : l_test_cmd));
  assign O_SDRC_PRECHARGE_CTRL    = !l_sdrc_local_rst_n ? 1'b0 :
                                    (l_refresh_cmd_en ? 1'b0 :
                                    (l_host_sdrc_selected ? l_host_precharge_ctrl : l_test_precharge_ctrl));
  assign O_SDRC_ADDR              = !l_sdrc_local_rst_n ? 21'h00000 :
                                    (l_host_sdrc_selected ? l_host_addr : l_test_addr);
  assign O_SDRC_DATA_LEN          = !l_sdrc_local_rst_n ? 8'h00 :
                                    (l_host_sdrc_selected ? l_host_data_len : l_test_data_len);
  assign O_SDRC_DQM               = !l_sdrc_local_rst_n ? 4'h0 :
                                    (l_host_sdrc_selected ? l_host_dqm : l_test_dqm);
  assign O_SDRC_WR_DATA           = !l_sdrc_local_rst_n ? 32'h0000_0000 :
                                    (l_host_sdrc_selected ? l_host_wr_data : l_test_wr_data);
  assign O_SDRC_READ_SAMPLE_VALID = !l_sdrc_local_rst_n ? 1'b0 :
                                    (l_host_sdrc_selected ? l_host_read_sample_valid : l_test_read_sample_valid);
  assign l_refresh_status_word = {
    8'h52,
    r_refresh_due,
    r_refresh_active,
    r_refresh_cmd_sent,
    l_refresh_can_start,
    l_any_pair_active,
    l_sdrc_ready_for_client,
    2'b00,
    r_refresh_defer_count,
    r_refresh_cnt[7:0]
  };

  // Holds only the SDRC and selftest logic in reset after a manual trigger.
  // The UART/status bridge remains live so the host can receive WRITE_ACK and
  // poll the reinitialization progress.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_sdrc_reset_cnt <= '0;
    end else if (l_selftest_restart_req) begin
      r_sdrc_reset_cnt <= SDRC_RESET_HOLD_CYCLES;
    end else if (r_sdrc_reset_cnt != 0) begin
      r_sdrc_reset_cnt <= r_sdrc_reset_cnt - 1'b1;
    end
  end

  // Presents manual reruns as an active test immediately after the host trigger.
  // This clears stale PASS/FAIL indications while the SDRC is being reset and
  // reinitialized, even before the memtest FSM reaches its transfer states.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_manual_selftest_pending <= 1'b0;
    end else if (l_selftest_restart_req) begin
      r_manual_selftest_pending <= 1'b1;
    end else if (r_manual_selftest_pending && (l_memtest_test_pass || l_memtest_test_fail)) begin
      r_manual_selftest_pending <= 1'b0;
    end
  end

  // Generates periodic AUTO_REFRESH commands for the HS IP. Refresh requests
  // are allowed to wait while an ACTIVE/read-write pair is in progress, but a
  // pending refresh blocks the next ACTIVE launch until the refresh completes.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_refresh_cnt         <= '0;
      r_refresh_due         <= 1'b0;
      r_refresh_active      <= 1'b0;
      r_refresh_cmd_sent    <= 1'b0;
      r_refresh_defer_count <= 8'h00;
    end else if (!l_sdrc_init_done_safe) begin
      r_refresh_cnt         <= '0;
      r_refresh_due         <= 1'b0;
      r_refresh_active      <= 1'b0;
      r_refresh_cmd_sent    <= 1'b0;
      r_refresh_defer_count <= 8'h00;
    end else begin
      if (!r_refresh_due && !r_refresh_active) begin
        if (r_refresh_cnt >= REFRESH_INTERVAL_CYCLES - 1) begin
          r_refresh_due <= 1'b1;
          r_refresh_cnt <= '0;
        end else begin
          r_refresh_cnt <= r_refresh_cnt + 1'b1;
        end
      end

      if (r_refresh_due && l_any_pair_active && !r_refresh_active &&
          (r_refresh_defer_count != 8'hFF)) begin
        r_refresh_defer_count <= r_refresh_defer_count + 1'b1;
      end

      if (l_refresh_can_start) begin
        r_refresh_active   <= 1'b1;
        r_refresh_cmd_sent <= 1'b0;
      end

      if (l_refresh_cmd_en) begin
        r_refresh_cmd_sent <= 1'b1;
      end

      if (r_refresh_active && I_SDRC_CMD_ACK) begin
        r_refresh_active      <= 1'b0;
        r_refresh_due         <= 1'b0;
        r_refresh_cmd_sent    <= 1'b0;
        r_refresh_defer_count <= 8'h00;
        r_refresh_cnt         <= '0;
      end
    end
  end

  sdram_memtest_ctrl #(
    .BURST_WORDS            (MEMTEST_BURST_WORDS),
    .BURST_COUNT            (MEMTEST_BURST_COUNT),
    .TEST_WORDS             (MEMTEST_TEST_WORDS),
    .POST_INIT_WAIT_CYCLES  (MEMTEST_POST_INIT_WAIT_CYCLES),
    .CLEAR_WORDS            (MEMTEST_CLEAR_WORDS)
  ) u_sdram_memtest_ctrl (
    .I_CLK                  (I_CLK),
    .I_RST_N                (l_sdrc_local_rst_n),
    .I_SDRC_INIT_DONE       (l_sdrc_init_done_safe),
    .I_SDRC_READY           (l_sdrc_ready_for_client),
    .I_SDRC_CMD_ACK         (l_test_cmd_ack),
    .I_SDRC_RD_DATA         (I_SDRC_RD_DATA),
    .O_SDRC_CMD_EN          (l_test_cmd_en),
    .O_SDRC_CMD             (l_test_cmd),
    .O_SDRC_PRECHARGE_CTRL  (l_test_precharge_ctrl),
    .O_SDRC_ADDR            (l_test_addr),
    .O_SDRC_DATA_LEN        (l_test_data_len),
    .O_SDRC_DQM             (l_test_dqm),
    .O_SDRC_WR_DATA         (l_test_wr_data),
    .O_SDRC_PAIR_ACTIVE     (l_test_pair_active),
    .O_READ_SAMPLE_VALID    (l_test_read_sample_valid),
    .O_TEST_ACTIVE          (l_memtest_test_active),
    .O_TEST_PASS            (l_memtest_test_pass),
    .O_TEST_FAIL            (l_memtest_test_fail),
    .O_DBG_MEM_SUMMARY      (l_memtest_summary),
    .O_DBG_STATE            (l_memtest_state),
    .O_DBG_FAIL_REASON      (l_memtest_fail_reason),
    .O_DBG_CURRENT_ADDR     (l_memtest_curr_addr),
    .O_DBG_EXPECTED_WORD    (l_memtest_expected),
    .O_DBG_LAST_READ_DATA   (l_memtest_last_read),
    .O_DBG_LAST_STATUS      (l_memtest_last_status),
    .O_DBG_FAIL_ADDR        (l_memtest_fail_addr),
    .O_DBG_FAIL_EXPECTED    (l_memtest_fail_expected),
    .O_DBG_FAIL_ACTUAL      (l_memtest_fail_actual),
    .O_DBG_RETRY_SUMMARY    (l_memtest_retry_summary),
    .O_DBG_RETRY_DATA1      (l_memtest_retry_data1),
    .O_DBG_RETRY_DATA2      (l_memtest_retry_data2),
    .O_DBG_CTRL_SUMMARY     (l_memtest_ctrl_summary),
    .O_DBG_CTRL_DETAIL      (l_memtest_ctrl_detail),
    .TEST_EVT_IF            (TEST_EVT_IF)
  );

  sdram_status_reg_map u_sdram_status_reg_map (
    .I_ADDR                     (l_status_addr),
    .I_INIT_DONE                (l_sdrc_init_done_safe),
    .I_TEST_ACTIVE              (O_TEST_ACTIVE),
    .I_TEST_PASS                (O_TEST_PASS),
    .I_TEST_FAIL                (O_TEST_FAIL),
    .I_HOST_BUSY                (O_HOST_BUSY),
    .I_SDRC_RESET_ACTIVE        (l_sdrc_reset_active),
    .I_SDRC_CMD_EN              (O_SDRC_CMD_EN),
    .I_SDRC_CMD                 (O_SDRC_CMD),
    .I_SDRC_CMD_ACK             (I_SDRC_CMD_ACK),
    .I_SDRC_READ_SAMPLE_VALID   (O_SDRC_READ_SAMPLE_VALID),
    .I_SDRC_REFRESH_STATUS      (l_refresh_status_word),
    .I_SDRC_RD_DATA             (I_SDRC_RD_DATA),
    .I_MEMTEST_SUMMARY          (l_memtest_summary),
    .I_MEMTEST_STATE            (l_memtest_state),
    .I_MEMTEST_FAIL_REASON      (l_memtest_fail_reason),
    .I_MEMTEST_CURR_ADDR        (l_memtest_curr_addr),
    .I_MEMTEST_EXPECTED         (l_memtest_expected),
    .I_MEMTEST_LAST_READ        (l_memtest_last_read),
    .I_MEMTEST_LAST_STATUS      (l_memtest_last_status),
    .I_MEMTEST_FAIL_ADDR        (l_memtest_fail_addr),
    .I_MEMTEST_FAIL_EXPECTED    (l_memtest_fail_expected),
    .I_MEMTEST_FAIL_ACTUAL      (l_memtest_fail_actual),
    .I_MEMTEST_RETRY_SUMMARY    (l_memtest_retry_summary),
    .I_MEMTEST_RETRY_DATA1      (l_memtest_retry_data1),
    .I_MEMTEST_RETRY_DATA2      (l_memtest_retry_data2),
    .I_MEMTEST_CTRL_SUMMARY     (l_memtest_ctrl_summary),
    .I_MEMTEST_CTRL_DETAIL      (l_memtest_ctrl_detail),
    .I_HOST_DBG_SUMMARY         (l_host_dbg_summary),
    .I_HOST_DBG_DETAIL          (l_host_dbg_detail),
    .I_HOST_DBG_RD_BEATS        (l_host_dbg_rd_beats),
    .O_RD_DATA                  (l_status_rd_data)
  );

  sdram_uart_bridge_ctrl u_sdram_uart_bridge_ctrl (
    .I_CLK                    (I_CLK),
    .I_RST_N                  (I_RST_N),
    .I_ENABLE                 (1'b1),
    .I_HOST_ACCESS_ENABLE     (l_host_access_enable),
    .I_CLI_RX_VALID           (I_CLI_RX_VALID),
    .I_CLI_RX_DATA            (I_CLI_RX_DATA),
    .I_SDRC_INIT_DONE         (l_sdrc_init_done_safe),
    .I_SDRC_READY             (l_sdrc_ready_for_client),
    .I_SDRC_CMD_ACK           (l_host_cmd_ack),
    .I_SDRC_RD_DATA           (I_SDRC_RD_DATA),
    .I_STATUS_RD_DATA         (l_status_rd_data),
    .O_STATUS_ADDR            (l_status_addr),
    .O_SELFTEST_RESTART_REQ   (l_selftest_restart_req),
    .O_SDRC_CMD_EN            (l_host_cmd_en),
    .O_SDRC_CMD               (l_host_cmd),
    .O_SDRC_PRECHARGE_CTRL    (l_host_precharge_ctrl),
    .O_SDRC_ADDR              (l_host_addr),
    .O_SDRC_DATA_LEN          (l_host_data_len),
    .O_SDRC_DQM               (l_host_dqm),
    .O_SDRC_WR_DATA           (l_host_wr_data),
    .O_SDRC_PAIR_ACTIVE       (l_host_pair_active),
    .O_READ_SAMPLE_VALID      (l_host_read_sample_valid),
    .O_SDRC_ACTIVE            (l_host_sdrc_active),
    .O_HOST_DBG_SUMMARY       (l_host_dbg_summary),
    .O_HOST_DBG_DETAIL        (l_host_dbg_detail),
    .O_HOST_DBG_RD_BEATS      (l_host_dbg_rd_beats),
    .O_CMD_BUSY               (O_HOST_BUSY),
    .HOST_EVT_IF              (HOST_EVT_IF)
  );

endmodule
