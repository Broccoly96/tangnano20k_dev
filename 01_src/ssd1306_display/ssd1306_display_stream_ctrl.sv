`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : ssd1306_display_stream_ctrl.sv
// Purpose      : SSD1306 display controller with streaming frame-byte fetch.
// Behavior     : Reuses the SSD1306 command serializer but requests each frame
//                byte on demand instead of latching a full frame upfront.
// Usage        : Assert `I_REQ_VALID` for one cycle while `O_REQ_READY` is
//                high. When `O_FRAME_BYTE_REQ` is asserted, return the selected
//                byte on `I_FRAME_BYTE_DATA` with `I_FRAME_BYTE_VALID`.
// Example      : A host bridge can stream bytes from SDRAM or a local line
//                buffer without constructing a 512-byte request vector.
//////////////////////////////////////////////////////////////////////////////////

module ssd1306_display_stream_ctrl #(
  parameter int unsigned CLK_HZ          = 24_000_000,
  parameter int unsigned I2C_BIT_RATE_HZ = 400_000,
  parameter logic [6:0]  I2C_SLAVE_ADDR  =
    ssd1306_uart_proto_pkg::SSD1306_DEFAULT_SLAVE_ADDR
) (
  input  logic I_CLK,
  input  logic I_RST_N,
  input  logic I_REQ_VALID,
  output logic O_REQ_READY,
  input  logic [2:0] I_REQ_OP,
  output logic O_FRAME_BYTE_REQ,
  output logic [((ssd1306_uart_proto_pkg::SSD1306_FRAME_BYTES <= 1) ? 1 :
                 $clog2(ssd1306_uart_proto_pkg::SSD1306_FRAME_BYTES))-1:0]
    O_FRAME_BYTE_IDX,
  input  logic I_FRAME_BYTE_VALID,
  input  logic [7:0] I_FRAME_BYTE_DATA,
  output logic O_DONE_VALID,
  output logic [2:0] O_DONE_OP,
  output logic O_DONE_OK,
  output logic [31:0] O_DONE_STATUS,
  output logic [31:0] O_DONE_DETAIL,
  output logic O_BUSY,
  input  logic I_I2C_SDA_IN,
  input  logic I_I2C_SCL_IN,
  output logic O_I2C_SDA_DRIVE_LOW,
  output logic O_I2C_SCL_DRIVE_LOW
);

  import ssd1306_uart_proto_pkg::*;

  localparam logic [1:0] BYTE_OP_READ  = 2'd0;
  localparam logic [1:0] BYTE_OP_START = 2'd1;
  localparam logic [1:0] BYTE_OP_STOP  = 2'd2;
  localparam logic [1:0] BYTE_OP_WRITE = 2'd3;

  localparam int unsigned INIT_CMD_BYTES   = 25;
  localparam int unsigned SETUP_CMD_BYTES  = 8;
  localparam int unsigned FRAME_DATA_BYTES = SSD1306_FRAME_BYTES;
  localparam int unsigned MAX_SEQ_BYTES    =
    1 + 1 + SETUP_CMD_BYTES + 1 + FRAME_DATA_BYTES;
  localparam int unsigned STEP_W =
    (MAX_SEQ_BYTES <= 1) ? 1 : $clog2(MAX_SEQ_BYTES);
  localparam int unsigned FRAME_BYTE_IDX_W =
    (SSD1306_FRAME_BYTES <= 1) ? 1 : $clog2(SSD1306_FRAME_BYTES);

  // FSM overview:
  // - ST_IDLE waits for a request.
  // - ST_ISSUE_START / ST_WAIT_START emit START.
  // - ST_WAIT_FRAME_BYTE stalls until a requested frame byte is available.
  // - ST_ISSUE_BYTE / ST_WAIT_BYTE transmit one byte and check ACK.
  // - ST_ISSUE_STOP / ST_WAIT_STOP close the current transaction phase.
  // Flow:
  //   ST_IDLE -> ST_ISSUE_START -> ST_WAIT_START
  //   -> {ST_WAIT_FRAME_BYTE, ST_ISSUE_BYTE}
  //   -> ST_ISSUE_BYTE -> ST_WAIT_BYTE
  //   -> {ST_WAIT_FRAME_BYTE, ST_ISSUE_BYTE, ST_ISSUE_STOP}
  //   -> ST_WAIT_STOP -> {ST_ISSUE_START for phase-2 data, ST_IDLE}
  // Transition conditions:
  // - Streaming frame writes enter ST_WAIT_FRAME_BYTE for payload bytes only.
  // - `I_FRAME_BYTE_VALID` or the registered one-cycle hold releases the wait.
  // - A write NACK captures detail in `O_DONE_DETAIL` and forces STOP.
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_ISSUE_START,
    ST_WAIT_START,
    ST_WAIT_FRAME_BYTE,
    ST_ISSUE_BYTE,
    ST_WAIT_BYTE,
    ST_ISSUE_STOP,
    ST_WAIT_STOP
  } st_state_e;

  st_state_e st_state;

  logic [2:0] r_active_op;
  logic [STEP_W-1:0] r_step_idx;
  logic r_txn_phase;
  logic [31:0] r_done_status;
  logic [31:0] r_done_detail;
  logic r_done_valid;
  logic r_done_ok;
  logic [2:0] r_done_op;

  logic r_byte_op_valid;
  logic [1:0] r_byte_op;
  logic [7:0] r_byte_wr_data;
  logic r_frame_byte_valid;
  logic r_byte_rd_send_ack;
  logic l_byte_op_ready;
  logic l_byte_done;
  logic l_byte_ack_ok;

  assign O_REQ_READY      = (st_state == ST_IDLE);
  assign O_DONE_VALID     = r_done_valid;
  assign O_DONE_OP        = r_done_op;
  assign O_DONE_OK        = r_done_ok;
  assign O_DONE_STATUS    = r_done_status;
  assign O_DONE_DETAIL    = r_done_detail;
  assign O_BUSY           = (st_state != ST_IDLE);
  assign O_FRAME_BYTE_REQ = (st_state == ST_WAIT_FRAME_BYTE);
  assign O_FRAME_BYTE_IDX =
    ((r_active_op == DISP_OP_FRAME_WRITE) &&
     r_txn_phase &&
     (r_step_idx >= 2)) ? FRAME_BYTE_IDX_W'(r_step_idx - 2) : '0;

  function automatic logic [31:0] pack_i2c_nack_detail(
    input logic [2:0] req_op,
    input logic txn_phase,
    input logic [STEP_W-1:0] byte_idx,
    input logic [7:0] wr_data,
    input logic scl_in,
    input logic sda_in
  );
    begin
      pack_i2c_nack_detail = {
        wr_data,
        8'(byte_idx),
        4'h0,
        req_op,
        txn_phase,
        2'b00,
        scl_in,
        sda_in
      };
    end
  endfunction

  function automatic logic [7:0] init_cmd_byte(input logic [4:0] init_idx);
    begin
      case (init_idx)
        5'd0: init_cmd_byte = 8'hAE;
        5'd1: init_cmd_byte = 8'hD5;
        5'd2: init_cmd_byte = 8'h80;
        5'd3: init_cmd_byte = 8'hA8;
        5'd4: init_cmd_byte = 8'h1F;
        5'd5: init_cmd_byte = 8'hD3;
        5'd6: init_cmd_byte = 8'h00;
        5'd7: init_cmd_byte = 8'h40;
        5'd8: init_cmd_byte = 8'h8D;
        5'd9: init_cmd_byte = 8'h14;
        5'd10: init_cmd_byte = 8'h20;
        5'd11: init_cmd_byte = 8'h00;
        5'd12: init_cmd_byte = 8'hA1;
        5'd13: init_cmd_byte = 8'hC8;
        5'd14: init_cmd_byte = 8'hDA;
        5'd15: init_cmd_byte = 8'h02;
        5'd16: init_cmd_byte = 8'h81;
        5'd17: init_cmd_byte = 8'h8F;
        5'd18: init_cmd_byte = 8'hD9;
        5'd19: init_cmd_byte = 8'hF1;
        5'd20: init_cmd_byte = 8'hDB;
        5'd21: init_cmd_byte = 8'h40;
        5'd22: init_cmd_byte = 8'hA4;
        5'd23: init_cmd_byte = 8'hA6;
        default: init_cmd_byte = 8'hAF;
      endcase
    end
  endfunction

  function automatic int unsigned seq_len(
    input logic [2:0] req_op,
    input logic txn_phase
  );
    begin
      case (req_op)
        DISP_OP_INIT: begin
          seq_len = 1 + 1 + INIT_CMD_BYTES;
        end
        DISP_OP_CLEAR,
        DISP_OP_FRAME_WRITE: begin
          if (!txn_phase) begin
            seq_len = 1 + 1 + SETUP_CMD_BYTES;
          end else begin
            seq_len = 1 + 1 + FRAME_DATA_BYTES;
          end
        end
        DISP_OP_ON,
        DISP_OP_OFF: begin
          seq_len = 1 + 1 + 1;
        end
        default: begin
          seq_len = 1 + 1 + 1;
        end
      endcase
    end
  endfunction

  function automatic logic [7:0] setup_cmd_byte(input logic [2:0] setup_idx);
    begin
      case (setup_idx)
        3'd0: setup_cmd_byte = 8'h20;
        3'd1: setup_cmd_byte = 8'h00;
        3'd2: setup_cmd_byte = 8'h21;
        3'd3: setup_cmd_byte = 8'h00;
        3'd4: setup_cmd_byte = 8'h7F;
        3'd5: setup_cmd_byte = 8'h22;
        3'd6: setup_cmd_byte = 8'h00;
        default: setup_cmd_byte = 8'h03;
      endcase
    end
  endfunction

  function automatic logic [7:0] seq_byte(
    input logic [2:0] req_op,
    input logic txn_phase,
    input int unsigned byte_idx
  );
    begin
      seq_byte = 8'h00;

      case (req_op)
        DISP_OP_INIT: begin
          if (byte_idx == 0) begin
            seq_byte = ssd1306_i2c_addr_byte(I2C_SLAVE_ADDR, 1'b0);
          end else if (byte_idx == 1) begin
            seq_byte = SSD1306_CTRL_CMD;
          end else begin
            seq_byte = init_cmd_byte(byte_idx - 2);
          end
        end

        DISP_OP_CLEAR,
        DISP_OP_FRAME_WRITE: begin
          if (byte_idx == 0) begin
            seq_byte = ssd1306_i2c_addr_byte(I2C_SLAVE_ADDR, 1'b0);
          end else if (!txn_phase && (byte_idx == 1)) begin
            seq_byte = SSD1306_CTRL_CMD;
          end else if (!txn_phase && (byte_idx < (2 + SETUP_CMD_BYTES))) begin
            seq_byte = setup_cmd_byte(byte_idx - 2);
          end else if (txn_phase && (byte_idx == 1)) begin
            seq_byte = SSD1306_CTRL_DATA;
          end else if (req_op == DISP_OP_CLEAR) begin
            seq_byte = 8'h00;
          end else begin
            seq_byte = I_FRAME_BYTE_DATA;
          end
        end

        DISP_OP_ON: begin
          if (byte_idx == 0) begin
            seq_byte = ssd1306_i2c_addr_byte(I2C_SLAVE_ADDR, 1'b0);
          end else if (byte_idx == 1) begin
            seq_byte = SSD1306_CTRL_CMD;
          end else begin
            seq_byte = 8'hAF;
          end
        end

        default: begin
          if (byte_idx == 0) begin
            seq_byte = ssd1306_i2c_addr_byte(I2C_SLAVE_ADDR, 1'b0);
          end else if (byte_idx == 1) begin
            seq_byte = SSD1306_CTRL_CMD;
          end else begin
            seq_byte = 8'hAE;
          end
        end
      endcase
    end
  endfunction

  eeprom_i2c_byte_ctrl #(
    .CLK_HZ          (CLK_HZ),
    .I2C_BIT_RATE_HZ (I2C_BIT_RATE_HZ)
  ) u_eeprom_i2c_byte_ctrl (
    .I_CLK           (I_CLK),
    .I_RST_N         (I_RST_N),
    .I_OP_VALID      (r_byte_op_valid),
    .O_OP_READY      (l_byte_op_ready),
    .I_OP            (r_byte_op),
    .I_WR_DATA       (r_byte_wr_data),
    .I_RD_SEND_ACK   (r_byte_rd_send_ack),
    .I_SDA_IN        (I_I2C_SDA_IN),
    .I_SCL_IN        (I_I2C_SCL_IN),
    .O_SDA_DRIVE_LOW (O_I2C_SDA_DRIVE_LOW),
    .O_SCL_DRIVE_LOW (O_I2C_SCL_DRIVE_LOW),
    .O_DONE          (l_byte_done),
    .O_ACK_OK        (l_byte_ack_ok),
    .O_RD_DATA       (),
    .O_BUSY          ()
  );

  // Issues one START / WRITE / STOP pulse per FSM issue state and preserves a
  // latched frame-byte valid indication while the controller waits to consume it.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_byte_op_valid    <= 1'b0;
      r_byte_op          <= BYTE_OP_READ;
      r_byte_wr_data     <= 8'h00;
      r_frame_byte_valid <= 1'b0;
      r_byte_rd_send_ack <= 1'b0;
    end else begin
      r_byte_op_valid    <= 1'b0;
      r_byte_rd_send_ack <= 1'b0;

      if (st_state != ST_WAIT_FRAME_BYTE) begin
        r_frame_byte_valid <= 1'b0;
      end

      case (st_state)
        ST_ISSUE_START: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_START;
          end
        end

        ST_ISSUE_BYTE: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_WRITE;
            if ((r_active_op == DISP_OP_FRAME_WRITE) &&
                r_txn_phase &&
                (r_step_idx >= 2)) begin
              if (!r_frame_byte_valid) begin
                r_byte_wr_data <= I_FRAME_BYTE_DATA;
              end
            end else begin
              r_byte_wr_data <= seq_byte(
                r_active_op,
                r_txn_phase,
                r_step_idx
              );
            end
          end
        end

        ST_ISSUE_STOP: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_STOP;
          end
        end

        default: begin
        end
      endcase

      if ((st_state == ST_WAIT_FRAME_BYTE) && I_FRAME_BYTE_VALID) begin
        r_frame_byte_valid <= 1'b1;
        r_byte_wr_data     <= I_FRAME_BYTE_DATA;
      end
    end
  end

  // Holds streaming request context, stalls for requested frame bytes, and
  // reports detailed NACK context when the byte controller rejects a transfer.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state      <= ST_IDLE;
      r_active_op   <= DISP_OP_OFF;
      r_step_idx    <= '0;
      r_txn_phase   <= 1'b0;
      r_done_status <= 32'h0000_0000;
      r_done_detail <= 32'h0000_0000;
      r_done_valid  <= 1'b0;
      r_done_ok     <= 1'b0;
      r_done_op     <= DISP_OP_OFF;
    end else begin
      r_done_valid <= 1'b0;

      case (st_state)
        ST_IDLE: begin
          if (I_REQ_VALID) begin
            r_active_op   <= I_REQ_OP;
            r_step_idx    <= '0;
            r_txn_phase   <= 1'b0;
            r_done_status <= 32'h0000_0000;
            r_done_detail <= 32'h0000_0000;
            r_done_ok     <= 1'b0;
            r_done_op     <= I_REQ_OP;
            st_state      <= ST_ISSUE_START;
          end
        end

        ST_ISSUE_START: begin
          if (l_byte_op_ready) begin
            st_state <= ST_WAIT_START;
          end
        end

        ST_WAIT_START: begin
          if (l_byte_done) begin
            if ((r_active_op == DISP_OP_FRAME_WRITE) &&
                r_txn_phase &&
                (r_step_idx >= 2)) begin
              st_state <= ST_WAIT_FRAME_BYTE;
            end else begin
              st_state <= ST_ISSUE_BYTE;
            end
          end
        end

        ST_WAIT_FRAME_BYTE: begin
          if (I_FRAME_BYTE_VALID || r_frame_byte_valid) begin
            st_state <= ST_ISSUE_BYTE;
          end
        end

        ST_ISSUE_BYTE: begin
          if (l_byte_op_ready) begin
            st_state <= ST_WAIT_BYTE;
          end
        end

        ST_WAIT_BYTE: begin
          if (l_byte_done) begin
            if (!l_byte_ack_ok) begin
              r_done_status <= ERR_I2C_NACK;
              r_done_detail <= pack_i2c_nack_detail(
                r_active_op,
                r_txn_phase,
                r_step_idx,
                r_byte_wr_data,
                I_I2C_SCL_IN,
                I_I2C_SDA_IN
              );
              st_state <= ST_ISSUE_STOP;
            end else if (r_step_idx + 1'b1 >=
                         seq_len(r_active_op, r_txn_phase)) begin
              st_state <= ST_ISSUE_STOP;
            end else begin
              r_step_idx <= r_step_idx + 1'b1;
              if ((r_active_op == DISP_OP_FRAME_WRITE) &&
                  r_txn_phase &&
                  ((r_step_idx + 1'b1) >= 2)) begin
                st_state <= ST_WAIT_FRAME_BYTE;
              end else begin
                st_state <= ST_ISSUE_BYTE;
              end
            end
          end
        end

        ST_ISSUE_STOP: begin
          if (l_byte_op_ready) begin
            st_state <= ST_WAIT_STOP;
          end
        end

        default: begin
          if (l_byte_done) begin
            if ((r_done_status == 32'h0000_0000) &&
                !r_txn_phase &&
                ((r_active_op == DISP_OP_CLEAR) ||
                 (r_active_op == DISP_OP_FRAME_WRITE))) begin
              r_txn_phase <= 1'b1;
              r_step_idx  <= '0;
              st_state    <= ST_ISSUE_START;
            end else begin
              r_done_valid <= 1'b1;
              r_done_ok    <= (r_done_status == 32'h0000_0000);
              st_state     <= ST_IDLE;
            end
          end
        end
      endcase
    end
  end

endmodule
