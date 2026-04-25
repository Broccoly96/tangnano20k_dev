`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : embedded_sdram_tb_pkg.sv
// Description  : Common helpers for embedded SDRAM stress simulations.
//                Provides:
//                - SDRAM-side command decode
//                - user-interface request helper tasks
//                - address construction helpers
//////////////////////////////////////////////////////////////////////////////////
`ifndef EMBEDDED_SDRAM_TB_PKG_SV
`define EMBEDDED_SDRAM_TB_PKG_SV

package embedded_sdram_tb_pkg;

  import tb_log_pkg::*;

  localparam int unsigned SDRC_SAFE_IDLE_GAP_CYCLES = 20;

  typedef enum int unsigned {
    SDRAM_CMD_INHIBIT = 0,
    SDRAM_CMD_NOP,
    SDRAM_CMD_ACTIVE,
    SDRAM_CMD_READ,
    SDRAM_CMD_WRITE,
    SDRAM_CMD_BURST_TERMINATE,
    SDRAM_CMD_PRECHARGE,
    SDRAM_CMD_AUTO_REFRESH,
    SDRAM_CMD_LOAD_MODE_REGISTER,
    SDRAM_CMD_UNKNOWN
  } sdram_cmd_e;

  function automatic logic [20:0] make_sdrc_addr(
    input logic [1:0]  bank,
    input logic [10:0] row,
    input logic [7:0]  col
  );
    make_sdrc_addr = {bank, row, col};
  endfunction

  function automatic sdram_cmd_e decode_sdram_cmd(
    input logic cke,
    input logic cs_n,
    input logic ras_n,
    input logic cas_n,
    input logic wen_n
  );
    if ((cke === 1'bx) || (cs_n === 1'bx) || (ras_n === 1'bx) ||
        (cas_n === 1'bx) || (wen_n === 1'bx)) begin
      decode_sdram_cmd = SDRAM_CMD_UNKNOWN;
    end else if (cs_n) begin
      decode_sdram_cmd = SDRAM_CMD_INHIBIT;
    end else begin
      unique case ({ras_n, cas_n, wen_n})
        3'b111: decode_sdram_cmd = SDRAM_CMD_NOP;
        3'b011: decode_sdram_cmd = SDRAM_CMD_ACTIVE;
        3'b101: decode_sdram_cmd = SDRAM_CMD_READ;
        3'b100: decode_sdram_cmd = SDRAM_CMD_WRITE;
        3'b110: decode_sdram_cmd = SDRAM_CMD_BURST_TERMINATE;
        3'b010: decode_sdram_cmd = SDRAM_CMD_PRECHARGE;
        3'b001: decode_sdram_cmd = SDRAM_CMD_AUTO_REFRESH;
        3'b000: decode_sdram_cmd = SDRAM_CMD_LOAD_MODE_REGISTER;
        default: decode_sdram_cmd = SDRAM_CMD_UNKNOWN;
      endcase
    end
  endfunction

  function automatic string sdram_cmd_name(
    input sdram_cmd_e cmd
  );
    case (cmd)
      SDRAM_CMD_INHIBIT:           sdram_cmd_name = "INHIBIT";
      SDRAM_CMD_NOP:               sdram_cmd_name = "NOP";
      SDRAM_CMD_ACTIVE:            sdram_cmd_name = "ACTIVE";
      SDRAM_CMD_READ:              sdram_cmd_name = "READ";
      SDRAM_CMD_WRITE:             sdram_cmd_name = "WRITE";
      SDRAM_CMD_BURST_TERMINATE:   sdram_cmd_name = "BURST_TERM";
      SDRAM_CMD_PRECHARGE:         sdram_cmd_name = "PRECHARGE";
      SDRAM_CMD_AUTO_REFRESH:      sdram_cmd_name = "AUTO_REFRESH";
      SDRAM_CMD_LOAD_MODE_REGISTER:sdram_cmd_name = "LOAD_MODE";
      default:                     sdram_cmd_name = "UNKNOWN";
    endcase
  endfunction

  task automatic sdrc_init_driver(
    ref logic        wr_n,
    ref logic        rd_n,
    ref logic [20:0] addr,
    ref logic [7:0]  data_len,
    ref logic [3:0]  dqm,
    ref logic [31:0] wr_data,
    ref logic        selfrefresh,
    ref logic        power_down
  );
    begin
      wr_n        = 1'b1;
      rd_n        = 1'b1;
      addr        = '0;
      data_len    = '0;
      dqm         = 4'h0;
      wr_data     = 32'h0000_0000;
      selfrefresh = 1'b0;
      power_down  = 1'b0;
    end
  endtask

  task automatic sdrc_wait_cycles(
    ref logic clk,
    input int unsigned cycles
  );
    begin
      repeat (cycles) @(posedge clk);
    end
  endtask

  task automatic sdrc_wait_init(
    ref logic clk,
    ref logic init_done,
    input int unsigned settle_cycles
  );
    begin
      while (!init_done) @(posedge clk);
      repeat (settle_cycles) @(posedge clk);
    end
  endtask

  task automatic sdrc_wait_idle(
    ref logic clk,
    ref logic busy_n
  );
    begin
      while (!busy_n) @(posedge clk);
    end
  endtask

  task automatic sdrc_wait_gap(
    ref logic clk,
    input int unsigned gap_cycles
  );
    begin
      repeat (gap_cycles) @(posedge clk);
    end
  endtask

  task automatic sdrc_issue_write_burst(
    ref logic        clk,
    ref logic        busy_n,
    ref logic        wr_n,
    ref logic        rd_n,
    ref logic [20:0] addr,
    ref logic [7:0]  data_len,
    ref logic [3:0]  dqm,
    ref logic [31:0] wr_data,
    input logic [20:0] req_addr,
    input logic [7:0]  req_len_m1,
    input logic [31:0] start_data
  );
    begin
      while (!busy_n) @(posedge clk);
      repeat (SDRC_SAFE_IDLE_GAP_CYCLES) @(posedge clk);
      tb_log_pkg::log_debug(
        "SDRAM TB PKG",
        $sformatf(
          "issue write addr=0x%05h len=%0d start_data=0x%08h",
          req_addr,
          req_len_m1 + 1,
          start_data
        )
      );
      addr     = req_addr;
      data_len = req_len_m1;
      dqm      = 4'h0;
      wr_data  = start_data;
      rd_n     = 1'b1;
      wr_n     = 1'b0;
      @(posedge clk);
      wr_n = 1'b1;

      for (int word_idx = 0; word_idx <= req_len_m1 + 2; word_idx++) begin
        wr_data = wr_data + 1'b1;
        tb_log_pkg::log_trace(
          "SDRAM TB PKG",
          $sformatf(
            "write stream beat=%0d drive=0x%08h",
            word_idx + 1,
            wr_data
          )
        );
        @(posedge clk);
      end
    end
  endtask

  task automatic sdrc_issue_read_burst(
    ref logic        clk,
    ref logic        busy_n,
    ref logic        wr_n,
    ref logic        rd_n,
    ref logic [20:0] addr,
    ref logic [7:0]  data_len,
    ref logic [3:0]  dqm,
    input logic [20:0] req_addr,
    input logic [7:0]  req_len_m1
  );
    begin
      while (!busy_n) @(posedge clk);
      repeat (SDRC_SAFE_IDLE_GAP_CYCLES) @(posedge clk);
      tb_log_pkg::log_debug(
        "SDRAM TB PKG",
        $sformatf(
          "issue read addr=0x%05h len=%0d",
          req_addr,
          req_len_m1 + 1
        )
      );
      addr     = req_addr;
      data_len = req_len_m1;
      dqm      = 4'h0;
      wr_n     = 1'b1;
      rd_n     = 1'b0;
      @(posedge clk);
      rd_n = 1'b1;
    end
  endtask

  task automatic sdrc_drive_selfrefresh(
    ref logic clk,
    ref logic busy_n,
    ref logic selfrefresh,
    input int unsigned hold_cycles
  );
    begin
      while (!busy_n) @(posedge clk);
      repeat (SDRC_SAFE_IDLE_GAP_CYCLES) @(posedge clk);
      tb_log_pkg::log_debug(
        "SDRAM TB PKG",
        $sformatf("enter self-refresh hold_cycles=%0d", hold_cycles)
      );
      selfrefresh = 1'b1;
      repeat (hold_cycles) @(posedge clk);
      selfrefresh = 1'b0;
      tb_log_pkg::log_debug("SDRAM TB PKG", "exit self-refresh");
      repeat (8) @(posedge clk);
    end
  endtask

  task automatic sdrc_drive_power_down(
    ref logic clk,
    ref logic busy_n,
    ref logic power_down,
    input int unsigned hold_cycles
  );
    begin
      while (!busy_n) @(posedge clk);
      repeat (SDRC_SAFE_IDLE_GAP_CYCLES) @(posedge clk);
      tb_log_pkg::log_debug(
        "SDRAM TB PKG",
        $sformatf("enter power-down hold_cycles=%0d", hold_cycles)
      );
      power_down = 1'b1;
      repeat (hold_cycles) @(posedge clk);
      power_down = 1'b0;
      tb_log_pkg::log_debug("SDRAM TB PKG", "exit power-down");
      repeat (8) @(posedge clk);
    end
  endtask

  task automatic sdrc_expect_read_words(
    ref logic        clk,
    ref logic        rd_valid,
    ref logic [31:0] rd_data,
    input logic [31:0] exp_words [],
    input int unsigned exp_beats,
    input int unsigned timeout_cycles,
    input string     log_context
  );
    int unsigned seen_beats;
    begin
      seen_beats = 0;
      repeat (timeout_cycles) begin
        @(posedge clk);
        if (rd_valid) begin
          if (seen_beats >= exp_beats) begin
            tb_log_pkg::log_fatal(
              1,
              "SDRAM TB PKG",
              $sformatf(
                "%s too many read beats beat=%0d data=0x%08h",
                log_context,
                seen_beats,
                rd_data
              )
            );
          end
          tb_log_pkg::log_trace(
            "SDRAM TB PKG",
            $sformatf(
              "%s read beat=%0d exp=0x%08h act=0x%08h",
              log_context,
              seen_beats,
              exp_words[seen_beats],
              rd_data
            )
          );
          if (rd_data !== exp_words[seen_beats]) begin
            tb_log_pkg::log_fatal(
              1,
              "SDRAM TB PKG",
              $sformatf(
                "%s mismatch beat=%0d exp=0x%08h act=0x%08h",
                log_context,
                seen_beats,
                exp_words[seen_beats],
                rd_data
              )
            );
          end
          seen_beats += 1;
        end
      end
      if (seen_beats != exp_beats) begin
        tb_log_pkg::log_fatal(
          1,
          "SDRAM TB PKG",
          $sformatf(
            "%s expected %0d beats but observed %0d",
            log_context,
            exp_beats,
            seen_beats
          )
        );
      end
      tb_log_pkg::log_debug(
        "SDRAM TB PKG",
        $sformatf("%s completed beats=%0d", log_context, seen_beats)
      );
    end
  endtask

endpackage : embedded_sdram_tb_pkg

`endif
