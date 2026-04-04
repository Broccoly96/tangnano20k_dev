`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : indexed_reg_test_block.sv
// Description  : Top-level CONF target for bring-up and regression.
//                Provides a scratch register, write observability, and
//                a write-one snapshot request pulse for the Ethernet debug
//                path.
//////////////////////////////////////////////////////////////////////////////////

module indexed_reg_test_block (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_CONF_SEL,
  input  logic [7:0]  I_CONF_REG_ID,
  input  logic        I_CONF_WR_EN,
  input  logic [31:0] I_CONF_WR_DATA,
  input  logic [31:0] I_TOP_STATUS,
  input  logic [31:0] I_TOP_UPTIME_LO,
  input  logic [31:0] I_TOP_UPTIME_HI,
  input  logic [31:0] I_TOP_SNAPSHOT_COUNT,
  output logic        O_SNAPSHOT_REQ_PULSE,
  output logic [31:0] O_CONF_RD_DATA
);

  import indexed_reg_pkg::*;

  logic [31:0] r_scratch;
  logic [31:0] r_wr_count;
  logic [31:0] r_last_data;

  //----------------------------------------------------------------------------
  // Write-observation state
  //----------------------------------------------------------------------------
  // The write count and last-data mirror update on every top CONF write.
  // The snapshot request is a one-cycle pulse used by the top-level Ethernet
  // debug path; it is not stored as state.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_scratch   <= 32'h0000_0000;
      r_wr_count  <= 32'h0000_0000;
      r_last_data <= 32'h0000_0000;
    end else if (I_CONF_SEL && I_CONF_WR_EN) begin
      r_last_data <= I_CONF_WR_DATA;
      r_wr_count  <= r_wr_count + 1'b1;
      if (I_CONF_REG_ID == TOP_CONF_REG_SCRATCH) begin
        r_scratch <= I_CONF_WR_DATA;
      end
    end
  end

  assign O_SNAPSHOT_REQ_PULSE =
    I_CONF_SEL && I_CONF_WR_EN && (I_CONF_REG_ID == TOP_CONF_REG_SNAPSHOT_REQ);

  //----------------------------------------------------------------------------
  // Readback mux
  //----------------------------------------------------------------------------
  // The top CONF block returns the fixed signature, scratch state, counters,
  // and the live status mirror values supplied by the board top.
  always_comb begin
    if (!I_CONF_SEL) begin
      O_CONF_RD_DATA = 32'h0000_0000;
    end else begin
      case (I_CONF_REG_ID)
        TOP_CONF_REG_ID:        O_CONF_RD_DATA = 32'h434F_4E46;
        TOP_CONF_REG_SCRATCH:   O_CONF_RD_DATA = r_scratch;
        TOP_CONF_REG_WR_COUNT:  O_CONF_RD_DATA = r_wr_count;
        TOP_CONF_REG_LAST_DATA: O_CONF_RD_DATA = r_last_data;
        TOP_CONF_REG_SNAPSHOT_REQ: O_CONF_RD_DATA = 32'h0000_0000;
        TOP_CONF_REG_STATUS:       O_CONF_RD_DATA = I_TOP_STATUS;
        TOP_CONF_REG_UPTIME_LO:    O_CONF_RD_DATA = I_TOP_UPTIME_LO;
        TOP_CONF_REG_UPTIME_HI:    O_CONF_RD_DATA = I_TOP_UPTIME_HI;
        TOP_CONF_REG_SNAPSHOT_COUNT: O_CONF_RD_DATA = I_TOP_SNAPSHOT_COUNT;
        default:                O_CONF_RD_DATA = 32'h0000_0000;
      endcase
    end
  end

endmodule
