`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_infer_core.sv
// Description  : Default-model OCR inference controller (1024->24->36).
//
// Layer geometry (HIDDEN0_COUNT = 24):
//   FC0 (1024 features, 24 neurons):
//     - 2 groups of 12 DSP lanes
//     - Per group: 512 data cycles + 3 flush cycles + 1 read cycle = 516
//     - O_CYCLES_L0 counts RUN+FLUSH only: (512+3)*2 = 1030
//   FC1 (24 hidden, 36 classes):
//     - 3 groups of 12 DSP lanes (HIDDEN_PAIRS = 12 pairs per group)
//     - Per group: 12 data cycles + 3 flush cycles + 1 read cycle = 16
//     - O_CYCLES_L1 counts RUN+FLUSH only: (12+3)*3 = 45
//   O_CYCLES_TOTAL = 1030 + 45 = 1075
//
// L0 Weight Storage (BSRAM):
//   12 per-lane BSRAM18 instances, each 1024 entries x 16-bit.
//   Address: {group_idx[0], pair_idx[8:0]} = 10-bit.
//   Data:    {wb[7:0], wa[7:0]}.
//   Pre-fetch: address is issued 1 cycle before use (combinatorial addr,
//   registered BSRAM read). ST_L0_RESET issues addr for pair 0;
//   each ST_L0_RUN cycle issues addr for pair_idx+1.
//
// L1 Weight Storage (LUT-ROM):
//   12 per-lane constant arrays, 36 entries x 16-bit.
//   Combinatorial read; no pre-fetch needed (addr = {group, pair}).
//
// Biases: zero-initialized constant arrays (bring-up default).
//
// State machine flow (unchanged):
//   ST_IDLE -> [L0: L0_RESET->L0_RUN->L0_FLUSH->L0_READ (x L0_GROUPS)] ->
//             [L1: L1_RESET->L1_RUN->L1_FLUSH->L1_READ (x L1_GROUPS)] ->
//   ST_DONE -> ST_IDLE
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_infer_core (
  input  logic                                        I_CLK,
  input  logic                                        I_RST_N,
  input  logic                                        I_START,
  input  logic                                        I_MODEL_SELECT,
  input  logic [1023:0]                               I_FEATURE_BITS,   // 1 bit per pixel (0 or 1 after preproc)
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

  // -----------------------------------------------------------------------
  // Helper: indexed 1-bit feature access (features are always 0 or 1)
  // -----------------------------------------------------------------------
  function automatic logic signed [7:0] get_feature(
    input logic [1023:0] fv, input int unsigned idx
  );
    get_feature = {7'b0, fv[idx]}; // expand 1-bit pixel to signed int8 (0 or 1)
  endfunction

  // -----------------------------------------------------------------------
  // L0 Weight BSRAM (12 per-lane instances, 1024 x 16-bit each)
  //
  // Memory layout for lane k:
  //   addr[9:0] = {group_idx[0], pair_idx[8:0]}
  //   addr 0..511   : weights for neuron k     (group 0), pairs 0..511
  //   addr 512..1023: weights for neuron k+12  (group 1), pairs 0..511
  //   entry data    : {wb[7:0]=W0[neuron][2p+1], wa[7:0]=W0[neuron][2p]}
  //
  // All entries initialized to zero for bring-up.
  // Replace initialization with $readmemh("weight0_lane_k.mem", ...) when
  // trained weights are available.
  // -----------------------------------------------------------------------
  logic [9:0]  w_w0_addr_next; // Combinatorial pre-fetch address for BSRAM
  logic [15:0] r_w0_data [0:CHAR_OCR_LANE_COUNT-1]; // Registered BSRAM output

  genvar gk;
  generate
    for (gk = 0; gk < CHAR_OCR_LANE_COUNT; gk++) begin : gen_w0_bsram
      (* ram_style = "block" *)
      logic [15:0] w0_rom [0:1023];
      // Zero weights for bring-up. Replace with:
      //   $readmemh("weight0_lane_N.mem", w0_rom);
      // to load trained model weights.
      integer ri;
      initial begin
        for (ri = 0; ri < 1024; ri++) w0_rom[ri] = 16'h0000;
      end
      // Synchronous read: 1-cycle latency (address captured at posedge CLK).
      always_ff @(posedge I_CLK) begin
        r_w0_data[gk] <= w0_rom[w_w0_addr_next];
      end
    end
  endgenerate

  // -----------------------------------------------------------------------
  // L1 Weight LUT-ROM (12 per-lane constant arrays, 36 x 16-bit each)
  //
  // Memory layout for lane k:
  //   addr[5:0] = {group_idx[1:0], pair_idx[3:0]}  (0..35)
  //   entry data: {wb[7:0]=W1[class][2h+1], wa[7:0]=W1[class][2h]}
  //   where class = group_idx * LANE_COUNT + k
  //
  // Combinatorial read (no pre-fetch needed; mux-tree in synthesis).
  // All zero for bring-up.
  // -----------------------------------------------------------------------
  logic [15:0] c_w1_rom [0:CHAR_OCR_LANE_COUNT-1][0:35];
  integer wi, wk;
  initial begin
    for (wk = 0; wk < CHAR_OCR_LANE_COUNT; wk++)
      for (wi = 0; wi < 36; wi++) c_w1_rom[wk][wi] = 16'h0000;
  end

  // -----------------------------------------------------------------------
  // Bias constants (zero for bring-up; update when trained biases available)
  // -----------------------------------------------------------------------
  logic signed [31:0] c_bias0 [0:CHAR_OCR_HIDDEN0_COUNT-1];
  logic signed [31:0] c_bias1 [0:CHAR_OCR_CLASS_COUNT-1];
  integer bi;
  initial begin
    for (bi = 0; bi < CHAR_OCR_HIDDEN0_COUNT; bi++) c_bias0[bi] = 32'sd0;
    for (bi = 0; bi < CHAR_OCR_CLASS_COUNT;   bi++) c_bias1[bi] = 32'sd0;
  end

  // -----------------------------------------------------------------------
  // State and control registers
  // -----------------------------------------------------------------------
  char_ocr_state_t st_state;
  logic [1:0]  r_group_idx;   // group of 12 lanes: 0..1 for L0, 0..2 for L1
  logic [8:0]  r_pair_idx;    // pair index within RUN: 0..511 (L0) or 0..11 (L1)
  logic [1:0]  r_flush_cnt;   // flush cycle counter 0..2

  // Hidden activations: output of FC0 after ReLU+clamp (24 elements)
  logic signed [7:0] r_hidden_act [0:CHAR_OCR_HIDDEN0_COUNT-1];
  // FC1 output scores (36 elements)
  logic signed [31:0] r_score_word [0:CHAR_OCR_CLASS_COUNT-1];

  // -----------------------------------------------------------------------
  // DSP array control signals (combinational)
  // -----------------------------------------------------------------------
  logic              l_dsp_reset;
  logic signed [7:0] l_act0, l_act1;
  logic signed [(12*8)-1:0] l_weight_a, l_weight_b;
  logic signed [(12*54)-1:0] l_accum_vector;

  // -----------------------------------------------------------------------
  // L0 BSRAM pre-fetch address (combinatorial)
  //
  // In ST_L0_RESET: issue addr for pair 0 (data ready in first ST_L0_RUN).
  // In ST_L0_RUN:   issue addr for pair_idx+1 (data ready next cycle).
  //   At pair_idx = FEAT_PAIRS-1: addr wraps/don't-care; FLUSH uses zeros.
  // -----------------------------------------------------------------------
  always_comb begin
    case (st_state)
      ST_L0_RESET: w_w0_addr_next = {r_group_idx[0], 9'd0};
      ST_L0_RUN:   w_w0_addr_next = {r_group_idx[0], r_pair_idx[8:0] + 9'd1};
      default:     w_w0_addr_next = 10'h0;
    endcase
  end

  // -----------------------------------------------------------------------
  // DSP input driving (always_comb)
  //
  // L0 RUN: act=features, weight=BSRAM registered output (pre-fetched).
  // L1 RUN: act=hidden activations, weight=LUT-ROM combinatorial output.
  // All other states: act=0, weight=0, DSP accumulates nothing.
  // -----------------------------------------------------------------------
  always_comb begin
    l_dsp_reset = (st_state == ST_L0_RESET) || (st_state == ST_L1_RESET);

    l_act0 = '0;
    l_act1 = '0;
    l_weight_a = '0;
    l_weight_b = '0;

    if (st_state == ST_L0_RUN) begin
      l_act0 = get_feature(I_FEATURE_BITS, int'(r_pair_idx) * 2);
      l_act1 = get_feature(I_FEATURE_BITS, int'(r_pair_idx) * 2 + 1);
      // Weights come from per-lane BSRAM (pre-fetched 1 cycle ahead).
      // nidx = group_idx * LANE_COUNT + k is always < HIDDEN0_COUNT for valid groups.
      for (int k = 0; k < CHAR_OCR_LANE_COUNT; k++) begin
        l_weight_a[(k*8) +: 8] = r_w0_data[k][7:0];   // wa
        l_weight_b[(k*8) +: 8] = r_w0_data[k][15:8];  // wb
      end

    end else if (st_state == ST_L1_RUN) begin
      l_act0 = r_hidden_act[int'(r_pair_idx) * 2];
      l_act1 = r_hidden_act[int'(r_pair_idx) * 2 + 1];
      // L1 weights: combinatorial LUT-ROM, addr = {group, pair}.
      // nidx = group_idx * LANE_COUNT + k is always < CLASS_COUNT for valid groups.
      begin
        automatic logic [5:0] w1_addr = {r_group_idx[1:0], r_pair_idx[3:0]};
        for (int k = 0; k < CHAR_OCR_LANE_COUNT; k++) begin
          l_weight_a[(k*8) +: 8] = c_w1_rom[k][w1_addr][7:0];   // wa
          l_weight_b[(k*8) +: 8] = c_w1_rom[k][w1_addr][15:8];  // wb
        end
      end
    end
  end

  // -----------------------------------------------------------------------
  // DSP accumulator array instantiation
  // -----------------------------------------------------------------------
  char_ocr_dsp12_accum u_dsp12_accum (
    .I_CLK          (I_CLK),
    .I_CE           (O_BUSY),
    .I_RESET        (l_dsp_reset),
    .I_ACT0         (l_act0),
    .I_ACT1         (l_act1),
    .I_WEIGHT_A     (l_weight_a),
    .I_WEIGHT_B     (l_weight_b),
    .O_ACCUM_VECTOR (l_accum_vector)
  );

  // -----------------------------------------------------------------------
  // FSM: state register and cycle counters
  // -----------------------------------------------------------------------
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state                  <= ST_IDLE;
      r_group_idx               <= '0;
      r_pair_idx                <= '0;
      r_flush_cnt               <= '0;
      O_BUSY                    <= 1'b0;
      O_DONE                    <= 1'b0;
      O_ERROR_UNSUPPORTED_MODEL <= 1'b0;
      O_CYCLES_TOTAL            <= 32'h0;
      O_CYCLES_L0               <= 32'h0;
      O_CYCLES_L1               <= 32'h0;
      O_CYCLES_L2               <= 32'h0;
      O_SCORE_VECTOR            <= '0;
      for (int i = 0; i < CHAR_OCR_HIDDEN0_COUNT; i++) r_hidden_act[i] <= 8'sd0;
      for (int i = 0; i < CHAR_OCR_CLASS_COUNT;   i++) r_score_word[i] <= 32'sd0;
    end else begin
      O_DONE <= 1'b0;

      case (st_state)

        // ---- Idle: wait for start pulse ----
        ST_IDLE: begin
          O_BUSY                    <= 1'b0;
          O_ERROR_UNSUPPORTED_MODEL <= 1'b0;
          if (I_START) begin
            O_CYCLES_TOTAL <= 32'h0;
            O_CYCLES_L0    <= 32'h0;
            O_CYCLES_L1    <= 32'h0;
            O_CYCLES_L2    <= 32'h0;
            O_SCORE_VECTOR <= '0;
            r_group_idx    <= '0;
            r_pair_idx     <= '0;
            r_flush_cnt    <= '0;
            for (int i = 0; i < CHAR_OCR_HIDDEN0_COUNT; i++) r_hidden_act[i] <= 8'sd0;
            for (int i = 0; i < CHAR_OCR_CLASS_COUNT;   i++) r_score_word[i] <= 32'sd0;
            if (I_MODEL_SELECT != 1'b0) begin
              O_ERROR_UNSUPPORTED_MODEL <= 1'b1;
              O_DONE                    <= 1'b1;
`ifdef SIM
              $display("[%0t][DEBUG][INFER] START: unsupported model %0d", $time, I_MODEL_SELECT);
