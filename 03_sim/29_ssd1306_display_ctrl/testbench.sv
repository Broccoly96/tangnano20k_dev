`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import ssd1306_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 20ns;

  logic tb_clk;
  logic tb_rst_n;
  logic tb_req_valid;
  logic tb_req_ready;
  logic [2:0] tb_req_op;
  logic [(SSD1306_FRAME_BYTES*8)-1:0] tb_req_frame_data;
  logic tb_done_valid;
  logic [2:0] tb_done_op;
  logic tb_done_ok;
  logic [31:0] tb_done_status;
  logic tb_busy;

  tri1 tb_sda;
  tri1 tb_scl;
  logic tb_master_sda_drive_low;
  logic tb_master_scl_drive_low;
  logic tb_model_sda_drive_low;

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
    tb_req_valid = 1'b0;
    tb_req_op = DISP_OP_OFF;
    tb_req_frame_data = '0;
    repeat (8) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(20ms);
    log_fatal(1, "SSD1306 CTRL TB", "simulation timeout");
  end

  ssd1306_display_ctrl #(
    .CLK_HZ          (50_000_000),
    .I2C_BIT_RATE_HZ (1_000_000)
  ) u_dut (
    .I_CLK                (tb_clk),
    .I_RST_N              (tb_rst_n),
    .I_REQ_VALID          (tb_req_valid),
    .O_REQ_READY          (tb_req_ready),
    .I_REQ_OP             (tb_req_op),
    .I_REQ_FRAME_DATA     (tb_req_frame_data),
    .O_DONE_VALID         (tb_done_valid),
    .O_DONE_OP            (tb_done_op),
    .O_DONE_OK            (tb_done_ok),
    .O_DONE_STATUS        (tb_done_status),
    .O_BUSY               (tb_busy),
    .I_I2C_SDA_IN         (tb_sda),
    .I_I2C_SCL_IN         (tb_scl),
    .O_I2C_SDA_DRIVE_LOW  (tb_master_sda_drive_low),
    .O_I2C_SCL_DRIVE_LOW  (tb_master_scl_drive_low)
  );

  ssd1306_i2c_model u_ssd1306_i2c_model (
    .I_CLK            (tb_clk),
    .I_RST_N          (tb_rst_n),
    .I_SCL            (tb_scl),
    .I_SDA            (tb_sda),
    .O_SDA_DRIVE_LOW  (tb_model_sda_drive_low)
  );

  task automatic reset_model_capture;
    integer idx;
    begin
      u_ssd1306_i2c_model.r_rx_count = 0;
      u_ssd1306_i2c_model.r_cmd_count = 0;
      u_ssd1306_i2c_model.r_curr_col = 8'h00;
      u_ssd1306_i2c_model.r_curr_page = 3'd0;
      u_ssd1306_i2c_model.r_col_start = 8'h00;
      u_ssd1306_i2c_model.r_col_end = 8'h7F;
      u_ssd1306_i2c_model.r_page_start = 3'd0;
      u_ssd1306_i2c_model.r_page_end = 3'd3;
      u_ssd1306_i2c_model.r_addressing_mode = 2'b00;
      for (idx = 0; idx < SSD1306_FRAME_BYTES; idx++) begin
        u_ssd1306_i2c_model.r_gddram[idx] = 8'h00;
      end
    end
  endtask

  task automatic fill_model_gddram(input logic [7:0] fill_byte);
    integer idx;
    begin
      for (idx = 0; idx < SSD1306_FRAME_BYTES; idx++) begin
        u_ssd1306_i2c_model.r_gddram[idx] = fill_byte;
      end
    end
  endtask

  task automatic issue_req(
    input logic [2:0] req_op,
    input logic [(SSD1306_FRAME_BYTES*8)-1:0] frame_data
  );
    begin
      while (!tb_req_ready) @(posedge tb_clk);
      @(negedge tb_clk);
      tb_req_valid = 1'b1;
      tb_req_op = req_op;
      tb_req_frame_data = frame_data;
      @(posedge tb_clk);
      @(negedge tb_clk);
      tb_req_valid = 1'b0;
      tb_req_op = DISP_OP_OFF;
      tb_req_frame_data = '0;
    end
  endtask

  task automatic wait_done(input logic [2:0] expected_op);
    begin
      @(posedge tb_done_valid);
      if (tb_done_op != expected_op) begin
        log_fatal(1, "SSD1306 CTRL TB", $sformatf("done op mismatch got=%0d exp=%0d", tb_done_op, expected_op));
      end
      if (!tb_done_ok || (tb_done_status != 32'h0000_0000)) begin
        log_fatal(1, "SSD1306 CTRL TB", $sformatf("done status mismatch ok=%0b status=0x%08h", tb_done_ok, tb_done_status));
      end
      repeat (4) @(posedge tb_clk);
    end
  endtask

`include "testcase_smoke.svh"

endmodule