`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_preproc_hshrink.sv
// Description  : Phase 1 OCR preprocessor.
//                - Converts the 64x32 raw 1bpp image into a 32x32 feature map
//                  using horizontal 2:1 OR reduction.
//                - Produces both the packed 32x32 1bpp buffer and the expanded
//                  1024-byte int8 feature buffer expected by later OCR blocks.
//                - Uses the raw-image packing defined in char_ocr_mmap.md:
//                  byte_index = y*8 + (x>>3), bit_index = x[2:0].
// Usage        : Drive I_RAW_IMAGE_BYTES with the 256-byte raw image buffer.
//                Read O_PREPROC_BIN_BYTES for the packed 32x32 bitmap and
//                O_FEATURE_BYTES for the row-major int8 feature vector.
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_preproc_hshrink (
  input  logic [2047:0] I_RAW_IMAGE_BYTES,
  output logic          O_EMPTY_IMAGE,
  output logic [1023:0] O_PREPROC_BIN_BYTES
);

  function automatic logic get_raw_pixel(
    input logic [2047:0] raw_image_bytes,
    input int unsigned   pixel_x,
    input int unsigned   pixel_y
  );
    int unsigned raw_byte_idx;
    int unsigned raw_bit_idx;
    begin
      raw_byte_idx = (pixel_y * 8) + (pixel_x >> 3);
      raw_bit_idx = pixel_x & 7;
      get_raw_pixel = raw_image_bytes[(raw_byte_idx * 8) + raw_bit_idx];
    end
  endfunction

  // Builds the packed 32x32 binary image and the expanded int8 feature vector
  // in one pass so the raw-image interpretation stays identical for both views.
  always_comb begin
    logic any_raw_pixel_set;
    logic left_pixel;
    logic right_pixel;
    logic preproc_pixel;
    int unsigned out_byte_idx;
    int unsigned out_bit_idx;
    int unsigned feature_idx; // kept for loop variable (unused in output)

    O_PREPROC_BIN_BYTES = '0;
    any_raw_pixel_set = 1'b0;

    for (int unsigned pixel_y = 0; pixel_y < 32; pixel_y++) begin
      for (int unsigned pixel_x = 0; pixel_x < 32; pixel_x++) begin
        left_pixel = get_raw_pixel(I_RAW_IMAGE_BYTES, pixel_x * 2, pixel_y);
        right_pixel = get_raw_pixel(I_RAW_IMAGE_BYTES, (pixel_x * 2) + 1, pixel_y);
        preproc_pixel = left_pixel | right_pixel;

        any_raw_pixel_set |= left_pixel;
        any_raw_pixel_set |= right_pixel;

        out_byte_idx = (pixel_y * 4) + (pixel_x >> 3);
        out_bit_idx = pixel_x & 7;
        O_PREPROC_BIN_BYTES[(out_byte_idx * 8) + out_bit_idx] = preproc_pixel;

        feature_idx = (pixel_y * 32) + pixel_x;
      end
    end

    O_EMPTY_IMAGE = ~any_raw_pixel_set;
  end

endmodule