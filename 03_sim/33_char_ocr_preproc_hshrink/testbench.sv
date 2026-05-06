`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;

  logic [2047:0] tb_raw_image_bytes;
  logic          tb_empty_image;
  logic [1023:0] tb_preproc_bin_bytes;
  logic [8191:0] tb_feature_bytes;

  initial begin
    configure_logging(LOG_DEBUG);
  end

  char_ocr_preproc_hshrink u_dut (
    .I_RAW_IMAGE_BYTES   (tb_raw_image_bytes),
    .O_EMPTY_IMAGE       (tb_empty_image),
    .O_PREPROC_BIN_BYTES (tb_preproc_bin_bytes),
    .O_FEATURE_BYTES     (tb_feature_bytes)
  );

  task automatic clear_raw_image();
    begin
      tb_raw_image_bytes = '0;
    end
  endtask

  task automatic set_raw_pixel(
    input int unsigned pixel_x,
    input int unsigned pixel_y
  );
    int unsigned raw_byte_idx;
    int unsigned raw_bit_idx;
    begin
      raw_byte_idx = (pixel_y * 8) + (pixel_x >> 3);
      raw_bit_idx = pixel_x & 7;
      tb_raw_image_bytes[(raw_byte_idx * 8) + raw_bit_idx] = 1'b1;
    end
  endtask

  function automatic logic get_preproc_pixel(
    input int unsigned pixel_x,
    input int unsigned pixel_y
  );
    int unsigned out_byte_idx;
    int unsigned out_bit_idx;
    begin
      out_byte_idx = (pixel_y * 4) + (pixel_x >> 3);
      out_bit_idx = pixel_x & 7;
      get_preproc_pixel = tb_preproc_bin_bytes[(out_byte_idx * 8) + out_bit_idx];
    end
  endfunction

  function automatic logic [7:0] get_preproc_byte(
    input int unsigned byte_idx
  );
    begin
      get_preproc_byte = tb_preproc_bin_bytes[(byte_idx * 8) +: 8];
    end
  endfunction

  function automatic logic [7:0] get_feature_byte(
    input int unsigned feature_idx
  );
    begin
      get_feature_byte = tb_feature_bytes[(feature_idx * 8) +: 8];
    end
  endfunction

  task automatic expect_empty(
    input logic  exp_empty,
    input string label
  );
    begin
      #1ns;
      if (tb_empty_image !== exp_empty) begin
        log_fatal(
          1,
          "OCR PREPROC TB",
          $sformatf(
            "empty mismatch %s act=%0b exp=%0b",
            label,
            tb_empty_image,
            exp_empty
          )
        );
      end
      log_info("OCR PREPROC TB", {"empty ok: ", label});
    end
  endtask

  task automatic expect_preproc_pixel(
    input int unsigned pixel_x,
    input int unsigned pixel_y,
    input logic        exp_pixel,
    input string       label
  );
    logic act_pixel;
    begin
      #1ns;
      act_pixel = get_preproc_pixel(pixel_x, pixel_y);
      if (act_pixel !== exp_pixel) begin
        log_fatal(
          1,
          "OCR PREPROC TB",
          $sformatf(
            "preproc pixel mismatch %s x=%0d y=%0d act=%0b exp=%0b",
            label,
            pixel_x,
            pixel_y,
            act_pixel,
            exp_pixel
          )
        );
      end
      log_info("OCR PREPROC TB", {"preproc pixel ok: ", label});
    end
  endtask

  task automatic expect_preproc_byte(
    input int unsigned byte_idx,
    input logic [7:0]  exp_byte,
    input string       label
  );
    logic [7:0] act_byte;
    begin
      #1ns;
      act_byte = get_preproc_byte(byte_idx);
      if (act_byte !== exp_byte) begin
        log_fatal(
          1,
          "OCR PREPROC TB",
          $sformatf(
            "preproc byte mismatch %s idx=%0d act=0x%02h exp=0x%02h",
            label,
            byte_idx,
            act_byte,
            exp_byte
          )
        );
      end
      log_info("OCR PREPROC TB", {"preproc byte ok: ", label});
    end
  endtask

  task automatic expect_feature_byte(
    input int unsigned feature_idx,
    input logic [7:0]  exp_byte,
    input string       label
  );
    logic [7:0] act_byte;
    begin
      #1ns;
      act_byte = get_feature_byte(feature_idx);
      if (act_byte !== exp_byte) begin
        log_fatal(
          1,
          "OCR PREPROC TB",
          $sformatf(
            "feature mismatch %s idx=%0d act=0x%02h exp=0x%02h",
            label,
            feature_idx,
            act_byte,
            exp_byte
          )
        );
      end
      log_info("OCR PREPROC TB", {"feature ok: ", label});
    end
  endtask

`include "testcase_smoke.svh"

endmodule