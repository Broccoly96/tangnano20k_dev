`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_status_reg_map.sv
// Description  : Read-only SDRAM debug/status register map exported to
//                uart_log_cli.
//                - Accepts a 16-bit byte address.
//                - Returns one 32-bit register image per 4-byte block.
//                - Implements a 64-byte map (16 registers).
//
// Register map:
//   0x00 : summary
//          [31:24] map version
//          [23:20] memtest FSM state
//          [19:16] fail reason
//                    0 = no fail latched
//                    1 = write response status error
//                    2 = read response status error
//                    3 = read data mismatch
//          [15:14] word wrapper state
//          [13:11] byte wrapper state
//          [7]     controller init/config busy
//          [6]     controller data_ready raw
//          [5]     controller busy raw
//          [4]     host busy
//          [3]     test active
//          [2]     test fail
//          [1]     test pass
//          [0]     init done
//   0x04 : memtest summary
//   0x08 : current word address
//   0x0C : expected word data
//   0x10 : last read data observed by memtest
//   0x14 : last response status observed by memtest
//   0x18 : fail arg0
//   0x1C : fail arg1
//   0x20 : first failing readback data
//   0x24 : readback retry summary
//          [31:28] configured retry limit
//          [27:24] retries used on the last readback issue
//          [23:20] total attempts on the last readback issue
//          [15]    retry active
//          [14]    retry recovered by a later read
//          [13]    retry exhausted and fail latched
//          [12]    retry issue valid
//          [3:0]   fail reason code
//                    0 = write response status error
//                    1 = read response status error
//                    2 = read data mismatch
//   0x28 : retry #1 readback data
//   0x2C : retry #2 readback data
//   0x30 : word wrapper summary
//   0x34 : word wrapper data
//   0x38 : byte wrapper summary
//   0x3C : last raw 32-bit word sampled by the byte wrapper on controller read
//////////////////////////////////////////////////////////////////////////////////

module sdram_status_reg_map (
  input  logic [15:0] I_ADDR,
  input  logic        I_INIT_DONE,
  input  logic        I_TEST_ACTIVE,
  input  logic        I_TEST_PASS,
  input  logic        I_TEST_FAIL,
  input  logic        I_HOST_BUSY,
  input  logic [31:0] I_MEMTEST_SUMMARY,
  input  logic [31:0] I_MEMTEST_CURR_WORD_ADDR,
  input  logic [31:0] I_MEMTEST_EXPECTED_WORD,
  input  logic [31:0] I_MEMTEST_LAST_RD_DATA,
  input  logic [31:0] I_MEMTEST_LAST_RSP_STATUS,
  input  logic [31:0] I_MEMTEST_FAIL_ARG0,
  input  logic [31:0] I_MEMTEST_FAIL_ARG1,
  input  logic [31:0] I_MEMTEST_FAIL_ARG2,
  input  logic [31:0] I_MEMTEST_FAIL_CTX_ARG0,
  input  logic [31:0] I_MEMTEST_FAIL_CTX_ARG1,
  input  logic [31:0] I_MEMTEST_FAIL_CTX_ARG2,
  input  logic [31:0] I_WORD_CTRL_SUMMARY,
  input  logic [31:0] I_WORD_CTRL_DATA,
  input  logic [31:0] I_BYTE_CTRL_SUMMARY,
  input  logic [31:0] I_BYTE_CTRL_DETAIL,
  output logic [31:0] O_RD_DATA
);

  localparam logic [7:0] MAP_VERSION = 8'h02;

  logic        l_addr_in_range;
  logic [3:0]  l_word_index;
  logic [3:0]  l_fail_reason;
  logic        l_ctrl_busy_raw;
  logic        l_ctrl_data_ready_raw;
  logic        l_ctrl_init_busy;
  logic [31:0] l_word_data;

  function automatic logic sanitize_debug_bit(
    input logic value
  );
    begin
      case (value)
        1'b1: sanitize_debug_bit = 1'b1;
        default: sanitize_debug_bit = 1'b0;
      endcase
    end
  endfunction

  assign l_addr_in_range = (I_ADDR[15:6] == 10'h000);
  assign l_word_index    = I_ADDR[5:2];
  assign l_fail_reason   = I_TEST_FAIL ? (I_MEMTEST_FAIL_CTX_ARG0[3:0] + 4'd1)
                                       : 4'h0;
  assign l_ctrl_busy_raw       = sanitize_debug_bit(I_BYTE_CTRL_SUMMARY[23]);
  assign l_ctrl_data_ready_raw = sanitize_debug_bit(I_BYTE_CTRL_SUMMARY[22]);
  assign l_ctrl_init_busy      = !I_INIT_DONE && l_ctrl_busy_raw;

  // Maps byte addresses into fixed 32-bit debug/status words so the TCP host
  // can reconstruct selftest progress and the last observed fail context.
  always_comb begin
    l_word_data = 32'h0000_0000;

    if (l_addr_in_range) begin
      case (l_word_index)
        4'h0: begin
          l_word_data = {
            MAP_VERSION,
            I_MEMTEST_SUMMARY[31:28],
            l_fail_reason,
            I_WORD_CTRL_SUMMARY[31:30],
            I_BYTE_CTRL_SUMMARY[31:29],
            3'h0,
            l_ctrl_init_busy,
            l_ctrl_data_ready_raw,
            l_ctrl_busy_raw,
            I_HOST_BUSY,
            I_TEST_ACTIVE,
            I_TEST_FAIL,
            I_TEST_PASS,
            I_INIT_DONE
          };
        end
        4'h1: l_word_data = I_MEMTEST_SUMMARY;
        4'h2: l_word_data = I_MEMTEST_CURR_WORD_ADDR;
        4'h3: l_word_data = I_MEMTEST_EXPECTED_WORD;
        4'h4: l_word_data = I_MEMTEST_LAST_RD_DATA;
        4'h5: l_word_data = I_MEMTEST_LAST_RSP_STATUS;
        4'h6: l_word_data = I_MEMTEST_FAIL_ARG0;
        4'h7: l_word_data = I_MEMTEST_FAIL_ARG1;
        4'h8: l_word_data = I_MEMTEST_FAIL_ARG2;
        4'h9: l_word_data = I_MEMTEST_FAIL_CTX_ARG0;
        4'hA: l_word_data = I_MEMTEST_FAIL_CTX_ARG1;
        4'hB: l_word_data = I_MEMTEST_FAIL_CTX_ARG2;
        4'hC: l_word_data = I_WORD_CTRL_SUMMARY;
        4'hD: l_word_data = I_WORD_CTRL_DATA;
        4'hE: l_word_data = I_BYTE_CTRL_SUMMARY;
        4'hF: l_word_data = I_BYTE_CTRL_DETAIL;
        default: l_word_data = 32'h0000_0000;
      endcase
    end
  end

  assign O_RD_DATA = l_word_data;

endmodule
