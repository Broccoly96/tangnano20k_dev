//////////////////////////////////////////////////////////////////////////////////
// File         : uart_log_cli_tb_tasks.svh
// Description  : Reusable helper tasks for uart_log_cli testbenches.
//                This file is included from the TB top and keeps helper logic
//                out of testcase files so testcase files can stay single-initial.
//////////////////////////////////////////////////////////////////////////////////

//------------------------------------------------------------------------------
// init_testbench
//------------------------------------------------------------------------------
// Releases reset and waits until DUT reset domain is ready for traffic.
task automatic init_testbench(input string tb_name);
  int timeout;
  begin
    timeout = 0;
    src_evt_valid = '0;
    src_evt_id    = '0;
    src_arg0      = '0;
    src_arg1      = '0;
    src_arg2      = '0;

    repeat (10) @(posedge clk_50m_ext);
    rst_testbench_n = 1'b1;

    while (!l_o_rst_fpga_n) begin
      @(posedge clk_50m_ext);
      timeout++;
      if (timeout > 1000000) begin
        tb_log_pkg::log_fatal(1, "INIT", "Reset deassert timeout.");
      end
    end

    $display("===== START %s TESTBENCH =====", tb_name);
  end
endtask

//------------------------------------------------------------------------------
// send_source_event
//------------------------------------------------------------------------------
// Drives one source event into the selected source input path.
// The task waits for source enable + ready handshake and emits one-cycle valid.
task automatic send_source_event(
  input int unsigned src_idx,
  input logic [7:0]  event_id,
  input logic [31:0] arg0,
  input logic [31:0] arg1,
  input logic [31:0] arg2
);
  int timeout;
  begin
    if (src_idx >= NUM_SRC) begin
      tb_log_pkg::log_fatal(1, "DRV", $sformatf("Invalid src_idx=%0d (NUM_SRC=%0d)", src_idx, NUM_SRC));
    end

    src_evt_id[src_idx*8 +: 8]     = event_id;
    src_arg0[src_idx*32 +: 32]     = arg0;
    src_arg1[src_idx*32 +: 32]     = arg1;
    src_arg2[src_idx*32 +: 32]     = arg2;

    timeout = 0;
    while (!(src_enable[src_idx] && src_evt_ready[src_idx])) begin
      @(posedge clk_50m_ext);
      timeout++;
      if (timeout > 1000000) begin
        tb_log_pkg::log_fatal(1, "DRV", $sformatf("Source %0d handshake timeout", src_idx));
      end
    end

    src_evt_valid[src_idx] = 1'b1;
    @(posedge clk_50m_ext);
    src_evt_valid[src_idx] = 1'b0;
  end
endtask

//------------------------------------------------------------------------------
// recv_frame
//------------------------------------------------------------------------------
// Receives one full UART log frame (19 bytes) using uart_receiver mailbox API
// and reconstructs the packed frame representation for scoreboarding.
task automatic recv_frame(output uart_log_cli_tb_pkg::uart_log_frame_t frame);
  logic [7:0] byte_data;
  logic [7:0] frame_bytes [0:18];
  begin
    for (int idx = 0; idx < 19; idx++) begin
      u0_uart_rcv.get_byte(byte_data);
      frame_bytes[idx] = byte_data;
    end

    frame.sync = frame_bytes[0];
    frame.seq  = frame_bytes[1];
    for (int idx = 0; idx < 16; idx++) begin
      frame.payload[idx*8 +: 8] = frame_bytes[idx+2];
    end
    frame.crc = frame_bytes[18];
  end
endtask

//------------------------------------------------------------------------------
// check_frame_integrity
//------------------------------------------------------------------------------
// Verifies SYNC and CRC for one frame.
task automatic check_frame_integrity(
  input uart_log_cli_tb_pkg::uart_log_frame_t frame,
  input string context_name
);
  logic [7:0] exp_crc;
  begin
    if (frame.sync !== uart_log_cli_pkg::UART_SYNC_BYTE) begin
      tb_log_pkg::log_fatal(1, "FRAME", $sformatf("[%s] Bad sync: 0x%02h", context_name, frame.sync));
    end

    exp_crc = uart_log_cli_tb_pkg::calc_expected_crc(frame);
    if (frame.crc !== exp_crc) begin
      tb_log_pkg::log_fatal(
        1,
        "FRAME",
        $sformatf("[%s] CRC mismatch: exp=0x%02h act=0x%02h", context_name, exp_crc, frame.crc)
      );
    end
  end
endtask

//------------------------------------------------------------------------------
// check_and_advance_seq
//------------------------------------------------------------------------------
// Enforces sequence continuity for each newly received frame.
task automatic check_and_advance_seq(
  input uart_log_cli_tb_pkg::uart_log_frame_t frame,
  inout bit seq_seen,
  inout logic [7:0] next_seq,
  input string context_name
);
  begin
    if (!seq_seen) begin
      seq_seen = 1'b1;
      next_seq = frame.seq + 1'b1;
    end else begin
      if (frame.seq !== next_seq) begin
        tb_log_pkg::log_fatal(
          1,
          "SEQ",
          $sformatf("[%s] SEQ mismatch: exp=0x%02h act=0x%02h", context_name, next_seq, frame.seq)
        );
      end
      next_seq = next_seq + 1'b1;
    end
  end
endtask
