`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import sdram_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 10ns;
  localparam int unsigned MEM_WORDS = 4096;

  typedef enum logic [2:0] {
    UIF_IDLE,
    UIF_WRITE_BUSY,
    UIF_WRITE_HANG,
    UIF_READ_BUSY,
    UIF_READ_HANG
  } uif_state_e;

  logic        tb_clk;
  logic        tb_rst_n;

  logic        tb_req_valid;
  logic        tb_req_ready;
  logic        tb_req_is_write;
  logic [20:0] tb_req_addr;
  logic [8:0]  tb_req_words;
  logic [31:0] tb_req_wr_beat_data;
  logic        tb_req_wr_beat_valid;
  logic [7:0]  tb_req_wr_beat_index;

  logic        tb_rsp_valid;
  logic        tb_rsp_ready;
  logic [31:0] tb_rsp_status;
  logic        tb_rsp_rd_beat_valid;
  logic [31:0] tb_rsp_rd_beat_data;
  logic [7:0]  tb_rsp_rd_beat_index;
  logic        tb_rsp_done;

  logic        tb_sdrc_busy_n;
  logic        tb_sdrc_wrd_ack;
  logic        tb_sdrc_rd_valid;
  logic [31:0] tb_sdrc_rd_data;
  logic        tb_sdrc_wr_n;
  logic        tb_sdrc_rd_n;
  logic [20:0] tb_sdrc_addr;
  logic [7:0]  tb_sdrc_data_len;
  logic [3:0]  tb_sdrc_dqm;
  logic [31:0] tb_sdrc_wr_data;

  logic [31:0] mem_words [0:MEM_WORDS-1];
  uif_state_e  st_uif;
  logic [20:0] r_uif_base_addr;
  logic [8:0]  r_uif_len;
  logic [8:0]  r_uif_count;
  logic [8:0]  r_uif_phase_count;
  logic [8:0]  r_uif_busy_count;
  logic        inject_next_wr_timeout;
  logic        inject_next_rd_timeout;
  logic [31:0] tb_pattern_base;

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n = 1'b0;
    tb_req_valid = 1'b0;
    tb_req_is_write = 1'b0;
    tb_req_addr = '0;
    tb_req_words = '0;
    tb_req_wr_beat_valid = 1'b0;
    tb_rsp_ready = 1'b1;
    tb_sdrc_busy_n = 1'b1;
    tb_sdrc_wrd_ack = 1'b0;
    tb_sdrc_rd_valid = 1'b0;
    tb_sdrc_rd_data = 32'h0;
    st_uif = UIF_IDLE;
    r_uif_base_addr = '0;
    r_uif_len = '0;
    r_uif_count = '0;
    r_uif_phase_count = '0;
    r_uif_busy_count = '0;
    inject_next_wr_timeout = 1'b0;
    inject_next_rd_timeout = 1'b0;
    tb_pattern_base = 32'hA500_0000;
    for (int idx = 0; idx < MEM_WORDS; idx++) begin
      mem_words[idx] = 32'h4000_0000 + idx;
    end
    repeat (8) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(500us);
    log_fatal(1, "SDRC EXEC TB", "simulation timeout");
  end

  assign tb_req_wr_beat_data = tb_pattern_base | tb_req_wr_beat_index;

  sdram_sdrc_burst_exec #(
    .RESP_TIMEOUT_CYCLES(1024)
  ) u_dut (
    .I_CLK            (tb_clk),
    .I_RST_N          (tb_rst_n),
    .I_REQ_VALID      (tb_req_valid),
    .O_REQ_READY      (tb_req_ready),
    .I_REQ_IS_WRITE   (tb_req_is_write),
    .I_REQ_ADDR       (tb_req_addr),
    .I_REQ_WORDS      (tb_req_words),
    .I_REQ_WR_BEAT_DATA(tb_req_wr_beat_data),
    .I_REQ_WR_BEAT_VALID(tb_req_wr_beat_valid),
    .O_REQ_WR_BEAT_INDEX(tb_req_wr_beat_index),
    .O_RSP_VALID      (tb_rsp_valid),
    .I_RSP_READY      (tb_rsp_ready),
    .O_RSP_STATUS     (tb_rsp_status),
    .O_RSP_RD_BEAT_VALID(tb_rsp_rd_beat_valid),
    .O_RSP_RD_BEAT_DATA(tb_rsp_rd_beat_data),
    .O_RSP_RD_BEAT_INDEX(tb_rsp_rd_beat_index),
    .O_RSP_DONE       (tb_rsp_done),
    .I_SDRC_BUSY_N    (tb_sdrc_busy_n),
    .I_SDRC_WRD_ACK   (tb_sdrc_wrd_ack),
    .I_SDRC_RD_VALID  (tb_sdrc_rd_valid),
    .I_SDRC_RD_DATA   (tb_sdrc_rd_data),
    .O_SDRC_WR_N      (tb_sdrc_wr_n),
    .O_SDRC_RD_N      (tb_sdrc_rd_n),
    .O_SDRC_ADDR      (tb_sdrc_addr),
    .O_SDRC_DATA_LEN  (tb_sdrc_data_len),
    .O_SDRC_DQM       (tb_sdrc_dqm),
    .O_SDRC_WR_DATA   (tb_sdrc_wr_data)
  );

  // Simple SDRC user-interface responder for executor unit testing.
  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      st_uif            <= UIF_IDLE;
      tb_sdrc_busy_n    <= 1'b1;
      tb_sdrc_rd_valid  <= 1'b0;
      tb_sdrc_rd_data   <= 32'h0;
      tb_sdrc_wrd_ack   <= 1'b0;
      r_uif_base_addr   <= '0;
      r_uif_len         <= '0;
      r_uif_count       <= '0;
      r_uif_phase_count <= '0;
      r_uif_busy_count  <= '0;
    end else begin
      tb_sdrc_rd_valid <= 1'b0;
      tb_sdrc_wrd_ack  <= 1'b0;

      case (st_uif)
        UIF_IDLE: begin
          tb_sdrc_busy_n    <= 1'b1;
          r_uif_count       <= '0;
          r_uif_phase_count <= '0;
          r_uif_busy_count  <= '0;
          if (!tb_sdrc_wr_n) begin
            r_uif_base_addr <= tb_sdrc_addr;
            r_uif_len       <= {1'b0, tb_sdrc_data_len} + 9'd1;
            mem_words[tb_sdrc_addr] <= tb_sdrc_wr_data;
            if (inject_next_wr_timeout) begin
              inject_next_wr_timeout <= 1'b0;
              r_uif_count       <= 9'd1;
              st_uif            <= UIF_WRITE_HANG;
            end else begin
              r_uif_count       <= 9'd1;
              st_uif            <= UIF_WRITE_BUSY;
            end
          end else if (!tb_sdrc_rd_n) begin
            r_uif_base_addr <= tb_sdrc_addr;
            r_uif_len       <= {1'b0, tb_sdrc_data_len} + 9'd1;
            if (inject_next_rd_timeout) begin
              inject_next_rd_timeout <= 1'b0;
              st_uif <= UIF_READ_HANG;
            end else begin
              st_uif <= UIF_READ_BUSY;
            end
          end
        end

        UIF_WRITE_BUSY: begin
          if (r_uif_phase_count == 9'd1) begin
            tb_sdrc_wrd_ack <= 1'b1;
          end
          if ((r_uif_phase_count >= 9'd2) && (r_uif_busy_count < r_uif_len)) begin
            tb_sdrc_busy_n   <= 1'b0;
            r_uif_busy_count <= r_uif_busy_count + 1'b1;
          end else begin
            tb_sdrc_busy_n <= 1'b1;
          end
          if (r_uif_count < r_uif_len) begin
            mem_words[r_uif_base_addr + r_uif_count] <= tb_sdrc_wr_data;
            r_uif_count <= r_uif_count + 1'b1;
          end
          r_uif_phase_count <= r_uif_phase_count + 1'b1;
          if ((r_uif_count >= r_uif_len) &&
              (r_uif_phase_count >= 9'd2) &&
              (r_uif_busy_count >= r_uif_len)) begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif         <= UIF_IDLE;
          end
        end

        UIF_WRITE_HANG: begin
          if (r_uif_phase_count == 9'd1) begin
            tb_sdrc_wrd_ack <= 1'b1;
          end
          if (r_uif_phase_count >= 9'd2) begin
            tb_sdrc_busy_n <= 1'b0;
          end
          r_uif_phase_count <= r_uif_phase_count + 1'b1;
          if (tb_rsp_valid) begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif         <= UIF_IDLE;
          end
        end

        UIF_READ_BUSY: begin
          if (r_uif_phase_count == 9'd1) begin
            tb_sdrc_wrd_ack <= 1'b1;
          end
          if ((r_uif_phase_count >= 9'd2) && (r_uif_count < r_uif_len)) begin
            tb_sdrc_busy_n   <= 1'b0;
            tb_sdrc_rd_valid <= 1'b1;
            tb_sdrc_rd_data  <= mem_words[r_uif_base_addr + r_uif_count];
            r_uif_count      <= r_uif_count + 1'b1;
          end else begin
            tb_sdrc_busy_n <= 1'b1;
          end
          r_uif_phase_count <= r_uif_phase_count + 1'b1;
          if ((r_uif_phase_count >= 9'd2) && (r_uif_count >= r_uif_len)) begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif         <= UIF_IDLE;
          end
        end

        UIF_READ_HANG: begin
          if (r_uif_phase_count == 9'd1) begin
            tb_sdrc_wrd_ack <= 1'b1;
          end
          if (r_uif_phase_count >= 9'd2) begin
            tb_sdrc_busy_n <= 1'b0;
          end
          r_uif_phase_count <= r_uif_phase_count + 1'b1;
          if (tb_rsp_valid) begin
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

  task automatic issue_write(
    input logic [20:0] addr,
    input int unsigned words,
    input logic [31:0] pattern_base
  );
    begin
      tb_pattern_base <= pattern_base;
      while (!tb_req_ready) @(posedge tb_clk);
      @(posedge tb_clk);
      tb_req_valid         <= 1'b1;
      tb_req_is_write      <= 1'b1;
      tb_req_addr          <= addr;
      tb_req_words         <= words[8:0];
      tb_req_wr_beat_valid <= 1'b1;
      @(posedge tb_clk);
      tb_req_valid         <= 1'b0;
      tb_req_is_write      <= 1'b0;
      tb_req_addr          <= '0;
      tb_req_words         <= '0;
      tb_req_wr_beat_valid <= 1'b0;
    end
  endtask

  task automatic issue_read(
    input logic [20:0] addr,
    input int unsigned words
  );
    begin
      while (!tb_req_ready) @(posedge tb_clk);
      @(posedge tb_clk);
      tb_req_valid         <= 1'b1;
      tb_req_is_write      <= 1'b0;
      tb_req_addr          <= addr;
      tb_req_words         <= words[8:0];
      tb_req_wr_beat_valid <= 1'b0;
      @(posedge tb_clk);
      tb_req_valid         <= 1'b0;
      tb_req_addr          <= '0;
      tb_req_words         <= '0;
    end
  endtask

  task automatic expect_rsp_status(
    input logic [31:0] exp_status,
    input string label
  );
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_rsp_valid) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 2000) begin
          log_fatal(1, "SDRC EXEC TB", {"timeout waiting response: ", label});
        end
      end
      if (tb_rsp_status !== exp_status) begin
        log_fatal(
          1,
          "SDRC EXEC TB",
          $sformatf("status mismatch %s status=0x%08h", label, tb_rsp_status)
        );
      end
      @(posedge tb_clk);
    end
  endtask

  task automatic expect_read_stream(
    input logic [20:0] addr,
    input int unsigned words,
    input logic [31:0] pattern_base,
    input string label
  );
    int beat_seen;
    int wait_cycles;
    begin
      beat_seen = 0;
      wait_cycles = 0;
      while (!tb_rsp_valid) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (tb_rsp_rd_beat_valid) begin
          if (tb_rsp_rd_beat_index !== beat_seen[7:0]) begin
            log_fatal(1, "SDRC EXEC TB", $sformatf("%s beat index mismatch exp=%0d act=%0d", label, beat_seen, tb_rsp_rd_beat_index));
          end
          if (tb_rsp_rd_beat_data !== (pattern_base | beat_seen)) begin
            log_fatal(1, "SDRC EXEC TB", $sformatf("%s beat data mismatch beat=%0d exp=0x%08h act=0x%08h", label, beat_seen, (pattern_base | beat_seen), tb_rsp_rd_beat_data));
          end
          beat_seen++;
        end
        if (wait_cycles > 2000) begin
          log_fatal(1, "SDRC EXEC TB", {"timeout waiting read stream: ", label});
        end
      end
      if (beat_seen != words) begin
        log_fatal(1, "SDRC EXEC TB", $sformatf("%s beat count mismatch exp=%0d act=%0d", label, words, beat_seen));
      end
      if (tb_rsp_status !== 32'h0000_0000) begin
        log_fatal(1, "SDRC EXEC TB", $sformatf("%s status mismatch 0x%08h", label, tb_rsp_status));
      end
      @(posedge tb_clk);
    end
  endtask

`include "testcase_smoke.svh"

endmodule
