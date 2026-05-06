  initial begin : tc_smoke
    @(posedge tb_rst_n);
    @(posedge tb_clk);

    set_raw_pixel(0, 0);
    set_weight0(0, 0, 8'sd100);
    set_weight1(10, 0, 8'sd5);
    set_bias0(0, 32'sd0);
    set_bias1(10, 32'sd0);

    tb_run_full_ocr = 1'b1;
    @(posedge tb_clk);
    tb_run_full_ocr = 1'b0;

    wait (tb_ocr_done == 1'b1);
    @(posedge tb_clk);

    if (tb_empty_image !== 1'b0) begin
      log_fatal(1, "OCR TOP TB", "unexpected empty-image detect");
    end
    if (tb_result_class !== 6'd10) begin
      log_fatal(1, "OCR TOP TB", $sformatf("result class mismatch act=%0d exp=10", tb_result_class));
    end
    if (tb_result_char !== 8'h41) begin
      log_fatal(1, "OCR TOP TB", $sformatf("result char mismatch act=0x%02h exp=0x41", tb_result_char));
    end
    if (tb_result_score0 !== 32'd500) begin
      log_fatal(1, "OCR TOP TB", $sformatf("score0 mismatch act=%0d exp=500", tb_result_score0));
    end
    if (tb_result_score1 !== 32'd0) begin
      log_fatal(1, "OCR TOP TB", $sformatf("score1 mismatch act=%0d exp=0", tb_result_score1));
    end
    if (tb_result_conf_gap !== 32'd500) begin
      log_fatal(1, "OCR TOP TB", $sformatf("conf gap mismatch act=%0d exp=500", tb_result_conf_gap));
    end

    expect_word(16'h0004, 32'h0000_0035, "status done and non-empty");
    expect_word(16'h003C, 32'h0000_0002, "nn layer count");
    expect_word(16'h0048, 32'd3200, "total cycles");
    expect_word(16'h004C, 32'd3072, "layer0 cycles");
    expect_word(16'h0050, 32'd128, "layer1 cycles");
    expect_word(16'h0054, 32'd0, "layer2 cycles");
    expect_word(16'h0060, 32'h0000_000A, "result class reg");
    expect_word(16'h0064, 32'h0000_0041, "result char reg");
    expect_word(16'h0068, 32'd500, "result score0 reg");
    expect_word(16'h006C, 32'd0, "result score1 reg");
    expect_word(16'h0070, 32'd500, "result gap reg");

    log_info("OCR TOP TB", "char_ocr_top default-model integration test passed");
    $finish;
  end