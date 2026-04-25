`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import eeprom_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 20833ps;

  logic tb_clk;
  logic tb_rst_n;
  logic tb_cli_rx_valid;
  logic [7:0] tb_cli_rx_data;
  logic tb_cmd_busy;

  tri1 tb_sda;
  tri1 tb_scl;
  logic tb_master_sda_drive_low;
  logic tb_master_scl_drive_low;
  logic tb_model_sda_drive_low;

  uart_log_evt_if tb_host_evt_if ();

  assign tb_sda = tb_master_sda_drive_low ? 1'b0 : 1'bz;
  assign tb_sda = tb_model_sda_drive_low ? 1'b0 : 1'bz;
  assign tb_scl = tb_master_scl_drive_low ? 1'b0 : 1'bz;

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n = 1'b0;
    tb_cli_rx_valid = 1'b0;
    tb_cli_rx_data = 8'h00;
    tb_host_evt_if.evt_ready = 1'b0;
    tb_host_evt_if.enable = 1'b1;
    repeat (16) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(8ms);
    log_fatal(1, "EEPROM BRIDGE TB", "simulation timeout");
  end

  eeprom_uart_bridge_ctrl #(
    .BULK_RX_TIMEOUT_CYCLES (80_000)
  ) u_dut (
    .I_CLK                (tb_clk),
    .I_RST_N              (tb_rst_n),
    .I_ENABLE             (1'b1),
    .I_CLI_RX_VALID       (tb_cli_rx_valid),
    .I_CLI_RX_DATA        (tb_cli_rx_data),
    .I_I2C_SDA_IN         (tb_sda),
    .I_I2C_SCL_IN         (tb_scl),
    .O_I2C_SDA_DRIVE_LOW  (tb_master_sda_drive_low),
    .O_I2C_SCL_DRIVE_LOW  (tb_master_scl_drive_low),
    .O_CMD_BUSY           (tb_cmd_busy),
    .HOST_EVT_IF          (tb_host_evt_if)
  );

  eeprom_i2c_model #(
    .CHIP_SELECT        (EEPROM_CHIP_SELECT),
    .WRITE_BUSY_CYCLES  (4096)
  ) u_eeprom_i2c_model (
    .I_CLK              (tb_clk),
    .I_RST_N            (tb_rst_n),
    .I_SCL              (tb_scl),
    .I_SDA              (tb_sda),
    .O_SDA_DRIVE_LOW    (tb_model_sda_drive_low)
  );

  task automatic send_byte(input logic [7:0] byte_value);
    begin
      @(posedge tb_clk);
      tb_cli_rx_valid <= 1'b1;
      tb_cli_rx_data  <= byte_value;
      @(posedge tb_clk);
      tb_cli_rx_valid <= 1'b0;
      tb_cli_rx_data  <= 8'h00;
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

  task automatic send_bulk_block(
    input logic [7:0] block_type,
    input logic [7:0] seq,
    input logic [15:0] payload_len,
    input logic [MAX_BULK_PAYLOAD_BYTES*8-1:0] payload_bits
  );
    logic [15:0] crc_value;
    begin
      crc_value = calc_bulk_crc16(block_type, seq, payload_len, payload_bits);
      send_byte(BULK_SOF0);
      send_byte(BULK_SOF1);
      send_byte(block_type);
      send_byte(seq);
      send_byte(payload_len[7:0]);
      send_byte(payload_len[15:8]);
      for (int byte_idx = 0; byte_idx < payload_len; byte_idx++) begin
        send_byte(payload_bits[byte_idx*8 +: 8]);
      end
      send_byte(crc_value[7:0]);
      send_byte(crc_value[15:8]);
    end
  endtask

  task automatic accept_event;
    begin
      @(posedge tb_clk);
      tb_host_evt_if.evt_ready <= 1'b1;
      @(posedge tb_clk);
      tb_host_evt_if.evt_ready <= 1'b0;
      @(posedge tb_clk);
    end
  endtask

  task automatic expect_event(
    input logic [7:0]  expect_evt_id,
    input logic [31:0] expect_arg0,
    input logic [31:0] expect_arg1,
    input logic [31:0] expect_arg2,
    input string       label
  );
    int unsigned timeout_cycles;
    begin
      timeout_cycles = 0;
      while (!tb_host_evt_if.evt_valid) begin
        @(posedge tb_clk);
        timeout_cycles = timeout_cycles + 1;
        if (timeout_cycles > 400000) begin
          log_fatal(1, "EEPROM BRIDGE TB", {"timeout waiting for event: ", label});
        end
      end

      if ((tb_host_evt_if.evt_id != expect_evt_id) ||
          (tb_host_evt_if.arg0 != expect_arg0) ||
          (tb_host_evt_if.arg1 != expect_arg1) ||
          (tb_host_evt_if.arg2 != expect_arg2)) begin
        log_fatal(
          1,
          "EEPROM BRIDGE TB",
          $sformatf(
            "%s mismatch id=0x%02h/0x%02h arg0=0x%08h/0x%08h arg1=0x%08h/0x%08h arg2=0x%08h/0x%08h",
            label,
            tb_host_evt_if.evt_id,
            expect_evt_id,
            tb_host_evt_if.arg0,
            expect_arg0,
            tb_host_evt_if.arg1,
            expect_arg1,
            tb_host_evt_if.arg2,
            expect_arg2
          )
        );
      end

      accept_event();
    end
  endtask

`include "testcase_smoke.svh"

endmodule