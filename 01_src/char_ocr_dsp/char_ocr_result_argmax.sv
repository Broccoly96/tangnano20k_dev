`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_result_argmax.sv
// Description  : OCR result reduction block (sequential, area-optimised).
//                - Scans the 36 signed int32 logits from the output layer
//                  over 37 clock cycles (1 init + 35 compare + 1 output latch).
//                - Returns the best class, best score, second-best score, and
//                  confidence gap = best - second_best.
//                - Uses a stable tie rule: the first highest score keeps the
//                  best-class slot, while later equal scores may become the
//                  second-best score. This keeps class selection deterministic
//                  and yields zero confidence gap on exact ties.
//                - I_START is a single-cycle pulse; O_DONE pulses one cycle
//                  after the last comparison is committed.
//                - Results are latched registers; they remain stable until the
//                  next I_START pulse.
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_result_argmax (
  input  logic         I_CLK,
  input  logic         I_RST_N,
  input  logic         I_START,           // single-cycle pulse to begin scan
  input  logic [1151:0] I_SCORE_VECTOR,   // 36 × 32-bit signed logits (stable during scan)
  output logic         O_DONE,            // single-cycle pulse when results are valid
  output logic [5:0]   O_RESULT_CLASS,
  output logic [7:0]   O_RESULT_CHAR,
  output logic [31:0]  O_RESULT_SCORE0,
  output logic [31:0]  O_RESULT_SCORE1,
  output logic [31:0]  O_RESULT_CONF_GAP
);

  import char_ocr_pkg::CHAR_OCR_CLASS_COUNT;

  // -----------------------------------------------------------------------
  // FSM
  // -----------------------------------------------------------------------
  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_SCAN = 2'd1,
    ST_DONE = 2'd2
  } argmax_state_t;

  argmax_state_t       r_state;
  logic [5:0]          r_scan_idx;         // current class index being evaluated
  logic signed [31:0]  r_best_score;
  logic signed [31:0]  r_second_best;
  logic [5:0]          r_best_class;

  // -----------------------------------------------------------------------
  // Combinational: extract current score word (36:1 mux, 6-bit address)
  // This is much cheaper than unrolling 35 compare+mux chains.
  // -----------------------------------------------------------------------
  logic signed [31:0] w_current_score;
  always_comb begin
    w_current_score = $signed(I_SCORE_VECTOR[(r_scan_idx * 32) +: 32]);
  end

  // -----------------------------------------------------------------------
  // Helper: map class index to ASCII character
  // -----------------------------------------------------------------------
  function automatic logic [7:0] class_to_ascii(input logic [5:0] class_idx);
    if (class_idx < 6'd10)
      class_to_ascii = 8'(8'd48 + class_idx);
    else
      class_to_ascii = 8'(8'd65 + (class_idx - 6'd10));
  endfunction

  // -----------------------------------------------------------------------
  // Sequential argmax FSM
  // -----------------------------------------------------------------------
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_state       <= ST_IDLE;
      r_scan_idx    <= '0;
      r_best_score  <= 32'sh8000_0000;
      r_second_best <= 32'sh8000_0000;
      r_best_class  <= '0;
      O_DONE        <= 1'b0;
      O_RESULT_CLASS    <= '0;
      O_RESULT_CHAR     <= 8'd48;
      O_RESULT_SCORE0   <= '0;
      O_RESULT_SCORE1   <= '0;
      O_RESULT_CONF_GAP <= '0;
    end else begin
      O_DONE <= 1'b0;

      case (r_state)
        ST_IDLE: begin
          if (I_START) begin
            // Initialise with class 0; next cycle scan from class 1
            r_best_score  <= $signed(I_SCORE_VECTOR[31:0]);
            r_second_best <= 32'sh8000_0000;
            r_best_class  <= 6'd0;
            r_scan_idx    <= 6'd1;
            r_state       <= ST_SCAN;
          end
        end

        ST_SCAN: begin
          // Compare w_current_score (= score[r_scan_idx]) with running bests
          if ($signed(w_current_score) > $signed(r_best_score)) begin
            r_second_best <= r_best_score;
            r_best_score  <= w_current_score;
            r_best_class  <= r_scan_idx;
          end else if ($signed(w_current_score) > $signed(r_second_best)) begin
            r_second_best <= w_current_score;
          end

          if (r_scan_idx == 6'(CHAR_OCR_CLASS_COUNT - 1)) begin
            r_state <= ST_DONE;
          end else begin
            r_scan_idx <= r_scan_idx + 6'd1;
          end
        end

        ST_DONE: begin
          // Latch outputs; r_best_score already reflects the winner
          // (the score[35] comparison was committed in the last ST_SCAN cycle)
          O_RESULT_CLASS    <= r_best_class;
          O_RESULT_CHAR     <= class_to_ascii(r_best_class);
          O_RESULT_SCORE0   <= r_best_score;
          O_RESULT_SCORE1   <= r_second_best;
          O_RESULT_CONF_GAP <= r_best_score - r_second_best;
          O_DONE            <= 1'b1;
          r_state           <= ST_IDLE;
        end

        default: r_state <= ST_IDLE;
      endcase
    end
  end

endmodule