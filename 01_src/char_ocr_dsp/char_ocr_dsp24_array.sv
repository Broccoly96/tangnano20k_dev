`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_dsp24_array.sv  (module: char_ocr_dsp12_accum)
// Description  : 12-lane OCR MAC accumulator built from 12 Gowin
//                MULTADDALU18X18 wrappers using internal DSP accumulation.
//
// Architecture:
//   Each of the 12 DSP instances accumulates the dot product for ONE neuron.
//   Two consecutive feature/weight pairs are fed per cycle:
//     DSP k cycle i: A0=act[2i]*B0=w[k][2i]  +  A1=act[2i+1]*B1=w[k][2i+1]
//   After FEAT_COUNT/2 = 512 cycles, each DSP holds:
//     ACCUM[k] = sum_j( act[j] * w[k][j] ) = dot(act, w[k])
//
//   Cycle sequence per neuron group:
//     1. RESET     (1 cycle)  : I_RESET=1 clears all accumulators and pipeline.
//     2. RUN       (512 or 32): I_RESET=0, valid I_ACT0/I_ACT1/I_WEIGHT_A/B fed.
//     3. FLUSH     (3 cycles) : zero inputs, pipeline drains into accumulator.
//     4. READ      (1 cycle)  : controller reads O_ACCUM_VECTOR[k*54+:54].
//
// Throughput: 24 MACs/cycle (12 DSPs x 2 multiplications each).
// Latency (pipeline): 3 cycles (see char_ocr_multaddalu18x18_wrapper).
//
// Ports:
//   I_ACT0[7:0]               : feature[2i]          (broadcast to all 12 DSPs)
//   I_ACT1[7:0]               : feature[2i+1]        (broadcast to all 12 DSPs)
//   I_WEIGHT_A[(12*8)-1:0]    : w[k][2i]   for k=0..11 ({w[11][2i], ..., w[0][2i]})
//   I_WEIGHT_B[(12*8)-1:0]    : w[k][2i+1] for k=0..11
//   O_ACCUM_VECTOR[(12*54)-1:0]: accumulated dot products for 12 neurons.
//                               O_ACCUM_VECTOR[k*54 +: 54] = ACCUM[k]
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_dsp12_accum (
  input  logic                         I_CLK,
  input  logic                         I_CE,
  input  logic                         I_RESET,           // synchronous, clears all 12 DSPs
  input  logic signed [7:0]            I_ACT0,            // activation feature[2i]
  input  logic signed [7:0]            I_ACT1,            // activation feature[2i+1]
  input  logic signed [(12*8)-1:0]     I_WEIGHT_A,        // w[k][2i]   for k=0..11
  input  logic signed [(12*8)-1:0]     I_WEIGHT_B,        // w[k][2i+1] for k=0..11
  output logic signed [(12*54)-1:0]    O_ACCUM_VECTOR     // 12 x 54-bit accumulated results
);

  genvar k;
  generate
    for (k = 0; k < 12; k++) begin : gen_dsp_lane
      // Each wrapper accumulates: ACCUM[k] += act0*w_a[k] + act1*w_b[k]
      // I_A0 = I_ACT0 (broadcast), I_B0 = w[k][2i]   (unique per lane)
      // I_A1 = I_ACT1 (broadcast), I_B1 = w[k][2i+1] (unique per lane)
      char_ocr_multaddalu18x18_wrapper u_dsp (
        .I_CLK   (I_CLK),
        .I_CE    (I_CE),
        .I_RESET (I_RESET),
        .I_A0    (I_ACT0),
        .I_B0    (I_WEIGHT_A[(k*8) +: 8]),
        .I_A1    (I_ACT1),
        .I_B1    (I_WEIGHT_B[(k*8) +: 8]),
        .O_DOUT  (O_ACCUM_VECTOR[(k*54) +: 54])
      );
    end
  endgenerate

endmodule