`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_open_word_ctrl.sv
// Description  : 32-bit word interface adapter on top of a byte transaction
//                backend.
//                - Serializes one word request into up to four byte accesses.
//                - Preserves byte lanes through active-high write byte enables.
//                - Returns exactly one response per accepted word request.
//////////////////////////////////////////////////////////////////////////////////

module sdram_open_word_ctrl (
  input  logic        I_CLK,
  input  logic        I_RST_N,
  input  logic        I_INIT_DONE,

  input  logic        I_REQ_VALID,
  output logic        O_REQ_READY,
  input  logic        I_REQ_IS_WRITE,
  input  logic [20:0] I_REQ_ADDR,
  input  logic [31:0] I_REQ_WR_DATA,
  input  logic [3:0]  I_REQ_WR_BE,

  output logic        O_RSP_VALID,
  input  logic        I_RSP_READY,
  output logic [31:0] O_RSP_RD_DATA,
  output logic [31:0] O_RSP_STATUS,
  output logic [31:0] O_DBG_SUMMARY,
  output logic [31:0] O_DBG_DATA,

  output logic        O_BYTE_REQ_VALID,
  input  logic        I_BYTE_REQ_READY,
  output logic        O_BYTE_REQ_IS_WRITE,
  output logic [22:0] O_BYTE_REQ_ADDR,
  output logic [7:0]  O_BYTE_REQ_WR_DATA,

  input  logic        I_BYTE_RSP_VALID,
  output logic        O_BYTE_RSP_READY,
  input  logic [7:0]  I_BYTE_RSP_RD_DATA,
  input  logic [31:0] I_BYTE_RSP_STATUS
);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_BYTE_WAIT,
    ST_RESPOND
  } st_state_e;

  st_state_e st_state;

  logic        r_req_is_write;
  logic [20:0] r_req_addr;
  logic [31:0] r_req_wr_data;
  logic [3:0]  r_req_wr_be;
  logic [31:0] r_rsp_rd_data;
  logic [31:0] r_rsp_status;
  logic        r_rsp_valid;
  logic [1:0]  r_lane_idx;
  logic        r_byte_inflight;

  function automatic logic lane_enabled(
    input logic        is_write,
    input logic [3:0]  wr_be,
    input logic [1:0]  lane_idx
  );
    begin
      if (is_write) begin
        lane_enabled = wr_be[lane_idx];
      end else begin
        lane_enabled = 1'b1;
      end
    end
  endfunction

  function automatic logic [1:0] next_lane(
    input logic        is_write,
    input logic [3:0]  wr_be,
    input logic [1:0]  curr_lane
  );
    begin
      next_lane = curr_lane;
      case (curr_lane)
        2'd0: begin
          if (lane_enabled(is_write, wr_be, 2'd1)) begin
            next_lane = 2'd1;
          end else if (lane_enabled(is_write, wr_be, 2'd2)) begin
            next_lane = 2'd2;
          end else if (lane_enabled(is_write, wr_be, 2'd3)) begin
            next_lane = 2'd3;
          end
        end

        2'd1: begin
          if (lane_enabled(is_write, wr_be, 2'd2)) begin
            next_lane = 2'd2;
          end else if (lane_enabled(is_write, wr_be, 2'd3)) begin
            next_lane = 2'd3;
          end
        end

        2'd2: begin
          if (lane_enabled(is_write, wr_be, 2'd3)) begin
            next_lane = 2'd3;
          end
        end

        default: begin
          next_lane = curr_lane;
        end
      endcase
    end
  endfunction

  function automatic logic has_more_lanes(
    input logic        is_write,
    input logic [3:0]  wr_be,
    input logic [1:0]  curr_lane
  );
    begin
      case (curr_lane)
        2'd0: begin
          has_more_lanes =
            lane_enabled(is_write, wr_be, 2'd1) ||
            lane_enabled(is_write, wr_be, 2'd2) ||
            lane_enabled(is_write, wr_be, 2'd3);
        end

        2'd1: begin
          has_more_lanes =
            lane_enabled(is_write, wr_be, 2'd2) ||
            lane_enabled(is_write, wr_be, 2'd3);
        end

        2'd2: begin
          has_more_lanes = lane_enabled(is_write, wr_be, 2'd3);
        end

        default: begin
          has_more_lanes = 1'b0;
        end
      endcase
    end
  endfunction

  function automatic logic [1:0] first_lane(
    input logic        is_write,
    input logic [3:0]  wr_be
  );
    begin
      first_lane = 2'd0;
      if (lane_enabled(is_write, wr_be, 2'd0)) begin
        first_lane = 2'd0;
      end else if (lane_enabled(is_write, wr_be, 2'd1)) begin
        first_lane = 2'd1;
      end else if (lane_enabled(is_write, wr_be, 2'd2)) begin
        first_lane = 2'd2;
      end else if (lane_enabled(is_write, wr_be, 2'd3)) begin
        first_lane = 2'd3;
      end
    end
  endfunction

  assign O_REQ_READY = (st_state == ST_IDLE) && !r_rsp_valid && I_INIT_DONE;
  assign O_RSP_VALID = r_rsp_valid;
  assign O_RSP_RD_DATA = r_rsp_rd_data;
  assign O_RSP_STATUS = r_rsp_status;
  assign O_DBG_SUMMARY = {
    st_state,
    r_byte_inflight,
    r_req_is_write,
    r_lane_idx,
    r_req_wr_be,
    r_rsp_valid,
    r_req_addr
  };
  assign O_DBG_DATA = r_rsp_rd_data;

  assign O_BYTE_REQ_VALID = (st_state == ST_BYTE_WAIT) && !r_byte_inflight;
  assign O_BYTE_REQ_IS_WRITE = r_req_is_write;
  assign O_BYTE_REQ_ADDR = {r_req_addr, 2'b00} + r_lane_idx;
  assign O_BYTE_REQ_WR_DATA = r_req_wr_data[(r_lane_idx * 8) +: 8];
  assign O_BYTE_RSP_READY = 1'b1;

  // Serializes one accepted word request into sequential byte requests.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      st_state        <= ST_IDLE;
      r_req_is_write  <= 1'b0;
      r_req_addr      <= '0;
      r_req_wr_data   <= 32'h0000_0000;
      r_req_wr_be     <= 4'h0;
      r_rsp_rd_data   <= 32'h0000_0000;
      r_rsp_status    <= 32'h0000_0000;
      r_rsp_valid     <= 1'b0;
      r_lane_idx      <= 2'd0;
      r_byte_inflight <= 1'b0;
    end else begin
      if (r_rsp_valid && I_RSP_READY) begin
        r_rsp_valid <= 1'b0;
      end

      case (st_state)
        ST_IDLE: begin
          r_byte_inflight <= 1'b0;
          if (I_REQ_VALID && O_REQ_READY) begin
            r_req_is_write <= I_REQ_IS_WRITE;
            r_req_addr     <= I_REQ_ADDR;
            r_req_wr_data  <= I_REQ_WR_DATA;
            r_req_wr_be    <= I_REQ_WR_BE;
            r_rsp_rd_data  <= 32'h0000_0000;
            r_rsp_status   <= 32'h0000_0000;

            if (I_REQ_IS_WRITE && (I_REQ_WR_BE == 4'h0)) begin
              r_rsp_valid <= 1'b1;
              st_state    <= ST_RESPOND;
            end else begin
              r_lane_idx <= first_lane(I_REQ_IS_WRITE, I_REQ_WR_BE);
              st_state   <= ST_BYTE_WAIT;
            end
          end
        end

        ST_BYTE_WAIT: begin
          if (O_BYTE_REQ_VALID && I_BYTE_REQ_READY) begin
            r_byte_inflight <= 1'b1;
          end

          if (I_BYTE_RSP_VALID && r_byte_inflight) begin
            r_byte_inflight <= 1'b0;

            if (I_BYTE_RSP_STATUS != 32'h0000_0000) begin
              r_rsp_status <= I_BYTE_RSP_STATUS;
              r_rsp_valid  <= 1'b1;
              st_state     <= ST_RESPOND;
            end else begin
              if (!r_req_is_write) begin
                r_rsp_rd_data[(r_lane_idx * 8) +: 8] <= I_BYTE_RSP_RD_DATA;
              end

              if (has_more_lanes(r_req_is_write, r_req_wr_be, r_lane_idx)) begin
                r_lane_idx <= next_lane(r_req_is_write, r_req_wr_be, r_lane_idx);
              end else begin
                r_rsp_status <= 32'h0000_0000;
                r_rsp_valid  <= 1'b1;
                st_state     <= ST_RESPOND;
              end
            end
          end
        end

        ST_RESPOND: begin
          if (!r_rsp_valid || I_RSP_READY) begin
            st_state <= ST_IDLE;
          end
        end

        default: begin
          st_state <= ST_IDLE;
        end
      endcase
    end
  end

endmodule
