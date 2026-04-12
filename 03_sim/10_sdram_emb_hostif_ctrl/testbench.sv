`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import sdram_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 41667ps;
  localparam int unsigned MEM_WORDS = 1024;

  typedef enum logic [2:0] {
    UIF_IDLE,
    UIF_WRITE_BUSY,
    UIF_READ_BUSY
  } uif_state_e;

  logic        tb_clk;
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
  logic        tb_host_evt_ready;
  logic [31:0] tb_sdrc_rd_data;
  logic        tb_sdrc_busy_n;
  logic        tb_sdrc_rd_valid;
  logic        tb_sdrc_wrd_ack;
  logic        tb_sdrc_init_done;
  logic        tb_init_done;
  logic        tb_test_active;
  logic        tb_test_pass;
  logic        tb_test_fail;
  logic        tb_host_busy;
  logic        tb_sdrc_wr_n;
  logic        tb_sdrc_rd_n;
  logic [20:0] tb_sdrc_addr;
  logic [7:0]  tb_sdrc_data_len;
  logic [3:0]  tb_sdrc_dqm;
  logic [31:0] tb_sdrc_wr_data;

  logic [31:0] mem_words [0:MEM_WORDS-1];
  uif_state_e  st_uif;
  logic [20:0] r_uif_base_addr;
  logic [7:0]  r_uif_len;
  logic [7:0]  r_uif_count;

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n         = 1'b0;
    tb_cli_rx_valid  = 1'b0;
    tb_cli_rx_data   = 8'h00;
    tb_host_evt_ready= 1'b0;
    tb_sdrc_rd_data  = 32'h0;
    tb_sdrc_busy_n   = 1'b1;
    tb_sdrc_rd_valid = 1'b0;
    tb_sdrc_wrd_ack  = 1'b0;
    tb_sdrc_init_done= 1'b0;
    st_uif           = UIF_IDLE;
    r_uif_base_addr  = '0;
    r_uif_len        = '0;
    r_uif_count      = '0;
    for (int idx = 0; idx < MEM_WORDS; idx++) begin
      mem_words[idx] = 32'h3000_0000 + idx;
    end
    repeat (32) @(posedge tb_clk);
    tb_rst_n = 1'b1;
    repeat (32) @(posedge tb_clk);
    tb_sdrc_init_done = 1'b1;
  end

  initial begin
    #(5ms);
    log_fatal(1, "HOSTIF CTRL TB", "simulation timeout");
  end

  sdram_emb_hostif_ctrl #(
    .MEMTEST_CLEAR_WORDS(1024)
  ) u_dut (
    .I_CLK           (tb_clk),
    .I_RST_N         (tb_rst_n),
    .I_CLI_RX_VALID  (tb_cli_rx_valid),
    .I_CLI_RX_DATA   (tb_cli_rx_data),
    .O_RAW_RX_BYPASS (),
    .O_RAW_TX_MODE   (),
    .O_RAW_TX_VALID  (),
    .O_RAW_TX_DATA   (),
    .I_RAW_TX_READY  (1'b0),
    .O_TEST_EVT_VALID(tb_test_evt_valid),
    .O_TEST_EVT_ID   (tb_test_evt_id),
    .O_TEST_EVT_ARG0 (tb_test_evt_arg0),
    .O_TEST_EVT_ARG1 (tb_test_evt_arg1),
    .O_TEST_EVT_ARG2 (tb_test_evt_arg2),
    .I_TEST_EVT_READY(1'b1),
    .O_HOST_EVT_VALID(tb_host_evt_valid),
    .O_HOST_EVT_ID   (tb_host_evt_id),
    .O_HOST_EVT_ARG0 (tb_host_evt_arg0),
    .O_HOST_EVT_ARG1 (tb_host_evt_arg1),
    .O_HOST_EVT_ARG2 (tb_host_evt_arg2),
    .I_HOST_EVT_READY(tb_host_evt_ready),
    .I_SDRC_RD_DATA  (tb_sdrc_rd_data),
    .I_SDRC_BUSY_N   (tb_sdrc_busy_n),
    .I_SDRC_RD_VALID (tb_sdrc_rd_valid),
    .I_SDRC_WRD_ACK  (tb_sdrc_wrd_ack),
    .I_SDRC_INIT_DONE(tb_sdrc_init_done),
    .O_INIT_DONE     (tb_init_done),
    .O_TEST_ACTIVE   (tb_test_active),
    .O_TEST_PASS     (tb_test_pass),
    .O_TEST_FAIL     (tb_test_fail),
    .O_HOST_BUSY     (tb_host_busy),
    .O_SDRC_WR_N     (tb_sdrc_wr_n),
    .O_SDRC_RD_N     (tb_sdrc_rd_n),
    .O_SDRC_ADDR     (tb_sdrc_addr),
    .O_SDRC_DATA_LEN (tb_sdrc_data_len),
    .O_SDRC_DQM      (tb_sdrc_dqm),
    .O_SDRC_WR_DATA  (tb_sdrc_wr_data)
  );

  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      st_uif          <= UIF_IDLE;
      tb_sdrc_busy_n  <= 1'b1;
      tb_sdrc_rd_valid<= 1'b0;
      tb_sdrc_rd_data <= 32'h0;
      tb_sdrc_wrd_ack <= 1'b0;
      r_uif_base_addr <= '0;
      r_uif_len       <= '0;
      r_uif_count     <= '0;
    end else begin
      tb_sdrc_rd_valid <= 1'b0;
      tb_sdrc_wrd_ack  <= 1'b0;
      case (st_uif)
        UIF_IDLE: begin
          tb_sdrc_busy_n <= 1'b1;
          r_uif_count    <= '0;
          if (!tb_sdrc_wr_n) begin
            r_uif_base_addr <= tb_sdrc_addr;
            r_uif_len       <= tb_sdrc_data_len + 1'b1;
            tb_sdrc_busy_n  <= 1'b0;
            tb_sdrc_wrd_ack <= 1'b1;
            mem_words[tb_sdrc_addr] <= tb_sdrc_wr_data;
            r_uif_count    <= 8'd1;
            st_uif         <= UIF_WRITE_BUSY;
          end else if (!tb_sdrc_rd_n) begin
            r_uif_base_addr <= tb_sdrc_addr;
            r_uif_len       <= tb_sdrc_data_len + 1'b1;
            tb_sdrc_busy_n  <= 1'b0;
            st_uif          <= UIF_READ_BUSY;
          end
        end

        UIF_WRITE_BUSY: begin
          if (r_uif_count < r_uif_len) begin
            mem_words[r_uif_base_addr + r_uif_count] <= tb_sdrc_wr_data;
            r_uif_count <= r_uif_count + 1'b1;
          end else begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif         <= UIF_IDLE;
          end
        end

        UIF_READ_BUSY: begin
          if (r_uif_count < r_uif_len) begin
            tb_sdrc_rd_valid <= 1'b1;
            tb_sdrc_rd_data  <= mem_words[r_uif_base_addr + r_uif_count];
            r_uif_count      <= r_uif_count + 1'b1;
          end else begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif         <= UIF_IDLE;
          end
        end

        default: begin
          st_uif <= UIF_IDLE;
        end
      endcase
    end
  end

  always_ff @(posedge tb_clk) begin
    if (tb_test_evt_valid) begin
      log_debug(
        "HOSTIF CTRL TB",
        $sformatf(
          "test_evt id=0x%02h arg0=0x%08h arg1=0x%08h arg2=0x%08h",
          tb_test_evt_id,
          tb_test_evt_arg0,
          tb_test_evt_arg1,
          tb_test_evt_arg2
        )
      );
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
        if (wait_cycles > 1000) begin
          log_fatal(1, "HOSTIF CTRL TB", {"timeout waiting host event: ", label});
        end
      end

      if ((tb_host_evt_id !== exp_id) ||
          (tb_host_evt_arg0 !== exp_arg0) ||
          (tb_host_evt_arg1 !== exp_arg1) ||
          (tb_host_evt_arg2 !== exp_arg2)) begin
        log_fatal(
          1,
          "HOSTIF CTRL TB",
          $sformatf(
            "host event mismatch %s id=0x%02h arg0=0x%08h arg1=0x%08h arg2=0x%08h",
            label,
            tb_host_evt_id,
            tb_host_evt_arg0,
            tb_host_evt_arg1,
            tb_host_evt_arg2
          )
        );
      end

      log_info("HOSTIF CTRL TB", {"host event ok: ", label});
      @(posedge tb_clk);
      tb_host_evt_ready <= 1'b1;
      @(posedge tb_clk);
      tb_host_evt_ready <= 1'b0;
    end
  endtask

`include "testcase_smoke.svh"

endmodule
