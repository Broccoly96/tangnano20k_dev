`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_pkg.sv
// Description  : Shared constants, types, and helper functions for the Phase 1
//                OCR subsystem.
//                - Keeps the default-model geometry and memory sizing in one
//                  place so datapath, register-map, and testbench code stay
//                  aligned.
//                - Encodes the class mapping used by the OCR result path.
//////////////////////////////////////////////////////////////////////////////////

package char_ocr_pkg;

  localparam int unsigned CHAR_OCR_RAW_WIDTH           = 64;
  localparam int unsigned CHAR_OCR_RAW_HEIGHT          = 32;
  localparam int unsigned CHAR_OCR_RAW_ROW_BYTES       = 8;
  localparam int unsigned CHAR_OCR_RAW_IMAGE_BYTES     = 256;
  localparam int unsigned CHAR_OCR_PREPROC_WIDTH       = 32;
  localparam int unsigned CHAR_OCR_PREPROC_HEIGHT      = 32;
  localparam int unsigned CHAR_OCR_PREPROC_BIN_BYTES   = 128;
  localparam int unsigned CHAR_OCR_FEATURE_COUNT       = 1024;
  localparam int unsigned CHAR_OCR_CLASS_COUNT         = 36;
  localparam int unsigned CHAR_OCR_HIDDEN0_COUNT       = 64;
  localparam int unsigned CHAR_OCR_SCORE_VECTOR_WIDTH  = CHAR_OCR_CLASS_COUNT * 32;
  localparam int unsigned CHAR_OCR_FEATURE_VECTOR_WIDTH = CHAR_OCR_FEATURE_COUNT * 8;
  localparam int unsigned CHAR_OCR_WEIGHT0_COUNT       = CHAR_OCR_FEATURE_COUNT * CHAR_OCR_HIDDEN0_COUNT;
  localparam int unsigned CHAR_OCR_WEIGHT1_COUNT       = CHAR_OCR_HIDDEN0_COUNT * CHAR_OCR_CLASS_COUNT;
  localparam int unsigned CHAR_OCR_BIAS0_COUNT         = CHAR_OCR_HIDDEN0_COUNT;
  localparam int unsigned CHAR_OCR_BIAS1_COUNT         = CHAR_OCR_CLASS_COUNT;
  localparam int unsigned CHAR_OCR_LANE_COUNT          = 24;
  localparam int unsigned CHAR_OCR_DSP_COUNT           = 12;

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_RUN_LAYER0,
    ST_RUN_LAYER1,
    ST_DONE
  } char_ocr_state_t;

  function automatic logic [7:0] char_ocr_class_to_ascii(
    input logic [5:0] class_idx
  );
    begin
      if (class_idx < 6'd10) begin
        char_ocr_class_to_ascii = 8'(8'd48 + class_idx);
      end else begin
        char_ocr_class_to_ascii = 8'(8'd65 + (class_idx - 6'd10));
      end
    end
  endfunction

  function automatic logic signed [7:0] char_ocr_clamp_int8(
    input logic signed [31:0] value_in
  );
    begin
      if (value_in > 32'sd127) begin
        char_ocr_clamp_int8 = 8'sd127;
      end else if (value_in < -32'sd128) begin
        char_ocr_clamp_int8 = -8'sd128;
      end else begin
        char_ocr_clamp_int8 = value_in[7:0];
      end
    end
  endfunction

endpackage