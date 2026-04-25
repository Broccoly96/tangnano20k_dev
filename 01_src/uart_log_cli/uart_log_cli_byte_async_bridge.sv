`timescale 1ns / 1ps
`ifndef UART_LOG_CLI_BYTE_ASYNC_BRIDGE_SV
`define UART_LOG_CLI_BYTE_ASYNC_BRIDGE_SV
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_cli_byte_async_bridge.sv
// Description  : Dual-clock byte mailbox used to carry CLI RX bytes from the
//                uart_log_cli clock domain into the SDRAM host-interface domain.
//                The transfer uses a bundled-data request/ack toggle so the
//                byte path does not rely on dual-clock RAM inference.
//////////////////////////////////////////////////////////////////////////////////

module uart_log_cli_byte_async_bridge #(
  parameter int unsigned FIFO_DEPTH = 16
) (
  input  logic       I_SRC_CLK,
  input  logic       I_SRC_RST_N,
  input  logic       I_DST_CLK,
  input  logic       I_DST_RST_N,
  input  logic       I_SRC_VALID,
  input  logic [7:0] I_SRC_DATA,
  output logic       O_SRC_READY,
  output logic       O_DST_VALID,
  output logic [7:0] O_DST_DATA,
  input  logic       I_DST_READY
);

  logic       r_src_req_toggle;
  logic [7:0] r_src_data;
  logic       r_dst_ack_toggle;
  logic       r_dst_valid;
  logic [7:0] r_dst_data;
  logic       r_dst_req_sync1;
  logic       r_dst_req_sync2;
  logic       r_src_ack_sync1;
  logic       r_src_ack_sync2;
  logic       s_src_busy;
  logic       s_src_push;
  logic       s_dst_has_pending;
  logic       s_dst_accept;

  assign s_src_busy        = (r_src_req_toggle != r_src_ack_sync2);
  assign s_src_push        = I_SRC_VALID && !s_src_busy;
  assign O_SRC_READY       = !s_src_busy;

  assign s_dst_has_pending = (r_dst_req_sync2 != r_dst_ack_toggle);
  assign s_dst_accept      = r_dst_valid && I_DST_READY;
  assign O_DST_VALID       = r_dst_valid;
  assign O_DST_DATA        = r_dst_data;

  // Source clock domain: hold one byte stable until the destination consumes it
  // and returns the acknowledge toggle.
  always_ff @(posedge I_SRC_CLK or negedge I_SRC_RST_N) begin
    if (!I_SRC_RST_N) begin
      r_src_req_toggle <= 1'b0;
      r_src_data       <= 8'h00;
      r_src_ack_sync1  <= 1'b0;
      r_src_ack_sync2  <= 1'b0;
    end else begin
      r_src_ack_sync1 <= r_dst_ack_toggle;
      r_src_ack_sync2 <= r_src_ack_sync1;

      if (s_src_push) begin
        r_src_data       <= I_SRC_DATA;
        r_src_req_toggle <= ~r_src_req_toggle;
      end
    end
  end

  // Destination clock domain: detect the request toggle, sample the stable byte,
  // then acknowledge only after the downstream consumer accepts the byte.
  always_ff @(posedge I_DST_CLK or negedge I_DST_RST_N) begin
    if (!I_DST_RST_N) begin
      r_dst_ack_toggle <= 1'b0;
      r_dst_valid      <= 1'b0;
      r_dst_data       <= 8'h00;
      r_dst_req_sync1  <= 1'b0;
      r_dst_req_sync2  <= 1'b0;
    end else begin
      r_dst_req_sync1 <= r_src_req_toggle;
      r_dst_req_sync2 <= r_dst_req_sync1;

      if (!r_dst_valid && s_dst_has_pending) begin
        r_dst_data  <= r_src_data;
        r_dst_valid <= 1'b1;
      end else if (s_dst_accept) begin
        r_dst_valid      <= 1'b0;
        r_dst_ack_toggle <= r_dst_req_sync2;
      end
    end
  end

endmodule
`endif
