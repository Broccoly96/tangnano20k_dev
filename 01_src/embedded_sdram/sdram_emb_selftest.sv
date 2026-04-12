`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// File         : sdram_emb_selftest.sv
// Description  : Embedded SDRAM wrapper with one-shot self-test and UART-log
//                source output.
//////////////////////////////////////////////////////////////////////////////////

module sdram_emb_selftest #(
  parameter int unsigned MEMTEST_BURST_WORDS = 26,
  parameter int unsigned MEMTEST_BURST_COUNT = 8,
  parameter int unsigned MEMTEST_POST_INIT_WAIT_CYCLES = 20_000,
  parameter int unsigned MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES = 4,
  parameter int unsigned MEMTEST_CLEAR_WORDS = 2_097_152
) (
  input  logic        I_CLK,
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

  logic        l_sdrc_wr_n;
  logic        l_sdrc_rd_n;
  logic [20:0] l_sdrc_addr;
  logic [7:0]  l_sdrc_data_len;
  logic [3:0]  l_sdrc_dqm;
  logic [31:0] l_sdrc_wr_data;
  logic [31:0] l_sdrc_rd_data;
  logic        l_sdrc_busy_n;
  logic        l_sdrc_rd_valid;
  logic        l_sdrc_wrd_ack;

  logic [103:0] r_evt_fifo_mem [0:EVT_FIFO_DEPTH-1];
  logic [EVT_FIFO_PTR_W-1:0] r_evt_wr_ptr;
  logic [EVT_FIFO_PTR_W-1:0] r_evt_rd_ptr;
  logic [EVT_FIFO_CNT_W-1:0] r_evt_count;
  logic                      s_evt_fifo_full;
  logic                      s_evt_fifo_empty;
  logic                      s_evt_push;
  logic                      s_evt_pop;

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
    .BURST_WORDS(MEMTEST_BURST_WORDS),
    .BURST_COUNT(MEMTEST_BURST_COUNT),
    .POST_INIT_WAIT_CYCLES(MEMTEST_POST_INIT_WAIT_CYCLES),
    .POST_WRITE_TO_READ_GAP_CYCLES(MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES),
    .CLEAR_WORDS(MEMTEST_CLEAR_WORDS)
  ) u_sdram_memtest_ctrl (
    .I_CLK            (I_CLK),
    .I_RST_N          (I_RST_N),
    .I_SDRC_INIT_DONE (O_INIT_DONE),
    .I_SDRC_BUSY_N    (l_sdrc_busy_n),
    .I_SDRC_WRD_ACK   (l_sdrc_wrd_ack),
    .I_SDRC_RD_VALID  (l_sdrc_rd_valid),
    .I_SDRC_RD_DATA   (l_sdrc_rd_data),
    .O_SDRC_WR_N      (l_sdrc_wr_n),
    .O_SDRC_RD_N      (l_sdrc_rd_n),
    .O_SDRC_ADDR      (l_sdrc_addr),
    .O_SDRC_DATA_LEN  (l_sdrc_data_len),
    .O_SDRC_DQM       (l_sdrc_dqm),
    .O_SDRC_WR_DATA   (l_sdrc_wr_data),
    .O_TEST_ACTIVE    (O_TEST_ACTIVE),
    .O_TEST_PASS      (O_TEST_PASS),
    .O_TEST_FAIL      (O_TEST_FAIL),
    .O_EVT_VALID      (l_evt_push_valid),
    .O_EVT_ID         (l_evt_push_id),
    .O_EVT_ARG0       (l_evt_push_arg0),
    .O_EVT_ARG1       (l_evt_push_arg1),
    .O_EVT_ARG2       (l_evt_push_arg2)
  );

  embedded_sdram u_embedded_sdram (
    .O_sdram_clk         (O_sdram_clk),
    .O_sdram_cke         (O_sdram_cke),
    .O_sdram_cs_n        (O_sdram_cs_n),
    .O_sdram_cas_n       (O_sdram_cas_n),
    .O_sdram_ras_n       (O_sdram_ras_n),
    .O_sdram_wen_n       (O_sdram_wen_n),
    .O_sdram_dqm         (O_sdram_dqm),
    .O_sdram_addr        (O_sdram_addr),
    .O_sdram_ba          (O_sdram_ba),
    .IO_sdram_dq         (IO_sdram_dq),
    .I_sdrc_rst_n        (I_RST_N),
    .I_sdrc_clk          (I_CLK),
    .I_sdram_clk         (I_CLK),
    .I_sdrc_selfrefresh  (1'b0),
    .I_sdrc_power_down   (1'b0),
    .I_sdrc_wr_n         (l_sdrc_wr_n),
    .I_sdrc_rd_n         (l_sdrc_rd_n),
    .I_sdrc_addr         (l_sdrc_addr),
    .I_sdrc_data_len     (l_sdrc_data_len),
    .I_sdrc_dqm          (l_sdrc_dqm),
    .I_sdrc_data         (l_sdrc_wr_data),
    .O_sdrc_data         (l_sdrc_rd_data),
    .O_sdrc_init_done    (O_INIT_DONE),
    .O_sdrc_busy_n       (l_sdrc_busy_n),
    .O_sdrc_rd_valid     (l_sdrc_rd_valid),
    .O_sdrc_wrd_ack      (l_sdrc_wrd_ack)
  );

  // Preserves SDRAM test events while another UART source is selected.
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
