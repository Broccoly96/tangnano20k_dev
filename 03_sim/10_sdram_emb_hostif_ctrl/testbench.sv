`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import sdram_hs_cmd_pkg::*;
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

  logic [31:0] mem_words [0:MEM_WORDS-1];
  uif_state_e  st_uif;
  logic [20:0] r_active_addr;
  logic [20:0] r_read_addr;
  logic        r_active_open;
  logic [8:0]  r_burst_len;
  logic [8:0]  r_burst_count;

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n         = 1'b0;
    tb_cli_rx_valid  = 1'b0;
    tb_cli_rx_data   = 8'h00;
    tb_test_evt_if.evt_ready = 1'b1;
    tb_test_evt_if.enable    = 1'b1;
    tb_host_evt_if.evt_ready = 1'b0;
    tb_host_evt_if.enable    = 1'b1;
    tb_sdrc_rd_data  = 32'h0;
    tb_sdrc_cmd_ack  = 1'b0;
    tb_sdrc_init_done= 1'b0;
    st_uif           = UIF_IDLE;
    r_active_addr    = '0;
    r_read_addr      = '0;
    r_active_open    = 1'b0;
    r_burst_len      = '0;
    r_burst_count    = '0;
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
    .TEST_EVT_IF     (tb_test_evt_if),
    .HOST_EVT_IF     (tb_host_evt_if),
    .I_SDRC_RD_DATA  (tb_sdrc_rd_data),
    .I_SDRC_CMD_ACK  (tb_sdrc_cmd_ack),
    .I_SDRC_INIT_DONE(tb_sdrc_init_done),
    .O_INIT_DONE     (tb_init_done),
    .O_TEST_ACTIVE   (tb_test_active),
    .O_TEST_PASS     (tb_test_pass),
    .O_TEST_FAIL     (tb_test_fail),
    .O_HOST_BUSY     (tb_host_busy),
    .O_SDRC_RST_N    (tb_sdrc_rst_n),
    .O_SDRC_CMD_EN   (tb_sdrc_cmd_en),
    .O_SDRC_CMD      (tb_sdrc_cmd),
    .O_SDRC_PRECHARGE_CTRL(tb_sdrc_precharge_ctrl),
    .O_SDRC_ADDR     (tb_sdrc_addr),
    .O_SDRC_DATA_LEN (tb_sdrc_data_len),
    .O_SDRC_DQM      (tb_sdrc_dqm),
    .O_SDRC_WR_DATA  (tb_sdrc_wr_data),
    .O_SDRC_READ_SAMPLE_VALID(tb_sdrc_read_sample_valid)
  );

  // Behavioral HS responder for hostif unit tests.
  // ACTIVE opens one address context. READ/WRITE must follow an ACTIVE, and
  // read data is supplied only on the controller's explicit sample cycle.
  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      tb_sdrc_cmd_ack <= 1'b0;
      tb_sdrc_init_done <= 1'b0;
      st_uif <= UIF_IDLE;
      r_active_addr <= '0;
      r_read_addr <= '0;
      r_active_open <= 1'b0;
      r_burst_len <= '0;
      r_burst_count <= '0;
    end else begin
      tb_sdrc_cmd_ack <= 1'b0;

      if (tb_sdrc_rst_n) begin
        tb_sdrc_init_done <= 1'b1;
      end else begin
        tb_sdrc_init_done <= 1'b0;
        r_active_open <= 1'b0;
        st_uif <= UIF_IDLE;
      end

      case (st_uif)
        UIF_IDLE: begin
          r_burst_count <= '0;
          if (tb_sdrc_cmd_en) begin
            case (tb_sdrc_cmd)
              SDRAM_HS_CMD_ACTIVE: begin
                if (r_active_open) begin
                  log_fatal(1, "HOSTIF CTRL TB", "ACTIVE while row is already open");
                end
                tb_sdrc_cmd_ack <= 1'b1;
                r_active_addr <= tb_sdrc_addr;
                r_active_open <= 1'b1;
              end

              SDRAM_HS_CMD_WRITE: begin
                if (!r_active_open) begin
                  log_fatal(1, "HOSTIF CTRL TB", "WRITE without preceding ACTIVE");
                end
                mem_words[tb_sdrc_addr % MEM_WORDS] <= tb_sdrc_wr_data;
                r_read_addr <= tb_sdrc_addr;
                r_burst_len <= {1'b0, tb_sdrc_data_len} + 9'd1;
                r_burst_count <= 9'd1;
                r_active_open <= 1'b0;
                st_uif <= UIF_WRITE_BUSY;
              end

              SDRAM_HS_CMD_READ: begin
                if (!r_active_open) begin
                  log_fatal(1, "HOSTIF CTRL TB", "READ without preceding ACTIVE");
                end
                r_read_addr <= tb_sdrc_addr;
                r_burst_len <= {1'b0, tb_sdrc_data_len} + 9'd1;
                r_burst_count <= '0;
                r_active_open <= 1'b0;
                st_uif <= UIF_READ_BUSY;
              end

              SDRAM_HS_CMD_AUTO_REFRESH: begin
                if (r_active_open) begin
                  log_fatal(1, "HOSTIF CTRL TB", "refresh inserted inside ACTIVE pair");
                end
                tb_sdrc_cmd_ack <= 1'b1;
              end

              default: begin
              end
            endcase
          end
        end

        UIF_WRITE_BUSY: begin
          if (r_burst_count < r_burst_len) begin
            mem_words[(r_read_addr + r_burst_count) % MEM_WORDS] <= tb_sdrc_wr_data;
            r_burst_count <= r_burst_count + 1'b1;
          end
          if (((r_burst_count + 1'b1) >= r_burst_len) || (r_burst_len == 9'd1)) begin
            tb_sdrc_cmd_ack <= 1'b1;
            st_uif <= UIF_IDLE;
          end
        end

        UIF_READ_BUSY: begin
          if (tb_sdrc_read_sample_valid) begin
            if ((r_burst_count + 1'b1) >= r_burst_len) begin
              tb_sdrc_cmd_ack <= 1'b1;
              st_uif <= UIF_IDLE;
            end
            r_burst_count <= r_burst_count + 1'b1;
          end
        end

        default: begin
          st_uif <= UIF_IDLE;
        end
      endcase
    end
  end

  always_comb begin
    if (tb_sdrc_read_sample_valid) begin
      tb_sdrc_rd_data = mem_words[(r_read_addr + r_burst_count) % MEM_WORDS];
    end else begin
      tb_sdrc_rd_data = 32'h0000_0000;
    end
  end

  always_ff @(posedge tb_clk) begin
    if (tb_test_evt_if.evt_valid) begin
      log_debug(
        "HOSTIF CTRL TB",
        $sformatf(
          "test_evt id=0x%02h arg0=0x%08h arg1=0x%08h arg2=0x%08h",
          tb_test_evt_if.evt_id,
          tb_test_evt_if.arg0,
          tb_test_evt_if.arg1,
          tb_test_evt_if.arg2
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

  task automatic send_bulk_block(
    input logic [7:0] block_type,
    input logic [7:0] seq,
    input logic [15:0] payload_len,
    input logic [MAX_BULK_PAYLOAD_BYTES*8-1:0] payload_bits,
    input logic        corrupt_crc
  );
    logic [15:0] crc_value;
    begin
      crc_value = calc_bulk_crc16(block_type, seq, payload_len, payload_bits);
      if (corrupt_crc) begin
        crc_value = crc_value ^ 16'h0001;
      end

      send_byte(BULK_SOF0);
      send_byte(BULK_SOF1);
      send_byte(block_type);
      send_byte(seq);
      send_byte(payload_len[7:0]);
      send_byte(payload_len[15:8]);
      for (int byte_idx = 0; byte_idx < payload_len; byte_idx++) begin
        send_byte(payload_bits[byte_idx*8 +: 8]);
      end
      send_byte(crc_value[7:0]);
      send_byte(crc_value[15:8]);
    end
  endtask

  task automatic send_bulk_data_words(
    input logic [7:0] seq,
    input logic [MAX_BULK_PAYLOAD_BYTES*8-1:0] payload_bits,
    input int unsigned word_count
  );
    begin
      send_bulk_block(BULK_WR_DATA, seq, word_count * 4, payload_bits, 1'b0);
    end
  endtask

  task automatic send_bulk_end(input logic [7:0] seq);
    begin
      send_bulk_block(BULK_WR_END, seq, 16'h0000, '0, 1'b0);
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
      while (!tb_host_evt_if.evt_valid) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 1000) begin
          log_fatal(1, "HOSTIF CTRL TB", {"timeout waiting host event: ", label});
        end
      end

      if ((tb_host_evt_if.evt_id !== exp_id) ||
          (tb_host_evt_if.arg0 !== exp_arg0) ||
          (tb_host_evt_if.arg1 !== exp_arg1) ||
          (tb_host_evt_if.arg2 !== exp_arg2)) begin
        log_fatal(
          1,
          "HOSTIF CTRL TB",
          $sformatf(
            "host event mismatch %s id=0x%02h arg0=0x%08h arg1=0x%08h arg2=0x%08h",
            label,
            tb_host_evt_if.evt_id,
            tb_host_evt_if.arg0,
            tb_host_evt_if.arg1,
            tb_host_evt_if.arg2
          )
        );
      end

      log_info("HOSTIF CTRL TB", {"host event ok: ", label});
      @(posedge tb_clk);
      tb_host_evt_if.evt_ready <= 1'b1;
      @(posedge tb_clk);
      tb_host_evt_if.evt_ready <= 1'b0;
      @(posedge tb_clk);
    end
  endtask

`include "testcase_smoke.svh"

endmodule