`endif
            end else begin
              O_BUSY   <= 1'b1;
              st_state <= ST_L0_RESET;
`ifdef SIM
              $display("[%0t][DEBUG][INFER] START accepted -> ST_L0_RESET", $time);
`endif
            end
          end
        end

        // ---- FC0 group: RESET (1 cycle) ----
        // l_dsp_reset asserted combinatorially. BSRAM addr pre-fetch issued.
        ST_L0_RESET: begin
          r_pair_idx  <= '0;
          r_flush_cnt <= '0;
          st_state    <= ST_L0_RUN;
`ifdef SIM
          $display("[%0t][DEBUG][INFER] ST_L0_RESET grp=%0d -> ST_L0_RUN", $time, r_group_idx);
`endif
        end

        // ---- FC0 group: RUN (FEAT_PAIRS = 512 cycles) ----
        // BSRAM output r_w0_data[k] contains pre-fetched weight for this pair.
        ST_L0_RUN: begin
          O_CYCLES_TOTAL <= O_CYCLES_TOTAL + 1;
          O_CYCLES_L0    <= O_CYCLES_L0    + 1;
          if (r_pair_idx == CHAR_OCR_FEAT_PAIRS - 1) begin
            r_pair_idx  <= '0;
            r_flush_cnt <= '0;
            st_state    <= ST_L0_FLUSH;
`ifdef SIM
            $display("[%0t][DEBUG][INFER] ST_L0_RUN grp=%0d done (pair=%0d) -> ST_L0_FLUSH",
              $time, r_group_idx, r_pair_idx);
