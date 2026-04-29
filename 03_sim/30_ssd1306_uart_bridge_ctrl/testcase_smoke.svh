initial begin : tc_smoke
  logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] payload_bits;
  integer block_idx;
  integer byte_idx;
  integer frame_idx;

  wait (tb_rst_n === 1'b1);
  repeat (4) @(posedge tb_clk);

  reset_evt_capture();
  send_text("Z\n");
  wait_evt_count(1);
  if (evt_ids[0] != EVT_CMD_ERR || evt_arg0[0] != ERR_UNSUPPORTED_CMD) begin
    log_fatal(1, "SSD1306 BRIDGE TB", "unsupported command event mismatch");
  end

  reset_evt_capture();
  send_text("I\n");
  repeat (2) @(posedge tb_clk);
  send_text("X\n");
  wait_evt_count(2);
  if (evt_ids[0] != EVT_CMD_ERR || evt_arg0[0] != ERR_BUSY) begin
    log_fatal(1, "SSD1306 BRIDGE TB", "busy event mismatch");
  end
  if (evt_ids[1] != EVT_CMD_ACK || evt_arg0[1][2:0] != DISP_OP_INIT) begin
    log_fatal(1, "SSD1306 BRIDGE TB", "init ack mismatch");
  end

  reset_evt_capture();
  send_text("W\n");
  wait_evt_count(1);
  if (evt_ids[0] != EVT_FRAME_OK || evt_arg0[0] != SSD1306_FRAME_BYTES) begin
    log_fatal(1, "SSD1306 BRIDGE TB", "frame accept mismatch");
  end

  for (block_idx = 0; block_idx < SSD1306_FRAME_BLOCKS; block_idx++) begin
    payload_bits = '0;
    for (byte_idx = 0; byte_idx < MAX_BULK_PAYLOAD_BYTES; byte_idx++) begin
      payload_bits[byte_idx*8 +: 8] = ((block_idx * MAX_BULK_PAYLOAD_BYTES) + byte_idx) ^ 8'h3C;
    end
    send_bulk_packet(BULK_WR_DATA, block_idx[7:0], MAX_BULK_PAYLOAD_BYTES, payload_bits);
    wait_evt_count(block_idx + 2);
    if (evt_ids[block_idx + 1] != EVT_FRAME_PROG) begin
      log_fatal(1, "SSD1306 BRIDGE TB", $sformatf("frame progress event mismatch idx=%0d", block_idx));
    end
  end

  send_bulk_packet(BULK_WR_END, SSD1306_FRAME_BLOCKS[7:0], 16'h0000, '0);
  wait_evt_count(SSD1306_FRAME_BLOCKS + 2);
  if (evt_ids[SSD1306_FRAME_BLOCKS + 1] != EVT_FRAME_DONE) begin
    log_fatal(1, "SSD1306 BRIDGE TB", "frame done event mismatch");
  end

  for (frame_idx = 0; frame_idx < SSD1306_FRAME_BYTES; frame_idx++) begin
    if (u_ssd1306_i2c_model.r_gddram[frame_idx] != (frame_idx[7:0] ^ 8'h3C)) begin
      log_fatal(
        1,
        "SSD1306 BRIDGE TB",
        $sformatf(
          "frame payload mismatch idx=%0d got=0x%02h exp=0x%02h",
          frame_idx,
          u_ssd1306_i2c_model.r_gddram[frame_idx],
          (frame_idx[7:0] ^ 8'h3C)
        )
      );
    end
  end

  $display("ssd1306_uart_bridge_ctrl smoke test passed");
  $finish;
end