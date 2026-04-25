`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import eeprom_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 41667ps;

  logic       tb_clk;
  logic       tb_rst_n;
  logic       tb_enable;
  logic       tb_rx_valid;
  logic [7:0] tb_rx_data;
  logic       tb_cmd_ready;
  logic       tb_cmd_valid;
  logic [1:0] tb_cmd_op;
  logic       tb_cmd_bulk_is_read;
  logic [16:0] tb_cmd_addr;
  logic [7:0] tb_cmd_data;
  logic [16:0] tb_cmd_count;
  logic       tb_err_valid;
  logic [31:0] tb_err_code;
  logic [31:0] tb_err_detail;

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n = 1'b0;
    tb_enable = 1'b1;
    tb_rx_valid = 1'b0;
    tb_rx_data = 8'h00;
    tb_cmd_ready = 1'b0;
    repeat (8) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(1ms);
    log_fatal(1, "EEPROM ASCII TB", "simulation timeout");
  end

  eeprom_uart_ascii_ctrl u_dut (
    .I_CLK              (tb_clk),
    .I_RST_N            (tb_rst_n),
    .I_ENABLE           (tb_enable),
    .I_RX_VALID         (tb_rx_valid),
    .I_RX_DATA          (tb_rx_data),
    .I_CMD_READY        (tb_cmd_ready),
    .O_CMD_VALID        (tb_cmd_valid),
    .O_CMD_OP           (tb_cmd_op),
    .O_CMD_BULK_IS_READ (tb_cmd_bulk_is_read),
    .O_CMD_ADDR         (tb_cmd_addr),
    .O_CMD_DATA         (tb_cmd_data),
    .O_CMD_COUNT        (tb_cmd_count),
    .O_ERR_VALID        (tb_err_valid),
    .O_ERR_CODE         (tb_err_code),
    .O_ERR_DETAIL       (tb_err_detail)
  );

  task automatic send_byte(input logic [7:0] byte_value);
    begin
      @(posedge tb_clk);
      tb_rx_valid <= 1'b1;
      tb_rx_data  <= byte_value;
      @(posedge tb_clk);
      tb_rx_valid <= 1'b0;
      tb_rx_data  <= 8'h00;
    end
  endtask

  task automatic send_text(input string text_value);
    int idx;
    begin
      for (idx = 0; idx < text_value.len(); idx++) begin
        send_byte(text_value[idx]);
      end
    end
  endtask

  task automatic clear_cmd;
    begin
      @(posedge tb_clk);
      tb_cmd_ready <= 1'b1;
      @(posedge tb_clk);
      tb_cmd_ready <= 1'b0;
    end
  endtask

  task automatic expect_cmd(
    input logic [1:0]  expect_op,
    input logic        expect_bulk_is_read,
    input logic [16:0] expect_addr,
    input logic [7:0]  expect_data,
    input logic [16:0] expect_count,
    input string       label
  );
    int unsigned timeout_cycles;
    begin
      timeout_cycles = 0;
      while (!tb_cmd_valid) begin
        @(posedge tb_clk);
        timeout_cycles = timeout_cycles + 1;
        if (timeout_cycles > 64) begin
          log_fatal(1, "EEPROM ASCII TB", {"timeout waiting for cmd: ", label});
        end
      end

      if ((tb_cmd_op != expect_op) ||
          (tb_cmd_bulk_is_read != expect_bulk_is_read) ||
          (tb_cmd_addr != expect_addr) ||
          (tb_cmd_data != expect_data) ||
          (tb_cmd_count != expect_count)) begin
        log_fatal(
          1,
          "EEPROM ASCII TB",
          $sformatf(
            "%s mismatch op=%0d/%0d bulk=%0b/%0b addr=0x%05h/0x%05h data=0x%02h/0x%02h count=0x%05h/0x%05h",
            label,
            tb_cmd_op,
            expect_op,
            tb_cmd_bulk_is_read,
            expect_bulk_is_read,
            tb_cmd_addr,
            expect_addr,
            tb_cmd_data,
            expect_data,
            tb_cmd_count,
            expect_count
          )
        );
      end

      clear_cmd();
    end
  endtask

  task automatic expect_err(
    input logic [31:0] expect_code,
    input logic [31:0] expect_detail,
    input string       label
  );
    int unsigned timeout_cycles;
    begin
      timeout_cycles = 0;
      while (!tb_err_valid) begin
        @(posedge tb_clk);
        timeout_cycles = timeout_cycles + 1;
        if (timeout_cycles > 64) begin
          log_fatal(1, "EEPROM ASCII TB", {"timeout waiting for err: ", label});
        end
      end

      if ((tb_err_code != expect_code) || (tb_err_detail != expect_detail)) begin
        log_fatal(
          1,
          "EEPROM ASCII TB",
          $sformatf(
            "%s mismatch code=0x%08h/0x%08h detail=0x%08h/0x%08h",
            label,
            tb_err_code,
            expect_code,
            tb_err_detail,
            expect_detail
          )
        );
      end

      @(posedge tb_clk);
    end
  endtask

`include "testcase_smoke.svh"

endmodule