`endif
          end else begin
`ifdef SIM
            if (r_pair_idx[6:0] == 7'd0)
              $display("[%0t][DEBUG][INFER] ST_L0_RUN grp=%0d pair=%0d/511",
                $time, r_group_idx, r_pair_idx);
`endif
            r_pair_idx <= r_pair_idx + 1;
          end
        end

        // ---- FC0 group: FLUSH (PIPE_LATENCY = 3 cycles) ----
        ST_L0_FLUSH: begin
          O_CYCLES_TOTAL <= O_CYCLES_TOTAL + 1;
          O_CYCLES_L0    <= O_CYCLES_L0    + 1;
          if (r_flush_cnt == CHAR_OCR_PIPE_LATENCY - 1) begin
            st_state <= ST_L0_READ;
`ifdef SIM
            $display("[%0t][DEBUG][INFER] ST_L0_FLUSH grp=%0d done -> ST_L0_READ", $time, r_group_idx);
`endif
          end else begin
            r_flush_cnt <= r_flush_cnt + 1;
          end
        end

        // ---- FC0 group: READ (1 cycle) ----
        // Apply bias (constant zero) and ReLU+clamp; store in r_hidden_act.
        ST_L0_READ: begin
          for (int k = 0; k < CHAR_OCR_LANE_COUNT; k++) begin
            automatic int unsigned nidx = int'(r_group_idx) * CHAR_OCR_LANE_COUNT + k;
            if (nidx < CHAR_OCR_HIDDEN0_COUNT) begin
              automatic logic signed [31:0] dot = $signed(l_accum_vector[(k*54) +: 32]);
              automatic logic signed [31:0] hval = dot + c_bias0[nidx];
`ifdef SIM
              $display("[%0t][DEBUG][INFER] L0_READ nidx=%0d dot=%0d bias=%0d hval=%0d act=%0d",
                $time, nidx, dot, c_bias0[nidx], hval,
                (hval > 0) ? int'(char_ocr_clamp_int8(hval)) : 0);
`endif
              r_hidden_act[nidx] <= (hval > 0) ? char_ocr_clamp_int8(hval) : 8'sd0;
            end
          end
          if (r_group_idx == CHAR_OCR_L0_GROUPS - 1) begin
`ifdef SIM
            $display("[%0t][DEBUG][INFER] ST_L0_READ grp=%0d (last) -> ST_L1_RESET", $time, r_group_idx);
`endif
            r_group_idx <= '0;
            st_state    <= ST_L1_RESET;
          end else begin
`ifdef SIM
            $display("[%0t][DEBUG][INFER] ST_L0_READ grp=%0d -> ST_L0_RESET grp=%0d",
              $time, r_group_idx, r_group_idx + 1);
`endif
            r_group_idx <= r_group_idx + 1;
            st_state    <= ST_L0_RESET;
          end
        end

        // ---- FC1 group: RESET (1 cycle) ----
        ST_L1_RESET: begin
          r_pair_idx  <= '0;
          r_flush_cnt <= '0;
          st_state    <= ST_L1_RUN;
`ifdef SIM
          $display("[%0t][DEBUG][INFER] ST_L1_RESET grp=%0d -> ST_L1_RUN", $time, r_group_idx);
`endif
        end

        // ---- FC1 group: RUN (HIDDEN_PAIRS = 12 cycles) ----
        // Weights from LUT-ROM (combinatorial, no pre-fetch latency).
        ST_L1_RUN: begin
          O_CYCLES_TOTAL <= O_CYCLES_TOTAL + 1;
          O_CYCLES_L1    <= O_CYCLES_L1    + 1;
          if (r_pair_idx == CHAR_OCR_HIDDEN_PAIRS - 1) begin
            r_pair_idx  <= '0;
            r_flush_cnt <= '0;
            st_state    <= ST_L1_FLUSH;
`ifdef SIM
            $display("[%0t][DEBUG][INFER] ST_L1_RUN grp=%0d done -> ST_L1_FLUSH", $time, r_group_idx);
`endif
          end else begin
            r_pair_idx <= r_pair_idx + 1;
          end
        end

        // ---- FC1 group: FLUSH (PIPE_LATENCY = 3 cycles) ----
        ST_L1_FLUSH: begin
          O_CYCLES_TOTAL <= O_CYCLES_TOTAL + 1;
          O_CYCLES_L1    <= O_CYCLES_L1    + 1;
          if (r_flush_cnt == CHAR_OCR_PIPE_LATENCY - 1) begin
            st_state <= ST_L1_READ;
`ifdef SIM
            $display("[%0t][DEBUG][INFER] ST_L1_FLUSH grp=%0d done -> ST_L1_READ", $time, r_group_idx);
`endif
          end else begin
            r_flush_cnt <= r_flush_cnt + 1;
          end
        end

        // ---- FC1 group: READ (1 cycle) ----
        // Apply bias (constant zero); store raw int32 score.
        ST_L1_READ: begin
          for (int k = 0; k < CHAR_OCR_LANE_COUNT; k++) begin
            automatic int unsigned cidx = int'(r_group_idx) * CHAR_OCR_LANE_COUNT + k;
            if (cidx < CHAR_OCR_CLASS_COUNT) begin
              automatic logic signed [31:0] dot = $signed(l_accum_vector[(k*54) +: 32]);
              automatic logic signed [31:0] sval = dot + c_bias1[cidx];
`ifdef SIM
              $display("[%0t][DEBUG][INFER] L1_READ cidx=%0d dot=%0d bias=%0d score=%0d",
                $time, cidx, dot, c_bias1[cidx], sval);
`endif
              r_score_word[cidx]             <= sval;
              O_SCORE_VECTOR[(cidx*32) +: 32] <= sval;
            end
          end
          if (r_group_idx == CHAR_OCR_L1_GROUPS - 1) begin
            O_BUSY   <= 1'b0;
            O_DONE   <= 1'b1;
            st_state <= ST_DONE;
`ifdef SIM
            $display("[%0t][DEBUG][INFER] ST_L1_READ grp=%0d (last) -> ST_DONE, O_DONE=1", $time, r_group_idx);
`endif
          end else begin
            r_group_idx <= r_group_idx + 1;
            st_state    <= ST_L1_RESET;
`ifdef SIM
            $display("[%0t][DEBUG][INFER] ST_L1_READ grp=%0d -> ST_L1_RESET grp=%0d",
              $time, r_group_idx, r_group_idx + 1);
`endif
          end
        end

        // ---- Done: return to idle next cycle ----
        ST_DONE: begin
          st_state <= ST_IDLE;
`ifdef SIM
          $display("[%0t][DEBUG][INFER] ST_DONE -> ST_IDLE (cycles_total=%0d l0=%0d l1=%0d)",
            $time, O_CYCLES_TOTAL, O_CYCLES_L0, O_CYCLES_L1);
`endif
        end

        default: st_state <= ST_IDLE;

      endcase
    end
  end

endmodule
