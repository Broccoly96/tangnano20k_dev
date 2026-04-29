`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : ssd1306_display_ctrl.sv
// Purpose      : Request-driven SSD1306 I2C command sequencer.
// Behavior     : Accepts one high-level display request at a time and expands it
//                into START, byte-write, and STOP transactions on the shared
//                `eeprom_i2c_byte_ctrl` primitive.
// Usage        : Drive `I_REQ_VALID` for one cycle while `O_REQ_READY` is high.
//                Wait for `O_DONE_VALID` to observe completion status.
// Example      : `DISP_OP_INIT` initializes the panel.
//                `DISP_OP_FRAME_WRITE` writes the full 128x32 framebuffer.
//////////////////////////////////////////////////////////////////////////////////

module ssd1306_display_ctrl #(
  parameter int unsigned CLK_HZ               = 24_000_000,
  parameter int unsigned I2C_BIT_RATE_HZ      = 400_000,
  parameter logic [6:0]  I2C_SLAVE_ADDR       =
    ssd1306_uart_proto_pkg::SSD1306_DEFAULT_SLAVE_ADDR,
  parameter bit          LATCH_REQ_FRAME_DATA = 1'b1
) (
  input  logic I_CLK,
  input  logic I_RST_N,
  input  logic I_REQ_VALID,
  output logic O_REQ_READY,
  input  logic [2:0] I_REQ_OP,
  input  logic [(ssd1306_uart_proto_pkg::SSD1306_FRAME_BYTES*8)-1:0]
    I_REQ_FRAME_DATA,
  output logic O_DONE_VALID,
  output logic [2:0] O_DONE_OP,
  output logic O_DONE_OK,
  output logic [31:0] O_DONE_STATUS,
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

  // FSM overview:
  // - ST_IDLE waits for a new request and captures request context.
  // - ST_ISSUE_START / ST_WAIT_START emit the I2C START condition.
  // - ST_ISSUE_BYTE / ST_WAIT_BYTE send one byte at a time and check ACK.
  // - ST_ISSUE_STOP / ST_WAIT_STOP emit STOP and either finish or launch the
  //   data phase for CLEAR / FRAME_WRITE.
  // Flow:
  //   ST_IDLE -> ST_ISSUE_START -> ST_WAIT_START -> ST_ISSUE_BYTE
  //   -> ST_WAIT_BYTE -> {ST_ISSUE_BYTE, ST_ISSUE_STOP}
  //   -> ST_WAIT_STOP -> {ST_ISSUE_START for phase-2 data, ST_IDLE}
  // Transition conditions:
  // - Issue states advance when `l_byte_op_ready` is asserted.
  // - Wait states advance when `l_byte_done` is asserted.
  // - Any write NACK stores `ERR_I2C_NACK` and forces STOP.
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_ISSUE_START,
    ST_WAIT_START,
    ST_ISSUE_BYTE,
    ST_WAIT_BYTE,
    ST_ISSUE_STOP,
    ST_WAIT_STOP
  } st_state_e;

  st_state_e st_state;

  logic [2:0] r_active_op;
  logic [7:0] r_active_frame_data [0:SSD1306_FRAME_BYTES-1];
  logic [STEP_W-1:0] r_step_idx;
  logic r_txn_phase;
  logic [31:0] r_done_status;
  logic r_done_valid;
  logic r_done_ok;
  logic [2:0] r_done_op;

  logic r_byte_op_valid;
  logic [1:0] r_byte_op;
  logic [7:0] r_byte_wr_data;
  logic r_byte_rd_send_ack;
  logic l_byte_op_ready;
  logic l_byte_done;
  logic l_byte_ack_ok;

  assign O_REQ_READY   = (st_state == ST_IDLE);
  assign O_DONE_VALID  = r_done_valid;
  assign O_DONE_OP     = r_done_op;
  assign O_DONE_OK     = r_done_ok;
  assign O_DONE_STATUS = r_done_status;
  assign O_BUSY        = (st_state != ST_IDLE);

  function automatic logic [7:0] init_cmd_byte(input logic [4:0] init_idx);
    begin
      case (init_idx)
        5'd0:     init_cmd_byte = 8'hAE;
        5'd1:     init_cmd_byte = 8'hD5;
        5'd2:     init_cmd_byte = 8'h80;
        5'd3:     init_cmd_byte = 8'hA8;
        5'd4:     init_cmd_byte = 8'h1F;
        5'd5:     init_cmd_byte = 8'hD3;
        5'd6:     init_cmd_byte = 8'h00;
        5'd7:     init_cmd_byte = 8'h40;
        5'd8:     init_cmd_byte = 8'h8D;
        5'd9:     init_cmd_byte = 8'h14;
        5'd10:    init_cmd_byte = 8'h20;
        5'd11:    init_cmd_byte = 8'h00;
        5'd12:    init_cmd_byte = 8'hA1;
        5'd13:    init_cmd_byte = 8'hC8;
        5'd14:    init_cmd_byte = 8'hDA;
        5'd15:    init_cmd_byte = 8'h02;
        5'd16:    init_cmd_byte = 8'h81;
        5'd17:    init_cmd_byte = 8'h8F;
        5'd18:    init_cmd_byte = 8'hD9;
        5'd19:    init_cmd_byte = 8'hF1;
        5'd20:    init_cmd_byte = 8'hDB;
        5'd21:    init_cmd_byte = 8'h40;
        5'd22:    init_cmd_byte = 8'hA4;
        5'd23:    init_cmd_byte = 8'hA6;
        default:  init_cmd_byte = 8'hAF;
      endcase
    end
  endfunction

  function automatic int unsigned seq_len(
    input logic [2:0] req_op,
    input logic txn_phase
  );
    begin
      case (req_op)
        DISP_OP_INIT:
                          seq_len = 1 + 1 + INIT_CMD_BYTES;
        DISP_OP_CLEAR,
        DISP_OP_FRAME_WRITE:
          if (!txn_phase) seq_len = 1 + 1 + SETUP_CMD_BYTES;
          else            seq_len = 1 + 1 + FRAME_DATA_BYTES;
        DISP_OP_ON,
        DISP_OP_OFF:
                          seq_len = 1 + 1 + 1;
        default:          seq_len = 1 + 1 + 1;
      endcase
    end
  endfunction

  function automatic logic [7:0] setup_cmd_byte(input logic [2:0] setup_idx);
    begin
      case (setup_idx)
        3'd0:     setup_cmd_byte = 8'h20;
        3'd1:     setup_cmd_byte = 8'h00;
        3'd2:     setup_cmd_byte = 8'h21;
        3'd3:     setup_cmd_byte = 8'h00;
        3'd4:     setup_cmd_byte = 8'h7F;
        3'd5:     setup_cmd_byte = 8'h22;
        3'd6:     setup_cmd_byte = 8'h00;
        default:  setup_cmd_byte = 8'h03;
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
          end else if (LATCH_REQ_FRAME_DATA) begin
            seq_byte = r_active_frame_data[byte_idx - 2];
          end else begin
            seq_byte = I_REQ_FRAME_DATA[(byte_idx - 2)*8 +: 8];
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

  // Issues exactly one byte-controller operation pulse per serialized I2C step.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_byte_op_valid    <= 1'b0;
      r_byte_op          <= BYTE_OP_READ;
      r_byte_wr_data     <= 8'h00;
      r_byte_rd_send_ack <= 1'b0;
    end else begin
      r_byte_op_valid    <= 1'b0;
      r_byte_rd_send_ack <= 1'b0;

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
            r_byte_wr_data  <= seq_byte(r_active_op, r_txn_phase, r_step_idx);
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
    end
  end

  // Holds request context, advances the transaction FSM, and reports
  // completion once all bytes of the active command phase are transferred.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    integer frame_idx;
    if (!I_RST_N) begin
      st_state      <= ST_IDLE;
      r_active_op   <= DISP_OP_OFF;
      r_step_idx    <= '0;
      r_txn_phase   <= 1'b0;
      r_done_status <= 32'h0000_0000;
      r_done_valid  <= 1'b0;
      r_done_ok     <= 1'b0;
      r_done_op     <= DISP_OP_OFF;
    end else begin
      r_done_valid <= 1'b0;

      case (st_state)
        ST_IDLE: begin
          if (I_REQ_VALID) begin
            r_active_op <= I_REQ_OP;
            if (LATCH_REQ_FRAME_DATA) begin
              for (frame_idx = 0;
                   frame_idx < SSD1306_FRAME_BYTES;
                   frame_idx++) begin
                r_active_frame_data[frame_idx] <=
                  I_REQ_FRAME_DATA[frame_idx*8 +: 8];
              end
            end
            r_step_idx    <= '0;
            r_txn_phase   <= 1'b0;
            r_done_status <= 32'h0000_0000;
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
              st_state      <= ST_ISSUE_STOP;
            end else if (r_step_idx + 1'b1 >=
                         seq_len(r_active_op, r_txn_phase)) begin
              st_state <= ST_ISSUE_STOP;
            end else begin
              r_step_idx <= r_step_idx + 1'b1;
              st_state   <= ST_ISSUE_BYTE;
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
