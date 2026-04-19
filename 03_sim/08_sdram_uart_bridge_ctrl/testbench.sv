`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import sdram_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 10ns;
  localparam int unsigned MEM_WORDS = 256;
  localparam int unsigned BURST_WORDS = 26;
  localparam int unsigned WRITE_STREAM_CYCLES = BURST_WORDS + 2;

  typedef enum logic [2:0] {
    UIF_IDLE,
    UIF_WRITE_BUSY,
    UIF_READ_BUSY
  } uif_state_e;

  logic        tb_clk;
  logic        tb_rst_n;
  logic        tb_enable;
  logic        tb_cli_rx_valid;
  logic [7:0]  tb_cli_rx_data;
  logic        tb_sdrc_init_done;
  logic        tb_sdrc_busy_n;
  logic        tb_sdrc_wrd_ack;
  logic        tb_sdrc_rd_valid;
  logic [31:0] tb_sdrc_rd_data;
  logic [15:0] tb_status_addr;
  logic [31:0] tb_status_rd_data;
  logic        tb_selftest_restart_req;
  logic        tb_host_access_enable;
  logic        tb_sdrc_wr_n;
  logic        tb_sdrc_rd_n;
  logic [20:0] tb_sdrc_addr;
  logic [7:0]  tb_sdrc_data_len;
  logic [3:0]  tb_sdrc_dqm;
  logic [31:0] tb_sdrc_wr_data;
  logic        tb_sdrc_active;
  logic        tb_evt_valid;
  logic [7:0]  tb_evt_id;
  logic [31:0] tb_evt_arg0;
  logic [31:0] tb_evt_arg1;
  logic [31:0] tb_evt_arg2;
  logic        tb_evt_ready;
  logic        tb_cmd_busy;
  integer      tb_restart_count;

  logic [31:0] mem_words [0:MEM_WORDS-1];

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n         = 1'b0;
    tb_enable        = 1'b1;
    tb_cli_rx_valid  = 1'b0;
    tb_cli_rx_data   = 8'h00;
    tb_sdrc_init_done= 1'b0;
    tb_host_access_enable = 1'b1;
    tb_sdrc_busy_n   = 1'b1;
    tb_sdrc_wrd_ack  = 1'b0;
    tb_sdrc_rd_valid = 1'b0;
    tb_sdrc_rd_data  = 32'h0;
    tb_evt_ready     = 1'b0;
    for (int idx = 0; idx < MEM_WORDS; idx++) begin
      mem_words[idx] = 32'h2000_0000 + idx;
    end
    repeat (8) @(posedge tb_clk);
    tb_rst_n          = 1'b1;
    tb_sdrc_init_done = 1'b1;
  end

  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      tb_restart_count <= 0;
    end else if (tb_selftest_restart_req) begin
      tb_restart_count <= tb_restart_count + 1;
    end
  end

  initial begin
    #(200us);
    log_fatal(1, "BRIDGE CTRL TB", "simulation timeout");
  end

  sdram_uart_bridge_ctrl u_dut (
    .I_CLK           (tb_clk),
    .I_RST_N         (tb_rst_n),
    .I_ENABLE        (tb_enable),
    .I_HOST_ACCESS_ENABLE(tb_host_access_enable),
    .I_CLI_RX_VALID  (tb_cli_rx_valid),
    .I_CLI_RX_DATA   (tb_cli_rx_data),
    .O_RAW_RX_BYPASS (),
    .O_RAW_TX_MODE   (),
    .O_RAW_TX_VALID  (),
    .O_RAW_TX_DATA   (),
    .I_RAW_TX_READY  (1'b0),
    .I_SDRC_INIT_DONE(tb_sdrc_init_done),
    .I_SDRC_BUSY_N   (tb_sdrc_busy_n),
    .I_SDRC_WRD_ACK  (tb_sdrc_wrd_ack),
    .I_SDRC_RD_VALID (tb_sdrc_rd_valid),
    .I_SDRC_RD_DATA  (tb_sdrc_rd_data),
    .I_STATUS_RD_DATA(tb_status_rd_data),
    .O_STATUS_ADDR   (tb_status_addr),
    .O_SELFTEST_RESTART_REQ(tb_selftest_restart_req),
    .O_SDRC_WR_N     (tb_sdrc_wr_n),
    .O_SDRC_RD_N     (tb_sdrc_rd_n),
    .O_SDRC_ADDR     (tb_sdrc_addr),
    .O_SDRC_DATA_LEN (tb_sdrc_data_len),
    .O_SDRC_DQM      (tb_sdrc_dqm),
    .O_SDRC_WR_DATA  (tb_sdrc_wr_data),
    .O_SDRC_ACTIVE   (tb_sdrc_active),
    .O_EVT_VALID     (tb_evt_valid),
    .O_EVT_ID        (tb_evt_id),
    .O_EVT_ARG0      (tb_evt_arg0),
    .O_EVT_ARG1      (tb_evt_arg1),
    .O_EVT_ARG2      (tb_evt_arg2),
    .I_EVT_READY     (tb_evt_ready),
    .O_CMD_BUSY      (tb_cmd_busy)
  );

  always_comb begin
    tb_status_rd_data = 32'h0000_0000;
    case (tb_status_addr[5:2])
      4'h0: tb_status_rd_data = 32'h0300_0008;
      4'h1: tb_status_rd_data = 32'hABCD_1234;
      4'h2: tb_status_rd_data = 32'h0000_0010;
      4'h9: tb_status_rd_data = 32'h0300_0000;
      default: tb_status_rd_data = mem_words[tb_status_addr[9:2]];
    endcase
  end

  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      tb_sdrc_busy_n  <= 1'b1;
      tb_sdrc_rd_valid<= 1'b0;
      tb_sdrc_rd_data <= 32'h0;
      tb_sdrc_wrd_ack <= 1'b0;
    end else begin
      tb_sdrc_rd_valid <= 1'b0;
      tb_sdrc_wrd_ack  <= 1'b0;
      if (!tb_sdrc_wr_n) begin
        tb_sdrc_busy_n  <= 1'b0;
        tb_sdrc_wrd_ack <= 1'b1;
        mem_words[tb_sdrc_addr] <= tb_sdrc_wr_data;
      end else if (!tb_sdrc_rd_n) begin
        tb_sdrc_busy_n   <= 1'b0;
        tb_sdrc_rd_valid <= 1'b1;
        tb_sdrc_rd_data  <= mem_words[tb_sdrc_addr];
      end else begin
        tb_sdrc_busy_n <= 1'b1;
      end
    end
  end

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

  task automatic expect_event(
    input logic [7:0]  exp_id,
    input logic [31:0] exp_arg0,
    input logic [31:0] exp_arg1,
    input logic [31:0] exp_arg2,
    input string       label
  );
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_evt_valid) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 500) begin
          log_fatal(1, "BRIDGE CTRL TB", {"timeout waiting event: ", label});
        end
      end

      if ((tb_evt_id !== exp_id) ||
          (tb_evt_arg0 !== exp_arg0) ||
          (tb_evt_arg1 !== exp_arg1) ||
          (tb_evt_arg2 !== exp_arg2)) begin
        log_fatal(
          1,
          "BRIDGE CTRL TB",
          $sformatf(
            "event mismatch %s id=0x%02h arg0=0x%08h arg1=0x%08h arg2=0x%08h",
            label,
            tb_evt_id,
            tb_evt_arg0,
            tb_evt_arg1,
            tb_evt_arg2
          )
        );
      end

      log_info("BRIDGE CTRL TB", {"event ok: ", label});
      @(posedge tb_clk);
      tb_evt_ready <= 1'b1;
      @(posedge tb_clk);
      tb_evt_ready <= 1'b0;
    end
  endtask

  task automatic expect_restart_count_changed(input int previous_count, input string label);
    begin
      @(posedge tb_clk);
      if (tb_restart_count <= previous_count) begin
        log_fatal(1, "BRIDGE CTRL TB", {"restart pulse was not observed: ", label});
      end
      log_info("BRIDGE CTRL TB", {"restart pulse ok: ", label});
    end
  endtask

`include "testcase_smoke.svh"

endmodule
