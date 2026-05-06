`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_infer_core.sv
// Description  : Default-model OCR inference controller.
//                - Executes the default 1024 -> 64 -> 36 MLP using the 24-lane
//                  DSP front-end.
//                - Keeps accumulation and activation scheduling explicit so the
//                  cycle counters match the intended hardware flow.
//                - Phase 1 supports model-select 0 only.
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_infer_core (
  input  logic                                        I_CLK,
  input  logic                                        I_RST_N,
  input  logic                                        I_START,
  input  logic                                        I_MODEL_SELECT,
  input  logic signed [(1024*8)-1:0]                  I_FEATURE_BYTES,
  input  logic signed [(65536*8)-1:0]                 I_WEIGHT0_BYTES,
  input  logic signed [(2304*8)-1:0]                  I_WEIGHT1_BYTES,
  input  logic signed [(64*32)-1:0]                   I_BIAS0_WORDS,
  input  logic signed [(36*32)-1:0]                   I_BIAS1_WORDS,
  output logic                                        O_BUSY,
  output logic                                        O_DONE,
  output logic                                        O_ERROR_UNSUPPORTED_MODEL,
  output logic signed [(36*32)-1:0]                   O_SCORE_VECTOR,
  output logic [31:0]                                 O_CYCLES_TOTAL,
  output logic [31:0]                                 O_CYCLES_L0,
  output logic [31:0]                                 O_CYCLES_L1,
  output logic [31:0]                                 O_CYCLES_L2
);

  import char_ocr_pkg::*;

  localparam int unsigned L0_GROUPS = (CHAR_OCR_HIDDEN0_COUNT + CHAR_OCR_LANE_COUNT - 1) / CHAR_OCR_LANE_COUNT;
  localparam int unsigned L1_GROUPS = (CHAR_OCR_CLASS_COUNT + CHAR_OCR_LANE_COUNT - 1) / CHAR_OCR_LANE_COUNT;

  char_ocr_state_t st_state;
  logic [1:0] r_group_idx;
  logic [9:0] r_input_idx;
  logic signed [31:0] r_accum [0:CHAR_OCR_LANE_COUNT-1];
  logic signed [7:0]  r_hidden_act [0:CHAR_OCR_HIDDEN0_COUNT-1];
  logic signed [31:0] r_score_word [0:CHAR_OCR_CLASS_COUNT-1];

  logic signed [7:0]  l_curr_activation;
  logic signed [(24*8)-1:0] l_weight_vector;
  logic signed [(24*32)-1:0] l_product_vector;
  logic signed [31:0] l_next_accum [0:CHAR_OCR_LANE_COUNT-1];

  function automatic logic signed [7:0] get_feature_byte(
    input logic signed [(1024*8)-1:0] feature_bytes,
    input int unsigned feature_idx
  );
    begin
      get_feature_byte = feature_bytes[(feature_idx * 8) +: 8];
    end
  endfunction

  function automatic logic signed [7:0] get_weight0_byte(
    input logic signed [(65536*8)-1:0] weight_bytes,
    input int unsigned hidden_idx,
    input int unsigned feature_idx
  );
    int unsigned flat_idx;
    begin
      flat_idx = (hidden_idx * CHAR_OCR_FEATURE_COUNT) + feature_idx;
      get_weight0_byte = weight_bytes[(flat_idx * 8) +: 8];
    end
  endfunction

  function automatic logic signed [7:0] get_weight1_byte(
    input logic signed [(2304*8)-1:0] weight_bytes,
    input int unsigned class_idx,
    input int unsigned hidden_idx
  );
    int unsigned flat_idx;
    begin
      flat_idx = (class_idx * CHAR_OCR_HIDDEN0_COUNT) + hidden_idx;
      get_weight1_byte = weight_bytes[(flat_idx * 8) +: 8];
    end
  endfunction

  function automatic logic signed [31:0] get_bias0_word(
    input logic signed [(64*32)-1:0] bias_words,
    input int unsigned hidden_idx
  );
    begin
      get_bias0_word = bias_words[(hidden_idx * 32) +: 32];
    end
  endfunction

  function automatic logic signed [31:0] get_bias1_word(
    input logic signed [(36*32)-1:0] bias_words,
    input int unsigned class_idx
  );
    begin
      get_bias1_word = bias_words[(class_idx * 32) +: 32];
    end
  endfunction

  always_comb begin
    l_curr_activation = '0;
    l_weight_vector = '0;

    if (st_state == ST_RUN_LAYER0) begin
      l_curr_activation = get_feature_byte(I_FEATURE_BYTES, r_input_idx);
      for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
        if (((r_group_idx * CHAR_OCR_LANE_COUNT) + lane_idx) < CHAR_OCR_HIDDEN0_COUNT) begin
          l_weight_vector[(lane_idx * 8) +: 8] = get_weight0_byte(
            I_WEIGHT0_BYTES,
            (r_group_idx * CHAR_OCR_LANE_COUNT) + lane_idx,
            r_input_idx
          );
        end
      end
    end else if (st_state == ST_RUN_LAYER1) begin
      l_curr_activation = r_hidden_act[r_input_idx];
      for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
        if (((r_group_idx * CHAR_OCR_LANE_COUNT) + lane_idx) < CHAR_OCR_CLASS_COUNT) begin
          l_weight_vector[(lane_idx * 8) +: 8] = get_weight1_byte(
            I_WEIGHT1_BYTES,
            (r_group_idx * CHAR_OCR_LANE_COUNT) + lane_idx,
            r_input_idx
          );
        end
      end
    end
  end

  char_ocr_dsp24_array u_char_ocr_dsp24_array (
    .I_CLK           (I_CLK),
    .I_CE            (O_BUSY),
    .I_RESET         (!I_RST_N),
    .I_ACTIVATION    (l_curr_activation),
    .I_WEIGHT_VECTOR (l_weight_vector),
    .O_PRODUCT_VECTOR(l_product_vector)
  );

  always_comb begin
    for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
      l_next_accum[lane_idx] = r_accum[lane_idx] + l_product_vector[(lane_idx * 32) +: 32];
    end
  end

  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state <= ST_IDLE;
      r_group_idx <= '0;
      r_input_idx <= '0;
      O_BUSY <= 1'b0;
      O_DONE <= 1'b0;
      O_ERROR_UNSUPPORTED_MODEL <= 1'b0;
      O_CYCLES_TOTAL <= 32'h0000_0000;
      O_CYCLES_L0 <= 32'h0000_0000;
      O_CYCLES_L1 <= 32'h0000_0000;
      O_CYCLES_L2 <= 32'h0000_0000;
      O_SCORE_VECTOR <= '0;
      for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
        r_accum[lane_idx] <= 32'sd0;
      end
      for (int unsigned hidden_idx = 0; hidden_idx < CHAR_OCR_HIDDEN0_COUNT; hidden_idx++) begin
        r_hidden_act[hidden_idx] <= 8'sd0;
      end
      for (int unsigned class_idx = 0; class_idx < CHAR_OCR_CLASS_COUNT; class_idx++) begin
        r_score_word[class_idx] <= 32'sd0;
      end
    end else begin
      O_DONE <= 1'b0;

      case (st_state)
        ST_IDLE: begin
          O_BUSY <= 1'b0;
          O_ERROR_UNSUPPORTED_MODEL <= 1'b0;
          if (I_START) begin
            O_CYCLES_TOTAL <= 32'h0000_0000;
            O_CYCLES_L0 <= 32'h0000_0000;
            O_CYCLES_L1 <= 32'h0000_0000;
            O_CYCLES_L2 <= 32'h0000_0000;
            O_SCORE_VECTOR <= '0;
            r_group_idx <= '0;
            r_input_idx <= '0;
            if (I_MODEL_SELECT != 1'b0) begin
              O_ERROR_UNSUPPORTED_MODEL <= 1'b1;
              O_DONE <= 1'b1;
            end else begin
              O_BUSY <= 1'b1;
              for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
                if (lane_idx < CHAR_OCR_HIDDEN0_COUNT) begin
                  r_accum[lane_idx] <= get_bias0_word(I_BIAS0_WORDS, lane_idx);
                end else begin
                  r_accum[lane_idx] <= 32'sd0;
                end
              end
              st_state <= ST_RUN_LAYER0;
            end
          end
        end

        ST_RUN_LAYER0: begin
          O_CYCLES_TOTAL <= O_CYCLES_TOTAL + 1'b1;
          O_CYCLES_L0 <= O_CYCLES_L0 + 1'b1;
          for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
            r_accum[lane_idx] <= l_next_accum[lane_idx];
          end

          if (r_input_idx == (CHAR_OCR_FEATURE_COUNT - 1)) begin
            for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
              if (((r_group_idx * CHAR_OCR_LANE_COUNT) + lane_idx) < CHAR_OCR_HIDDEN0_COUNT) begin
                if (l_next_accum[lane_idx] > 0) begin
                  r_hidden_act[(r_group_idx * CHAR_OCR_LANE_COUNT) + lane_idx] <=
                    char_ocr_clamp_int8(l_next_accum[lane_idx]);
                end else begin
                  r_hidden_act[(r_group_idx * CHAR_OCR_LANE_COUNT) + lane_idx] <= 8'sd0;
                end
              end
            end

            if (r_group_idx == (L0_GROUPS - 1)) begin
              r_group_idx <= '0;
              r_input_idx <= '0;
              for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
                if (lane_idx < CHAR_OCR_CLASS_COUNT) begin
                  r_accum[lane_idx] <= get_bias1_word(I_BIAS1_WORDS, lane_idx);
                end else begin
                  r_accum[lane_idx] <= 32'sd0;
                end
              end
              st_state <= ST_RUN_LAYER1;
            end else begin
              r_group_idx <= r_group_idx + 1'b1;
              r_input_idx <= '0;
              for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
                if ((((r_group_idx + 1'b1) * CHAR_OCR_LANE_COUNT) + lane_idx) < CHAR_OCR_HIDDEN0_COUNT) begin
                  r_accum[lane_idx] <= get_bias0_word(
                    I_BIAS0_WORDS,
                    ((r_group_idx + 1'b1) * CHAR_OCR_LANE_COUNT) + lane_idx
                  );
                end else begin
                  r_accum[lane_idx] <= 32'sd0;
                end
              end
            end
          end else begin
            r_input_idx <= r_input_idx + 1'b1;
          end
        end

        ST_RUN_LAYER1: begin
          O_CYCLES_TOTAL <= O_CYCLES_TOTAL + 1'b1;
          O_CYCLES_L1 <= O_CYCLES_L1 + 1'b1;
          for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
            r_accum[lane_idx] <= l_next_accum[lane_idx];
          end

          if (r_input_idx == (CHAR_OCR_HIDDEN0_COUNT - 1)) begin
            for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
              if (((r_group_idx * CHAR_OCR_LANE_COUNT) + lane_idx) < CHAR_OCR_CLASS_COUNT) begin
                r_score_word[(r_group_idx * CHAR_OCR_LANE_COUNT) + lane_idx] <= l_next_accum[lane_idx];
                O_SCORE_VECTOR[(((r_group_idx * CHAR_OCR_LANE_COUNT) + lane_idx) * 32) +: 32] <= l_next_accum[lane_idx];
              end
            end

            if (r_group_idx == (L1_GROUPS - 1)) begin
              O_BUSY <= 1'b0;
              O_DONE <= 1'b1;
              st_state <= ST_DONE;
            end else begin
              r_group_idx <= r_group_idx + 1'b1;
              r_input_idx <= '0;
              for (int unsigned lane_idx = 0; lane_idx < CHAR_OCR_LANE_COUNT; lane_idx++) begin
                if ((((r_group_idx + 1'b1) * CHAR_OCR_LANE_COUNT) + lane_idx) < CHAR_OCR_CLASS_COUNT) begin
                  r_accum[lane_idx] <= get_bias1_word(
                    I_BIAS1_WORDS,
                    ((r_group_idx + 1'b1) * CHAR_OCR_LANE_COUNT) + lane_idx
                  );
                end else begin
                  r_accum[lane_idx] <= 32'sd0;
                end
              end
            end
          end else begin
            r_input_idx <= r_input_idx + 1'b1;
          end
        end

        ST_DONE: begin
          st_state <= ST_IDLE;
        end

        default: begin
          st_state <= ST_IDLE;
        end
      endcase
    end
  end

endmodule