`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : eeprom_i2c_access_engine.sv
// Description  : 24FC1025 access engine for byte and chunked bulk operations.
//                - Single read/write requests emit one completion event.
//                - Raw bulk write uses page-program plus ACK polling.
//                - Raw bulk read performs random read followed by sequential
//                  byte reads within one 64 KiB block.
//////////////////////////////////////////////////////////////////////////////////

module eeprom_i2c_access_engine #(
  parameter int unsigned CLK_HZ                    = 48_000_000,
  parameter int unsigned I2C_BIT_RATE_HZ           = 100_000,
  parameter int unsigned WRITE_POLL_TIMEOUT_CYCLES = 480_000
) (
  input  logic I_CLK,
  input  logic I_RST_N,
  input  logic I_REQ_VALID,
  output logic O_REQ_READY,
  input  logic I_REQ_IS_WRITE,
  input  logic I_REQ_IS_RAW_BULK,
  input  logic [16:0] I_REQ_ADDR,
  input  logic [7:0]  I_REQ_COUNT,
  input  logic [(eeprom_uart_proto_pkg::MAX_BULK_PAYLOAD_BYTES*8)-1:0] I_REQ_RAW_WR_DATA,
  input  logic I_I2C_SDA_IN,
  input  logic I_I2C_SCL_IN,
  output logic O_I2C_SDA_DRIVE_LOW,
  output logic O_I2C_SCL_DRIVE_LOW,
  output logic O_EVT_VALID,
  input  logic I_EVT_READY,
  output logic [7:0]  O_EVT_ID,
  output logic [31:0] O_EVT_ARG0,
  output logic [31:0] O_EVT_ARG1,
  output logic [31:0] O_EVT_ARG2,
  output logic O_RAW_DONE,
  output logic O_RAW_ERR_VALID,
  output logic [31:0] O_RAW_ERR_CODE,
  output logic [(eeprom_uart_proto_pkg::MAX_BULK_PAYLOAD_BYTES*8)-1:0] O_RAW_RD_DATA,
  output logic O_BUSY
);

  import eeprom_uart_proto_pkg::*;

  localparam int unsigned TIMEOUT_W =
    (WRITE_POLL_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(WRITE_POLL_TIMEOUT_CYCLES + 1);

  localparam logic [1:0] BYTE_OP_READ  = 2'd0;
  localparam logic [1:0] BYTE_OP_START = 2'd1;
  localparam logic [1:0] BYTE_OP_STOP  = 2'd2;
  localparam logic [1:0] BYTE_OP_WRITE = 2'd3;

  typedef enum logic [4:0] {
    IDLE,
    ISSUE_START,
    WAIT_START,
    ISSUE_CTRL_WRITE,
    WAIT_CTRL_WRITE,
    ISSUE_ADDR_HI,
    WAIT_ADDR_HI,
    ISSUE_ADDR_LO,
    WAIT_ADDR_LO,
    ISSUE_WRITE_DATA,
    WAIT_WRITE_DATA,
    ISSUE_RSTART,
    WAIT_RSTART,
    ISSUE_CTRL_READ,
    WAIT_CTRL_READ,
    ISSUE_READ_DATA,
    WAIT_READ_DATA,
    ISSUE_STOP,
    WAIT_STOP,
    ISSUE_POLL_START,
    WAIT_POLL_START,
    ISSUE_POLL_CTRL,
    WAIT_POLL_CTRL,
    ISSUE_POLL_STOP,
    WAIT_POLL_STOP
  } st_state_e;

  typedef enum logic [1:0] {
    STOP_FINISH_OK,
    STOP_FINISH_EVT_ERR,
    STOP_FINISH_RAW_ERR,
    STOP_FINISH_POLL
  } stop_action_e;

  st_state_e      st_state;
  stop_action_e   r_stop_action;
  logic [16:0]    r_req_addr;
  logic [7:0]     r_req_count;
  logic           r_req_is_write;
  logic           r_req_is_raw_bulk;
  logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] r_req_raw_wr_data;
  logic [(MAX_BULK_PAYLOAD_BYTES*8)-1:0] r_raw_rd_data;
  logic [7:0]     r_data_index;
  logic [7:0]     r_last_read_byte;
  logic [31:0]    r_finish_error;
  logic [TIMEOUT_W-1:0] r_poll_timeout_cnt;

  logic           r_evt_valid;
  logic [7:0]     r_evt_id;
  logic [31:0]    r_evt_arg0;
  logic [31:0]    r_evt_arg1;
  logic [31:0]    r_evt_arg2;
  logic           r_raw_done;
  logic           r_raw_err_valid;
  logic [31:0]    r_raw_err_code;

  logic           r_byte_op_valid;
  logic [1:0]     r_byte_op;
  logic [7:0]     r_byte_wr_data;
  logic           r_byte_rd_send_ack;
  logic           l_byte_op_ready;
  logic           l_byte_done;
  logic           l_byte_ack_ok;
  logic [7:0]     l_byte_rd_data;

  assign O_REQ_READY     = (st_state == IDLE) && !r_evt_valid && !r_raw_done && !r_raw_err_valid;
  assign O_EVT_VALID     = r_evt_valid;
  assign O_EVT_ID        = r_evt_id;
  assign O_EVT_ARG0      = r_evt_arg0;
  assign O_EVT_ARG1      = r_evt_arg1;
  assign O_EVT_ARG2      = r_evt_arg2;
  assign O_RAW_DONE      = r_raw_done;
  assign O_RAW_ERR_VALID = r_raw_err_valid;
  assign O_RAW_ERR_CODE  = r_raw_err_code;
  assign O_RAW_RD_DATA   = r_raw_rd_data;
  assign O_BUSY          = (st_state != IDLE) || r_evt_valid || r_raw_done || r_raw_err_valid;

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
    .O_RD_DATA       (l_byte_rd_data),
    .O_BUSY          ()
  );

  task automatic set_event(
    input logic [7:0]  evt_id,
    input logic [31:0] arg0,
    input logic [31:0] arg1,
    input logic [31:0] arg2
  );
    begin
      r_evt_valid <= 1'b1;
      r_evt_id    <= evt_id;
      r_evt_arg0  <= arg0;
      r_evt_arg1  <= arg1;
      r_evt_arg2  <= arg2;
    end
  endtask

  task automatic finish_single(
    input logic [31:0] data_value,
    input logic [31:0] status_code
  );
    begin
      set_event(
        r_req_is_write ? EVT_WRITE_ACK : EVT_READ_RSP,
        {15'h0000, r_req_addr},
        data_value,
        status_code
      );
      st_state <= IDLE;
    end
  endtask

  task automatic finish_raw_ok;
    begin
      r_raw_done <= 1'b1;
      st_state   <= IDLE;
    end
  endtask

  task automatic finish_raw_err(
    input logic [31:0] error_code
  );
    begin
      r_raw_err_valid <= 1'b1;
      r_raw_err_code  <= error_code;
      st_state        <= IDLE;
    end
  endtask

  function automatic logic [7:0] current_control_byte(input logic is_read);
    begin
      current_control_byte = eeprom_control_byte(r_req_addr[16], is_read);
    end
  endfunction

  function automatic logic [7:0] current_write_byte;
    begin
      current_write_byte = r_req_raw_wr_data[r_data_index*8 +: 8];
    end
  endfunction

  function automatic logic [7:0] current_addr_hi;
    begin
      current_addr_hi = r_req_addr[15:8];
    end
  endfunction

  function automatic logic [7:0] current_addr_lo;
    begin
      current_addr_lo = r_req_addr[7:0];
    end
  endfunction

  // Serializes complete EEPROM transactions and emits the same host-facing
  // completion surfaces used by the SDRAM bridge pattern.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state            <= IDLE;
      r_stop_action       <= STOP_FINISH_OK;
      r_req_addr          <= '0;
      r_req_count         <= 8'h01;
      r_req_is_write      <= 1'b0;
      r_req_is_raw_bulk   <= 1'b0;
      r_req_raw_wr_data   <= '0;
      r_raw_rd_data       <= '0;
      r_data_index        <= 8'h00;
      r_last_read_byte    <= 8'h00;
      r_finish_error      <= 32'h0000_0000;
      r_poll_timeout_cnt  <= '0;
      r_evt_valid         <= 1'b0;
      r_evt_id            <= 8'h00;
      r_evt_arg0          <= 32'h0000_0000;
      r_evt_arg1          <= 32'h0000_0000;
      r_evt_arg2          <= 32'h0000_0000;
      r_raw_done          <= 1'b0;
      r_raw_err_valid     <= 1'b0;
      r_raw_err_code      <= 32'h0000_0000;
      r_byte_op_valid     <= 1'b0;
      r_byte_op           <= BYTE_OP_READ;
      r_byte_wr_data      <= 8'h00;
      r_byte_rd_send_ack  <= 1'b0;
    end else begin
      r_raw_done      <= 1'b0;
      r_raw_err_valid <= 1'b0;
      r_byte_op_valid <= 1'b0;

      if (r_evt_valid && I_EVT_READY) begin
        r_evt_valid <= 1'b0;
      end

      if (st_state != IDLE && st_state != ISSUE_POLL_STOP && st_state != WAIT_POLL_STOP &&
          st_state != ISSUE_STOP && st_state != WAIT_STOP &&
          r_stop_action == STOP_FINISH_POLL && (r_poll_timeout_cnt != WRITE_POLL_TIMEOUT_CYCLES)) begin
        r_poll_timeout_cnt <= r_poll_timeout_cnt + 1'b1;
      end

      case (st_state)
        IDLE: begin
          r_poll_timeout_cnt <= '0;
          if (I_REQ_VALID && O_REQ_READY) begin
            r_req_addr        <= I_REQ_ADDR;
            r_req_count       <= I_REQ_IS_RAW_BULK ? I_REQ_COUNT : 8'h01;
            r_req_is_write    <= I_REQ_IS_WRITE;
            r_req_is_raw_bulk <= I_REQ_IS_RAW_BULK;
            r_req_raw_wr_data <= I_REQ_RAW_WR_DATA;
            r_raw_rd_data     <= '0;
            r_data_index      <= 8'h00;
            r_last_read_byte  <= 8'h00;

            if (I_REQ_ADDR > EEPROM_MAX_ADDR) begin
              if (I_REQ_IS_RAW_BULK) begin
                finish_raw_err(ERR_ADDR_RANGE);
              end else begin
                finish_single(32'h0000_0000, ERR_ADDR_RANGE);
              end
            end else if (I_REQ_IS_RAW_BULK && ((I_REQ_COUNT == 0) || (I_REQ_COUNT > MAX_BULK_PAYLOAD_BYTES))) begin
              finish_raw_err(ERR_BYTE_COUNT);
            end else if (I_REQ_IS_RAW_BULK && !I_REQ_IS_WRITE && eeprom_crosses_block(I_REQ_ADDR, I_REQ_COUNT)) begin
              finish_raw_err(ERR_ADDR_RANGE);
            end else if (I_REQ_IS_RAW_BULK && I_REQ_IS_WRITE &&
                         (eeprom_crosses_page(I_REQ_ADDR, I_REQ_COUNT) || eeprom_crosses_block(I_REQ_ADDR, I_REQ_COUNT))) begin
              finish_raw_err(ERR_ADDR_RANGE);
            end else begin
              st_state <= ISSUE_START;
            end
          end
        end

        ISSUE_START: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_START;
            st_state        <= WAIT_START;
          end
        end

        WAIT_START: begin
          if (l_byte_done) begin
            st_state <= ISSUE_CTRL_WRITE;
          end
        end

        ISSUE_CTRL_WRITE: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_WRITE;
            r_byte_wr_data  <= current_control_byte(1'b0);
            st_state        <= WAIT_CTRL_WRITE;
          end
        end

        WAIT_CTRL_WRITE: begin
          if (l_byte_done) begin
            if (!l_byte_ack_ok) begin
              r_finish_error <= ERR_I2C_NACK;
              r_stop_action  <= r_req_is_raw_bulk ? STOP_FINISH_RAW_ERR : STOP_FINISH_EVT_ERR;
              st_state       <= ISSUE_STOP;
            end else begin
              st_state <= ISSUE_ADDR_HI;
            end
          end
        end

        ISSUE_ADDR_HI: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_WRITE;
            r_byte_wr_data  <= current_addr_hi();
            st_state        <= WAIT_ADDR_HI;
          end
        end

        WAIT_ADDR_HI: begin
          if (l_byte_done) begin
            if (!l_byte_ack_ok) begin
              r_finish_error <= ERR_I2C_NACK;
              r_stop_action  <= r_req_is_raw_bulk ? STOP_FINISH_RAW_ERR : STOP_FINISH_EVT_ERR;
              st_state       <= ISSUE_STOP;
            end else begin
              st_state <= ISSUE_ADDR_LO;
            end
          end
        end

        ISSUE_ADDR_LO: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_WRITE;
            r_byte_wr_data  <= current_addr_lo();
            st_state        <= WAIT_ADDR_LO;
          end
        end

        WAIT_ADDR_LO: begin
          if (l_byte_done) begin
            if (!l_byte_ack_ok) begin
              r_finish_error <= ERR_I2C_NACK;
              r_stop_action  <= r_req_is_raw_bulk ? STOP_FINISH_RAW_ERR : STOP_FINISH_EVT_ERR;
              st_state       <= ISSUE_STOP;
            end else if (r_req_is_write) begin
              st_state <= ISSUE_WRITE_DATA;
            end else begin
              st_state <= ISSUE_RSTART;
            end
          end
        end

        ISSUE_WRITE_DATA: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_WRITE;
            r_byte_wr_data  <= r_req_is_raw_bulk ? current_write_byte() : r_req_raw_wr_data[7:0];
            st_state        <= WAIT_WRITE_DATA;
          end
        end

        WAIT_WRITE_DATA: begin
          if (l_byte_done) begin
            if (!l_byte_ack_ok) begin
              r_finish_error <= ERR_I2C_NACK;
              r_stop_action  <= r_req_is_raw_bulk ? STOP_FINISH_RAW_ERR : STOP_FINISH_EVT_ERR;
              st_state       <= ISSUE_STOP;
            end else if (r_data_index + 1 < r_req_count) begin
              r_data_index <= r_data_index + 1'b1;
              st_state     <= ISSUE_WRITE_DATA;
            end else begin
              r_stop_action <= STOP_FINISH_POLL;
              st_state      <= ISSUE_STOP;
            end
          end
        end

        ISSUE_RSTART: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_START;
            st_state        <= WAIT_RSTART;
          end
        end

        WAIT_RSTART: begin
          if (l_byte_done) begin
            st_state <= ISSUE_CTRL_READ;
          end
        end

        ISSUE_CTRL_READ: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_WRITE;
            r_byte_wr_data  <= current_control_byte(1'b1);
            st_state        <= WAIT_CTRL_READ;
          end
        end

        WAIT_CTRL_READ: begin
          if (l_byte_done) begin
            if (!l_byte_ack_ok) begin
              r_finish_error <= ERR_I2C_NACK;
              r_stop_action  <= r_req_is_raw_bulk ? STOP_FINISH_RAW_ERR : STOP_FINISH_EVT_ERR;
              st_state       <= ISSUE_STOP;
            end else begin
              st_state <= ISSUE_READ_DATA;
            end
          end
        end

        ISSUE_READ_DATA: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid    <= 1'b1;
            r_byte_op          <= BYTE_OP_READ;
            r_byte_rd_send_ack <= (r_data_index + 1) < r_req_count;
            st_state           <= WAIT_READ_DATA;
          end
        end

        WAIT_READ_DATA: begin
          if (l_byte_done) begin
            r_last_read_byte <= l_byte_rd_data;
            if (r_req_is_raw_bulk) begin
              r_raw_rd_data[r_data_index*8 +: 8] <= l_byte_rd_data;
            end

            if (r_data_index + 1 < r_req_count) begin
              r_data_index <= r_data_index + 1'b1;
              st_state     <= ISSUE_READ_DATA;
            end else begin
              r_stop_action <= STOP_FINISH_OK;
              st_state      <= ISSUE_STOP;
            end
          end
        end

        ISSUE_STOP: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_STOP;
            st_state        <= WAIT_STOP;
          end
        end

        WAIT_STOP: begin
          if (l_byte_done) begin
            unique case (r_stop_action)
              STOP_FINISH_OK: begin
                if (r_req_is_raw_bulk) begin
                  finish_raw_ok();
                end else begin
                  finish_single({24'h000000, r_last_read_byte}, 32'h0000_0000);
                end
              end

              STOP_FINISH_EVT_ERR: begin
                finish_single(
                  r_req_is_write ? {24'h000000, r_req_raw_wr_data[7:0]} : 32'h0000_0000,
                  r_finish_error
                );
              end

              STOP_FINISH_RAW_ERR: begin
                finish_raw_err(r_finish_error);
              end

              default: begin
                st_state <= ISSUE_POLL_START;
              end
            endcase
          end
        end

        ISSUE_POLL_START: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_START;
            st_state        <= WAIT_POLL_START;
          end
        end

        WAIT_POLL_START: begin
          if (l_byte_done) begin
            st_state <= ISSUE_POLL_CTRL;
          end
        end

        ISSUE_POLL_CTRL: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_WRITE;
            r_byte_wr_data  <= current_control_byte(1'b0);
            st_state        <= WAIT_POLL_CTRL;
          end
        end

        WAIT_POLL_CTRL: begin
          if (l_byte_done) begin
            if (l_byte_ack_ok) begin
              r_stop_action <= STOP_FINISH_OK;
            end else if (r_poll_timeout_cnt >= WRITE_POLL_TIMEOUT_CYCLES - 1) begin
              r_finish_error <= ERR_I2C_TIMEOUT;
              r_stop_action  <= r_req_is_raw_bulk ? STOP_FINISH_RAW_ERR : STOP_FINISH_EVT_ERR;
            end else begin
              r_stop_action <= STOP_FINISH_POLL;
            end
            st_state <= ISSUE_POLL_STOP;
          end
        end

        ISSUE_POLL_STOP: begin
          if (l_byte_op_ready) begin
            r_byte_op_valid <= 1'b1;
            r_byte_op       <= BYTE_OP_STOP;
            st_state        <= WAIT_POLL_STOP;
          end
        end

        WAIT_POLL_STOP: begin
          if (l_byte_done) begin
            if (r_stop_action == STOP_FINISH_OK) begin
              if (r_req_is_raw_bulk) begin
                finish_raw_ok();
              end else begin
                finish_single({24'h000000, r_req_raw_wr_data[7:0]}, 32'h0000_0000);
              end
            end else if (r_stop_action == STOP_FINISH_POLL) begin
              st_state <= ISSUE_POLL_START;
            end else if (r_stop_action == STOP_FINISH_RAW_ERR) begin
              finish_raw_err(r_finish_error);
            end else begin
              finish_single({24'h000000, r_req_raw_wr_data[7:0]}, r_finish_error);
            end
          end
        end

        default: begin
          st_state <= IDLE;
        end
      endcase
    end
  end

endmodule