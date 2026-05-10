  // HIDDEN0_COUNT=24: L0_GROUPS=2, L1_GROUPS=3, HIDDEN_PAIRS=12
  // Expected cycle counts:
  //   L0: (FEAT_PAIRS + PIPE_LATENCY) * L0_GROUPS = (512+3)*2 = 1030
  //   L1: (HIDDEN_PAIRS + PIPE_LATENCY) * L1_GROUPS = (12+3)*3 = 45
  //   Total: 1030 + 45 = 1075
  //
  // All weights and biases are zero (BSRAM init = 0x0000, LUT-ROM init = 0x0000).
  // With zero weights, all scores are 0. argmax returns first class (class=0 = char '0').

  initial begin : tc_smoke
    @(posedge tb_rst_n);
    @(posedge tb_clk);

    // Set a non-empty raw image: at least 1 pixel must be set for OCR to start.
    // Pixel (0,0) is sufficient to make the image non-empty.
    set_raw_pixel(0, 0);

    tb_run_full_ocr = 1'b1;
    log_info("OCR TOP TB", "run_full_ocr pulsed (zero-weight model, expect class=0 char='0')");
    @(posedge tb_clk);
    tb_run_full_ocr = 1'b0;
    log_debug("OCR TOP TB", $sformatf("after pulse: ocr_done=%0d empty_image=%0d",
      tb_ocr_done, tb_empty_image));

    log_info("OCR TOP TB", "waiting for ocr_done (timeout=300us)...");
    fork
      begin : wait_done
        wait (tb_ocr_done == 1'b1);
      end
      begin : timeout_guard
        // 1075 cycles * 40ns/cycle = 43us; allow 300us for reset + pipeline margin
        #(300_000ns);
        log_fatal(1, "OCR TOP TB",
          $sformatf("TIMEOUT: ocr_done not seen after 300us (busy=%0d done=%0d)",
            u_dut.u_char_ocr_infer_core.O_BUSY,
            u_dut.u_char_ocr_infer_core.O_DONE));
      end
    join_any
    disable fork;
    log_debug("OCR TOP TB", "ocr_done received");
    @(posedge tb_clk);

    // Empty-image: should be 0 (we set at least 1 pixel)
    if (tb_empty_image !== 1'b0) begin
      log_fatal(1, "OCR TOP TB", "unexpected empty-image flag set");
    end

    // With all-zero weights and biases, all 36 scores are 0.
    // argmax picks the lowest-index class that achieves the maximum (0).
    // Expected: class=0 (char '0' = ASCII 0x30).
    if (tb_result_class !== 6'd0) begin
      log_fatal(1, "OCR TOP TB",
        $sformatf("result class mismatch act=%0d exp=0", tb_result_class));
    end
    if (tb_result_char !== 8'h30) begin
      log_fatal(1, "OCR TOP TB",
        $sformatf("result char mismatch act=0x%02h exp=0x30('0')", tb_result_char));
    end

    // All scores zero; score0=score1=0, conf_gap=0
    if (tb_result_score0 !== 32'd0) begin
      log_fatal(1, "OCR TOP TB",
        $sformatf("score0 mismatch act=%0d exp=0", tb_result_score0));
    end
    if (tb_result_score1 !== 32'd0) begin
      log_fatal(1, "OCR TOP TB",
        $sformatf("score1 mismatch act=%0d exp=0", tb_result_score1));
    end
    if (tb_result_conf_gap !== 32'd0) begin
      log_fatal(1, "OCR TOP TB",
        $sformatf("conf_gap mismatch act=%0d exp=0", tb_result_conf_gap));
    end

    // Register-map spot-checks
    expect_word(16'h0004, 32'h0000_0035, "status done and non-empty");
    expect_word(16'h003C, 32'h0000_0002, "nn layer count");
    expect_word(16'h0048, 32'd1075,      "total cycles (L0=1030 + L1=45)");
    expect_word(16'h004C, 32'd1030,      "layer0 cycles (2*(512+3))");
    expect_word(16'h0050, 32'd45,        "layer1 cycles (3*(12+3))");
    expect_word(16'h0054, 32'd0,         "layer2 cycles (unused)");
    expect_word(16'h0060, 32'h0000_0000, "result class reg = 0");
    expect_word(16'h0064, 32'h0000_0030, "result char reg = '0'");
    expect_word(16'h0068, 32'd0,         "result score0 reg = 0");
    expect_word(16'h006C, 32'd0,         "result score1 reg = 0");
    expect_word(16'h0070, 32'd0,         "result gap reg = 0");

    log_info("OCR TOP TB", "PASS: char_ocr_top 24-neuron zero-weight integration test");
    $finish;
  end