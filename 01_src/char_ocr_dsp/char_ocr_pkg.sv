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
  // HIDDEN0_COUNT = 24 (2 groups of 12 DSP lanes) to fit L0 weight ROMs in
  // remaining BSRAM18 blocks. Each lane uses one BSRAM18 (1024 x 16-bit).
  // 12 lanes x 1 BSRAM18 = 12 BSRAM18 for L0; L1 uses LUT-ROM (small).
  localparam int unsigned CHAR_OCR_HIDDEN0_COUNT       = 24;
  localparam int unsigned CHAR_OCR_SCORE_VECTOR_WIDTH  = CHAR_OCR_CLASS_COUNT * 32;
  localparam int unsigned CHAR_OCR_FEATURE_VECTOR_WIDTH = CHAR_OCR_FEATURE_COUNT * 8;
  localparam int unsigned CHAR_OCR_WEIGHT0_COUNT       = CHAR_OCR_FEATURE_COUNT * CHAR_OCR_HIDDEN0_COUNT;
  localparam int unsigned CHAR_OCR_WEIGHT1_COUNT       = CHAR_OCR_HIDDEN0_COUNT * CHAR_OCR_CLASS_COUNT;
  localparam int unsigned CHAR_OCR_BIAS0_COUNT         = CHAR_OCR_HIDDEN0_COUNT;
  localparam int unsigned CHAR_OCR_BIAS1_COUNT         = CHAR_OCR_CLASS_COUNT;
  // DSP array: 12 MULTADDALU18X18 units, each accumulates one neuron.
  // Two MACs per DSP per cycle (A0*B0 + A1*B1), processing two consecutive
  // features of the same neuron per clock.
  localparam int unsigned CHAR_OCR_LANE_COUNT          = 12;
  localparam int unsigned CHAR_OCR_DSP_COUNT           = 12;
  // Pipeline latency of gowin_multaddalu_18x18:
  //   Stage 1: A/B input registers
  //   Stage 2: Multiply pipe registers (PIPE0_REG, PIPE1_REG)
  //   Stage 3: OUT_REG (accumulator register)
  // After the last valid input, 3 extra zero-input cycles flush the pipeline.
  localparam int unsigned CHAR_OCR_PIPE_LATENCY        = 3;
  // Feature and hidden-activation pair counts (2 per cycle)
  localparam int unsigned CHAR_OCR_FEAT_PAIRS    = CHAR_OCR_FEATURE_COUNT / 2;   // 512
  localparam int unsigned CHAR_OCR_HIDDEN_PAIRS  = CHAR_OCR_HIDDEN0_COUNT / 2;   // 32
  // Layer group counts: how many groups of LANE_COUNT neurons are needed
  localparam int unsigned CHAR_OCR_L0_GROUPS =
    (CHAR_OCR_HIDDEN0_COUNT + CHAR_OCR_LANE_COUNT - 1) / CHAR_OCR_LANE_COUNT;  // 6
  localparam int unsigned CHAR_OCR_L1_GROUPS =
    (CHAR_OCR_CLASS_COUNT + CHAR_OCR_LANE_COUNT - 1) / CHAR_OCR_LANE_COUNT;    // 3

  // Inference state machine.
  // Each layer group cycles through: RESET -> RUN -> FLUSH -> READ.
  // RESET  : one cycle, DSP accumulators and pipeline cleared.
  // RUN    : FEAT_PAIRS (512) or HIDDEN_PAIRS (32) cycles, valid data fed.
  // FLUSH  : PIPE_LATENCY (3) cycles, zero inputs flush the pipeline.
  // READ   : one cycle, accumulated result captured and bias+ReLU applied.
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_L0_RESET,
    ST_L0_RUN,
    ST_L0_FLUSH,
    ST_L0_READ,
    ST_L1_RESET,
    ST_L1_RUN,
    ST_L1_FLUSH,
    ST_L1_READ,
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