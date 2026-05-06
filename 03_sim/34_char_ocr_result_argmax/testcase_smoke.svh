  initial begin : tc_smoke
    clear_scores();
    for (int unsigned class_idx = 0; class_idx < 36; class_idx++) begin
      set_score(class_idx, -32'sd1000 + class_idx);
    end
    set_score(10, 32'sd1250);
    set_score(35, 32'sd900);
    expect_result(6'd10, 8'h41, 32'd1250, 32'd900, 32'd350, "basic argmax to 'A'");

    clear_scores();
    for (int unsigned class_idx = 0; class_idx < 36; class_idx++) begin
      set_score(class_idx, -32'sd4000);
    end
    set_score(1, 32'sd777);
    set_score(5, 32'sd777);
    set_score(8, 32'sd100);
    expect_result(6'd1, 8'h31, 32'd777, 32'd777, 32'd0, "stable tie handling");

    clear_scores();
    for (int unsigned class_idx = 0; class_idx < 36; class_idx++) begin
      set_score(class_idx, -32'sd4000);
    end
    set_score(0, -32'sd5);
    set_score(9, -32'sd1);
    set_score(10, -32'sd2);
    set_score(35, -32'sd3);
    expect_result(6'd9, 8'h39, 32'hFFFF_FFFF, 32'hFFFF_FFFE, 32'd1, "negative score handling");

    log_info("OCR ARGMAX TB", "char_ocr_result_argmax smoke test passed");
    $finish;
  end