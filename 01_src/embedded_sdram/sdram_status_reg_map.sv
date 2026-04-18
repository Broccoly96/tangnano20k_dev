`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_status_reg_map.sv
// Description  : SDRAM debug register map for uart_log_cli host access.
//                - 64-byte map, byte addressed, 32-bit word reads at 4-byte steps.
//                - Exposes self-test progress, fail context, retry results, and
//                  live Gowin SDRC handshake status.
//                - Address 0x003C is also a write-only control register:
//                  write bit0=1 to reset the SDRC and rerun the selftest.
//////////////////////////////////////////////////////////////////////////////////

module sdram_status_reg_map (
  input  logic [15:0] I_ADDR,
  input  logic        I_INIT_DONE,
  input  logic        I_TEST_ACTIVE,
  input  logic        I_TEST_PASS,
  input  logic        I_TEST_FAIL,
  input  logic        I_HOST_BUSY,
  input  logic        I_SDRC_RESET_ACTIVE,
  input  logic        I_SDRC_BUSY_N,
  input  logic        I_SDRC_RD_VALID,
  input  logic        I_SDRC_WRD_ACK,
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
  output logic [31:0] O_RD_DATA
);

  localparam logic [7:0] MAP_VERSION = 8'h04;

  logic [31:0] s_summary_word;
  logic [31:0] s_handshake_word;

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
    s_handshake_word[31:24] = 8'h47;
    s_handshake_word[23]    = I_SDRC_BUSY_N;
    s_handshake_word[22]    = I_SDRC_RD_VALID;
    s_handshake_word[21]    = I_SDRC_WRD_ACK;
    s_handshake_word[20]    = I_INIT_DONE;
    s_handshake_word[19]    = I_TEST_ACTIVE;
    s_handshake_word[18]    = I_TEST_PASS;
    s_handshake_word[17]    = I_TEST_FAIL;
    s_handshake_word[16]    = I_HOST_BUSY;
    s_handshake_word[15:0]  = I_ADDR;
  end

  // Maps each 32-bit status word onto a 4-byte aligned byte address.
  always_comb begin
    O_RD_DATA = 32'h0000_0000;

    case (I_ADDR[5:2])
      4'h0: O_RD_DATA = s_summary_word;
      4'h1: O_RD_DATA = I_MEMTEST_SUMMARY;
      4'h2: O_RD_DATA = {11'h000, I_MEMTEST_CURR_ADDR};
      4'h3: O_RD_DATA = I_MEMTEST_EXPECTED;
      4'h4: O_RD_DATA = I_MEMTEST_LAST_READ;
      4'h5: O_RD_DATA = I_MEMTEST_LAST_STATUS;
      4'h6: O_RD_DATA = I_MEMTEST_FAIL_ADDR;
      4'h7: O_RD_DATA = I_MEMTEST_FAIL_EXPECTED;
      4'h8: O_RD_DATA = I_MEMTEST_FAIL_ACTUAL;
      4'h9: O_RD_DATA = I_MEMTEST_RETRY_SUMMARY;
      4'hA: O_RD_DATA = I_MEMTEST_RETRY_DATA1;
      4'hB: O_RD_DATA = I_MEMTEST_RETRY_DATA2;
      4'hC: O_RD_DATA = I_MEMTEST_CTRL_SUMMARY;
      4'hD: O_RD_DATA = I_MEMTEST_CTRL_DETAIL;
      4'hE: O_RD_DATA = s_handshake_word;
      4'hF: O_RD_DATA = I_SDRC_RD_DATA;
      default: O_RD_DATA = 32'h0000_0000;
    endcase
  end

endmodule
