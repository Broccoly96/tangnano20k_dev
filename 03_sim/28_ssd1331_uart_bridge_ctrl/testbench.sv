`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import ssd1331_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 20ns;
  localparam int unsigned CAP_MAX_BYTES = 64;
  localparam int unsigned EVT_MAX_COUNT = 8;

  logic        tb_clk;
  logic        tb_rst_n;
  logic        tb_cli_valid;
  logic [7:0]  tb_cli_data;
  logic        tb_busy;
  logic        tb_cs_n;
  logic        tb_sclk;
  logic        tb_sdin;
  logic        tb_dc;
  logic        tb_res_n;

  uart_log_evt_if tb_evt_if();

  logic [7:0] cap_bytes [0:CAP_MAX_BYTES-1];
  integer     cap_byte_count;
  integer     cap_bit_count;
  logic [7:0] cap_shift;

  logic [7:0]  evt_ids [0:EVT_MAX_COUNT-1];
  logic [31:0] evt_arg0 [0:EVT_MAX_COUNT-1];
  logic [31:0] evt_arg1 [0:EVT_MAX_COUNT-1];
  integer      evt_count;

  assign tb_evt_if.enable = 1'b1;
  assign tb_evt_if.evt_ready = 1'b1;

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n = 1'b0;
    tb_cli_valid = 1'b0;
    tb_cli_data = 8'h00;
    reset_spi_capture();
    reset_evt_capture();
    repeat (8) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(8ms);
    log_fatal(1, "SSD1331 BRIDGE TB", "simulation timeout");
  end

  ssd1331_uart_bridge_ctrl #(
    .SPI_CLK_DIV          (2),
    .RESET_ASSERT_CYCLES  (8),
    .RESET_RELEASE_CYCLES (8)
  ) u_dut (
    .I_CLK        (tb_clk),
    .I_RST_N      (tb_rst_n),
    .I_ENABLE     (1'b1),
    .I_CLI_RX_VALID(tb_cli_valid),
    .I_CLI_RX_DATA(tb_cli_data),
    .O_CMD_BUSY   (tb_busy),
    .O_DISP_CS_N  (tb_cs_n),
    .O_DISP_SCLK  (tb_sclk),
    .O_DISP_SDIN  (tb_sdin),
    .O_DISP_DC    (tb_dc),
    .O_DISP_RES_N (tb_res_n),
    .HOST_EVT_IF  (tb_evt_if)
  );

  always @(posedge tb_clk) begin
    if (tb_evt_if.evt_valid && tb_evt_if.evt_ready) begin
      if (evt_count >= EVT_MAX_COUNT) begin
        log_fatal(1, "SSD1331 BRIDGE TB", "event capture overflow");
      end
      evt_ids[evt_count] = tb_evt_if.evt_id;
      evt_arg0[evt_count] = tb_evt_if.arg0;
      evt_arg1[evt_count] = tb_evt_if.arg1;
      evt_count = evt_count + 1;
    end
  end

  always @(posedge tb_sclk) begin
    if (!tb_cs_n) begin
      cap_shift = {cap_shift[6:0], tb_sdin};
      cap_bit_count = cap_bit_count + 1;
      if (cap_bit_count == 8) begin
        if (cap_byte_count >= CAP_MAX_BYTES) begin
          log_fatal(1, "SSD1331 BRIDGE TB", "spi capture overflow");
        end
        cap_bytes[cap_byte_count] = cap_shift;
        cap_byte_count = cap_byte_count + 1;
        cap_bit_count = 0;
        cap_shift = 8'h00;
      end
    end
  end

  task automatic reset_spi_capture;
    integer idx;
    begin
      cap_byte_count = 0;
      cap_bit_count = 0;
      cap_shift = 8'h00;
      for (idx = 0; idx < CAP_MAX_BYTES; idx++) begin
        cap_bytes[idx] = 8'h00;
      end
    end
  endtask

  task automatic reset_evt_capture;
    integer idx;
    begin
      evt_count = 0;
      for (idx = 0; idx < EVT_MAX_COUNT; idx++) begin
        evt_ids[idx] = 8'h00;
        evt_arg0[idx] = 32'h0;
        evt_arg1[idx] = 32'h0;
      end
    end
  endtask

  task automatic send_byte(input logic [7:0] byte_value);
    begin
      @(negedge tb_clk);
      tb_cli_valid = 1'b1;
      tb_cli_data = byte_value;
      @(posedge tb_clk);
      @(negedge tb_clk);
      tb_cli_valid = 1'b0;
      tb_cli_data = 8'h00;
    end
  endtask

  task automatic send_text(input string text_value);
    integer idx;
    begin
      for (idx = 0; idx < text_value.len(); idx++) begin
        send_byte(text_value[idx]);
      end
    end
  endtask

  task automatic wait_evt_count(input integer expected_count);
    begin
      while (evt_count < expected_count) @(posedge tb_clk);
      repeat (4) @(posedge tb_clk);
    end
  endtask

`include "testcase_smoke.svh"

endmodule