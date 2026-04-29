initial begin
  wait (tb_rst_n === 1'b1);
  repeat (4) @(posedge tb_clk);

  reset_evt_capture();
  send_text("Z\n");
  wait_evt_count(1);
  if (evt_ids[0] != EVT_CMD_ERR || evt_arg0[0] != ERR_UNSUPPORTED_CMD) begin
    log_fatal(1, "SSD1331 BRIDGE TB", "unsupported command event mismatch");
  end

  reset_evt_capture();
  send_text("F ZZ0000\n");
  wait_evt_count(1);
  if (evt_ids[0] != EVT_CMD_ERR || evt_arg0[0] != ERR_BAD_ASCII_FIELD) begin
    log_fatal(1, "SSD1331 BRIDGE TB", "bad ASCII event mismatch");
  end

  reset_spi_capture();
  reset_evt_capture();
  send_text("I\n");
  repeat (2) @(posedge tb_clk);
  send_text("C\n");
  wait_evt_count(2);
  if (evt_ids[0] != EVT_CMD_ERR || evt_arg0[0] != ERR_BUSY) begin
    log_fatal(1, "SSD1331 BRIDGE TB", "busy rejection event mismatch");
  end
  if (evt_ids[1] != EVT_CMD_ACK || evt_arg0[1][2:0] != DISP_OP_INIT) begin
    log_fatal(1, "SSD1331 BRIDGE TB", "init ack mismatch");
  end
  if (cap_byte_count != 39) begin
    log_fatal(1, "SSD1331 BRIDGE TB", $sformatf("unexpected init byte count: %0d", cap_byte_count));
  end

  reset_spi_capture();
  reset_evt_capture();
  send_text("F FF0000\n");
  wait_evt_count(1);
  if (evt_ids[0] != EVT_CMD_ACK || evt_arg0[0][2:0] != DISP_OP_FILL) begin
    log_fatal(1, "SSD1331 BRIDGE TB", "fill ack mismatch");
  end
  if (evt_arg1[0][23:0] != 24'hFF0000) begin
    log_fatal(1, "SSD1331 BRIDGE TB", "fill ack color mismatch");
  end
  if (cap_byte_count != 13) begin
    log_fatal(1, "SSD1331 BRIDGE TB", $sformatf("unexpected fill byte count: %0d", cap_byte_count));
  end
  if (cap_bytes[0] != 8'h26 || cap_bytes[1] != 8'h01 || cap_bytes[2] != 8'h22 || cap_bytes[7] != 8'h3E) begin
    log_fatal(1, "SSD1331 BRIDGE TB", "fill byte prefix mismatch");
  end

  reset_spi_capture();
  reset_evt_capture();
  send_text("A\n");
  wait_evt_count(1);
  if (evt_ids[0] != EVT_CMD_ACK || evt_arg0[0][2:0] != DISP_OP_ALL_ON) begin
    log_fatal(1, "SSD1331 BRIDGE TB", "all-on ack mismatch");
  end
  if (cap_byte_count != 1 || cap_bytes[0] != 8'hA5) begin
    log_fatal(1, "SSD1331 BRIDGE TB", "all-on byte mismatch");
  end

  $display("ssd1331_uart_bridge_ctrl smoke test passed");
  $finish;
end
