initial begin : tc_smoke
  logic [MAX_BULK_PAYLOAD_BYTES*8-1:0] bulk_payload;

  @(posedge tb_rst_n);

  log_info("EEPROM BRIDGE TB", "case: single ASCII write emits byte ACK event");
  send_text("W 00123 7F\n");
  expect_event(EVT_WRITE_ACK, 32'h0000_0123, 32'h0000_007F, 32'h0000_0000, "single write ack");

  log_info("EEPROM BRIDGE TB", "case: single ASCII read returns written byte");
  send_text("R 00123\n");
  expect_event(EVT_READ_RSP, 32'h0000_0123, 32'h0000_007F, 32'h0000_0000, "single read rsp");

  bulk_payload = '0;
  bulk_payload[0 +: 8]  = 8'h11;
  bulk_payload[8 +: 8]  = 8'h22;
  bulk_payload[16 +: 8] = 8'h33;
  bulk_payload[24 +: 8] = 8'h44;
  bulk_payload[32 +: 8] = 8'h55;
  bulk_payload[40 +: 8] = 8'h66;

  log_info("EEPROM BRIDGE TB", "case: BW session accepts padded payload and reports progress");
  send_text("BW 01010 00006\n");
  expect_event(EVT_BULK_OK, 32'h0000_1010, 32'h0000_0006, 32'h0000_0000, "bulk write ok");
  send_bulk_block(BULK_WR_DATA, 8'h00, 16'd8, bulk_payload);
  expect_event(EVT_BULK_PROG, 32'h0000_1010, 32'h0000_0006, 32'h0000_0000, "bulk write progress");
  send_bulk_block(BULK_WR_END, 8'h01, 16'd0, '0);
  expect_event(EVT_BULK_DONE, 32'h0000_1010, 32'h0000_0006, 32'h0000_0006, "bulk write done");

  log_info("EEPROM BRIDGE TB", "case: BR session returns byte-packed progress event");
  send_text("BR 01010 00006\n");
  expect_event(EVT_BULK_OK, 32'h0000_1010, 32'h0000_0006, 32'h0000_0001, "bulk read ok");
  expect_event(
    EVT_BULK_PROG,
    pack_eeprom_bulk_progress_arg0(17'h01010, 8'd6),
    32'h44332211,
    32'h00006655,
    "bulk read progress"
  );
  expect_event(EVT_BULK_DONE, 32'h0000_1010, 32'h0000_0006, 32'h0000_0006, "bulk read done");

  bulk_payload = '0;
  bulk_payload[0 +: 8]  = 8'hA1;
  bulk_payload[8 +: 8]  = 8'hA2;
  bulk_payload[16 +: 8] = 8'hA3;
  bulk_payload[24 +: 8] = 8'hA4;

  log_info("EEPROM BRIDGE TB", "case: BW splits a page-crossing write into two progress events");
  send_text("BW 0007E 00004\n");
  expect_event(EVT_BULK_OK, 32'h0000_007E, 32'h0000_0004, 32'h0000_0000, "page split write ok");
  send_bulk_block(BULK_WR_DATA, 8'h00, 16'd4, bulk_payload);
  expect_event(EVT_BULK_PROG, 32'h0000_007E, 32'h0000_0002, 32'h0000_0002, "page split write prog1");
  expect_event(EVT_BULK_PROG, 32'h0000_0080, 32'h0000_0004, 32'h0000_0000, "page split write prog2");
  send_bulk_block(BULK_WR_END, 8'h01, 16'd0, '0);
  expect_event(EVT_BULK_DONE, 32'h0000_007E, 32'h0000_0004, 32'h0000_0004, "page split write done");

  log_info("EEPROM BRIDGE TB", "case: BR splits a block-crossing read into two byte packets");
  send_text("BR 0FFFE 00004\n");
  expect_event(EVT_BULK_OK, 32'h0000_FFFE, 32'h0000_0004, 32'h0000_0001, "block split read ok");
  expect_event(
    EVT_BULK_PROG,
    pack_eeprom_bulk_progress_arg0(17'h0FFFE, 8'd2),
    32'h0000FFFE,
    32'h00000000,
    "block split read prog1"
  );
  expect_event(
    EVT_BULK_PROG,
    pack_eeprom_bulk_progress_arg0(17'h10000, 8'd2),
    32'h00000100,
    32'h00000000,
    "block split read prog2"
  );
  expect_event(EVT_BULK_DONE, 32'h0000_FFFE, 32'h0000_0004, 32'h0000_0004, "block split read done");

  log_info("EEPROM BRIDGE TB", "eeprom_uart_bridge_ctrl smoke test passed");
  $finish;
end