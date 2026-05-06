`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;

  logic [1151:0] tb_score_vector;
  logic [5:0]    tb_result_class;
  logic [7:0]    tb_result_char;
  logic [31:0]   tb_result_score0;
  logic [31:0]   tb_result_score1;
  logic [31:0]   tb_result_conf_gap;

  initial begin
    configure_logging(LOG_DEBUG);
  end

  char_ocr_result_argmax u_dut (
    .I_SCORE_VECTOR    (tb_score_vector),
    .O_RESULT_CLASS    (tb_result_class),
    .O_RESULT_CHAR     (tb_result_char),
    .O_RESULT_SCORE0   (tb_result_score0),
    .O_RESULT_SCORE1   (tb_result_score1),
    .O_RESULT_CONF_GAP (tb_result_conf_gap)
  );

  task automatic clear_scores();
    begin
      tb_score_vector = '0;
    end
  endtask

  task automatic set_score(
    input int unsigned       class_idx,
    input logic signed [31:0] score_value
  );
    begin
      tb_score_vector[(class_idx * 32) +: 32] = score_value;
    end
  endtask

  task automatic expect_result(
    input logic [5:0]   exp_class,
    input logic [7:0]   exp_char,
    input logic [31:0]  exp_score0,
    input logic [31:0]  exp_score1,
    input logic [31:0]  exp_conf_gap,
    input string        label
  );
    begin
      #1ns;
      if (tb_result_class !== exp_class) begin
        log_fatal(1, "OCR ARGMAX TB", $sformatf("class mismatch %s act=%0d exp=%0d", label, tb_result_class, exp_class));
      end
      if (tb_result_char !== exp_char) begin
        log_fatal(1, "OCR ARGMAX TB", $sformatf("char mismatch %s act=0x%02h exp=0x%02h", label, tb_result_char, exp_char));
      end
      if (tb_result_score0 !== exp_score0) begin
        log_fatal(1, "OCR ARGMAX TB", $sformatf("score0 mismatch %s act=0x%08h exp=0x%08h", label, tb_result_score0, exp_score0));
      end
      if (tb_result_score1 !== exp_score1) begin
        log_fatal(1, "OCR ARGMAX TB", $sformatf("score1 mismatch %s act=0x%08h exp=0x%08h", label, tb_result_score1, exp_score1));
      end
      if (tb_result_conf_gap !== exp_conf_gap) begin
        log_fatal(1, "OCR ARGMAX TB", $sformatf("conf gap mismatch %s act=0x%08h exp=0x%08h", label, tb_result_conf_gap, exp_conf_gap));
      end
      log_info("OCR ARGMAX TB", {"result ok: ", label});
    end
  endtask

`include "testcase_smoke.svh"

endmodule