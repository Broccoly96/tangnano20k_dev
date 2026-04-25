`timescale 1ns / 1ps

`include "../../01_src/uart_log_cli/uart_log_cli_byte_async_bridge.sv"
`include "../../02_tb/tb_log_pkg.sv"

module testbench;

  import tb_log_pkg::*;

  localparam time SRC_CLK_PERIOD = 40ns;
  localparam time DST_CLK_PERIOD = 20ns;

  logic       tb_src_clk;
  logic       tb_dst_clk;
  logic       tb_src_rst_n;
  logic       tb_dst_rst_n;
  logic       tb_src_valid;
  logic [7:0] tb_src_data;
  logic       tb_src_ready;
  logic       tb_dst_valid;
  logic [7:0] tb_dst_data;
  logic       tb_dst_ready;

  initial begin
    configure_logging(LOG_DEBUG);
    tb_src_clk   = 1'b0;
    tb_dst_clk   = 1'b0;
    tb_src_rst_n = 1'b0;
    tb_dst_rst_n = 1'b0;
    tb_src_valid = 1'b0;
    tb_src_data  = 8'h00;
    tb_dst_ready = 1'b1;
  end

  initial forever #(SRC_CLK_PERIOD / 2) tb_src_clk = ~tb_src_clk;
  initial forever #(DST_CLK_PERIOD / 2) tb_dst_clk = ~tb_dst_clk;

  initial begin
    repeat (8) @(posedge tb_src_clk);
    tb_src_rst_n = 1'b1;
    repeat (8) @(posedge tb_dst_clk);
    tb_dst_rst_n = 1'b1;
  end

  initial begin
    #(200us);
    log_fatal(1, "CLI BYTE CDC TB", "simulation timeout");
  end

  uart_log_cli_byte_async_bridge u_dut (
    .I_SRC_CLK   (tb_src_clk),
    .I_SRC_RST_N (tb_src_rst_n),
    .I_DST_CLK   (tb_dst_clk),
    .I_DST_RST_N (tb_dst_rst_n),
    .I_SRC_VALID (tb_src_valid),
    .I_SRC_DATA  (tb_src_data),
    .O_SRC_READY (tb_src_ready),
    .O_DST_VALID (tb_dst_valid),
    .O_DST_DATA  (tb_dst_data),
    .I_DST_READY (tb_dst_ready)
  );

  task automatic send_source_byte(
    input logic [7:0] byte_value,
    input int unsigned gap_cycles
  );
    begin
      repeat (gap_cycles) @(posedge tb_src_clk);
      @(negedge tb_src_clk);
      tb_src_valid <= 1'b1;
      tb_src_data  <= byte_value;
      @(posedge tb_src_clk);
      @(negedge tb_src_clk);
      tb_src_valid <= 1'b0;
      tb_src_data  <= 8'h00;
    end
  endtask

  task automatic wait_for_dst_valid(input string label);
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_dst_valid) begin
        @(posedge tb_dst_clk);
        wait_cycles++;
        if (wait_cycles > 512) begin
          log_fatal(1, "CLI BYTE CDC TB", $sformatf("timeout waiting dst_valid: %s", label));
        end
      end
    end
  endtask

  task automatic expect_dst_byte(
    input logic [7:0] expected_byte,
    input string      label
  );
    int clear_cycles;
    begin
      wait_for_dst_valid(label);
      if (tb_dst_data !== expected_byte) begin
        log_fatal(
          1,
          "CLI BYTE CDC TB",
          $sformatf("dst byte mismatch %s exp=0x%02h got=0x%02h", label, expected_byte, tb_dst_data)
        );
      end
      clear_cycles = 0;
      while (tb_dst_valid) begin
        @(posedge tb_dst_clk);
        clear_cycles++;
        if (clear_cycles > 4) begin
          log_fatal(1, "CLI BYTE CDC TB", $sformatf("dst_valid did not clear after accept: %s", label));
        end
      end
    end
  endtask

  task automatic wait_for_src_ready(input string label);
    int wait_cycles;
    begin
      wait_cycles = 0;
      while (!tb_src_ready) begin
        @(posedge tb_src_clk);
        wait_cycles++;
        if (wait_cycles > 512) begin
          log_fatal(1, "CLI BYTE CDC TB", $sformatf("timeout waiting src_ready: %s", label));
        end
      end
    end
  endtask

`include "testcase_smoke.svh"

endmodule