initial begin
  wait (tb_rst_n === 1'b1);
  repeat (4) @(posedge tb_clk);

  send_byte(8'hA0, 1'b0, 1'b1, 1'b0);
  send_byte(8'h72, 1'b1, 1'b0, 1'b0);
  send_byte(8'h15, 1'b1, 1'b0, 1'b1);

  @(posedge tb_tx_done);
  repeat (8) @(posedge tb_clk);

  if (cap_byte_count != 3) begin
    log_fatal(1, "SSD1331 SPI TB", $sformatf("unexpected byte count: %0d", cap_byte_count));
  end

  if (cap_bytes[0] != 8'hA0 || cap_dcs[0] != 1'b0) begin
    log_fatal(1, "SSD1331 SPI TB", $sformatf("byte0 mismatch data=0x%02h dc=%0b", cap_bytes[0], cap_dcs[0]));
  end
  if (cap_bytes[1] != 8'h72 || cap_dcs[1] != 1'b1) begin
    log_fatal(1, "SSD1331 SPI TB", $sformatf("byte1 mismatch data=0x%02h dc=%0b", cap_bytes[1], cap_dcs[1]));
  end
  if (cap_bytes[2] != 8'h15 || cap_dcs[2] != 1'b1) begin
    log_fatal(1, "SSD1331 SPI TB", $sformatf("byte2 mismatch data=0x%02h dc=%0b", cap_bytes[2], cap_dcs[2]));
  end

  if (cap_cs_assert_count != 1 || cap_cs_deassert_count != 1) begin
    log_fatal(
      1,
      "SSD1331 SPI TB",
      $sformatf("unexpected CS framing assert=%0d deassert=%0d", cap_cs_assert_count, cap_cs_deassert_count)
    );
  end

  if (tb_cs_n != 1'b1 || tb_sclk != 1'b0 || tb_busy != 1'b0) begin
    log_fatal(
      1,
      "SSD1331 SPI TB",
      $sformatf("unexpected idle outputs cs_n=%0b sclk=%0b busy=%0b", tb_cs_n, tb_sclk, tb_busy)
    );
  end

  $display("ssd1331_spi_master smoke test passed");
  $finish;
end