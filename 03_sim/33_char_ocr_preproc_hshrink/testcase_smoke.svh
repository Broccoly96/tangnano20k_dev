  initial begin : tc_smoke
    clear_raw_image();

    expect_empty(1'b1, "blank image");
    expect_preproc_byte(0, 8'h00, "blank row0 byte0");
    expect_preproc_byte(127, 8'h00, "blank last byte");
    expect_feature_bit(0, 1'b0, "blank feature 0");
    expect_feature_bit(1023, 1'b0, "blank feature 1023");

    set_raw_pixel(0, 0);
    set_raw_pixel(15, 0);
    set_raw_pixel(16, 0);
    set_raw_pixel(10, 7);
    set_raw_pixel(63, 31);

    expect_empty(1'b0, "non-empty image");
    expect_preproc_pixel(0, 0, 1'b1, "raw x0 sets out x0");
    expect_preproc_pixel(7, 0, 1'b1, "raw x15 sets out x7");
    expect_preproc_pixel(8, 0, 1'b1, "raw x16 sets out x8");
    expect_preproc_pixel(5, 7, 1'b1, "raw x10 sets out x5");
    expect_preproc_pixel(31, 31, 1'b1, "raw x63 sets last pixel");
    expect_preproc_pixel(6, 7, 1'b0, "neighbor pair remains clear");
    expect_preproc_pixel(30, 31, 1'b0, "last row neighbor remains clear");

    expect_preproc_byte(0, 8'h81, "row0 byte0 LSB-first packing");
    expect_preproc_byte(1, 8'h01, "row0 byte1 first bit");
    expect_preproc_byte(28, 8'h20, "row7 byte0 pair position");
    expect_preproc_byte(127, 8'h80, "last byte boundary");

    expect_feature_bit(0, 1'b1, "feature[0]");
    expect_feature_bit(7, 1'b1, "feature[7]");
    expect_feature_bit(8, 1'b1, "feature[8]");
    expect_feature_bit((7 * 32) + 5, 1'b1, "feature row7 col5");
    expect_feature_bit((31 * 32) + 31, 1'b1, "feature last entry");
    expect_feature_bit((7 * 32) + 6, 1'b0, "feature clear neighbor");

    log_info("OCR PREPROC TB", "char_ocr_preproc_hshrink smoke test passed");
    $finish;
  end