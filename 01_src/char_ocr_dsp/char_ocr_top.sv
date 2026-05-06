`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_top.sv
// Description  : Phase 1 OCR subsystem integration top for simulation and
//                bring-up.
//                - Integrates raw-image preprocessing, default-model inference,
//                  argmax reduction, and the OCR register read map.
//                - Keeps the control surface intentionally small: start pulse,
//                  model payload vectors, and a host-style read address port.
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_top (
  input  logic                                        I_CLK,
  input  logic                                        I_RST_N,
  input  logic                                        I_RUN_FULL_OCR,
  input  logic [15:0]                                 I_RD_ADDR,
  input  logic                                        I_NN_MODEL_SELECT,
  input  logic [2047:0]                               I_RAW_IMAGE_BYTES,
  input  logic signed [(65536*8)-1:0]                 I_WEIGHT0_BYTES,
  input  logic signed [(2304*8)-1:0]                  I_WEIGHT1_BYTES,
  input  logic signed [(64*32)-1:0]                   I_BIAS0_WORDS,
  input  logic signed [(36*32)-1:0]                   I_BIAS1_WORDS,
  output logic [31:0]                                 O_RD_DATA,
  output logic                                        O_OCR_DONE,
  output logic                                        O_EMPTY_IMAGE,
  output logic [5:0]                                  O_RESULT_CLASS,
  output logic [7:0]                                  O_RESULT_CHAR,
  output logic [31:0]                                 O_RESULT_SCORE0,
  output logic [31:0]                                 O_RESULT_SCORE1,
  output logic [31:0]                                 O_RESULT_CONF_GAP
);

  import char_ocr_pkg::*;

  logic          l_preproc_empty_image;
  logic [1023:0] l_preproc_bin_bytes;
  logic [8191:0] l_feature_bytes;
  logic          l_infer_busy;
  logic          l_infer_done;
  logic          l_infer_error_unsupported_model;
  logic signed [(36*32)-1:0] l_score_vector;
  logic [31:0]   l_cycles_total;
  logic [31:0]   l_cycles_l0;
  logic [31:0]   l_cycles_l1;
  logic [31:0]   l_cycles_l2;
  logic [31:0]   l_ctrl_rd_data;
  logic [31:0]   l_status_rd_data;
  logic [31:0]   l_irq_enable_rd_data;
  logic [31:0]   l_irq_status_rd_data;
  logic [31:0]   l_model_ctrl_rd_data;
  logic [31:0]   l_model_status_rd_data;
  logic [31:0]   l_model_id_rd_data;
  logic [31:0]   l_model_crc_rd_data;
  logic [31:0]   l_preproc_ctrl_rd_data;
  logic [31:0]   l_preproc_status_rd_data;
  logic [31:0]   l_bbox_x_rd_data;
  logic [31:0]   l_bbox_y_rd_data;
  logic [31:0]   l_nn_ctrl_rd_data;
  logic [31:0]   l_nn_status_rd_data;
  logic [31:0]   l_dsp_config_rd_data;
  logic [31:0]   l_dsp_status_rd_data;
  logic [31:0]   l_oled_ctrl_rd_data;
  logic [31:0]   l_oled_status_rd_data;
  logic [31:0]   l_oled_toggle_ms_rd_data;
  logic [31:0]   l_version_rd_data;
  logic [31:0]   l_build_id_rd_data;
  logic          r_preproc_done;
  logic          r_nn_done;
  logic          r_ocr_done;
  logic          r_error_unsupported_model;
  logic          r_run_pending;

  char_ocr_preproc_hshrink u_char_ocr_preproc_hshrink (
    .I_RAW_IMAGE_BYTES   (I_RAW_IMAGE_BYTES),
    .O_EMPTY_IMAGE       (l_preproc_empty_image),
    .O_PREPROC_BIN_BYTES (l_preproc_bin_bytes),
    .O_FEATURE_BYTES     (l_feature_bytes)
  );

  char_ocr_infer_core u_char_ocr_infer_core (
    .I_CLK                     (I_CLK),
    .I_RST_N                   (I_RST_N),
    .I_START                   (I_RUN_FULL_OCR && !l_preproc_empty_image),
    .I_MODEL_SELECT            (I_NN_MODEL_SELECT),
    .I_FEATURE_BYTES           (l_feature_bytes),
    .I_WEIGHT0_BYTES           (I_WEIGHT0_BYTES),
    .I_WEIGHT1_BYTES           (I_WEIGHT1_BYTES),
    .I_BIAS0_WORDS             (I_BIAS0_WORDS),
    .I_BIAS1_WORDS             (I_BIAS1_WORDS),
    .O_BUSY                    (l_infer_busy),
    .O_DONE                    (l_infer_done),
    .O_ERROR_UNSUPPORTED_MODEL (l_infer_error_unsupported_model),
    .O_SCORE_VECTOR            (l_score_vector),
    .O_CYCLES_TOTAL            (l_cycles_total),
    .O_CYCLES_L0               (l_cycles_l0),
    .O_CYCLES_L1               (l_cycles_l1),
    .O_CYCLES_L2               (l_cycles_l2)
  );

  char_ocr_result_argmax u_char_ocr_result_argmax (
    .I_SCORE_VECTOR    (l_score_vector),
    .O_RESULT_CLASS    (O_RESULT_CLASS),
    .O_RESULT_CHAR     (O_RESULT_CHAR),
    .O_RESULT_SCORE0   (O_RESULT_SCORE0),
    .O_RESULT_SCORE1   (O_RESULT_SCORE1),
    .O_RESULT_CONF_GAP (O_RESULT_CONF_GAP)
  );

  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_preproc_done <= 1'b0;
      r_nn_done <= 1'b0;
      r_ocr_done <= 1'b0;
      r_error_unsupported_model <= 1'b0;
      r_run_pending <= 1'b0;
    end else begin
      if (I_RUN_FULL_OCR) begin
        r_preproc_done <= 1'b0;
        r_nn_done <= 1'b0;
        r_ocr_done <= 1'b0;
        r_error_unsupported_model <= 1'b0;
        r_run_pending <= 1'b1;
      end else begin
        if (r_run_pending && !l_preproc_empty_image) begin
          r_preproc_done <= 1'b1;
        end
        if (r_run_pending && l_preproc_empty_image) begin
          r_ocr_done <= 1'b1;
          r_run_pending <= 1'b0;
        end
        if (l_infer_done) begin
          r_nn_done <= 1'b1;
          r_ocr_done <= 1'b1;
          r_run_pending <= 1'b0;
        end
        if (l_infer_error_unsupported_model) begin
          r_error_unsupported_model <= 1'b1;
          r_ocr_done <= 1'b1;
          r_run_pending <= 1'b0;
        end
      end
    end
  end

  assign O_OCR_DONE = r_ocr_done;
  assign O_EMPTY_IMAGE = l_preproc_empty_image;

  always_comb begin
    l_ctrl_rd_data = 32'h0000_0000;
    l_ctrl_rd_data[2] = I_RUN_FULL_OCR;

    l_status_rd_data = 32'h0000_0000;
    l_status_rd_data[0] = 1'b1;
    l_status_rd_data[1] = 1'b0;
    l_status_rd_data[2] = r_preproc_done;
    l_status_rd_data[3] = l_infer_busy;
    l_status_rd_data[4] = r_nn_done;
    l_status_rd_data[5] = r_ocr_done;
    l_status_rd_data[6] = l_preproc_empty_image;
    l_status_rd_data[7] = r_error_unsupported_model;

    l_irq_enable_rd_data = 32'h0000_0000;
    l_irq_status_rd_data = 32'h0000_0000;
    l_model_ctrl_rd_data = {22'h0, I_NN_MODEL_SELECT, 9'h0};
    l_model_status_rd_data = {31'h0, !r_error_unsupported_model};
    l_model_id_rd_data = 32'h4F43_5231;
    l_model_crc_rd_data = 32'h0000_0000;
    l_preproc_ctrl_rd_data = 32'h0000_0001;
    l_preproc_status_rd_data = {25'h0, l_preproc_empty_image, !l_preproc_empty_image, 5'h0};
    l_bbox_x_rd_data = 32'h0000_0000;
    l_bbox_y_rd_data = 32'h0000_0000;
    l_nn_ctrl_rd_data = {31'h0, I_NN_MODEL_SELECT};
    l_nn_status_rd_data = {29'h0, r_error_unsupported_model, r_nn_done, l_infer_busy};
    l_dsp_config_rd_data = 32'h0000_031C;
    l_dsp_status_rd_data = {30'h0, l_infer_done, l_infer_busy};
    l_oled_ctrl_rd_data = 32'h0000_0000;
    l_oled_status_rd_data = 32'h0000_0000;
    l_oled_toggle_ms_rd_data = 32'd1000;
    l_version_rd_data = 32'h0001_0000;
    l_build_id_rd_data = 32'h2026_0502;
  end

  char_ocr_reg_map u_char_ocr_reg_map (
    .I_ADDR                    (I_RD_ADDR),
    .I_CTRL_RD_DATA            (l_ctrl_rd_data),
    .I_STATUS_RD_DATA          (l_status_rd_data),
    .I_IRQ_ENABLE_RD_DATA      (l_irq_enable_rd_data),
    .I_IRQ_STATUS_RD_DATA      (l_irq_status_rd_data),
    .I_MODEL_CTRL_RD_DATA      (l_model_ctrl_rd_data),
    .I_MODEL_STATUS_RD_DATA    (l_model_status_rd_data),
    .I_MODEL_ID_RD_DATA        (l_model_id_rd_data),
    .I_MODEL_CRC_RD_DATA       (l_model_crc_rd_data),
    .I_PREPROC_CTRL_RD_DATA    (l_preproc_ctrl_rd_data),
    .I_PREPROC_STATUS_RD_DATA  (l_preproc_status_rd_data),
    .I_BBOX_X_RD_DATA          (l_bbox_x_rd_data),
    .I_BBOX_Y_RD_DATA          (l_bbox_y_rd_data),
    .I_NN_CTRL_RD_DATA         (l_nn_ctrl_rd_data),
    .I_NN_STATUS_RD_DATA       (l_nn_status_rd_data),
    .I_NN_MODEL_SELECT         (I_NN_MODEL_SELECT),
    .I_NN_LAYER_COUNT          (8'd2),
    .I_DSP_CONFIG_RD_DATA      (l_dsp_config_rd_data),
    .I_DSP_STATUS_RD_DATA      (l_dsp_status_rd_data),
    .I_DSP_CYCLES_TOTAL_RD_DATA(l_cycles_total),
    .I_DSP_CYCLES_L0_RD_DATA   (l_cycles_l0),
    .I_DSP_CYCLES_L1_RD_DATA   (l_cycles_l1),
    .I_DSP_CYCLES_L2_RD_DATA   (l_cycles_l2),
    .I_RESULT_CLASS            (O_RESULT_CLASS),
    .I_RESULT_CHAR             (O_RESULT_CHAR),
    .I_RESULT_SCORE0_RD_DATA   (O_RESULT_SCORE0),
    .I_RESULT_SCORE1_RD_DATA   (O_RESULT_SCORE1),
    .I_RESULT_CONF_GAP_RD_DATA (O_RESULT_CONF_GAP),
    .I_OLED_CTRL_RD_DATA       (l_oled_ctrl_rd_data),
    .I_OLED_STATUS_RD_DATA     (l_oled_status_rd_data),
    .I_OLED_TOGGLE_MS_RD_DATA  (l_oled_toggle_ms_rd_data),
    .I_VERSION_RD_DATA         (l_version_rd_data),
    .I_BUILD_ID_RD_DATA        (l_build_id_rd_data),
    .O_RD_DATA                 (O_RD_DATA)
  );

endmodule