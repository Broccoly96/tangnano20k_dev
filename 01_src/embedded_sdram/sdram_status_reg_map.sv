`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_status_reg_map.sv
// Description  : SDRAM debug register map for uart_log_cli host access.
//                - Base HS status map uses 80 bytes, byte addressed, 32-bit
//                  word reads at 4-byte steps.
//                - Temporary host debug window starts at 0x004C and exposes
//                  the latest 26-beat host read capture.
//                - Exposes self-test progress, fail context, retry results, and
//                  live Gowin SDRC HS command and refresh status.
//                - Address 0x003C is also a write-only control register:
//                  write bit0=1 to reset the SDRC and rerun the selftest.
//////////////////////////////////////////////////////////////////////////////////

module sdram_status_reg_map #(
  parameter int unsigned HOST_DBG_BURST_WORDS = 26
) (
  input  logic [15:0] I_ADDR,
  input  logic        I_INIT_DONE,
  input  logic        I_TEST_ACTIVE,
  input  logic        I_TEST_PASS,
  input  logic        I_TEST_FAIL,
  input  logic        I_HOST_BUSY,
  input  logic        I_SDRC_RESET_ACTIVE,
  input  logic        I_SDRC_CMD_EN,
  input  logic [2:0]  I_SDRC_CMD,
  input  logic        I_SDRC_CMD_ACK,
  input  logic        I_SDRC_READ_SAMPLE_VALID,
  input  logic [31:0] I_SDRC_REFRESH_STATUS,
  input  logic [31:0] I_SDRC_RD_DATA,
  input  logic [31:0] I_MEMTEST_SUMMARY,
  input  logic [7:0]  I_MEMTEST_STATE,
  input  logic [7:0]  I_MEMTEST_FAIL_REASON,
  input  logic [20:0] I_MEMTEST_CURR_ADDR,
  input  logic [31:0] I_MEMTEST_EXPECTED,
  input  logic [31:0] I_MEMTEST_LAST_READ,
  input  logic [31:0] I_MEMTEST_LAST_STATUS,
  input  logic [31:0] I_MEMTEST_FAIL_ADDR,
  input  logic [31:0] I_MEMTEST_FAIL_EXPECTED,
  input  logic [31:0] I_MEMTEST_FAIL_ACTUAL,
  input  logic [31:0] I_MEMTEST_RETRY_SUMMARY,
  input  logic [31:0] I_MEMTEST_RETRY_DATA1,
  input  logic [31:0] I_MEMTEST_RETRY_DATA2,
  input  logic [31:0] I_MEMTEST_CTRL_SUMMARY,
  input  logic [31:0] I_MEMTEST_CTRL_DETAIL,
  input  logic [31:0] I_HOST_DBG_SUMMARY,
  input  logic [31:0] I_HOST_DBG_DETAIL,
  input  logic [(HOST_DBG_BURST_WORDS*32)-1:0] I_HOST_DBG_RD_BEATS,
  output logic [31:0] O_RD_DATA
);

  localparam logic [7:0] MAP_VERSION = 8'h05;
  localparam logic [5:0] HOST_DBG_BEAT_BASE_WORD = 6'h13;

  logic [31:0] s_summary_word;
  logic [31:0] s_handshake_word;
  logic [5:0]  s_word_addr;
  logic [5:0]  s_host_dbg_beat_idx;

  assign s_word_addr = I_ADDR[7:2];
  assign s_host_dbg_beat_idx = s_word_addr - HOST_DBG_BEAT_BASE_WORD;

  always_comb begin
    s_summary_word = 32'h0000_0000;
    s_summary_word[31:24] = MAP_VERSION;
    s_summary_word[23:16] = I_MEMTEST_STATE;
    s_summary_word[15:8]  = I_MEMTEST_FAIL_REASON;
    s_summary_word[7]     = I_HOST_BUSY;
    s_summary_word[6]     = I_TEST_ACTIVE;
    s_summary_word[5]     = I_TEST_PASS;
    s_summary_word[4]     = I_TEST_FAIL;
    s_summary_word[3]     = I_INIT_DONE;
    s_summary_word[2]     = I_SDRC_RESET_ACTIVE;
  end

  always_comb begin
    s_handshake_word = 32'h0000_0000;
    s_handshake_word[31:24] = 8'h48;
    s_handshake_word[23]    = I_SDRC_CMD_EN;
    s_handshake_word[22:20] = I_SDRC_CMD;
    s_handshake_word[19]    = I_SDRC_CMD_ACK;
    s_handshake_word[18]    = I_SDRC_READ_SAMPLE_VALID;
    s_handshake_word[17]    = I_INIT_DONE;
    s_handshake_word[16]    = I_HOST_BUSY;
    s_handshake_word[15]    = I_TEST_ACTIVE;
    s_handshake_word[14]    = I_TEST_PASS;
    s_handshake_word[13]    = I_TEST_FAIL;
    s_handshake_word[12:0]  = I_ADDR[12:0];
  end

  // Maps each 32-bit status word onto a 4-byte aligned byte address.
  // 0x00..0x3C is the stable selftest/status map.
  // 0x40..0x44 is host access-engine debug summary/detail.
  // 0x48 is HS refresh scheduler status.
  // 0x4C..0xB0 is the latest host read burst capture, beat0..beat25.
  always_comb begin
    O_RD_DATA = 32'h0000_0000;

    case (s_word_addr)
      6'h00: O_RD_DATA = s_summary_word;
      6'h01: O_RD_DATA = I_MEMTEST_SUMMARY;
      6'h02: O_RD_DATA = {11'h000, I_MEMTEST_CURR_ADDR};
      6'h03: O_RD_DATA = I_MEMTEST_EXPECTED;
      6'h04: O_RD_DATA = I_MEMTEST_LAST_READ;
      6'h05: O_RD_DATA = I_MEMTEST_LAST_STATUS;
      6'h06: O_RD_DATA = I_MEMTEST_FAIL_ADDR;
      6'h07: O_RD_DATA = I_MEMTEST_FAIL_EXPECTED;
      6'h08: O_RD_DATA = I_MEMTEST_FAIL_ACTUAL;
      6'h09: O_RD_DATA = I_MEMTEST_RETRY_SUMMARY;
      6'h0A: O_RD_DATA = I_MEMTEST_RETRY_DATA1;
      6'h0B: O_RD_DATA = I_MEMTEST_RETRY_DATA2;
      6'h0C: O_RD_DATA = I_MEMTEST_CTRL_SUMMARY;
      6'h0D: O_RD_DATA = I_MEMTEST_CTRL_DETAIL;
      6'h0E: O_RD_DATA = s_handshake_word;
      6'h0F: O_RD_DATA = I_SDRC_RD_DATA;
      6'h10: O_RD_DATA = I_HOST_DBG_SUMMARY;
      6'h11: O_RD_DATA = I_HOST_DBG_DETAIL;
      6'h12: O_RD_DATA = I_SDRC_REFRESH_STATUS;
      default: O_RD_DATA = 32'h0000_0000;
    endcase

    if ((s_word_addr >= HOST_DBG_BEAT_BASE_WORD) &&
        (s_word_addr < (HOST_DBG_BEAT_BASE_WORD + HOST_DBG_BURST_WORDS[5:0]))) begin
      O_RD_DATA = I_HOST_DBG_RD_BEATS[s_host_dbg_beat_idx*32 +: 32];
    end
  end

endmodule
