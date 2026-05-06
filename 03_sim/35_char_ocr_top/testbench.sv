`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;

  localparam time CLK_HALF_PERIOD = 20ns;

  logic tb_clk;
  logic tb_rst_n;
  logic tb_run_full_ocr;
  logic [15:0] tb_rd_addr;
  logic tb_nn_model_select;
  logic [2047:0] tb_raw_image_bytes;
  logic signed [(65536*8)-1:0] tb_weight0_bytes;
  logic signed [(2304*8)-1:0] tb_weight1_bytes;
  logic signed [(64*32)-1:0] tb_bias0_words;
  logic signed [(36*32)-1:0] tb_bias1_words;
  logic [31:0] tb_rd_data;
  logic tb_ocr_done;
  logic tb_empty_image;
  logic [5:0] tb_result_class;
  logic [7:0] tb_result_char;
  logic [31:0] tb_result_score0;
  logic [31:0] tb_result_score1;
  logic [31:0] tb_result_conf_gap;

  initial begin
    configure_logging(LOG_INFO);
    tb_clk = 1'b0;
    forever #(CLK_HALF_PERIOD) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n = 1'b0;
    tb_run_full_ocr = 1'b0;
    tb_rd_addr = 16'h0000;
    tb_nn_model_select = 1'b0;
    tb_raw_image_bytes = '0;
    tb_weight0_bytes = '0;
    tb_weight1_bytes = '0;
    tb_bias0_words = '0;
    tb_bias1_words = '0;
    repeat (5) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  char_ocr_top u_dut (
    .I_CLK            (tb_clk),
    .I_RST_N          (tb_rst_n),
    .I_RUN_FULL_OCR   (tb_run_full_ocr),
    .I_RD_ADDR        (tb_rd_addr),
    .I_NN_MODEL_SELECT(tb_nn_model_select),
    .I_RAW_IMAGE_BYTES(tb_raw_image_bytes),
    .I_WEIGHT0_BYTES  (tb_weight0_bytes),
    .I_WEIGHT1_BYTES  (tb_weight1_bytes),
    .I_BIAS0_WORDS    (tb_bias0_words),
    .I_BIAS1_WORDS    (tb_bias1_words),
    .O_RD_DATA        (tb_rd_data),
    .O_OCR_DONE       (tb_ocr_done),
    .O_EMPTY_IMAGE    (tb_empty_image),
    .O_RESULT_CLASS   (tb_result_class),
    .O_RESULT_CHAR    (tb_result_char),
    .O_RESULT_SCORE0  (tb_result_score0),
    .O_RESULT_SCORE1  (tb_result_score1),
    .O_RESULT_CONF_GAP(tb_result_conf_gap)
  );

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

  task automatic set_weight0(
    input int unsigned hidden_idx,
    input int unsigned feature_idx,
    input logic signed [7:0] weight_value
  );
    int unsigned flat_idx;
    begin
      flat_idx = (hidden_idx * 1024) + feature_idx;
      tb_weight0_bytes[(flat_idx * 8) +: 8] = weight_value;
    end
  endtask

  task automatic set_weight1(
    input int unsigned class_idx,
    input int unsigned hidden_idx,
    input logic signed [7:0] weight_value
  );
    int unsigned flat_idx;
    begin
      flat_idx = (class_idx * 64) + hidden_idx;
      tb_weight1_bytes[(flat_idx * 8) +: 8] = weight_value;
    end
  endtask

  task automatic set_bias0(
    input int unsigned hidden_idx,
    input logic signed [31:0] bias_value
  );
    begin
      tb_bias0_words[(hidden_idx * 32) +: 32] = bias_value;
    end
  endtask

  task automatic set_bias1(
    input int unsigned class_idx,
    input logic signed [31:0] bias_value
  );
    begin
      tb_bias1_words[(class_idx * 32) +: 32] = bias_value;
    end
  endtask

  task automatic expect_word(
    input logic [15:0] addr,
    input logic [31:0] exp_data,
    input string       label
  );
    begin
      tb_rd_addr = addr;
      #1ns;
      if (tb_rd_data !== exp_data) begin
        log_fatal(
          1,
          "OCR TOP TB",
          $sformatf(
            "word mismatch %s addr=0x%04h act=0x%08h exp=0x%08h",
            label,
            addr,
            tb_rd_data,
            exp_data
          )
        );
      end
      log_info("OCR TOP TB", {"word ok: ", label});
    end
  endtask

`include "testcase_smoke.svh"

endmodule