`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_reg_map.sv
// Description  : OCR control/status register read map for the Phase 1 character
//                OCR subsystem.
//                - Maps byte-addressed control and status registers onto 32-bit
//                  read data words at 4-byte steps.
//                - Keeps address decode separate from the write-side controller
//                  so later OCR blocks can share one stable host-visible map.
//                - Unmapped or reserved addresses return zero.
// Usage        : Connect this block to the OCR controller's live register/state
//                images and feed host read addresses through I_ADDR.
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_reg_map (
  input  logic [15:0] I_ADDR,
  input  logic [31:0] I_CTRL_RD_DATA,
  input  logic [31:0] I_STATUS_RD_DATA,
  input  logic [31:0] I_IRQ_ENABLE_RD_DATA,
  input  logic [31:0] I_IRQ_STATUS_RD_DATA,
  input  logic [31:0] I_MODEL_CTRL_RD_DATA,
  input  logic [31:0] I_MODEL_STATUS_RD_DATA,
  input  logic [31:0] I_MODEL_ID_RD_DATA,
  input  logic [31:0] I_MODEL_CRC_RD_DATA,
  input  logic [31:0] I_PREPROC_CTRL_RD_DATA,
  input  logic [31:0] I_PREPROC_STATUS_RD_DATA,
  input  logic [31:0] I_BBOX_X_RD_DATA,
  input  logic [31:0] I_BBOX_Y_RD_DATA,
  input  logic [31:0] I_NN_CTRL_RD_DATA,
  input  logic [31:0] I_NN_STATUS_RD_DATA,
  input  logic        I_NN_MODEL_SELECT,
  input  logic [7:0]  I_NN_LAYER_COUNT,
  input  logic [31:0] I_DSP_CONFIG_RD_DATA,
  input  logic [31:0] I_DSP_STATUS_RD_DATA,
  input  logic [31:0] I_DSP_CYCLES_TOTAL_RD_DATA,
  input  logic [31:0] I_DSP_CYCLES_L0_RD_DATA,
  input  logic [31:0] I_DSP_CYCLES_L1_RD_DATA,
  input  logic [31:0] I_DSP_CYCLES_L2_RD_DATA,
  input  logic [5:0]  I_RESULT_CLASS,
  input  logic [7:0]  I_RESULT_CHAR,
  input  logic [31:0] I_RESULT_SCORE0_RD_DATA,
  input  logic [31:0] I_RESULT_SCORE1_RD_DATA,
  input  logic [31:0] I_RESULT_CONF_GAP_RD_DATA,
  input  logic [31:0] I_OLED_CTRL_RD_DATA,
  input  logic [31:0] I_OLED_STATUS_RD_DATA,
  input  logic [31:0] I_OLED_TOGGLE_MS_RD_DATA,
  input  logic [31:0] I_VERSION_RD_DATA,
  input  logic [31:0] I_BUILD_ID_RD_DATA,
  output logic [31:0] O_RD_DATA
);

  localparam int unsigned WORD_CTRL             = 16'h0000 >> 2;
  localparam int unsigned WORD_STATUS           = 16'h0004 >> 2;
  localparam int unsigned WORD_IRQ_ENABLE       = 16'h0008 >> 2;
  localparam int unsigned WORD_IRQ_STATUS       = 16'h000C >> 2;
  localparam int unsigned WORD_MODEL_CTRL       = 16'h0010 >> 2;
  localparam int unsigned WORD_MODEL_STATUS     = 16'h0014 >> 2;
  localparam int unsigned WORD_MODEL_ID         = 16'h0018 >> 2;
  localparam int unsigned WORD_MODEL_CRC        = 16'h001C >> 2;
  localparam int unsigned WORD_PREPROC_CTRL     = 16'h0020 >> 2;
  localparam int unsigned WORD_PREPROC_STATUS   = 16'h0024 >> 2;
  localparam int unsigned WORD_BBOX_X           = 16'h0028 >> 2;
  localparam int unsigned WORD_BBOX_Y           = 16'h002C >> 2;
  localparam int unsigned WORD_NN_CTRL          = 16'h0030 >> 2;
  localparam int unsigned WORD_NN_STATUS        = 16'h0034 >> 2;
  localparam int unsigned WORD_NN_MODEL_SELECT  = 16'h0038 >> 2;
  localparam int unsigned WORD_NN_LAYER_COUNT   = 16'h003C >> 2;
  localparam int unsigned WORD_DSP_CONFIG       = 16'h0040 >> 2;
  localparam int unsigned WORD_DSP_STATUS       = 16'h0044 >> 2;
  localparam int unsigned WORD_DSP_CYCLES_TOTAL = 16'h0048 >> 2;
  localparam int unsigned WORD_DSP_CYCLES_L0    = 16'h004C >> 2;
  localparam int unsigned WORD_DSP_CYCLES_L1    = 16'h0050 >> 2;
  localparam int unsigned WORD_DSP_CYCLES_L2    = 16'h0054 >> 2;
  localparam int unsigned WORD_RESULT_CLASS     = 16'h0060 >> 2;
  localparam int unsigned WORD_RESULT_CHAR      = 16'h0064 >> 2;
  localparam int unsigned WORD_RESULT_SCORE0    = 16'h0068 >> 2;
  localparam int unsigned WORD_RESULT_SCORE1    = 16'h006C >> 2;
  localparam int unsigned WORD_RESULT_CONF_GAP  = 16'h0070 >> 2;
  localparam int unsigned WORD_OLED_CTRL        = 16'h0080 >> 2;
  localparam int unsigned WORD_OLED_STATUS      = 16'h0084 >> 2;
  localparam int unsigned WORD_OLED_TOGGLE_MS   = 16'h0088 >> 2;
  localparam int unsigned WORD_VERSION          = 16'h00F0 >> 2;
  localparam int unsigned WORD_BUILD_ID         = 16'h00F4 >> 2;

  logic [13:0] word_addr;
  logic [31:0] s_nn_model_select_word;
  logic [31:0] s_nn_layer_count_word;
  logic [31:0] s_result_class_word;
  logic [31:0] s_result_char_word;

  assign word_addr = I_ADDR[15:2];

  always_comb begin
    s_nn_model_select_word = 32'h0000_0000;
    s_nn_model_select_word[0] = I_NN_MODEL_SELECT;
  end

  always_comb begin
    s_nn_layer_count_word = 32'h0000_0000;
    s_nn_layer_count_word[7:0] = I_NN_LAYER_COUNT;
  end

  always_comb begin
    s_result_class_word = 32'h0000_0000;
    s_result_class_word[5:0] = I_RESULT_CLASS;
  end

  always_comb begin
    s_result_char_word = 32'h0000_0000;
    s_result_char_word[7:0] = I_RESULT_CHAR;
  end

  // Byte-addressed host reads collapse onto 32-bit words by ignoring I_ADDR[1:0].
  // Reserved holes intentionally read back as zero to keep the map stable.
  always_comb begin
    O_RD_DATA = 32'h0000_0000;

    case (word_addr)
      WORD_CTRL:             O_RD_DATA = I_CTRL_RD_DATA;
      WORD_STATUS:           O_RD_DATA = I_STATUS_RD_DATA;
      WORD_IRQ_ENABLE:       O_RD_DATA = I_IRQ_ENABLE_RD_DATA;
      WORD_IRQ_STATUS:       O_RD_DATA = I_IRQ_STATUS_RD_DATA;
      WORD_MODEL_CTRL:       O_RD_DATA = I_MODEL_CTRL_RD_DATA;
      WORD_MODEL_STATUS:     O_RD_DATA = I_MODEL_STATUS_RD_DATA;
      WORD_MODEL_ID:         O_RD_DATA = I_MODEL_ID_RD_DATA;
      WORD_MODEL_CRC:        O_RD_DATA = I_MODEL_CRC_RD_DATA;
      WORD_PREPROC_CTRL:     O_RD_DATA = I_PREPROC_CTRL_RD_DATA;
      WORD_PREPROC_STATUS:   O_RD_DATA = I_PREPROC_STATUS_RD_DATA;
      WORD_BBOX_X:           O_RD_DATA = I_BBOX_X_RD_DATA;
      WORD_BBOX_Y:           O_RD_DATA = I_BBOX_Y_RD_DATA;
      WORD_NN_CTRL:          O_RD_DATA = I_NN_CTRL_RD_DATA;
      WORD_NN_STATUS:        O_RD_DATA = I_NN_STATUS_RD_DATA;
      WORD_NN_MODEL_SELECT:  O_RD_DATA = s_nn_model_select_word;
      WORD_NN_LAYER_COUNT:   O_RD_DATA = s_nn_layer_count_word;
      WORD_DSP_CONFIG:       O_RD_DATA = I_DSP_CONFIG_RD_DATA;
      WORD_DSP_STATUS:       O_RD_DATA = I_DSP_STATUS_RD_DATA;
      WORD_DSP_CYCLES_TOTAL: O_RD_DATA = I_DSP_CYCLES_TOTAL_RD_DATA;
      WORD_DSP_CYCLES_L0:    O_RD_DATA = I_DSP_CYCLES_L0_RD_DATA;
      WORD_DSP_CYCLES_L1:    O_RD_DATA = I_DSP_CYCLES_L1_RD_DATA;
      WORD_DSP_CYCLES_L2:    O_RD_DATA = I_DSP_CYCLES_L2_RD_DATA;
      WORD_RESULT_CLASS:     O_RD_DATA = s_result_class_word;
      WORD_RESULT_CHAR:      O_RD_DATA = s_result_char_word;
      WORD_RESULT_SCORE0:    O_RD_DATA = I_RESULT_SCORE0_RD_DATA;
      WORD_RESULT_SCORE1:    O_RD_DATA = I_RESULT_SCORE1_RD_DATA;
      WORD_RESULT_CONF_GAP:  O_RD_DATA = I_RESULT_CONF_GAP_RD_DATA;
      WORD_OLED_CTRL:        O_RD_DATA = I_OLED_CTRL_RD_DATA;
      WORD_OLED_STATUS:      O_RD_DATA = I_OLED_STATUS_RD_DATA;
      WORD_OLED_TOGGLE_MS:   O_RD_DATA = I_OLED_TOGGLE_MS_RD_DATA;
      WORD_VERSION:          O_RD_DATA = I_VERSION_RD_DATA;
      WORD_BUILD_ID:         O_RD_DATA = I_BUILD_ID_RD_DATA;
      default:               O_RD_DATA = 32'h0000_0000;
    endcase
  end

endmodule