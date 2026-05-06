`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_multaddalu18x18_wrapper.sv
// Description  : Simulation-safe wrapper around Gowin MULTADDALU18X18.
//                - In simulation, uses a behavioral model so Questa can run
//                  without vendor primitive libraries.
//                - In synthesis, can instantiate the Gowin primitive when
//                  `CHAR_OCR_USE_GOWIN_DSP` is defined by the build flow.
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_multaddalu18x18_wrapper (
  input  logic                 I_CLK,
  input  logic                 I_CE,
  input  logic                 I_RESET,
  input  logic                 I_ACCLOAD,
  input  logic signed [17:0]   I_A0,
  input  logic signed [17:0]   I_B0,
  input  logic signed [17:0]   I_A1,
  input  logic signed [17:0]   I_B1,
  input  logic signed [53:0]   I_C,
  output logic signed [53:0]   O_DOUT
);

`ifdef CHAR_OCR_USE_GOWIN_DSP
  wire [53:0] w_dout;

  MULTADDALU18X18 #(
    .A0REG(1'b0),
    .A1REG(1'b0),
    .B0REG(1'b0),
    .B1REG(1'b0),
    .CREG(1'b0),
    .OUT_REG(1'b0),
    .PIPE_REG(1'b0),
    .MULTADDALU18X18_MODE(0)
  ) u_multaddalu18x18 (
    .A0      (I_A0),
    .B0      (I_B0),
    .A1      (I_A1),
    .B1      (I_B1),
    .C       (I_C),
    .SIA     (18'h00000),
    .SIB     (18'h00000),
    .ASIGN   (2'b11),
    .BSIGN   (2'b11),
    .ASEL    (2'b00),
    .BSEL    (2'b00),
    .CASI    (55'h00000000000000),
    .ACCLOAD (I_ACCLOAD),
    .CLK     (I_CLK),
    .CE      (I_CE),
    .RESET   (I_RESET),
    .DOUT    (w_dout),
    .CASO    (),
    .SOA     (),
    .SOB     ()
  );

  always_comb begin
    O_DOUT = $signed(w_dout);
  end
`else
  logic signed [53:0] s_dout_next;

  always_comb begin
    s_dout_next = ($signed(I_A0) * $signed(I_B0)) +
                  ($signed(I_A1) * $signed(I_B1));
    if (!I_ACCLOAD) begin
      s_dout_next = s_dout_next + $signed(I_C);
    end
  end

  always_ff @(posedge I_CLK or posedge I_RESET) begin
    if (I_RESET) begin
      O_DOUT <= '0;
    end else if (I_CE) begin
      O_DOUT <= s_dout_next;
    end
  end
`endif

endmodule