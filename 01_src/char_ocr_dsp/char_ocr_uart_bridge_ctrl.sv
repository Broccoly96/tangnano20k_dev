`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : char_ocr_uart_bridge_ctrl.sv
// Description  : ASCII UART command bridge for OCR inference.
//
// Command protocol (RX, 1 byte):
//   'Z' (0x5A) - Trigger OCR inference with the currently loaded image.
//
// Event protocol (TX, via HOST_EVT_IF):
//   EVT_OCR_ACK    (0x30): Command accepted. arg0=0x4F435200 ("OCR\0").
//   EVT_OCR_BUSY   (0x31): OCR already running, command rejected.
//   EVT_OCR_RESULT (0x40): Classification result.
//                           arg0 = {8'h00, class[5:0], 2'h0, char[7:0], 8'h00}
//                                  = {24-bit packed: class in [21:16], char in [15:8]}
//                           arg1 = score0 (top-1 score, int32 truncated to 32-bit)
//                           arg2 = score1 (top-2 score)
//   EVT_OCR_CYCLES (0x41): Cycle count breakdown.
//                           arg0 = cycles_total, arg1 = cycles_l0, arg2 = cycles_l1
//
// EVT IDs are chosen to be consistent with the WebUI UartEvent parser (srcId = OCR src).
//////////////////////////////////////////////////////////////////////////////////

module char_ocr_uart_bridge_ctrl (
  input  logic            I_CLK,
  input  logic            I_RST_N,
  input  logic            I_ENABLE,
  // RX command from UART CLI byte bridge
  input  logic            I_CLI_RX_VALID,
  input  logic [7:0]      I_CLI_RX_DATA,
  // OCR control interface (48 MHz domain, same as this module)
  output logic            O_RUN_OCR,
  input  logic            I_OCR_BUSY,
  input  logic            I_OCR_DONE,
  input  logic [5:0]      I_RESULT_CLASS,
  input  logic [7:0]      I_RESULT_CHAR,
  input  logic [31:0]     I_RESULT_SCORE0,
  input  logic [31:0]     I_RESULT_SCORE1,
  input  logic [31:0]     I_CYCLES_TOTAL,
  input  logic [31:0]     I_CYCLES_L0,
  input  logic [31:0]     I_CYCLES_L1,
  // Event output to uart_log_cli (producer side)
  uart_log_evt_if.producer HOST_EVT_IF
);

  // -----------------------------------------------------------------------
  // Command byte constants
  // -----------------------------------------------------------------------
  localparam logic [7:0] CMD_RUN_OCR  = 8'h5A; // 'Z'

  // -----------------------------------------------------------------------
  // Event ID constants
  // -----------------------------------------------------------------------
  localparam logic [7:0] EVT_OCR_ACK    = 8'h30;
  localparam logic [7:0] EVT_OCR_BUSY   = 8'h31;
  localparam logic [7:0] EVT_OCR_RESULT = 8'h40;
  localparam logic [7:0] EVT_OCR_CYCLES = 8'h41;

  // -----------------------------------------------------------------------
  // Event FIFO (3 entries: ACK + RESULT + CYCLES)
  // -----------------------------------------------------------------------
  localparam int unsigned FIFO_DEPTH = 4;
  localparam int unsigned PTR_W      = $clog2(FIFO_DEPTH);

  // Event frame: {evt_id[7:0], arg0[31:0], arg1[31:0], arg2[31:0]} = 104 bits
  logic [103:0] r_evt_fifo_mem [0:FIFO_DEPTH-1];
  logic [PTR_W-1:0] r_evt_wr_ptr;
  logic [PTR_W-1:0] r_evt_rd_ptr;
  logic [2:0]       r_evt_count;  // 0..FIFO_DEPTH

  logic s_evt_fifo_full;
  logic s_evt_fifo_empty;
  logic s_evt_push;
  logic s_evt_pop;

  assign s_evt_fifo_full  = (r_evt_count == FIFO_DEPTH);
  assign s_evt_fifo_empty = (r_evt_count == 0);

  // Interface drive (producer side)
  assign HOST_EVT_IF.evt_valid = !s_evt_fifo_empty && I_ENABLE;
  assign HOST_EVT_IF.evt_id    = r_evt_fifo_mem[r_evt_rd_ptr][103:96];
  assign HOST_EVT_IF.arg0      = r_evt_fifo_mem[r_evt_rd_ptr][95:64];
  assign HOST_EVT_IF.arg1      = r_evt_fifo_mem[r_evt_rd_ptr][63:32];
  assign HOST_EVT_IF.arg2      = r_evt_fifo_mem[r_evt_rd_ptr][31:0];

  assign s_evt_pop  = HOST_EVT_IF.evt_valid && HOST_EVT_IF.evt_ready;

  // -----------------------------------------------------------------------
  // Control registers
  // -----------------------------------------------------------------------
  logic [103:0] r_pending_evt;
  logic         r_push_req;
  logic         r_ocr_run_req;

  assign O_RUN_OCR  = r_ocr_run_req;
  assign s_evt_push = r_push_req && !s_evt_fifo_full;

  // -----------------------------------------------------------------------
  // FIFO memory update
  // -----------------------------------------------------------------------
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_evt_wr_ptr <= '0;
      r_evt_rd_ptr <= '0;
      r_evt_count  <= '0;
    end else begin
      if (s_evt_push && !s_evt_pop) begin
        r_evt_count <= r_evt_count + 1;
      end else if (!s_evt_push && s_evt_pop) begin
        r_evt_count <= r_evt_count - 1;
      end
      if (s_evt_push) begin
        r_evt_fifo_mem[r_evt_wr_ptr] <= r_pending_evt;
        r_evt_wr_ptr <= r_evt_wr_ptr + 1;
      end
      if (s_evt_pop) begin
        r_evt_rd_ptr <= r_evt_rd_ptr + 1;
      end
    end
  end

  // -----------------------------------------------------------------------
  // Command decoder + event sequencer
  //
  // States:
  //   ST_IDLE  : waiting for command
  //   ST_ACK   : push ACK event, then assert run_req for 1 cycle
  //   ST_WAIT  : waiting for OCR to complete (busy=1)
  //   ST_RESULT: push RESULT event
  //   ST_CYCLES: push CYCLES event
  // -----------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_ACK,
    ST_WAIT,
    ST_RESULT,
    ST_CYCLES
  } ocr_bridge_state_t;

  ocr_bridge_state_t st_state;

  // Helper to build event frame
  function automatic logic [103:0] make_evt(
    input logic [7:0]  id,
    input logic [31:0] a0,
    input logic [31:0] a1,
    input logic [31:0] a2
  );
    make_evt = {id, a0, a1, a2};
  endfunction

  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state       <= ST_IDLE;
      r_push_req     <= 1'b0;
      r_pending_evt  <= '0;
      r_ocr_run_req  <= 1'b0;
    end else begin
      r_push_req    <= 1'b0;
      r_ocr_run_req <= 1'b0;

      case (st_state)

        ST_IDLE: begin
          if (I_ENABLE && I_CLI_RX_VALID) begin
            if (I_CLI_RX_DATA == CMD_RUN_OCR) begin
              if (I_OCR_BUSY) begin
                // OCR still running: send BUSY event
                r_pending_evt <= make_evt(EVT_OCR_BUSY, 32'h4F435200, 32'h0, 32'h0);
                r_push_req    <= 1'b1;
              end else begin
                // Accept command: send ACK and start OCR
                r_pending_evt <= make_evt(EVT_OCR_ACK, 32'h4F435200, 32'h0, 32'h0);
                r_push_req    <= 1'b1;
                r_ocr_run_req <= 1'b1;
                st_state      <= ST_WAIT;
              end
            end
            // Unknown commands are silently ignored.
          end
        end

        ST_WAIT: begin
          // Wait for OCR completion
          if (I_OCR_DONE) begin
            st_state <= ST_RESULT;
          end
        end

        ST_RESULT: begin
          // Push result event: arg0={class[21:16], char[15:8]},
          //                    arg1=score0, arg2=score1
          r_pending_evt <= make_evt(
            EVT_OCR_RESULT,
            {10'h0, I_RESULT_CLASS, I_RESULT_CHAR, 8'h00},
            I_RESULT_SCORE0,
            I_RESULT_SCORE1
          );
          r_push_req <= 1'b1;
          st_state   <= ST_CYCLES;
        end

        ST_CYCLES: begin
          // Wait until RESULT is pushed (FIFO has space), then push CYCLES.
          // r_push_req goes low after 1 cycle; check count to avoid re-pushing.
          if (!r_push_req) begin
            r_pending_evt <= make_evt(
              EVT_OCR_CYCLES,
              I_CYCLES_TOTAL,
              I_CYCLES_L0,
              I_CYCLES_L1
            );
            r_push_req <= 1'b1;
            st_state   <= ST_IDLE;
          end
        end

        default: st_state <= ST_IDLE;

      endcase
    end
  end

endmodule
