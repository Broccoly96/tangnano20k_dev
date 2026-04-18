`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_emb_selftest.sv
// Description  : Integrated SDRAM self-test subsystem.
//                - Instantiates the native word controller and byte controller.
//                - Runs the one-shot startup memtest.
//                - Preserves test events in a small FIFO for the log bridge.
//////////////////////////////////////////////////////////////////////////////////

module sdram_emb_selftest #(
  parameter int unsigned MEMTEST_CLK_HZ = 48_000_000,
  parameter int unsigned MEMTEST_BURST_WORDS = 256,
  parameter int unsigned MEMTEST_TOTAL_WORDS = 2_097_152,
  parameter int unsigned MEMTEST_POST_INIT_WAIT_CYCLES = 20_000,
  parameter int unsigned MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES = 4
) (
  input  logic        I_CLK,
  input  logic        I_CLK_SDRAM,
  input  logic        I_RST_N,
  output logic        O_EVT_VALID,
  output logic [7:0]  O_EVT_ID,
  output logic [31:0] O_EVT_ARG0,
  output logic [31:0] O_EVT_ARG1,
  output logic [31:0] O_EVT_ARG2,
  input  logic        I_EVT_READY,
  output logic        O_INIT_DONE,
  output logic        O_TEST_ACTIVE,
  output logic        O_TEST_PASS,
  output logic        O_TEST_FAIL,
  output logic        O_sdram_clk,
  output logic        O_sdram_cke,
  output logic        O_sdram_cs_n,
  output logic        O_sdram_cas_n,
  output logic        O_sdram_ras_n,
  output logic        O_sdram_wen_n,
  output logic [3:0]  O_sdram_dqm,
  output logic [10:0] O_sdram_addr,
  output logic [1:0]  O_sdram_ba,
  inout  wire [31:0]  IO_sdram_dq
);

  localparam int unsigned EVT_FIFO_DEPTH = 4;
  localparam int unsigned EVT_FIFO_PTR_W = $clog2(EVT_FIFO_DEPTH);
  localparam int unsigned EVT_FIFO_CNT_W = $clog2(EVT_FIFO_DEPTH + 1);

  logic        l_evt_push_valid;
  logic [7:0]  l_evt_push_id;
  logic [31:0] l_evt_push_arg0;
  logic [31:0] l_evt_push_arg1;
  logic [31:0] l_evt_push_arg2;

  logic        l_mem_req_valid;
  logic        l_mem_req_ready;
  logic        l_mem_req_is_write;
  logic [20:0] l_mem_req_addr;
  logic [31:0] l_mem_req_wr_data;
  logic [3:0]  l_mem_req_wr_be;
  logic        l_mem_rsp_valid;
  logic        l_mem_rsp_ready;
  logic [31:0] l_mem_rsp_rd_data;
  logic [31:0] l_mem_rsp_status;

  logic        l_byte_req_valid;
  logic        l_byte_req_ready;
  logic        l_byte_req_is_write;
  logic [22:0] l_byte_req_addr;
  logic [7:0]  l_byte_req_wr_data;
  logic        l_byte_rsp_valid;
  logic        l_byte_rsp_ready;
  logic [7:0]  l_byte_rsp_rd_data;
  logic [31:0] l_byte_rsp_status;
  logic [31:0] l_memtest_dbg_summary_unused;
  logic [31:0] l_memtest_dbg_curr_word_addr_unused;
  logic [31:0] l_memtest_dbg_expected_word_unused;
  logic [31:0] l_memtest_dbg_last_rd_data_unused;
  logic [31:0] l_memtest_dbg_last_rsp_status_unused;
  logic [31:0] l_memtest_dbg_fail_arg0_unused;
  logic [31:0] l_memtest_dbg_fail_arg1_unused;
  logic [31:0] l_memtest_dbg_fail_arg2_unused;
  logic [31:0] l_memtest_dbg_fail_ctx_arg0_unused;
  logic [31:0] l_memtest_dbg_fail_ctx_arg1_unused;
  logic [31:0] l_memtest_dbg_fail_ctx_arg2_unused;
  logic [31:0] l_word_ctrl_dbg_summary_unused;
  logic [31:0] l_word_ctrl_dbg_data_unused;
  logic [31:0] l_byte_ctrl_dbg_summary_unused;
  logic [31:0] l_byte_ctrl_dbg_detail_unused;

  logic [103:0] r_evt_fifo_mem [0:EVT_FIFO_DEPTH-1];
  logic [EVT_FIFO_PTR_W-1:0] r_evt_wr_ptr;
  logic [EVT_FIFO_PTR_W-1:0] r_evt_rd_ptr;
  logic [EVT_FIFO_CNT_W-1:0] r_evt_count;
  logic s_evt_fifo_full;
  logic s_evt_fifo_empty;
  logic s_evt_push;
  logic s_evt_pop;

  assign s_evt_fifo_full  = (r_evt_count == EVT_FIFO_DEPTH);
  assign s_evt_fifo_empty = (r_evt_count == 0);
  assign s_evt_push       = l_evt_push_valid && !s_evt_fifo_full;
  assign s_evt_pop        = O_EVT_VALID && I_EVT_READY;

  assign O_EVT_VALID = !s_evt_fifo_empty;
  assign O_EVT_ID    = s_evt_fifo_empty ? 8'h00 : r_evt_fifo_mem[r_evt_rd_ptr][103:96];
  assign O_EVT_ARG0  = s_evt_fifo_empty ? 32'h0000_0000 : r_evt_fifo_mem[r_evt_rd_ptr][95:64];
  assign O_EVT_ARG1  = s_evt_fifo_empty ? 32'h0000_0000 : r_evt_fifo_mem[r_evt_rd_ptr][63:32];
  assign O_EVT_ARG2  = s_evt_fifo_empty ? 32'h0000_0000 : r_evt_fifo_mem[r_evt_rd_ptr][31:0];

  sdram_memtest_ctrl #(
    .CLK_HZ(MEMTEST_CLK_HZ),
    .MEMTEST_BURST_WORDS(MEMTEST_BURST_WORDS),
    .MEMTEST_TOTAL_WORDS(MEMTEST_TOTAL_WORDS),
    .POST_INIT_WAIT_CYCLES(MEMTEST_POST_INIT_WAIT_CYCLES),
    .POST_WRITE_TO_READ_GAP_CYCLES(MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES)
  ) u_sdram_memtest_ctrl (
    .I_CLK       (I_CLK),
    .I_RST_N     (I_RST_N),
    .I_INIT_DONE (O_INIT_DONE),
    .O_REQ_VALID (l_mem_req_valid),
    .I_REQ_READY (l_mem_req_ready),
    .O_REQ_IS_WRITE(l_mem_req_is_write),
    .O_REQ_ADDR  (l_mem_req_addr),
    .O_REQ_WR_DATA(l_mem_req_wr_data),
    .O_REQ_WR_BE (l_mem_req_wr_be),
    .I_RSP_VALID (l_mem_rsp_valid),
    .O_RSP_READY (l_mem_rsp_ready),
    .I_RSP_RD_DATA(l_mem_rsp_rd_data),
    .I_RSP_STATUS(l_mem_rsp_status),
    .O_TEST_ACTIVE(O_TEST_ACTIVE),
    .O_TEST_PASS (O_TEST_PASS),
    .O_TEST_FAIL (O_TEST_FAIL),
    .O_DBG_SUMMARY(l_memtest_dbg_summary_unused),
    .O_DBG_CURR_WORD_ADDR(l_memtest_dbg_curr_word_addr_unused),
    .O_DBG_EXPECTED_WORD(l_memtest_dbg_expected_word_unused),
    .O_DBG_LAST_RD_DATA(l_memtest_dbg_last_rd_data_unused),
    .O_DBG_LAST_RSP_STATUS(l_memtest_dbg_last_rsp_status_unused),
    .O_DBG_FAIL_ARG0(l_memtest_dbg_fail_arg0_unused),
    .O_DBG_FAIL_ARG1(l_memtest_dbg_fail_arg1_unused),
    .O_DBG_FAIL_ARG2(l_memtest_dbg_fail_arg2_unused),
    .O_DBG_FAIL_CTX_ARG0(l_memtest_dbg_fail_ctx_arg0_unused),
    .O_DBG_FAIL_CTX_ARG1(l_memtest_dbg_fail_ctx_arg1_unused),
    .O_DBG_FAIL_CTX_ARG2(l_memtest_dbg_fail_ctx_arg2_unused),
    .O_EVT_VALID (l_evt_push_valid),
    .O_EVT_ID    (l_evt_push_id),
    .O_EVT_ARG0  (l_evt_push_arg0),
    .O_EVT_ARG1  (l_evt_push_arg1),
    .O_EVT_ARG2  (l_evt_push_arg2)
  );

  sdram_open_word_ctrl u_sdram_open_word_ctrl (
    .I_CLK       (I_CLK),
    .I_RST_N     (I_RST_N),
    .I_INIT_DONE (O_INIT_DONE),
    .I_REQ_VALID (l_mem_req_valid),
    .O_REQ_READY (l_mem_req_ready),
    .I_REQ_IS_WRITE(l_mem_req_is_write),
    .I_REQ_ADDR  (l_mem_req_addr),
    .I_REQ_WR_DATA(l_mem_req_wr_data),
    .I_REQ_WR_BE (l_mem_req_wr_be),
    .O_RSP_VALID (l_mem_rsp_valid),
    .I_RSP_READY (l_mem_rsp_ready),
    .O_RSP_RD_DATA(l_mem_rsp_rd_data),
    .O_RSP_STATUS(l_mem_rsp_status),
    .O_DBG_SUMMARY(l_word_ctrl_dbg_summary_unused),
    .O_DBG_DATA  (l_word_ctrl_dbg_data_unused),
    .O_BYTE_REQ_VALID(l_byte_req_valid),
    .I_BYTE_REQ_READY(l_byte_req_ready),
    .O_BYTE_REQ_IS_WRITE(l_byte_req_is_write),
    .O_BYTE_REQ_ADDR(l_byte_req_addr),
    .O_BYTE_REQ_WR_DATA(l_byte_req_wr_data),
    .I_BYTE_RSP_VALID(l_byte_rsp_valid),
    .O_BYTE_RSP_READY(l_byte_rsp_ready),
    .I_BYTE_RSP_RD_DATA(l_byte_rsp_rd_data),
    .I_BYTE_RSP_STATUS(l_byte_rsp_status)
  );

  sdram_open_byte_ctrl u_sdram_open_byte_ctrl (
    .I_CLK       (I_CLK),
    .I_CLK_SDRAM (I_CLK_SDRAM),
    .I_RST_N     (I_RST_N),
    .I_REQ_VALID (l_byte_req_valid),
    .O_REQ_READY (l_byte_req_ready),
    .I_REQ_IS_WRITE(l_byte_req_is_write),
    .I_REQ_ADDR  (l_byte_req_addr),
    .I_REQ_WR_DATA(l_byte_req_wr_data),
    .O_RSP_VALID (l_byte_rsp_valid),
    .I_RSP_READY (l_byte_rsp_ready),
    .O_RSP_RD_DATA(l_byte_rsp_rd_data),
    .O_RSP_STATUS(l_byte_rsp_status),
    .O_INIT_DONE (O_INIT_DONE),
    .O_DBG_SUMMARY(l_byte_ctrl_dbg_summary_unused),
    .O_DBG_DETAIL(l_byte_ctrl_dbg_detail_unused),
    .O_sdram_clk (O_sdram_clk),
    .O_sdram_cke (O_sdram_cke),
    .O_sdram_cs_n(O_sdram_cs_n),
    .O_sdram_cas_n(O_sdram_cas_n),
    .O_sdram_ras_n(O_sdram_ras_n),
    .O_sdram_wen_n(O_sdram_wen_n),
    .O_sdram_dqm (O_sdram_dqm),
    .O_sdram_addr(O_sdram_addr),
    .O_sdram_ba  (O_sdram_ba),
    .IO_sdram_dq (IO_sdram_dq)
  );

  // Preserves memtest events while the destination logger is not ready.
  always_ff @(posedge I_CLK or negedge I_RST_N) begin
    if (!I_RST_N) begin
      r_evt_wr_ptr   <= '0;
      r_evt_rd_ptr   <= '0;
      r_evt_count    <= '0;
      r_evt_fifo_mem <= '{default: 104'h0};
    end else begin
      if (s_evt_push) begin
        r_evt_fifo_mem[r_evt_wr_ptr] <= {
          l_evt_push_id,
          l_evt_push_arg0,
          l_evt_push_arg1,
          l_evt_push_arg2
        };
        if (r_evt_wr_ptr == EVT_FIFO_DEPTH - 1) begin
          r_evt_wr_ptr <= '0;
        end else begin
          r_evt_wr_ptr <= r_evt_wr_ptr + 1'b1;
        end
      end

      if (s_evt_pop) begin
        if (r_evt_rd_ptr == EVT_FIFO_DEPTH - 1) begin
          r_evt_rd_ptr <= '0;
        end else begin
          r_evt_rd_ptr <= r_evt_rd_ptr + 1'b1;
        end
      end

      case ({s_evt_push, s_evt_pop})
        2'b10: r_evt_count <= r_evt_count + 1'b1;
        2'b01: r_evt_count <= r_evt_count - 1'b1;
        default: r_evt_count <= r_evt_count;
      endcase
    end
  end

endmodule
