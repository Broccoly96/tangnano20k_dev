`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import sdram_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 10ns;
  localparam int unsigned MEM_WORDS = 2048;
  localparam int unsigned BURST_WORDS = 26;

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
  logic [31:0] tb_req_data;
  logic        tb_sdrc_init_done;
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
  logic        tb_rsp_valid;
  logic        tb_rsp_is_write;
  logic [20:0] tb_rsp_addr;
  logic [31:0] tb_rsp_data;
  logic [31:0] tb_rsp_status;
  logic        tb_busy;
  logic [31:0] tb_dbg_host_summary;
  logic [31:0] tb_dbg_host_detail;
  logic [(BURST_WORDS*32)-1:0] tb_dbg_host_rd_beats;
  logic [31:0] mem_words [0:MEM_WORDS-1];
  uif_state_e  st_uif;
  logic [20:0] r_uif_base_addr;
  logic [7:0]  r_uif_len;
  logic [7:0]  r_uif_count;
  logic [7:0]  r_uif_phase_count;
  logic [7:0]  r_uif_busy_count;
  logic [31:0] r_uif_wr_value;
  logic        r_read_valid_seen_low_busy;
  integer      read_req_count;
  logic        inject_next_wr_timeout;
  logic        inject_next_rd_timeout;

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n              = 1'b0;
    tb_req_valid          = 1'b0;
    tb_req_is_write       = 1'b0;
    tb_req_addr           = '0;
    tb_req_data           = '0;
    tb_sdrc_init_done     = 1'b0;
    tb_sdrc_busy_n        = 1'b1;
    tb_sdrc_wrd_ack       = 1'b0;
    tb_sdrc_rd_valid      = 1'b0;
    tb_sdrc_rd_data       = 32'h0;
    st_uif                = UIF_IDLE;
    r_uif_base_addr       = '0;
    r_uif_len             = '0;
    r_uif_count           = '0;
    r_uif_phase_count     = '0;
    r_uif_busy_count      = '0;
    r_uif_wr_value        = '0;
    r_read_valid_seen_low_busy = 1'b0;
    read_req_count        = 0;
    inject_next_wr_timeout= 1'b0;
    inject_next_rd_timeout= 1'b0;
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
    .RESP_TIMEOUT_CYCLES(64)
  ) u_dut (
    .I_CLK           (tb_clk),
    .I_RST_N         (tb_rst_n),
    .I_REQ_VALID     (tb_req_valid),
    .O_REQ_READY     (tb_req_ready),
    .I_REQ_IS_WRITE  (tb_req_is_write),
    .I_REQ_ADDR      (tb_req_addr),
    .I_REQ_DATA      (tb_req_data),
    .I_SDRC_INIT_DONE(tb_sdrc_init_done),
    .I_SDRC_BUSY_N   (tb_sdrc_busy_n),
    .I_SDRC_WRD_ACK  (tb_sdrc_wrd_ack),
    .I_SDRC_RD_VALID (tb_sdrc_rd_valid),
    .I_SDRC_RD_DATA  (tb_sdrc_rd_data),
    .O_SDRC_WR_N     (tb_sdrc_wr_n),
    .O_SDRC_RD_N     (tb_sdrc_rd_n),
    .O_SDRC_ADDR     (tb_sdrc_addr),
    .O_SDRC_DATA_LEN (tb_sdrc_data_len),
    .O_SDRC_DQM      (tb_sdrc_dqm),
    .O_SDRC_WR_DATA  (tb_sdrc_wr_data),
    .O_RSP_VALID     (tb_rsp_valid),
    .I_RSP_READY     (1'b1),
    .O_RSP_IS_WRITE  (tb_rsp_is_write),
    .O_RSP_ADDR      (tb_rsp_addr),
    .O_RSP_DATA      (tb_rsp_data),
    .O_RSP_STATUS    (tb_rsp_status),
    .O_BUSY          (tb_busy),
    .O_DBG_HOST_SUMMARY(tb_dbg_host_summary),
    .O_DBG_HOST_DETAIL (tb_dbg_host_detail),
    .O_DBG_HOST_RD_BEATS(tb_dbg_host_rd_beats)
  );

  // Simple SDRC user-interface responder for unit testing.
  always_ff @(posedge tb_clk or negedge tb_rst_n) begin
    if (!tb_rst_n) begin
      st_uif            <= UIF_IDLE;
      tb_sdrc_busy_n    <= 1'b1;
      tb_sdrc_rd_valid  <= 1'b0;
      tb_sdrc_rd_data   <= 32'h0;
      r_uif_base_addr   <= '0;
      r_uif_len         <= '0;
      r_uif_count       <= '0;
      r_uif_phase_count <= '0;
      r_uif_busy_count  <= '0;
      r_uif_wr_value    <= '0;
      r_read_valid_seen_low_busy <= 1'b0;
      read_req_count    <= 0;
    end else begin
      tb_sdrc_rd_valid <= 1'b0;
      tb_sdrc_wrd_ack  <= 1'b0;

      case (st_uif)
        UIF_IDLE: begin
          tb_sdrc_busy_n    <= 1'b1;
          r_uif_count       <= '0;
          r_uif_phase_count <= '0;
          r_uif_busy_count  <= '0;
          r_read_valid_seen_low_busy <= 1'b0;
          if (!tb_sdrc_wr_n) begin
            r_uif_base_addr <= tb_sdrc_addr;
            r_uif_len       <= tb_sdrc_data_len + 1'b1;
            r_uif_wr_value  <= tb_sdrc_wr_data;
            mem_words[tb_sdrc_addr] <= tb_sdrc_wr_data;
            if (inject_next_wr_timeout) begin
              inject_next_wr_timeout <= 1'b0;
              r_uif_count       <= 8'd1;
              r_uif_phase_count <= 8'd0;
              r_uif_busy_count  <= 8'd0;
              st_uif <= UIF_WRITE_HANG;
            end else begin
              r_uif_count       <= 8'd1;
              r_uif_phase_count <= 8'd0;
              r_uif_busy_count  <= 8'd0;
              st_uif <= UIF_WRITE_BUSY;
            end
            log_debug(
              "ACCESS ENG TB",
              $sformatf(
                "accept_write addr=0x%05h len=%0d data=0x%08h",
                tb_sdrc_addr,
                tb_sdrc_data_len + 1,
                tb_sdrc_wr_data
              )
            );
          end else if (!tb_sdrc_rd_n) begin
            r_uif_base_addr <= tb_sdrc_addr;
            r_uif_len       <= tb_sdrc_data_len + 1'b1;
            r_uif_count     <= '0;
            r_uif_phase_count <= 8'd0;
            r_uif_busy_count  <= 8'd0;
            read_req_count  <= read_req_count + 1;
            if (inject_next_rd_timeout) begin
              inject_next_rd_timeout <= 1'b0;
              st_uif <= UIF_READ_HANG;
            end else begin
              st_uif <= UIF_READ_BUSY;
            end
            log_debug(
              "ACCESS ENG TB",
              $sformatf(
                "accept_read addr=0x%05h len=%0d count=%0d",
                tb_sdrc_addr,
                tb_sdrc_data_len + 1,
                read_req_count + 1
              )
            );
          end
        end

        UIF_WRITE_BUSY: begin
          if (r_uif_phase_count == 8'd1) begin
            tb_sdrc_wrd_ack <= 1'b1;
          end
          if ((r_uif_phase_count >= 8'd2) && (r_uif_busy_count < r_uif_len)) begin
            tb_sdrc_busy_n   <= 1'b0;
            r_uif_busy_count <= r_uif_busy_count + 1'b1;
          end else begin
            tb_sdrc_busy_n <= 1'b1;
          end
          if ((r_uif_phase_count >= 8'd3) && (r_uif_count < r_uif_len)) begin
            mem_words[r_uif_base_addr + r_uif_count] <= tb_sdrc_wr_data;
            r_uif_count <= r_uif_count + 1'b1;
          end
          r_uif_phase_count <= r_uif_phase_count + 1'b1;
          if ((r_uif_count >= r_uif_len) &&
              (r_uif_phase_count >= 8'd2) &&
              (r_uif_busy_count >= r_uif_len)) begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif         <= UIF_IDLE;
          end
        end

        UIF_WRITE_HANG: begin
          if (r_uif_phase_count == 8'd1) begin
            tb_sdrc_wrd_ack <= 1'b1;
          end
          if (r_uif_phase_count >= 8'd2) begin
            tb_sdrc_busy_n <= 1'b0;
          end
          r_uif_phase_count <= r_uif_phase_count + 1'b1;
          if (tb_rsp_valid) begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif         <= UIF_IDLE;
          end
        end

        UIF_READ_BUSY: begin
          if (r_uif_phase_count == 8'd1) begin
            tb_sdrc_wrd_ack <= 1'b1;
            tb_sdrc_rd_valid <= 1'b1;
            tb_sdrc_rd_data  <= r_uif_wr_value;
          end
          if ((r_uif_phase_count >= 8'd2) && (r_uif_count < r_uif_len)) begin
            tb_sdrc_busy_n  <= 1'b0;
            tb_sdrc_rd_valid <= 1'b1;
            tb_sdrc_rd_data  <= mem_words[r_uif_base_addr + r_uif_count];
            r_uif_count      <= r_uif_count + 1'b1;
            r_read_valid_seen_low_busy <= 1'b1;
          end else if (r_read_valid_seen_low_busy && (r_uif_busy_count < 8'd3)) begin
            tb_sdrc_busy_n   <= 1'b0;
            r_uif_busy_count <= r_uif_busy_count + 1'b1;
          end else begin
            tb_sdrc_busy_n <= 1'b1;
          end
          r_uif_phase_count <= r_uif_phase_count + 1'b1;
          if ((r_uif_phase_count >= 8'd2) &&
              (r_uif_count >= r_uif_len) &&
              (!r_read_valid_seen_low_busy || (r_uif_busy_count >= 8'd3))) begin
            tb_sdrc_busy_n <= 1'b1;
            st_uif         <= UIF_IDLE;
          end
        end

        UIF_READ_HANG: begin
          if (r_uif_phase_count == 8'd1) begin
            tb_sdrc_wrd_ack <= 1'b1;
          end
          if (r_uif_phase_count >= 8'd2) begin
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

  // The DUT must keep its host-side busy/mux ownership asserted until the
  // Gowin SDRC transaction has returned to idle. This catches the historical
  // read path bug where response was generated immediately on rd_valid.
  always_ff @(posedge tb_clk) begin
    if (tb_rst_n && (st_uif == UIF_READ_BUSY) &&
        r_read_valid_seen_low_busy && !tb_sdrc_busy_n && !tb_busy) begin
      log_fatal(
        1,
        "ACCESS ENG TB",
        "DUT released O_BUSY before read transaction returned to busy_n=1"
      );
    end
  end

  task automatic issue_request(
    input logic is_write,
    input logic [20:0] addr,
    input logic [31:0] data
  );
    begin
      while (!tb_req_ready) @(posedge tb_clk);
      @(posedge tb_clk);
      tb_req_valid    <= 1'b1;
      tb_req_is_write <= is_write;
      tb_req_addr     <= addr;
      tb_req_data     <= data;
      @(posedge tb_clk);
      tb_req_valid    <= 1'b0;
      tb_req_is_write <= 1'b0;
      tb_req_addr     <= '0;
      tb_req_data     <= '0;
    end
  endtask

  task automatic expect_response(
    input logic        exp_is_write,
    input logic [20:0] exp_addr,
    input logic [31:0] exp_data,
    input logic [31:0] exp_status,
    input string       label
  );
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_rsp_valid) begin
        @(posedge tb_clk);
        wait_cycles++;
        if (wait_cycles > 200) begin
          log_fatal(1, "ACCESS ENG TB", {"timeout waiting response: ", label});
        end
      end

      if ((tb_rsp_is_write !== exp_is_write) ||
          (tb_rsp_addr !== exp_addr) ||
          (tb_rsp_data !== exp_data) ||
          (tb_rsp_status !== exp_status)) begin
        log_fatal(
          1,
          "ACCESS ENG TB",
          $sformatf(
            "response mismatch %s is_write=%0b addr=0x%05h data=0x%08h status=0x%08h",
            label,
            tb_rsp_is_write,
            tb_rsp_addr,
            tb_rsp_data,
            tb_rsp_status
          )
        );
      end

      log_info("ACCESS ENG TB", {"response ok: ", label});
      @(posedge tb_clk);
    end
  endtask

`include "testcase_smoke.svh"

endmodule
