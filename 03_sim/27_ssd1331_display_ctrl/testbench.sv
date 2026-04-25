`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import ssd1331_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 20ns;
  localparam int unsigned CAP_MAX_BYTES = 64;

  logic        tb_clk;
  logic        tb_rst_n;
  logic        tb_req_valid;
  logic        tb_req_ready;
  logic [2:0]  tb_req_op;
  logic [23:0] tb_req_color;
  logic        tb_done_valid;
  logic [2:0]  tb_done_op;
  logic        tb_busy;
  logic        tb_cs_n;
  logic        tb_sclk;
  logic        tb_sdin;
  logic        tb_dc;
  logic        tb_res_n;

  logic [7:0] cap_bytes [0:CAP_MAX_BYTES-1];
  logic       cap_dcs [0:CAP_MAX_BYTES-1];
  integer     cap_byte_count;
  integer     cap_bit_count;
  logic [7:0] cap_shift;
  integer     cap_cs_assert_count;
  integer     cap_cs_deassert_count;
  logic       cap_res_low_seen;

  logic [7:0] expected_bytes [0:CAP_MAX_BYTES-1];
  logic       expected_dcs [0:CAP_MAX_BYTES-1];

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n = 1'b0;
    tb_req_valid = 1'b0;
    tb_req_op = DISP_OP_OFF;
    tb_req_color = 24'h000000;
    reset_capture();
    repeat (8) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(5ms);
    log_fatal(1, "SSD1331 CTRL TB", "simulation timeout");
  end

  ssd1331_display_ctrl #(
    .SPI_CLK_DIV          (2),
    .RESET_ASSERT_CYCLES  (8),
    .RESET_RELEASE_CYCLES (8)
  ) u_dut (
    .I_CLK        (tb_clk),
    .I_RST_N      (tb_rst_n),
    .I_REQ_VALID  (tb_req_valid),
    .O_REQ_READY  (tb_req_ready),
    .I_REQ_OP     (tb_req_op),
    .I_REQ_COLOR  (tb_req_color),
    .O_DONE_VALID (tb_done_valid),
    .O_DONE_OP    (tb_done_op),
    .O_BUSY       (tb_busy),
    .O_DISP_CS_N  (tb_cs_n),
    .O_DISP_SCLK  (tb_sclk),
    .O_DISP_SDIN  (tb_sdin),
    .O_DISP_DC    (tb_dc),
    .O_DISP_RES_N (tb_res_n)
  );

  always @(negedge tb_cs_n) begin
    if (tb_rst_n) begin
      cap_cs_assert_count = cap_cs_assert_count + 1;
    end
  end

  always @(posedge tb_cs_n) begin
    if (tb_rst_n) begin
      cap_cs_deassert_count = cap_cs_deassert_count + 1;
    end
  end

  always @(negedge tb_res_n) begin
    if (tb_rst_n) begin
      cap_res_low_seen = 1'b1;
    end
  end

  always @(posedge tb_sclk) begin
    if (!tb_cs_n) begin
      cap_shift = {cap_shift[6:0], tb_sdin};
      cap_bit_count = cap_bit_count + 1;
      if (cap_bit_count == 8) begin
        if (cap_byte_count >= CAP_MAX_BYTES) begin
          log_fatal(1, "SSD1331 CTRL TB", "capture overflow");
        end
        cap_bytes[cap_byte_count] = cap_shift;
        cap_dcs[cap_byte_count] = tb_dc;
        cap_byte_count = cap_byte_count + 1;
        cap_bit_count = 0;
        cap_shift = 8'h00;
      end
    end
  end

  task automatic reset_capture;
    integer idx;
    begin
      cap_byte_count = 0;
      cap_bit_count = 0;
      cap_shift = 8'h00;
      cap_cs_assert_count = 0;
      cap_cs_deassert_count = 0;
      cap_res_low_seen = 1'b0;
      for (idx = 0; idx < CAP_MAX_BYTES; idx++) begin
        cap_bytes[idx] = 8'h00;
        cap_dcs[idx] = 1'b0;
        expected_bytes[idx] = 8'h00;
        expected_dcs[idx] = 1'b0;
      end
    end
  endtask

  task automatic issue_req(
    input logic [2:0]  req_op,
    input logic [23:0] req_color
  );
    begin
      while (!tb_req_ready) @(posedge tb_clk);
      @(negedge tb_clk);
      tb_req_valid = 1'b1;
      tb_req_op = req_op;
      tb_req_color = req_color;
      @(posedge tb_clk);
      @(negedge tb_clk);
      tb_req_valid = 1'b0;
      tb_req_op = DISP_OP_OFF;
      tb_req_color = 24'h000000;
    end
  endtask

  task automatic wait_done(input logic [2:0] expected_op);
    begin
      @(posedge tb_done_valid);
      if (tb_done_op != expected_op) begin
        log_fatal(1, "SSD1331 CTRL TB", $sformatf("done op mismatch got=%0d exp=%0d", tb_done_op, expected_op));
      end
      repeat (8) @(posedge tb_clk);
    end
  endtask

  task automatic expect_capture(input integer expected_count);
    integer idx;
    begin
      if (cap_byte_count != expected_count) begin
        log_fatal(1, "SSD1331 CTRL TB", $sformatf("capture count mismatch got=%0d exp=%0d", cap_byte_count, expected_count));
      end
      if (cap_cs_assert_count != expected_count || cap_cs_deassert_count != expected_count) begin
        log_fatal(
          1,
          "SSD1331 CTRL TB",
          $sformatf("unexpected CS framing assert=%0d deassert=%0d exp=%0d", cap_cs_assert_count, cap_cs_deassert_count, expected_count)
        );
      end
      for (idx = 0; idx < expected_count; idx++) begin
        if (cap_bytes[idx] != expected_bytes[idx] || cap_dcs[idx] != expected_dcs[idx]) begin
          log_fatal(
            1,
            "SSD1331 CTRL TB",
            $sformatf(
              "byte mismatch idx=%0d got=0x%02h/%0b exp=0x%02h/%0b",
              idx,
              cap_bytes[idx],
              cap_dcs[idx],
              expected_bytes[idx],
              expected_dcs[idx]
            )
          );
        end
      end
    end
  endtask

`include "testcase_smoke.svh"

endmodule