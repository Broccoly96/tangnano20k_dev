`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_dsp24_array.sv
// Description  : 24-lane OCR MAC front-end built from 12 Gowin MULTADDALU18X18
//                compatible wrappers.
//                - Processes one activation sample against 24 signed int8
//                  weights per cycle.
//                - Emits a 24-lane vector of signed products so the outer OCR
//                  controller can own per-neuron accumulation and scheduling.
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_dsp24_array (
  input  logic                                I_CLK,
  input  logic                                I_CE,
  input  logic                                I_RESET,
  input  logic signed [7:0]                   I_ACTIVATION,
  input  logic signed [(24*8)-1:0]            I_WEIGHT_VECTOR,
  output logic signed [(24*32)-1:0]           O_PRODUCT_VECTOR
);

  genvar lane_pair_idx;
  generate
    for (lane_pair_idx = 0; lane_pair_idx < 12; lane_pair_idx++) begin : gen_dsp_pair
      logic signed [53:0] l_dout;
      logic signed [17:0] l_act0;
      logic signed [17:0] l_act1;
      logic signed [17:0] l_w0;
      logic signed [17:0] l_w1;

      always_comb begin
        l_act0 = {{10{I_ACTIVATION[7]}}, I_ACTIVATION};
        l_act1 = {{10{I_ACTIVATION[7]}}, I_ACTIVATION};
        l_w0 = {{10{I_WEIGHT_VECTOR[(lane_pair_idx*16)+7]}}, I_WEIGHT_VECTOR[(lane_pair_idx*16) +: 8]};
        l_w1 = {{10{I_WEIGHT_VECTOR[(lane_pair_idx*16)+15]}}, I_WEIGHT_VECTOR[(lane_pair_idx*16)+8 +: 8]};
      end

      char_ocr_multaddalu18x18_wrapper u_dsp (
        .I_CLK     (I_CLK),
        .I_CE      (I_CE),
        .I_RESET   (I_RESET),
        .I_ACCLOAD (1'b1),
        .I_A0      (l_act0),
        .I_B0      (l_w0),
        .I_A1      (l_act1),
        .I_B1      (l_w1),
        .I_C       ('0),
        .O_DOUT    (l_dout)
      );

      always_comb begin
        O_PRODUCT_VECTOR[(lane_pair_idx*64) +: 32] = l_act0 * l_w0;
        O_PRODUCT_VECTOR[(lane_pair_idx*64)+32 +: 32] = l_act1 * l_w1;
      end
    end
  endgenerate

endmodule