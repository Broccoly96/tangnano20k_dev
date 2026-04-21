`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_cli.sv
// Description  : UART debug log core with fixed 19-byte framing and minimal CLI.
//                - Aggregates one selected source at a time.
//                - Buffers all events into a shared 128x2048 FIFO before UART TX.
//                - Emits fixed-size frames: SYNC + SEQ + 16B payload + CRC8.
//                - Accepts CLI commands: ?, Ctrl+R, Ctrl+F, Ctrl+D, Ctrl+T.
//
// Usage example:
//   uart_log_cli #(
//     .CLK_HZ (50_000_000),
//     .BAUD   (115_200),
//     .NUM_SRC(3)
//   ) u_uart_log_cli (...);
//////////////////////////////////////////////////////////////////////////////////

module uart_log_cli #(
  parameter int unsigned CLK_HZ  = 50_000_000,
  parameter int unsigned BAUD    = 115_200,
  parameter int unsigned NUM_SRC = 2,
  parameter logic [NUM_SRC-1:0] SRC_ENABLE_MASK = {NUM_SRC{1'b1}}
) (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_UART_RX,
  output logic        O_UART_TX,
  output logic        O_SOFT_RESET_REQ,
  output logic        O_CLI_RX_VALID,
  output logic [7:0]  O_CLI_RX_DATA,

  uart_log_evt_if.consumer SRC_IF [NUM_SRC]
);

  import uart_log_cli_pkg::*;

  localparam int unsigned SEL_W       = (NUM_SRC <= 1) ? 1 : $clog2(NUM_SRC);
  localparam int unsigned BAUD_CNT    = (BAUD == 0) ? 1 : ((CLK_HZ + (BAUD/2)) / BAUD);
  localparam int unsigned MS_TICK_CNT = (CLK_HZ < 1000) ? 1 : ((CLK_HZ + 500) / 1000);
  localparam int unsigned MS_DIV_W    = (MS_TICK_CNT <= 1) ? 1 : $clog2(MS_TICK_CNT);

  localparam int unsigned SYS_Q_DEPTH = 4;
  localparam int unsigned SYS_Q_PTR_W = (SYS_Q_DEPTH <= 1) ? 1 : $clog2(SYS_Q_DEPTH);
  localparam int unsigned SYS_Q_CNT_W = $clog2(SYS_Q_DEPTH + 1);

  typedef enum logic [1:0] {
    SYS_PUSH_NONE  = 2'd0,
    SYS_PUSH_MODE  = 2'd1,
    SYS_PUSH_RESET = 2'd2
  } sys_push_sel_e;

  typedef enum logic [0:0] {
    TX_IDLE      = 1'b0,
    TX_WAIT_DONE = 1'b1
  } tx_fsm_e;

  // UART RX/TX byte-stream wires.
  logic [7:0] s_uart_rx_data;
  logic       s_uart_rx_valid;
  logic       r_uart_tx_start;
  logic [7:0] r_uart_tx_data;
  logic       s_uart_tx_busy;
  logic       s_uart_tx_done;

  // Timestamp generator state.
  logic [MS_DIV_W-1:0] r_ms_div_cnt;
  logic [15:0]         r_timestamp_ms;

  // Source selection and pending source-change request.
  logic [SEL_W-1:0] r_log_src_sel;
  logic             r_sel_pending_valid;
  logic [SEL_W-1:0] r_sel_pending;

  // CLI pending responses.
  logic       r_reset_ack_pending;
  logic       r_cli_literal_pending;

  // System-event queue (payload-only queue, still used to prioritize/serialize
  // command-generated system events before shared FIFO producer arbitration).
  logic [127:0] r_sys_q_mem [0:SYS_Q_DEPTH-1];
  logic [SYS_Q_PTR_W-1:0] r_sys_q_wr_ptr;
  logic [SYS_Q_PTR_W-1:0] r_sys_q_rd_ptr;
  logic [SYS_Q_CNT_W-1:0] r_sys_q_count;
  logic                   s_sys_q_full;
  logic                   s_sys_q_empty;
  logic [127:0]           s_sys_q_rdata;

  // Per-source taps and selected-source view.
  logic [NUM_SRC-1:0] s_sel_onehot;
  logic [NUM_SRC-1:0] s_tap_evt_ready;
  logic [NUM_SRC-1:0] s_tap_tvalid;
  logic [NUM_SRC-1:0] s_tap_tready;
  logic [127:0]       s_tap_tdata [NUM_SRC-1:0];
  logic [NUM_SRC-1:0] s_tap_pop;
  logic               s_sel_tvalid;
  logic [127:0]       s_sel_tdata;

  // Shared event FIFO between producer arbitration and UART framing.
  logic           s_shared_wr_en;
  logic [127:0]   s_shared_wr_data;
  logic           s_shared_full;
  logic           s_shared_rd_en;
  logic [127:0]   s_shared_rd_data;
  logic           s_shared_empty;
  logic           r_shared_rd_pending;

  // Shared FIFO drop counters (debug/verification only, not exported).
  logic [31:0]    r_drop_shared_sys_cnt;
  logic [31:0]    r_drop_shared_src_cnt;

  // Framing engine state.
  logic           r_frame_active;
  logic [4:0]     r_frame_byte_idx;
  logic [7:0]     r_frame_seq;
  logic [127:0]   r_frame_payload;
  logic [7:0]     r_frame_crc;
  logic [7:0]     r_seq_counter;
  tx_fsm_e        r_tx_state;

  // Queue/arbitration combinational wires.
  logic           s_tx_boundary_idle;
  logic           s_apply_sel_now;
  logic [127:0]   s_mode_payload;
  logic [127:0]   s_reset_payload;
  logic           s_push_req;
  logic [127:0]   s_push_data;
  sys_push_sel_e  s_push_sel;
  logic           s_do_push;
  logic           s_sys_q_drop;
  logic           s_sys_pop;
  logic           s_reset_clear;

  logic           s_prod_has_sys;
  logic           s_prod_has_src;
  logic           s_prod_take_sys;
  logic           s_prod_take_src;
  logic           s_prod_drop_sys;
  logic           s_prod_drop_src;
  logic           s_cli_dle_escape;
  logic           s_cli_forward_valid;
  logic [7:0]     s_cli_forward_data;
  logic           s_cmd_soft_reset;
  logic           s_cmd_next_src;
  logic           s_cmd_prev_src;

  //------------------------------------------------------------------------------
  // frame_byte_at
  //------------------------------------------------------------------------------
  // Returns one UART byte from the currently latched frame.
  // Returns the selected byte from the currently latched UART output frame.
  function automatic logic [7:0] frame_byte_at(
    input logic [4:0]   byte_index,
    input logic [7:0]   frame_seq,
    input logic [127:0] frame_payload,
    input logic [7:0]   frame_crc
  );
    begin
      case (byte_index)
        5'd0:     frame_byte_at = UART_SYNC_BYTE;
        5'd1:     frame_byte_at = frame_seq;
        5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7, 5'd8, 5'd9, 5'd10, 5'd11, 5'd12, 5'd13, 5'd14, 5'd15, 5'd16, 5'd17:
                  frame_byte_at = frame_payload[(byte_index - 5'd2)*8 +: 8];
        5'd18:    frame_byte_at = frame_crc;
        default:  frame_byte_at = 8'h00;
      endcase
    end
  endfunction

  //------------------------------------------------------------------------------
  // sel_to_u8
  //------------------------------------------------------------------------------
  // Safely zero-extends SEL_W-wide source index to 8 bits without out-of-range
  // part-selects (avoids X propagation when SEL_W < 8).
  // Zero-extends the source selector to 8 bits without invalid part-selects.
  function automatic logic [7:0] sel_to_u8(input logic [SEL_W-1:0] sel);
    logic [7:0] value_u8;
    begin
      value_u8 = 8'h00;
      for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
        if (bit_idx < SEL_W) value_u8[bit_idx] = sel[bit_idx];
      end
      sel_to_u8 = value_u8;
    end
  endfunction

  function automatic logic [SEL_W-1:0] sel_next_local(input logic [SEL_W-1:0] sel);
    begin
      if (NUM_SRC <= 1) begin
        sel_next_local = '0;
      end else if (sel >= (NUM_SRC - 1)) begin
        sel_next_local = '0;
      end else begin
        sel_next_local = sel + 1'b1;
      end
    end
  endfunction

  function automatic logic [SEL_W-1:0] sel_prev_local(input logic [SEL_W-1:0] sel);
    begin
      if (NUM_SRC <= 1) begin
        sel_prev_local = '0;
      end else if (sel == '0) begin
        sel_prev_local = '0;
        for (int bit_idx = 0; bit_idx < SEL_W; bit_idx++) begin
          sel_prev_local[bit_idx] = ((NUM_SRC - 1) >> bit_idx) & 1;
        end
      end else begin
        sel_prev_local = sel - 1'b1;
      end
    end
  endfunction

  //------------------------------------------------------------------------------
  // UART RX/TX blocks
  //------------------------------------------------------------------------------
  uart_rx_stream #(
    .C_BAUD_COUNT (BAUD_CNT)
  ) u_uart_rx (
    .I_CLK        (I_CLK),
    .I_RST_N      (I_RST_N),
    .I_UART_RX    (I_UART_RX),
    .O_DATA       (s_uart_rx_data),
    .O_VALID      (s_uart_rx_valid)
  );

  uart_tx_stream #(
    .C_BAUD_COUNT (BAUD_CNT)
  ) u_uart_tx (
    .I_CLK        (I_CLK),
    .I_RST_N      (I_RST_N),
    .I_START      (r_uart_tx_start),
    .I_DATA       (r_uart_tx_data),
    .O_UART_TX    (O_UART_TX),
    .O_VALID      (s_uart_tx_done),
    .O_BUSY       (s_uart_tx_busy)
  );

  //------------------------------------------------------------------------------
  // Source select decode and selected-source view
  //------------------------------------------------------------------------------
  // One-hot decode of the active source index. This one-hot vector is used for
  // source enable, selected tap data selection, and pop signaling.
  always_comb begin
    s_sel_onehot = '0;
    for (int src_idx = 0; src_idx < NUM_SRC; src_idx++) begin
      if (src_idx == r_log_src_sel) begin
        s_sel_onehot[src_idx] = 1'b1;
      end
    end
  end

  always_comb begin
    s_sel_tvalid = 1'b0;
    s_sel_tdata  = 128'h0;
    for (int src_idx = 0; src_idx < NUM_SRC; src_idx++) begin
      if (s_sel_onehot[src_idx]) begin
        s_sel_tvalid = s_tap_tvalid[src_idx];
        s_sel_tdata  = s_tap_tdata[src_idx];
      end
    end
  end

  assign s_tap_tready = s_tap_pop;

  //------------------------------------------------------------------------------
  // Source taps
  //------------------------------------------------------------------------------
  // Each source gets a dedicated 4-entry log tap. src_id is fixed to index+1
  // while src_id=0x00 remains reserved for system/CLI events.
  genvar g_src;
  generate
    for (g_src = 0; g_src < NUM_SRC; g_src++) begin : g_log_tap
      localparam int unsigned SRC_ID = g_src + 1;

      wire [7:0]   w_evt_id;
      wire [31:0]  w_arg0;
      wire [31:0]  w_arg1;
      wire [31:0]  w_arg2;
      wire [127:0] w_payload;

      assign SRC_IF[g_src].enable    = s_sel_onehot[g_src] & SRC_ENABLE_MASK[g_src];
      assign SRC_IF[g_src].evt_ready = s_tap_evt_ready[g_src];

      assign w_evt_id = SRC_IF[g_src].evt_id;
      assign w_arg0   = SRC_IF[g_src].arg0;
      assign w_arg1   = SRC_IF[g_src].arg1;
      assign w_arg2   = SRC_IF[g_src].arg2;

      if (SRC_ENABLE_MASK[g_src]) begin : g_enabled_tap
        assign w_payload = pack_event_payload(
          SRC_ID[7:0],
          w_evt_id,
          r_timestamp_ms,
          w_arg0,
          w_arg1,
          w_arg2
        );

        uart_log_tap u_tap (
          .I_CLK        (I_CLK),
          .I_RST_N      (I_RST_N),
          .I_ENABLE     (s_sel_onehot[g_src]),
          .I_EVT_VALID  (SRC_IF[g_src].evt_valid),
          .I_EVT_DATA   (w_payload),
          .O_EVT_READY  (s_tap_evt_ready[g_src]),
          .O_TVALID     (s_tap_tvalid[g_src]),
          .I_TREADY     (s_tap_tready[g_src]),
          .O_TDATA      (s_tap_tdata[g_src])
        );
      end else begin : g_disabled_tap
        assign w_payload              = 128'h0;
        assign s_tap_evt_ready[g_src] = 1'b0;
        assign s_tap_tvalid[g_src]    = 1'b0;
        assign s_tap_tdata[g_src]     = 128'h0;
      end
    end
  endgenerate

  //------------------------------------------------------------------------------
  // Shared event FIFO
  //------------------------------------------------------------------------------
  // The producer side writes one 128-bit payload per accepted event, and the
  // consumer side reads payloads for frame serialization.
  uart_log_cli_evt_fifo u_evt_fifo (
    .I_CLK      (I_CLK),
    .I_RST_N    (I_RST_N),
    .I_WR_EN    (s_shared_wr_en),
    .I_WR_DATA  (s_shared_wr_data),
    .O_FULL     (s_shared_full),
    .I_RD_EN    (s_shared_rd_en),
    .O_RD_DATA  (s_shared_rd_data),
    .O_EMPTY    (s_shared_empty)
  );

  //------------------------------------------------------------------------------
  // Queue/arbitration combinational logic
  //------------------------------------------------------------------------------
  assign s_sys_q_full  = (r_sys_q_count == SYS_Q_DEPTH);
  assign s_sys_q_empty = (r_sys_q_count == 0);
  assign s_sys_q_rdata = r_sys_q_mem[r_sys_q_rd_ptr];

  assign s_tx_boundary_idle = (!r_frame_active) && (!s_uart_tx_busy);

  // Source change is applied only when all in-flight payloads are drained:
  //  - frame engine idle
  //  - shared FIFO empty
  //  - no outstanding shared read request
  assign s_apply_sel_now = s_tx_boundary_idle && (!r_shared_rd_pending) && s_shared_empty && r_sel_pending_valid;

  assign s_mode_payload = pack_event_payload(
    SYS_SRC_ID,
    EV_MODE_CHANGE,
    r_timestamp_ms,
    {24'h0, sel_to_u8(r_log_src_sel)},
    {24'h0, sel_to_u8(r_sel_pending)},
    32'h00000000
  );

  assign s_reset_payload = pack_event_payload(
    SYS_SRC_ID,
    EV_RESET_ACK,
    r_timestamp_ms,
    32'h00000000,
    32'h00000000,
    32'h00000000
  );

  // System queue source priority:
  //   1) mode-change notification (generated at apply time)
  //   2) reset-ack response
  always_comb begin
    s_push_req  = 1'b0;
    s_push_data = 128'h0;
    s_push_sel  = SYS_PUSH_NONE;

    if (s_apply_sel_now) begin
      s_push_req  = 1'b1;
      s_push_data = s_mode_payload;
      s_push_sel  = SYS_PUSH_MODE;
    end else if (r_reset_ack_pending) begin
      s_push_req  = 1'b1;
      s_push_data = s_reset_payload;
      s_push_sel  = SYS_PUSH_RESET;
    end
  end

  assign s_do_push        = s_push_req && !s_sys_q_full;
  assign s_sys_q_drop     = s_push_req && s_sys_q_full;

  // Producer arbitration into shared FIFO (every cycle).
  // Priority is fixed: system queue first, then selected source tap.
  assign s_prod_has_sys   = !s_sys_q_empty;
  assign s_prod_has_src   = s_sys_q_empty && s_sel_tvalid;

  assign s_prod_take_sys  = s_prod_has_sys && !s_shared_full;
  assign s_prod_take_src  = s_prod_has_src && !s_shared_full;
  assign s_prod_drop_sys  = s_prod_has_sys && s_shared_full;
  assign s_prod_drop_src  = s_prod_has_src && s_shared_full;

  assign s_sys_pop        = s_prod_take_sys || s_prod_drop_sys;
  assign s_tap_pop        = (s_prod_take_src || s_prod_drop_src) ? s_sel_onehot : '0;

  assign s_shared_wr_en   = s_prod_take_sys || s_prod_take_src;
  assign s_shared_wr_data = s_prod_take_sys ? s_sys_q_rdata : s_sel_tdata;

  assign s_reset_clear    = s_do_push && (s_push_sel == SYS_PUSH_RESET);

  // Consumer read request from shared FIFO.
  assign s_shared_rd_en = s_tx_boundary_idle && (!r_shared_rd_pending) && (!s_shared_empty);

  //------------------------------------------------------------------------------
  // CLI command decode
  //------------------------------------------------------------------------------
  // DLE escapes the next byte so that control bytes can be forwarded to the
  // downstream ASCII command parser without triggering uart_log_cli side effects.
  assign s_cli_dle_escape     = s_uart_rx_valid && !r_cli_literal_pending && (s_uart_rx_data == CMD_LITERAL_NEXT);
  assign s_cli_forward_valid  = s_uart_rx_valid && !s_cli_dle_escape;
  assign s_cli_forward_data   = s_uart_rx_data;
  assign s_cmd_soft_reset     = s_uart_rx_valid && !r_cli_literal_pending && (s_uart_rx_data == CMD_SOFT_RESET);
  assign s_cmd_next_src       = s_uart_rx_valid && !r_cli_literal_pending && (s_uart_rx_data == CMD_NEXT_SRC);
  assign s_cmd_prev_src       = s_uart_rx_valid && !r_cli_literal_pending && (s_uart_rx_data == CMD_PREV_SRC);

  //------------------------------------------------------------------------------
  // Timestamp generator
  //------------------------------------------------------------------------------
  // Generates a free-running millisecond timestamp used in every event payload.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_ms_div_cnt   <= '0;
      r_timestamp_ms <= '0;
    end else begin
      if (MS_TICK_CNT <= 1) begin
        r_timestamp_ms <= r_timestamp_ms + 1'b1;
      end else if (r_ms_div_cnt == MS_TICK_CNT - 1) begin
        r_ms_div_cnt   <= '0;
        r_timestamp_ms <= r_timestamp_ms + 1'b1;
      end else begin
        r_ms_div_cnt   <= r_ms_div_cnt + 1'b1;
      end
    end
  end

  //------------------------------------------------------------------------------
  // CLI byte forwarding and side-effect pulses
  //------------------------------------------------------------------------------
  // Forwards all non-DLE bytes to the downstream CLI parser. A DLE byte consumes
  // the next byte as literal data and suppresses source/reset side effects.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      O_SOFT_RESET_REQ      <= 1'b0;
      O_CLI_RX_VALID        <= 1'b0;
      O_CLI_RX_DATA         <= 8'h00;
      r_cli_literal_pending <= 1'b0;
    end else begin
      O_SOFT_RESET_REQ <= 1'b0;
      O_CLI_RX_VALID   <= 1'b0;

      if (s_cli_forward_valid) begin
        O_CLI_RX_VALID <= 1'b1;
        O_CLI_RX_DATA  <= s_cli_forward_data;
      end

      if (s_uart_rx_valid) begin
        if (r_cli_literal_pending) begin
          r_cli_literal_pending <= 1'b0;
        end else if (s_uart_rx_data == uart_log_cli_pkg::CMD_LITERAL_NEXT) begin
          r_cli_literal_pending <= 1'b1;
        end
      end

      if (s_cmd_soft_reset) begin
        O_SOFT_RESET_REQ <= 1'b1;
      end
    end
  end

  //------------------------------------------------------------------------------
  // Source selection control
  //------------------------------------------------------------------------------
  // Queues source-select requests from CLI bytes and applies them only at a frame
  // boundary after all already-selected source payloads have drained.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_log_src_sel       <= '0;
      r_sel_pending_valid <= 1'b0;
      r_sel_pending       <= '0;
    end else begin
      if (s_apply_sel_now) begin
        r_log_src_sel       <= r_sel_pending;
        r_sel_pending_valid <= 1'b0;
      end else if (s_cmd_next_src) begin
        if (r_sel_pending_valid) begin
          r_sel_pending <= sel_next_local(r_sel_pending);
        end else begin
          r_sel_pending <= sel_next_local(r_log_src_sel);
        end
        r_sel_pending_valid <= 1'b1;
      end else if (s_cmd_prev_src) begin
        if (r_sel_pending_valid) begin
          r_sel_pending <= sel_prev_local(r_sel_pending);
        end else begin
          r_sel_pending <= sel_prev_local(r_log_src_sel);
        end
        r_sel_pending_valid <= 1'b1;
      end
    end
  end

  //------------------------------------------------------------------------------
  // Reset-ack pending flag
  //------------------------------------------------------------------------------
  // Keeps reset acknowledgement pending until the corresponding system event is
  // actually pushed. A new soft-reset command wins over a simultaneous clear.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_reset_ack_pending <= 1'b0;
    end else if (s_cmd_soft_reset) begin
      r_reset_ack_pending <= 1'b1;
    end else if (s_reset_clear) begin
      r_reset_ack_pending <= 1'b0;
    end
  end

  //------------------------------------------------------------------------------
  // System-event queue
  //------------------------------------------------------------------------------
  // Queues source-change and reset-ack payloads before the shared event FIFO.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_sys_q_wr_ptr <= '0;
      r_sys_q_rd_ptr <= '0;
      r_sys_q_count  <= '0;
      r_sys_q_mem    <= '{default: 128'h0};
    end else begin
      if (s_do_push) begin
        r_sys_q_mem[r_sys_q_wr_ptr] <= s_push_data;
        if (r_sys_q_wr_ptr == SYS_Q_DEPTH - 1) begin
          r_sys_q_wr_ptr <= '0;
        end else begin
          r_sys_q_wr_ptr <= r_sys_q_wr_ptr + 1'b1;
        end
      end

      if (s_sys_pop) begin
        if (r_sys_q_rd_ptr == SYS_Q_DEPTH - 1) begin
          r_sys_q_rd_ptr <= '0;
        end else begin
          r_sys_q_rd_ptr <= r_sys_q_rd_ptr + 1'b1;
        end
      end

      case ({s_do_push, s_sys_pop})
        2'b10: r_sys_q_count <= r_sys_q_count + 1'b1;
        2'b01: r_sys_q_count <= r_sys_q_count - 1'b1;
        default: r_sys_q_count <= r_sys_q_count;
      endcase
    end
  end

  //------------------------------------------------------------------------------
  // Shared FIFO drop counters
  //------------------------------------------------------------------------------
  // Counts system/source payloads discarded because the shared event FIFO is full.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_drop_shared_sys_cnt <= 32'd0;
      r_drop_shared_src_cnt <= 32'd0;
    end else begin
      if (s_prod_drop_sys) begin
        r_drop_shared_sys_cnt <= r_drop_shared_sys_cnt + 1'b1;
      end
      if (s_prod_drop_src) begin
        r_drop_shared_src_cnt <= r_drop_shared_src_cnt + 1'b1;
      end
    end
  end

  //------------------------------------------------------------------------------
  // Shared FIFO read-pending tracker
  //------------------------------------------------------------------------------
  // Tracks the one-cycle-later read data return from the synchronous FIFO.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_shared_rd_pending <= 1'b0;
    end else begin
      if (r_shared_rd_pending) begin
        r_shared_rd_pending <= 1'b0;
      end else if (s_shared_rd_en) begin
        r_shared_rd_pending <= 1'b1;
      end
    end
  end

  //------------------------------------------------------------------------------
  // Frame latch and UART byte scheduler
  //------------------------------------------------------------------------------
  // TX_IDLE waits for a latched frame byte and emits a one-cycle UART start.
  // TX_WAIT_DONE advances to the next byte after uart_tx_stream completes.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_frame_active    <= 1'b0;
      r_frame_byte_idx  <= '0;
      r_frame_seq       <= 8'h00;
      r_frame_payload   <= 128'h0;
      r_frame_crc       <= 8'h00;
      r_seq_counter     <= 8'h00;
      r_tx_state        <= TX_IDLE;
      r_uart_tx_start   <= 1'b0;
      r_uart_tx_data    <= 8'h00;
    end else begin
      r_uart_tx_start   <= 1'b0;

      if (r_shared_rd_pending) begin
        r_frame_payload  <= s_shared_rd_data;
        r_frame_seq      <= r_seq_counter;
        r_frame_crc      <= calc_frame_crc(r_seq_counter, s_shared_rd_data);
        r_seq_counter    <= r_seq_counter + 1'b1;
        r_frame_byte_idx <= 5'd0;
        r_frame_active   <= 1'b1;
        r_uart_tx_data   <= frame_byte_at(
          5'd0,
          r_seq_counter,
          s_shared_rd_data,
          calc_frame_crc(r_seq_counter, s_shared_rd_data)
        );
      end

      case (r_tx_state)
        TX_IDLE: begin
          if (r_frame_active && !s_uart_tx_busy) begin
            r_uart_tx_start <= 1'b1;
            r_tx_state      <= TX_WAIT_DONE;
          end
        end

        TX_WAIT_DONE: begin
          if (s_uart_tx_done) begin
            if (r_frame_byte_idx == 5'd18) begin
              r_frame_byte_idx <= 5'd0;
              r_frame_active   <= 1'b0;
            end else begin
              r_frame_byte_idx <= r_frame_byte_idx + 1'b1;
              r_uart_tx_data   <= frame_byte_at(
                r_frame_byte_idx + 1'b1,
                r_frame_seq,
                r_frame_payload,
                r_frame_crc
              );
            end
            r_tx_state <= TX_IDLE;
          end
        end
      endcase

    end
  end

endmodule
