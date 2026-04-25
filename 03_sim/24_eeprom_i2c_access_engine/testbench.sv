`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;
  import eeprom_uart_proto_pkg::*;

  localparam time CLK_PERIOD = 20833ps;

  logic tb_clk;
  logic tb_rst_n;
  logic tb_req_valid;
  logic tb_req_ready;
  logic tb_req_is_write;
  logic tb_req_is_raw_bulk;
  logic [16:0] tb_req_addr;
  logic [7:0]  tb_req_count;
  logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] tb_req_raw_wr_data;
  logic tb_evt_valid;
  logic tb_evt_ready;
  logic [7:0] tb_evt_id;
  logic [31:0] tb_evt_arg0;
  logic [31:0] tb_evt_arg1;
  logic [31:0] tb_evt_arg2;
  logic tb_raw_done;
  logic tb_raw_err_valid;
  logic [31:0] tb_raw_err_code;
  logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] tb_raw_rd_data;
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
    tb_req_is_write = 1'b0;
    tb_req_is_raw_bulk = 1'b0;
    tb_req_addr = '0;
    tb_req_count = 8'h01;
    tb_req_raw_wr_data = '0;
    tb_evt_ready = 1'b0;
    repeat (16) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(5ms);
    log_fatal(1, "EEPROM ACCESS TB", "simulation timeout");
  end

  eeprom_i2c_access_engine #(
    .CLK_HZ                    (48_000_000),
    .I2C_BIT_RATE_HZ           (100_000),
    .WRITE_POLL_TIMEOUT_CYCLES (80_000)
  ) u_dut (
    .I_CLK                  (tb_clk),
    .I_RST_N                (tb_rst_n),
    .I_REQ_VALID            (tb_req_valid),
    .O_REQ_READY            (tb_req_ready),
    .I_REQ_IS_WRITE         (tb_req_is_write),
    .I_REQ_IS_RAW_BULK      (tb_req_is_raw_bulk),
    .I_REQ_ADDR             (tb_req_addr),
    .I_REQ_COUNT            (tb_req_count),
    .I_REQ_RAW_WR_DATA      (tb_req_raw_wr_data),
    .I_I2C_SDA_IN           (tb_sda),
    .I_I2C_SCL_IN           (tb_scl),
    .O_I2C_SDA_DRIVE_LOW    (tb_master_sda_drive_low),
    .O_I2C_SCL_DRIVE_LOW    (tb_master_scl_drive_low),
    .O_EVT_VALID            (tb_evt_valid),
    .I_EVT_READY            (tb_evt_ready),
    .O_EVT_ID               (tb_evt_id),
    .O_EVT_ARG0             (tb_evt_arg0),
    .O_EVT_ARG1             (tb_evt_arg1),
    .O_EVT_ARG2             (tb_evt_arg2),
    .O_RAW_DONE             (tb_raw_done),
    .O_RAW_ERR_VALID        (tb_raw_err_valid),
    .O_RAW_ERR_CODE         (tb_raw_err_code),
    .O_RAW_RD_DATA          (tb_raw_rd_data),
    .O_BUSY                 (tb_busy)
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

  task automatic issue_request(
    input logic        is_write,
    input logic        is_raw_bulk,
    input logic [16:0] addr,
    input logic [7:0]  byte_count,
    input logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] raw_wr_data
  );
    begin
      while (!tb_req_ready) @(posedge tb_clk);
      @(posedge tb_clk);
      tb_req_valid       <= 1'b1;
      tb_req_is_write    <= is_write;
      tb_req_is_raw_bulk <= is_raw_bulk;
      tb_req_addr        <= addr;
      tb_req_count       <= byte_count;
      tb_req_raw_wr_data <= raw_wr_data;
      @(posedge tb_clk);
      tb_req_valid       <= 1'b0;
      tb_req_is_write    <= 1'b0;
      tb_req_is_raw_bulk <= 1'b0;
      tb_req_addr        <= '0;
      tb_req_count       <= 8'h01;
      tb_req_raw_wr_data <= '0;
    end
  endtask

  task automatic consume_event;
    begin
      @(posedge tb_clk);
      tb_evt_ready <= 1'b1;
      @(posedge tb_clk);
      tb_evt_ready <= 1'b0;
    end
  endtask

  task automatic expect_single_event(
    input logic [7:0]  expect_evt_id,
    input logic [16:0] expect_addr,
    input logic [31:0] expect_data,
    input logic [31:0] expect_status,
    input string       label
  );
    int unsigned timeout_cycles;
    begin
      timeout_cycles = 0;
      while (!tb_evt_valid) begin
        @(posedge tb_clk);
        timeout_cycles = timeout_cycles + 1;
        if (timeout_cycles > 200000) begin
          log_fatal(1, "EEPROM ACCESS TB", {"timeout waiting for event: ", label});
        end
      end

      if ((tb_evt_id != expect_evt_id) ||
          (tb_evt_arg0 != {15'h0000, expect_addr}) ||
          (tb_evt_arg1 != expect_data) ||
          (tb_evt_arg2 != expect_status)) begin
        log_fatal(
          1,
          "EEPROM ACCESS TB",
          $sformatf(
            "%s mismatch id=0x%02h/0x%02h arg0=0x%08h/0x%08h arg1=0x%08h/0x%08h arg2=0x%08h/0x%08h",
            label,
            tb_evt_id,
            expect_evt_id,
            tb_evt_arg0,
            {15'h0000, expect_addr},
            tb_evt_arg1,
            expect_data,
            tb_evt_arg2,
            expect_status
          )
        );
      end

      consume_event();
    end
  endtask

  task automatic expect_raw_done(input string label);
    int unsigned timeout_cycles;
    begin
      timeout_cycles = 0;
      while (!tb_raw_done && !tb_raw_err_valid) begin
        @(posedge tb_clk);
        timeout_cycles = timeout_cycles + 1;
        if (timeout_cycles > 200000) begin
          log_fatal(1, "EEPROM ACCESS TB", {"timeout waiting for raw completion: ", label});
        end
      end
      if (tb_raw_err_valid) begin
        log_fatal(1, "EEPROM ACCESS TB", $sformatf("%s unexpected raw error 0x%08h", label, tb_raw_err_code));
      end
    end
  endtask

  task automatic expect_raw_err(
    input logic [31:0] expect_code,
    input string       label
  );
    int unsigned timeout_cycles;
    begin
      timeout_cycles = 0;
      while (!tb_raw_err_valid) begin
        @(posedge tb_clk);
        timeout_cycles = timeout_cycles + 1;
        if (timeout_cycles > 200000) begin
          log_fatal(1, "EEPROM ACCESS TB", {"timeout waiting for raw error: ", label});
        end
      end
      if (tb_raw_err_code != expect_code) begin
        log_fatal(
          1,
          "EEPROM ACCESS TB",
          $sformatf("%s raw error mismatch 0x%08h/0x%08h", label, tb_raw_err_code, expect_code)
        );
      end
    end
  endtask

`include "testcase_smoke.svh"

endmodule