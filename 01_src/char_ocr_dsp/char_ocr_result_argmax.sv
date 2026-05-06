`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_result_argmax.sv
// Description  : OCR result reduction block.
//                - Scans the 36 signed int32 logits from the output layer.
//                - Returns the best class, best score, second-best score, and
//                  confidence gap = best - second_best.
//                - Uses a stable tie rule: the first highest score keeps the
//                  best-class slot, while later equal scores may become the
//                  second-best score. This keeps class selection deterministic
//                  and yields zero confidence gap on exact ties.
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_result_argmax (
  input  logic [1151:0] I_SCORE_VECTOR,
  output logic [5:0]    O_RESULT_CLASS,
  output logic [7:0]    O_RESULT_CHAR,
  output logic [31:0]   O_RESULT_SCORE0,
  output logic [31:0]   O_RESULT_SCORE1,
  output logic [31:0]   O_RESULT_CONF_GAP
);

  function automatic logic [7:0] class_to_ascii(
    input logic [5:0] class_idx
  );
    begin
      if (class_idx < 6'd10) begin
        class_to_ascii = 8'(8'd48 + class_idx);
      end else begin
        class_to_ascii = 8'(8'd65 + (class_idx - 6'd10));
      end
    end
  endfunction

  // Reduces the 36 score words in one combinational pass.
  // The flattened vector stores score[class_idx] at class_idx*32 +: 32.
  always_comb begin
    logic signed [31:0] best_score;
    logic signed [31:0] second_best_score;
    logic signed [31:0] current_score;
    logic [5:0]         best_class;

    best_score = $signed(I_SCORE_VECTOR[31:0]);
    second_best_score = 32'sh8000_0000;
    best_class = 6'd0;

    for (int unsigned class_idx = 1; class_idx < 36; class_idx++) begin
      current_score = $signed(I_SCORE_VECTOR[(class_idx * 32) +: 32]);

      if (current_score > best_score) begin
        second_best_score = best_score;
        best_score = current_score;
        best_class = class_idx[5:0];
      end else if (current_score > second_best_score) begin
        second_best_score = current_score;
      end
    end

    O_RESULT_CLASS = best_class;
    O_RESULT_CHAR = class_to_ascii(best_class);
    O_RESULT_SCORE0 = best_score;
    O_RESULT_SCORE1 = second_best_score;
    O_RESULT_CONF_GAP = best_score - second_best_score;
  end

endmodule