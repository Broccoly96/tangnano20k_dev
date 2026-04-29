`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import ssd1306_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 20ns;
  localparam int unsigned EVT_MAX_COUNT = 16;

  logic tb_clk;
  logic tb_rst_n;
  logic tb_cli_valid;
  logic [7:0] tb_cli_data;
  logic tb_busy;

  tri1 tb_sda;
  tri1 tb_scl;
  logic tb_master_sda_drive_low;
  logic tb_master_scl_drive_low;
  logic tb_model_sda_drive_low;

  uart_log_evt_if tb_evt_if();

  logic [7:0] evt_ids [0:EVT_MAX_COUNT-1];
  logic [31:0] evt_arg0 [0:EVT_MAX_COUNT-1];
  logic [31:0] evt_arg1 [0:EVT_MAX_COUNT-1];
  logic [31:0] evt_arg2 [0:EVT_MAX_COUNT-1];
  integer evt_count;

  assign tb_sda = tb_master_sda_drive_low ? 1'b0 : 1'bz;
  assign tb_sda = tb_model_sda_drive_low ? 1'b0 : 1'bz;
  assign tb_scl = tb_master_scl_drive_low ? 1'b0 : 1'bz;
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
    reset_evt_capture();
    repeat (8) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(30ms);
    log_fatal(1, "SSD1306 BRIDGE TB", "simulation timeout");
  end

  ssd1306_uart_bridge_ctrl #(
    .CLK_HZ          (50_000_000),
    .I2C_BIT_RATE_HZ (1_000_000)
  ) u_dut (
    .I_CLK                (tb_clk),
    .I_RST_N              (tb_rst_n),
    .I_ENABLE             (1'b1),
    .I_CLI_RX_VALID       (tb_cli_valid),
    .I_CLI_RX_DATA        (tb_cli_data),
    .I_I2C_SDA_IN         (tb_sda),
    .I_I2C_SCL_IN         (tb_scl),
    .O_I2C_SDA_DRIVE_LOW  (tb_master_sda_drive_low),
    .O_I2C_SCL_DRIVE_LOW  (tb_master_scl_drive_low),
    .O_CMD_BUSY           (tb_busy),
    .HOST_EVT_IF          (tb_evt_if)
  );

  ssd1306_i2c_model u_ssd1306_i2c_model (
    .I_CLK            (tb_clk),
    .I_RST_N          (tb_rst_n),
    .I_SCL            (tb_scl),
    .I_SDA            (tb_sda),
    .O_SDA_DRIVE_LOW  (tb_model_sda_drive_low)
  );

  always @(posedge tb_clk) begin
    if (tb_evt_if.evt_valid && tb_evt_if.evt_ready) begin
      if (evt_count >= EVT_MAX_COUNT) begin
        log_fatal(1, "SSD1306 BRIDGE TB", "event capture overflow");
      end
      evt_ids[evt_count] = tb_evt_if.evt_id;
      evt_arg0[evt_count] = tb_evt_if.arg0;
      evt_arg1[evt_count] = tb_evt_if.arg1;
      evt_arg2[evt_count] = tb_evt_if.arg2;
      evt_count = evt_count + 1;
    end
  end

  task automatic reset_evt_capture;
    integer idx;
    begin
      evt_count = 0;
      for (idx = 0; idx < EVT_MAX_COUNT; idx++) begin
        evt_ids[idx] = 8'h00;
        evt_arg0[idx] = 32'h0;
        evt_arg1[idx] = 32'h0;
        evt_arg2[idx] = 32'h0;
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

  task automatic send_bulk_packet(
    input logic [7:0] type_byte,
    input logic [7:0] seq_byte,
    input logic [15:0] payload_len,
    input logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] payload_bits
  );
    logic [15:0] crc_value;
    integer byte_idx;
    begin
      crc_value = calc_bulk_crc16(type_byte, seq_byte, payload_len, payload_bits);
      send_byte(BULK_SOF0);
      send_byte(BULK_SOF1);
      send_byte(type_byte);
      send_byte(seq_byte);
      send_byte(payload_len[7:0]);
      send_byte(payload_len[15:8]);
      for (byte_idx = 0; byte_idx < payload_len; byte_idx++) begin
        send_byte(payload_bits[byte_idx*8 +: 8]);
      end
      send_byte(crc_value[7:0]);
      send_byte(crc_value[15:8]);
    end
  endtask

`include "testcase_smoke.svh"

endmodule