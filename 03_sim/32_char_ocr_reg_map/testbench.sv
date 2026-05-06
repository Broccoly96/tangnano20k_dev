`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;

  logic [15:0] tb_addr;
  logic [31:0] tb_ctrl_rd_data;
  logic [31:0] tb_status_rd_data;
  logic [31:0] tb_irq_enable_rd_data;
  logic [31:0] tb_irq_status_rd_data;
  logic [31:0] tb_model_ctrl_rd_data;
  logic [31:0] tb_model_status_rd_data;
  logic [31:0] tb_model_id_rd_data;
  logic [31:0] tb_model_crc_rd_data;
  logic [31:0] tb_preproc_ctrl_rd_data;
  logic [31:0] tb_preproc_status_rd_data;
  logic [31:0] tb_bbox_x_rd_data;
  logic [31:0] tb_bbox_y_rd_data;
  logic [31:0] tb_nn_ctrl_rd_data;
  logic [31:0] tb_nn_status_rd_data;
  logic        tb_nn_model_select;
  logic [7:0]  tb_nn_layer_count;
  logic [31:0] tb_dsp_config_rd_data;
  logic [31:0] tb_dsp_status_rd_data;
  logic [31:0] tb_dsp_cycles_total_rd_data;
  logic [31:0] tb_dsp_cycles_l0_rd_data;
  logic [31:0] tb_dsp_cycles_l1_rd_data;
  logic [31:0] tb_dsp_cycles_l2_rd_data;
  logic [5:0]  tb_result_class;
  logic [7:0]  tb_result_char;
  logic [31:0] tb_result_score0_rd_data;
  logic [31:0] tb_result_score1_rd_data;
  logic [31:0] tb_result_conf_gap_rd_data;
  logic [31:0] tb_oled_ctrl_rd_data;
  logic [31:0] tb_oled_status_rd_data;
  logic [31:0] tb_oled_toggle_ms_rd_data;
  logic [31:0] tb_version_rd_data;
  logic [31:0] tb_build_id_rd_data;
  logic [31:0] tb_rd_data;

  initial begin
    configure_logging(LOG_DEBUG);
  end

  char_ocr_reg_map u_dut (
    .I_ADDR                  (tb_addr),
    .I_CTRL_RD_DATA          (tb_ctrl_rd_data),
    .I_STATUS_RD_DATA        (tb_status_rd_data),
    .I_IRQ_ENABLE_RD_DATA    (tb_irq_enable_rd_data),
    .I_IRQ_STATUS_RD_DATA    (tb_irq_status_rd_data),
    .I_MODEL_CTRL_RD_DATA    (tb_model_ctrl_rd_data),
    .I_MODEL_STATUS_RD_DATA  (tb_model_status_rd_data),
    .I_MODEL_ID_RD_DATA      (tb_model_id_rd_data),
    .I_MODEL_CRC_RD_DATA     (tb_model_crc_rd_data),
    .I_PREPROC_CTRL_RD_DATA  (tb_preproc_ctrl_rd_data),
    .I_PREPROC_STATUS_RD_DATA(tb_preproc_status_rd_data),
    .I_BBOX_X_RD_DATA        (tb_bbox_x_rd_data),
    .I_BBOX_Y_RD_DATA        (tb_bbox_y_rd_data),
    .I_NN_CTRL_RD_DATA       (tb_nn_ctrl_rd_data),
    .I_NN_STATUS_RD_DATA     (tb_nn_status_rd_data),
    .I_NN_MODEL_SELECT       (tb_nn_model_select),
    .I_NN_LAYER_COUNT        (tb_nn_layer_count),
    .I_DSP_CONFIG_RD_DATA    (tb_dsp_config_rd_data),
    .I_DSP_STATUS_RD_DATA    (tb_dsp_status_rd_data),
    .I_DSP_CYCLES_TOTAL_RD_DATA(tb_dsp_cycles_total_rd_data),
    .I_DSP_CYCLES_L0_RD_DATA (tb_dsp_cycles_l0_rd_data),
    .I_DSP_CYCLES_L1_RD_DATA (tb_dsp_cycles_l1_rd_data),
    .I_DSP_CYCLES_L2_RD_DATA (tb_dsp_cycles_l2_rd_data),
    .I_RESULT_CLASS          (tb_result_class),
    .I_RESULT_CHAR           (tb_result_char),
    .I_RESULT_SCORE0_RD_DATA (tb_result_score0_rd_data),
    .I_RESULT_SCORE1_RD_DATA (tb_result_score1_rd_data),
    .I_RESULT_CONF_GAP_RD_DATA(tb_result_conf_gap_rd_data),
    .I_OLED_CTRL_RD_DATA     (tb_oled_ctrl_rd_data),
    .I_OLED_STATUS_RD_DATA   (tb_oled_status_rd_data),
    .I_OLED_TOGGLE_MS_RD_DATA(tb_oled_toggle_ms_rd_data),
    .I_VERSION_RD_DATA       (tb_version_rd_data),
    .I_BUILD_ID_RD_DATA      (tb_build_id_rd_data),
    .O_RD_DATA               (tb_rd_data)
  );

  task automatic expect_word(
    input logic [15:0] addr,
    input logic [31:0] exp_data,
    input string       label
  );
    begin
      tb_addr = addr;
      #1ns;
      if (tb_rd_data !== exp_data) begin
        log_fatal(
          1,
          "OCR REG MAP TB",
          $sformatf(
            "word mismatch %s addr=0x%04h act=0x%08h exp=0x%08h",
            label,
            addr,
            tb_rd_data,
            exp_data
          )
        );
      end
      log_info("OCR REG MAP TB", {"word ok: ", label});
    end
  endtask

`include "testcase_smoke.svh"

endmodule