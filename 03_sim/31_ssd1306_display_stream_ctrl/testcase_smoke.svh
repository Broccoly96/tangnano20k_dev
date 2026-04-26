initial begin : tc_smoke
  integer idx;

  wait (tb_rst_n === 1'b1);
  repeat (4) @(posedge tb_clk);

  reset_model_capture();
  issue_req(DISP_OP_FRAME_WRITE);
  wait_done(DISP_OP_FRAME_WRITE);

  if (u_ssd1306_i2c_model.r_rx_count != 524) begin
    log_fatal(
      1,
      "SSD1306 STREAM TB",
      $sformatf("frame rx count mismatch got=%0d", u_ssd1306_i2c_model.r_rx_count)
    );
  end

  for (idx = 0; idx < SSD1306_FRAME_BYTES; idx++) begin
    if (u_ssd1306_i2c_model.r_gddram[idx] != (idx[7:0] ^ 8'hA5)) begin
      log_fatal(
        1,
        "SSD1306 STREAM TB",
        $sformatf(
          "frame gddram mismatch idx=%0d got=0x%02h exp=0x%02h",
          idx,
          u_ssd1306_i2c_model.r_gddram[idx],
          (idx[7:0] ^ 8'hA5)
        )
      );
    end
  end

  $display("ssd1306_display_stream_ctrl smoke test passed");
  $finish;
end
