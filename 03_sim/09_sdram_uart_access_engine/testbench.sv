`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import sdram_hs_cmd_pkg::*;
  import sdram_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 10ns;
  localparam int unsigned MEM_WORDS = 2048;
  localparam int unsigned HOST_BURST_WORDS = 256;

  typedef enum logic [1:0] {
    UIF_IDLE,
    UIF_WRITE_BUSY,
    UIF_WRITE_HANG,
    UIF_READ_BUSY
  } uif_state_e;

  logic        tb_clk;
  logic        tb_rst_n;
  logic        tb_req_valid;
  logic        tb_req_ready;
  logic        tb_req_is_write;
  logic        tb_req_is_burst_test;
  logic        tb_req_is_raw_bulk;
  logic [20:0] tb_req_addr;
  logic [31:0] tb_req_data;
  logic [8:0]  tb_req_words;
  logic        tb_raw_wr_valid;
  logic        tb_raw_wr_ready;
  logic [31:0] tb_raw_wr_data;
  logic        tb_raw_rd_valid;
  logic        tb_raw_rd_ready;
  logic [8:0]  tb_raw_rd_index;
  logic [31:0] tb_raw_rd_word_data;
  logic        tb_raw_rd_last;
  logic        tb_sdrc_init_done;
  logic        tb_sdrc_ready;
  logic        tb_sdrc_cmd_ack;
  logic [31:0] tb_sdrc_rd_data;
  logic        tb_sdrc_cmd_en;
  logic [2:0]  tb_sdrc_cmd;
  logic        tb_sdrc_precharge_ctrl;
  logic [20:0] tb_sdrc_addr;
  logic [7:0]  tb_sdrc_data_len;
  logic [3:0]  tb_sdrc_dqm;
  logic [31:0] tb_sdrc_wr_data;
  logic        tb_sdrc_pair_active;
  logic        tb_read_sample_valid;
  logic        tb_evt_valid;
  logic        tb_evt_ready;
  logic [7:0]  tb_evt_id;
  logic [31:0] tb_evt_arg0;
  logic [31:0] tb_evt_arg1;
  logic [31:0] tb_evt_arg2;
  logic        tb_raw_done;
  logic        tb_raw_err_valid;
  logic [31:0] tb_raw_err_code;
  logic [(MAX_BULK_PAYLOAD_WORDS*32)-1:0] tb_raw_rd_data;
  logic        tb_busy;
  logic [31:0] tb_dbg_host_summary;
  logic [31:0] tb_dbg_host_detail;
  logic [(HOST_BURST_WORDS*32)-1:0] tb_dbg_host_rd_beats;
  logic [31:0] mem_words [0:MEM_WORDS-1];
  uif_state_e  st_uif;
  logic [20:0] r_uif_base_addr;
  logic [8:0]  r_uif_len;
  logic [8:0]  r_uif_count;
  logic        inject_next_wr_timeout;
  logic [2:0]  cmd_history [0:127];
  integer      cmd_history_count;

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n              = 1'b0;
    tb_req_valid          = 1'b0;
    tb_req_is_write       = 1'b0;
    tb_req_is_burst_test  = 1'b0;
    tb_req_is_raw_bulk    = 1'b0;
    tb_req_addr           = '0;
    tb_req_data           = '0;
    tb_req_words          = 9'd1;
    tb_raw_wr_valid       = 1'b0;
    tb_raw_wr_data        = 32'h0;
    tb_raw_rd_ready       = 1'b1;
    tb_raw_rd_data        = '0;
    tb_sdrc_init_done     = 1'b0;
    tb_sdrc_ready         = 1'b1;
    tb_sdrc_cmd_ack       = 1'b0;
    tb_evt_ready          = 1'b0;
    st_uif                = UIF_IDLE;
    r_uif_base_addr       = '0;
    r_uif_len             = '0;
    r_uif_count           = '0;
    inject_next_wr_timeout= 1'b0;
    cmd_history_count     = 0;
    for (int idx = 0; idx < MEM_WORDS; idx++) begin
      mem_words[idx] = 32'h1000_0000 + idx;
    end
    repeat (8) @(posedge tb_clk);
    tb_rst_n          = 1'b1;
    tb_sdrc_init_done = 1'b1;
  end

  initial begin
    #(200us);
    log_fatal(1, "ACCESS ENG TB", "simulation timeout");
  end

  sdram_uart_access_engine #(
    .RESP_TIMEOUT_CYCLES(512),
    .HOST_BURST_WORDS(HOST_BURST_WORDS),
    .READ_DATA_LATENCY_CYCLES(2)
  ) u_dut (
    .I_CLK              (tb_clk),
    .I_RST_N            (tb_rst_n),
    .I_REQ_VALID        (tb_req_valid),
    .O_REQ_READY        (tb_req_ready),
    .I_REQ_IS_WRITE     (tb_req_is_write),
    .I_REQ_IS_BURST_TEST(tb_req_is_burst_test),
    .I_REQ_IS_RAW_BULK  (tb_req_is_raw_bulk),
    .I_REQ_ADDR         (tb_req_addr),
    .I_REQ_DATA         (tb_req_data),
    .I_REQ_WORDS        (tb_req_words),
    .I_RAW_WR_VALID     (tb_raw_wr_valid),
    .O_RAW_WR_READY     (tb_raw_wr_ready),
    .I_RAW_WR_DATA      (tb_raw_wr_data),
    .O_RAW_RD_VALID     (tb_raw_rd_valid),
    .I_RAW_RD_READY     (tb_raw_rd_ready),
    .O_RAW_RD_INDEX     (tb_raw_rd_index),
    .O_RAW_RD_DATA      (tb_raw_rd_word_data),
    .O_RAW_RD_LAST      (tb_raw_rd_last),
    .I_SDRC_INIT_DONE   (tb_sdrc_init_done),
    .I_SDRC_READY       (tb_sdrc_ready),
    .I_SDRC_CMD_ACK     (tb_sdrc_cmd_ack),
    .I_SDRC_RD_DATA     (tb_sdrc_rd_data),
    .O_SDRC_CMD_EN      (tb_sdrc_cmd_en),
    .O_SDRC_CMD         (tb_sdrc_cmd),
    .O_SDRC_PRECHARGE_CTRL(tb_sdrc_precharge_ctrl),
    .O_SDRC_ADDR        (tb_sdrc_addr),
    .O_SDRC_DATA_LEN    (tb_sdrc_data_len),
    .O_SDRC_DQM         (tb_sdrc_dqm),
    .O_SDRC_WR_DATA     (tb_sdrc_wr_data),
    .O_SDRC_PAIR_ACTIVE (tb_sdrc_pair_active),
    .O_READ_SAMPLE_VALID(tb_read_sample_valid),
    .O_EVT_VALID        (tb_evt_valid),
    .I_EVT_READY        (tb_evt_ready),
    .O_EVT_ID           (tb_evt_id),
    .O_EVT_ARG0         (tb_evt_arg0),
    .O_EVT_ARG1         (tb_evt_arg1),
    .O_EVT_ARG2         (tb_evt_arg2),
    .O_RAW_DONE         (tb_raw_done),
    .O_RAW_ERR_VALID    (tb_raw_err_valid),
    .O_RAW_ERR_CODE     (tb_raw_err_code),
    .O_BUSY             (tb_busy),
    .O_DBG_HOST_SUMMARY (tb_dbg_host_summary),
    .O_DBG_HOST_DETAIL  (tb_dbg_host_detail),
    .O_DBG_HOST_RD_BEATS(tb_dbg_host_rd_beats)
  );

  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      tb_raw_rd_data <= '0;
    end else if (tb_raw_rd_valid && tb_raw_rd_ready) begin
      tb_raw_rd_data[tb_raw_rd_index*32 +: 32] <= tb_raw_rd_word_data;
    end
  end

  always_comb begin
    tb_sdrc_rd_data = 32'h0000_0000;
    if (st_uif == UIF_READ_BUSY) begin
      tb_sdrc_rd_data = mem_words[r_uif_base_addr + r_uif_count];
    end
  end

  // Native HS SDRAM responder:
  // ACTIVE is acknowledged immediately.
  // WRITE stores the command-cycle word and following burst beats.
  // READ presents each word before O_READ_SAMPLE_VALID samples it.
  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      st_uif            <= UIF_IDLE;
      tb_sdrc_cmd_ack   <= 1'b0;
      r_uif_base_addr   <= '0;
      r_uif_len         <= '0;
      r_uif_count       <= '0;
      cmd_history_count <= 0;
    end else begin
      tb_sdrc_ready   <= 1'b1;
      tb_sdrc_cmd_ack <= 1'b0;

      if (tb_sdrc_cmd_en) begin
        cmd_history[cmd_history_count] <= tb_sdrc_cmd;
        cmd_history_count <= cmd_history_count + 1;
      end

      case (st_uif)
        UIF_IDLE: begin
          r_uif_count <= '0;
          if (tb_sdrc_cmd_en && (tb_sdrc_cmd == SDRAM_HS_CMD_ACTIVE)) begin
            tb_sdrc_cmd_ack <= 1'b1;
          end else if (tb_sdrc_cmd_en && (tb_sdrc_cmd == SDRAM_HS_CMD_WRITE)) begin
            r_uif_base_addr <= tb_sdrc_addr;
            r_uif_len       <= {1'b0, tb_sdrc_data_len} + 9'd1;
            mem_words[tb_sdrc_addr] <= tb_sdrc_wr_data;
            r_uif_count     <= 9'd1;
            st_uif          <= inject_next_wr_timeout ? UIF_WRITE_HANG : UIF_WRITE_BUSY;
            inject_next_wr_timeout <= 1'b0;
          end else if (tb_sdrc_cmd_en && (tb_sdrc_cmd == SDRAM_HS_CMD_READ)) begin
            r_uif_base_addr <= tb_sdrc_addr;
            r_uif_len       <= {1'b0, tb_sdrc_data_len} + 9'd1;
            r_uif_count     <= '0;
            st_uif          <= UIF_READ_BUSY;
          end
        end

        UIF_WRITE_BUSY: begin
          if (r_uif_count < r_uif_len) begin
            mem_words[r_uif_base_addr + r_uif_count] <= tb_sdrc_wr_data;
            r_uif_count <= r_uif_count + 1'b1;
          end
          if (((r_uif_count + 1'b1) >= r_uif_len) || (r_uif_len == 9'd1)) begin
            tb_sdrc_cmd_ack <= 1'b1;
            st_uif          <= UIF_IDLE;
          end
        end

        UIF_WRITE_HANG: begin
          if (tb_evt_valid) begin
            st_uif <= UIF_IDLE;
          end
        end

        UIF_READ_BUSY: begin
          if (tb_read_sample_valid) begin
            if ((r_uif_count + 1'b1) >= r_uif_len) begin
              tb_sdrc_cmd_ack <= 1'b1;
              st_uif          <= UIF_IDLE;
            end
            r_uif_count <= r_uif_count + 1'b1;
          end
        end

        default: begin
          st_uif <= UIF_IDLE;
        end
      endcase
    end
  end

  task automatic issue_request(
    input logic        is_write,
    input logic        is_burst_test,
    input logic [20:0] addr,
    input logic [31:0] data,
    input logic [8:0]  words
  );
    begin
      while (!tb_req_ready) @(posedge tb_clk);
      @(posedge tb_clk);
      tb_req_valid         <= 1'b1;
      tb_req_is_write      <= is_write;
      tb_req_is_burst_test <= is_burst_test;
      tb_req_addr          <= addr;
      tb_req_data          <= data;
      tb_req_words         <= words;
      @(posedge tb_clk);
      tb_req_valid         <= 1'b0;
      tb_req_is_write      <= 1'b0;
      tb_req_is_burst_test <= 1'b0;
      tb_req_is_raw_bulk   <= 1'b0;
      tb_req_addr          <= '0;
      tb_req_data          <= '0;
      tb_req_words         <= 9'd1;
    end
  endtask

  task automatic issue_raw_request(
    input logic        is_write,
    input logic [20:0] addr,
    input logic [8:0]  words,
    input logic [(MAX_BULK_PAYLOAD_WORDS*32)-1:0] raw_data
  );
    begin
      while (!tb_req_ready) @(posedge tb_clk);
      @(posedge tb_clk);
      tb_req_valid         <= 1'b1;
      tb_req_is_write      <= is_write;
      tb_req_is_burst_test <= 1'b0;
      tb_req_is_raw_bulk   <= 1'b1;
      tb_req_addr          <= addr;
      tb_req_data          <= 32'h0;
      tb_req_words         <= words;
      @(posedge tb_clk);
      tb_req_valid         <= 1'b0;
      tb_req_is_write      <= 1'b0;
      tb_req_is_burst_test <= 1'b0;
      tb_req_is_raw_bulk   <= 1'b0;
      tb_req_addr          <= '0;
      tb_req_words         <= 9'd1;

      if (is_write && (words != 0) && (words <= MAX_BULK_PAYLOAD_WORDS)) begin
        for (int beat = 0; beat < words; beat++) begin
          tb_raw_wr_data  <= raw_data[beat*32 +: 32];
          tb_raw_wr_valid <= 1'b1;
          do begin
            @(posedge tb_clk);
          end while (!tb_raw_wr_ready);
        end
        tb_raw_wr_valid <= 1'b0;
        tb_raw_wr_data  <= 32'h0000_0000;
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
        if (wait_cycles > 800) begin
          log_fatal(1, "ACCESS ENG TB", {"timeout waiting event: ", label});
        end
      end

      if ((tb_evt_id !== exp_id) ||
          (tb_evt_arg0 !== exp_arg0) ||
          (tb_evt_arg1 !== exp_arg1) ||
          (tb_evt_arg2 !== exp_arg2)) begin
        log_fatal(
          1,
          "ACCESS ENG TB",
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

      log_info("ACCESS ENG TB", {"event ok: ", label});
      @(posedge tb_clk);
      tb_evt_ready <= 1'b1;
      @(posedge tb_clk);
      tb_evt_ready <= 1'b0;
      #1;
    end
  endtask

  task automatic expect_command_pair(
    input int unsigned first_idx,
    input logic [2:0]  exp_access_cmd,
    input string       label
  );
    begin
      if ((cmd_history_count - first_idx) != 2) begin
        log_fatal(
          1,
          "ACCESS ENG TB",
          $sformatf("command count mismatch %s count=%0d", label, cmd_history_count - first_idx)
        );
      end
      if ((cmd_history[first_idx] !== SDRAM_HS_CMD_ACTIVE) ||
          (cmd_history[first_idx + 1] !== exp_access_cmd)) begin
        log_fatal(
          1,
          "ACCESS ENG TB",
          $sformatf(
            "command sequence mismatch %s cmd0=%03b cmd1=%03b",
            label,
            cmd_history[first_idx],
            cmd_history[first_idx + 1]
          )
        );
      end
    end
  endtask

  task automatic expect_raw_done(input string label);
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_raw_done) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 800) begin
          log_fatal(1, "ACCESS ENG TB", {"timeout waiting raw done: ", label});
        end
      end
      if (tb_evt_valid) begin
        log_fatal(1, "ACCESS ENG TB", {"raw mode unexpectedly emitted event: ", label});
      end
      log_info("ACCESS ENG TB", {"raw done ok: ", label});
    end
  endtask

  task automatic expect_raw_error(
    input logic [31:0] exp_code,
    input string       label
  );
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_raw_err_valid) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 800) begin
          log_fatal(1, "ACCESS ENG TB", {"timeout waiting raw error: ", label});
        end
      end
      if (tb_raw_err_code !== exp_code) begin
        log_fatal(
          1,
          "ACCESS ENG TB",
          $sformatf("raw err mismatch %s code=0x%08h", label, tb_raw_err_code)
        );
      end
      log_info("ACCESS ENG TB", {"raw err ok: ", label});
    end
  endtask

`include "testcase_smoke.svh"

endmodule
