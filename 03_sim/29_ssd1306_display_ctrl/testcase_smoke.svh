initial begin : tc_smoke
  logic [(SSD1306_FRAME_BYTES*8)-1:0] frame_bits;
  integer idx;

  wait (tb_rst_n === 1'b1);
  repeat (4) @(posedge tb_clk);

  reset_model_capture();
  issue_req(DISP_OP_INIT, '0);
  wait_done(DISP_OP_INIT);
  if (u_ssd1306_i2c_model.r_rx_count != 27) begin
    log_fatal(1, "SSD1306 CTRL TB", $sformatf("init rx count mismatch got=%0d", u_ssd1306_i2c_model.r_rx_count));
  end
  if (u_ssd1306_i2c_model.r_rx_bytes[0] != 8'h78 ||
      u_ssd1306_i2c_model.r_rx_bytes[1] != 8'h00 ||
      u_ssd1306_i2c_model.r_rx_bytes[2] != 8'hAE ||
      u_ssd1306_i2c_model.r_rx_bytes[3] != 8'hD5 ||
      u_ssd1306_i2c_model.r_rx_bytes[4] != 8'h80 ||
      u_ssd1306_i2c_model.r_rx_bytes[26] != 8'hAF) begin
    log_fatal(1, "SSD1306 CTRL TB", "init byte prefix mismatch");
  end
  if (u_ssd1306_i2c_model.r_cmd_count != 16) begin
    log_fatal(1, "SSD1306 CTRL TB", $sformatf("init command count mismatch got=%0d", u_ssd1306_i2c_model.r_cmd_count));
  end

  reset_model_capture();
  fill_model_gddram(8'hA5);
  issue_req(DISP_OP_CLEAR, '0);
  wait_done(DISP_OP_CLEAR);
  if (u_ssd1306_i2c_model.r_rx_count != 524) begin
    log_fatal(1, "SSD1306 CTRL TB", $sformatf("clear rx count mismatch got=%0d", u_ssd1306_i2c_model.r_rx_count));
  end
  if (u_ssd1306_i2c_model.r_rx_bytes[0] != 8'h78 ||
      u_ssd1306_i2c_model.r_rx_bytes[1] != 8'h00 ||
      u_ssd1306_i2c_model.r_rx_bytes[2] != 8'h20 ||
      u_ssd1306_i2c_model.r_rx_bytes[3] != 8'h00 ||
      u_ssd1306_i2c_model.r_rx_bytes[4] != 8'h21 ||
      u_ssd1306_i2c_model.r_rx_bytes[9] != 8'h03 ||
      u_ssd1306_i2c_model.r_rx_bytes[10] != 8'h78 ||
      u_ssd1306_i2c_model.r_rx_bytes[11] != 8'h40) begin
    log_fatal(1, "SSD1306 CTRL TB", "clear command prefix mismatch");
  end
  for (idx = 0; idx < SSD1306_FRAME_BYTES; idx++) begin
    if (u_ssd1306_i2c_model.r_gddram[idx] != 8'h00) begin
      log_fatal(1, "SSD1306 CTRL TB", $sformatf("clear gddram mismatch idx=%0d data=0x%02h", idx, u_ssd1306_i2c_model.r_gddram[idx]));
    end
  end

  reset_model_capture();
  frame_bits = '0;
  for (idx = 0; idx < SSD1306_FRAME_BYTES; idx++) begin
    frame_bits[idx*8 +: 8] = idx[7:0] ^ 8'h5A;
  end
  issue_req(DISP_OP_FRAME_WRITE, frame_bits);
  wait_done(DISP_OP_FRAME_WRITE);
  if (u_ssd1306_i2c_model.r_rx_count != 524) begin
    log_fatal(1, "SSD1306 CTRL TB", $sformatf("frame rx count mismatch got=%0d", u_ssd1306_i2c_model.r_rx_count));
  end
  for (idx = 0; idx < SSD1306_FRAME_BYTES; idx++) begin
    if (u_ssd1306_i2c_model.r_gddram[idx] != (idx[7:0] ^ 8'h5A)) begin
      log_fatal(
        1,
        "SSD1306 CTRL TB",
        $sformatf(
          "frame gddram mismatch idx=%0d got=0x%02h exp=0x%02h",
          idx,
          u_ssd1306_i2c_model.r_gddram[idx],
          (idx[7:0] ^ 8'h5A)
        )
      );
    end
  end

  if (tb_busy != 1'b0 || tb_sda !== 1'b1 || tb_scl !== 1'b1) begin
    log_fatal(1, "SSD1306 CTRL TB", $sformatf("unexpected idle bus busy=%0b sda=%0b scl=%0b", tb_busy, tb_sda, tb_scl));
  end

  $display("ssd1306_display_ctrl smoke test passed");
  $finish;
end