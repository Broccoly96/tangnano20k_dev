//---------------------------------------------------------------------------------------------
// Name         : tangnano20k_top
// Description  : top module
//---------------------------------------------------------------------------------------------

module tangnano20k_top(
  input   wire      PIN04_IOL07A_LPLL1,
  // input   wire      PIN05_IOR25B_SYS_TMS,
  // input   wire      PIN06_IOR26A_SYS_TCK,
  // input   wire      PIN07_IOR26B_SYS_TDI,
  // input   wire      PIN08_IOR25A_SYS_TDO,
  // input   wire      PIN09_IOR31B_RECONFIG_N,
  input   wire      PIN10_IOL29A,
  input   wire      PIN11_IOL29B,
  input   wire      PIN13_IOL45A,
  output  wire      PIN15_IOL47A_LED0,
  output  wire      PIN16_IOL47B_LED1,
  output  wire      PIN17_IOL49A_LED2,
  input   wire      PIN18_IOL49B_LED3,
  output  wire      PIN19_IOL51A_LED4,
  output  wire      PIN20_IOL51B_LED5,
  input   wire      PIN25_IOB06A,
  input   wire      PIN26_IOB06B,
  input   wire      PIN27_IOB08A,
  input   wire      PIN28_IOB08B,
  input   wire      PIN29_IOB14A,
  input   wire      PIN30_IOB14B,
  input   wire      PIN31_IOB18A,
  input   wire      PIN32_IOB18B,
  input   wire      PIN33_IOB24A,
  input   wire      PIN34_IOB24B,
  // input   wire      PIN35_IOB30A,
  // input   wire      PIN36_IOB30B,
  // input   wire      PIN37_IOB34A,
  // input   wire      PIN38_IOB34B,
  input   wire      PIN39_IOB40A,
  input   wire      PIN40_IOB40B,
  input   wire      PIN41_IOB43A,
  input   wire      PIN42_IOB42B,
  input   wire      PIN48_IOR49B,
  input   wire      PIN49_IOR49A,
  input   wire      PIN51_IOR45A,
  input   wire      PIN52_IOR39A,
  input   wire      PIN53_IOR38B,
  input   wire      PIN54_IOR38A,
  input   wire      PIN55_IOR36B,
  input   wire      PIN56_IOR36A,
  input   wire      PIN57_IOR35A,
  // input   wire      PIN59_IOR34B,
  // input   wire      PIN60_IOR34A,
  // input   wire      PIN61_IOR33B,
  // input   wire      PIN62_IOR33A,
  input   wire      PIN63_IOR29A,
  input   wire      PIN69_IOT50A,
  input   wire      PIN70_IOT44B,
  input   wire      PIN71_IOT44A,
  input   wire      PIN72_IOT40B,
  input   wire      PIN73_IOT40A,
  input   wire      PIN74_IOT34B,
  input   wire      PIN75_IOT34A,
  input   wire      PIN76_IOT30B,
  input   wire      PIN77_IOT30A,
  input   wire      PIN79_IOT27B,
  input   wire      PIN80_IOT27A,
  input   wire      PIN81_IOT17B,
  input   wire      PIN82_IOT17A,
  input   wire      PIN83_IOT16B,
  input   wire      PIN84_IOT16A,
  input   wire      PIN85_IOT14B,
  input   wire      PIN86_IOT14A,
  input   wire      PIN87_IOT30B,
  input   wire      PIN88_IOT30A,
  // Embedded SDRAM
  output           O_sdram_clk,
  output           O_sdram_cke,
  output           O_sdram_cs_n,
  output           O_sdram_cas_n,
  output           O_sdram_ras_n,
  output           O_sdram_wen_n,
  output   [3:0]   O_sdram_dqm,
  output   [10:0]  O_sdram_addr,
  output   [1:0]   O_sdram_ba,
  inout    [31:0]  IO_sdram_dq,
  // Simulation
  output            O_RST_FPGA_N
  );

  localparam int unsigned FPGA_INIT_WAIT         = 24000;
  localparam int unsigned UART_LOG_CLK_HZ        = 24_000_000;
  localparam int unsigned UART_LOG_BAUD          = 115_200;
  localparam int unsigned UART_LOG_NUM_SRC       = 3;
  localparam int unsigned SOFT_RESET_HOLD_CYCLES = UART_LOG_CLK_HZ;
  localparam int unsigned SOFT_RESET_CNT_W       = $clog2(SOFT_RESET_HOLD_CYCLES + 1);
  localparam int unsigned TESTSRC_CLK_HZ         = 24_000_000;
  localparam int unsigned TESTSRC_PERIOD_CYCLES  = TESTSRC_CLK_HZ * 10;


  // PLL
  wire        clk_96m;
  wire        clk_24m;
  wire        clk_96m_sdram;
  wire        clk_96m_sdram;
  wire        pll_lock;
  wire        pll_lock_sdram;
  // Reset Management
  wire        rst_fpga_24m_n;
  logic       rst_fpga_100m_n;
  logic       r_rst_100m_sync1;
  logic       r_rst_100m_sync2;
  // Button
  logic       button_s1;
  logic       button_s2;

  // UART to ESP_WROOM2
  logic       uart_esp_tx;
  logic       uart_esp_rx;
  logic       soft_rst_req_100m;
  logic       soft_rst_req_cli_24m;
  logic       soft_rst_n;
  logic [SOFT_RESET_CNT_W-1:0] r_soft_reset_cnt;
  logic       r_soft_rst_req_toggle_100m;
  logic       r_soft_rst_req_sync1_24m;
  logic       r_soft_rst_req_sync2_24m;
  logic       r_soft_rst_req_sync3_24m;
  logic       soft_rst_req_24m;

  logic [UART_LOG_NUM_SRC-1:0]   l_src_evt_valid;
  logic [UART_LOG_NUM_SRC*8-1:0] l_src_evt_id;
  logic [UART_LOG_NUM_SRC*32-1:0] l_src_arg0;
  logic [UART_LOG_NUM_SRC*32-1:0] l_src_arg1;
  logic [UART_LOG_NUM_SRC*32-1:0] l_src_arg2;
  logic [UART_LOG_NUM_SRC-1:0]   l_src_evt_ready;
  logic [UART_LOG_NUM_SRC-1:0]   l_src_enable;
  logic                          l_src0_evt_valid_24m;
  logic [7:0]                    l_src0_evt_id_24m;
  logic [31:0]                   l_src0_arg0_24m;
  logic [31:0]                   l_src0_arg1_24m;
  logic [31:0]                   l_src0_arg2_24m;
  logic                          l_src0_enable_24m;
  logic                          l_src0_evt_ready_24m;
  logic                          l_src0_evt_valid_100m;
  logic [7:0]                    l_src0_evt_id_100m;
  logic [31:0]                   l_src0_arg0_100m;
  logic [31:0]                   l_src0_arg1_100m;
  logic [31:0]                   l_src0_arg2_100m;
  logic                          l_src1_evt_valid_24m;
  logic [7:0]                    l_src1_evt_id_24m;
  logic [31:0]                   l_src1_arg0_24m;
  logic [31:0]                   l_src1_arg1_24m;
  logic [31:0]                   l_src1_arg2_24m;
  logic                          l_src1_evt_valid_100m;
  logic [7:0]                    l_src1_evt_id_100m;
  logic [31:0]                   l_src1_arg0_100m;
  logic [31:0]                   l_src1_arg1_100m;
  logic [31:0]                   l_src1_arg2_100m;
  logic                          l_src1_evt_ready_100m;
  logic                          l_src1_enable_100m;
  logic                          l_src2_evt_valid_24m;
  logic [7:0]                    l_src2_evt_id_24m;
  logic [31:0]                   l_src2_arg0_24m;
  logic [31:0]                   l_src2_arg1_24m;
  logic [31:0]                   l_src2_arg2_24m;
  logic                          l_src2_evt_valid_100m;
  logic [7:0]                    l_src2_evt_id_100m;
  logic [31:0]                   l_src2_arg0_100m;
  logic [31:0]                   l_src2_arg1_100m;
  logic [31:0]                   l_src2_arg2_100m;
  logic                          l_src2_evt_ready_100m;
  logic                          l_src2_enable_100m;
  logic                          l_sdram_init_done;
  logic                          l_sdram_test_active;
  logic                          l_sdram_test_pass;
  logic                          l_sdram_test_fail;
  logic                          l_sdram_host_busy;
  logic                          l_sdram_raw_rx_bypass_100m;
  logic                          l_sdram_raw_tx_mode_100m;
  logic                          l_sdram_raw_tx_valid_100m;
  logic [7:0]                    l_sdram_raw_tx_data_100m;
  logic                          l_sdram_raw_tx_ready_100m;
  logic                          l_sdram_raw_rx_bypass_sync1_24m;
  logic                          l_sdram_raw_rx_bypass_sync2_24m;
  logic                          l_sdram_raw_tx_mode_sync1_24m;
  logic                          l_sdram_raw_tx_mode_sync2_24m;
  logic                          l_sdram_raw_tx_valid_24m;
  logic [7:0]                    l_sdram_raw_tx_data_24m;
  logic                          l_cli_rx_valid_24m;
  logic [7:0]                    l_cli_rx_data_24m;
  logic                          l_cli_rx_valid_100m;
  logic [7:0]                    l_cli_rx_data_100m;
  logic                          I_sdrc_rst_n;
  logic                          I_sdrc_clk;
  logic                          I_sdram_clk;
  logic                          I_sdrc_selfrefresh;
  logic                          I_sdrc_power_down;
  logic                          I_sdrc_wr_n;
  logic                          I_sdrc_rd_n;
  logic [20:0]                   I_sdrc_addr;
  logic [7:0]                    I_sdrc_data_len;
  logic [3:0]                    I_sdrc_dqm;
  logic [31:0]                   I_sdrc_data;
  logic [31:0]                   O_sdrc_data;
  logic                          O_sdrc_init_done;
  logic                          O_sdrc_busy_n;
  logic                          O_sdrc_rd_valid;
  logic                          O_sdrc_wrd_ack;
  logic                          l_hostif_sdrc_wr_n;
  logic                          l_hostif_sdrc_rd_n;
  logic [20:0]                   l_hostif_sdrc_addr;
  logic [7:0]                    l_hostif_sdrc_data_len;
  logic [3:0]                    l_hostif_sdrc_dqm;
  logic [31:0]                   l_hostif_sdrc_data;
  //---------------------------------------------------------------------------------------------
  // PLL
  //---------------------------------------------------------------------------------------------
  gowin_pll u0_gowin_pll(
    .clkin    (PIN04_IOL07A_LPLL1),
    .lock     (pll_lock),
    .clkout   (clk_96m),
    .clkoutp  (clk_96m_sdram)
    //.clkoutd  (clk_24m)
  );

  //gowin_rpll_sdram u0_gowin_rpll_sdram(
  //  .clkin    (clk_24m),
  //  .lock     (pll_lock_sdram),
  //  .clkout   (clk_96m_sdram)
  //);

  //---------------------------------------------------------------------------------------------
  // Reset Management
  //---------------------------------------------------------------------------------------------
  reset_mng #(
    .FPGA_INIT_WAIT     (FPGA_INIT_WAIT)
    ) u0_reset_mng(
    .I_CLK_24M          (clk_24m),
    .I_PLL_LOCK         (pll_lock),
    .I_SOFT_RST_N       (soft_rst_n),
    .O_RST_FPGA_24M_N   (rst_fpga_24m_n)
  );

  assign O_RST_FPGA_N = rst_fpga_24m_n;

  // Synchronizes the 24MHz reset release into the 100MHz SDRAM/UART domain
  // while keeping asynchronous assertion on PLL loss or top-level soft reset.
  always_ff @(posedge clk_96m_sdram or negedge rst_fpga_24m_n or negedge pll_lock_sdram) begin
    if (!rst_fpga_24m_n || !pll_lock_sdram) begin
      r_rst_100m_sync1 <= 1'b0;
      r_rst_100m_sync2 <= 1'b0;
      rst_fpga_100m_n  <= 1'b0;
    end else begin
      r_rst_100m_sync1 <= 1'b1;
      r_rst_100m_sync2 <= r_rst_100m_sync1;
      rst_fpga_100m_n  <= r_rst_100m_sync2;
    end
  end

  // Carries the one-cycle 100MHz soft-reset pulse safely into the 24MHz reset
  // stretcher so host-triggered resets are never missed.
  always_ff @(posedge clk_96m_sdram or negedge rst_fpga_100m_n) begin
    if (!rst_fpga_100m_n) begin
      r_soft_rst_req_toggle_100m <= 1'b0;
    end else if (soft_rst_req_100m) begin
      r_soft_rst_req_toggle_100m <= ~r_soft_rst_req_toggle_100m;
    end
  end

  always_ff @(posedge clk_24m or negedge pll_lock) begin
    if (!pll_lock) begin
      r_soft_rst_req_sync1_24m <= 1'b0;
      r_soft_rst_req_sync2_24m <= 1'b0;
      r_soft_rst_req_sync3_24m <= 1'b0;
    end else begin
      r_soft_rst_req_sync1_24m <= r_soft_rst_req_toggle_100m;
      r_soft_rst_req_sync2_24m <= r_soft_rst_req_sync1_24m;
      r_soft_rst_req_sync3_24m <= r_soft_rst_req_sync2_24m;
    end
  end

  assign clk_24m              = clk_96m;
  assign pll_lock_sdram       = pll_lock;
  assign l_src0_evt_ready_24m = l_src_evt_ready[0];
  assign soft_rst_req_24m     = r_soft_rst_req_sync2_24m ^ r_soft_rst_req_sync3_24m;
  assign I_sdrc_rst_n       = rst_fpga_100m_n;
  assign I_sdrc_clk         = clk_96m_sdram;
  assign I_sdram_clk        = clk_96m_sdram;
  assign I_sdrc_selfrefresh = 1'b0;
  assign I_sdrc_power_down  = 1'b0;
  assign I_sdrc_wr_n        = l_hostif_sdrc_wr_n;
  assign I_sdrc_rd_n        = l_hostif_sdrc_rd_n;
  assign I_sdrc_addr        = l_hostif_sdrc_addr;
  assign I_sdrc_data_len    = l_hostif_sdrc_data_len;
  assign I_sdrc_dqm         = l_hostif_sdrc_dqm;
  assign I_sdrc_data        = l_hostif_sdrc_data;
  assign l_sdram_init_done  = O_sdrc_init_done;

  // Synchronizes SDRAM raw-session flags into the 24MHz UART domain.
  always_ff @(posedge clk_24m or negedge pll_lock) begin
    if (!pll_lock) begin
      l_sdram_raw_rx_bypass_sync1_24m <= 1'b0;
      l_sdram_raw_rx_bypass_sync2_24m <= 1'b0;
      l_sdram_raw_tx_mode_sync1_24m   <= 1'b0;
      l_sdram_raw_tx_mode_sync2_24m   <= 1'b0;
    end else begin
      l_sdram_raw_rx_bypass_sync1_24m <= l_sdram_raw_rx_bypass_100m;
      l_sdram_raw_rx_bypass_sync2_24m <= l_sdram_raw_rx_bypass_sync1_24m;
      l_sdram_raw_tx_mode_sync1_24m   <= l_sdram_raw_tx_mode_100m;
      l_sdram_raw_tx_mode_sync2_24m   <= l_sdram_raw_tx_mode_sync1_24m;
    end
  end

  //---------------------------------------------------------------------------------------------
  // Soft reset pulse stretcher
  //---------------------------------------------------------------------------------------------
  // Holds reset_mng.I_SOFT_RST_N low for at least 1ms after Ctrl+R.
  // This logic is intentionally independent from rst_fpga_24m_n so the hold
  // time survives the user-logic reset it requests.
  always_ff @(posedge clk_24m or negedge pll_lock) begin
    if (~pll_lock) begin
      r_soft_reset_cnt <= '0;
      soft_rst_n       <= 1'b1;
    end else if (soft_rst_req_24m || soft_rst_req_cli_24m) begin
      r_soft_reset_cnt <= SOFT_RESET_HOLD_CYCLES - 1;
      soft_rst_n       <= 1'b0;
    end else if (r_soft_reset_cnt != 0) begin
      r_soft_reset_cnt <= r_soft_reset_cnt - 1'b1;
      soft_rst_n       <= 1'b0;
    end else if (button_s1) begin
      soft_rst_n       <= 1'b0;
    end else begin
      r_soft_reset_cnt <= '0;
      soft_rst_n       <= 1'b1;
    end
  end

  assign button_s1 = PIN88_IOT30A;
  assign button_s2 = PIN87_IOT30B;
  assign soft_rst_req_100m = 1'b0;


  //---------------------------------------------------------------------------------------------
  // System Onboard LED
  //---------------------------------------------------------------------------------------------
  assign PIN15_IOL47A_LED0 = ~rst_fpga_24m_n;
  assign PIN16_IOL47B_LED1 = ~l_sdram_init_done;
  assign PIN17_IOL49A_LED2 = ~l_sdram_test_pass;
  assign PIN20_IOL51B_LED5 = ~l_sdram_test_fail;


  //---------------------------------------------------------------------------------------------
  // UART debug log source wiring
  //---------------------------------------------------------------------------------------------
  assign l_src_evt_valid[0]    = l_src0_evt_valid_24m;
  assign l_src_evt_valid[1]    = l_src1_evt_valid_24m;
  assign l_src_evt_valid[2]    = l_src2_evt_valid_24m;
  assign l_src_evt_id[7:0]     = l_src0_evt_id_24m;
  assign l_src_evt_id[15:8]    = l_src1_evt_id_24m;
  assign l_src_evt_id[23:16]   = l_src2_evt_id_24m;
  assign l_src_arg0[31:0]      = l_src0_arg0_24m;
  assign l_src_arg0[63:32]     = l_src1_arg0_24m;
  assign l_src_arg0[95:64]     = l_src2_arg0_24m;
  assign l_src_arg1[31:0]      = l_src0_arg1_24m;
  assign l_src_arg1[63:32]     = l_src1_arg1_24m;
  assign l_src_arg1[95:64]     = l_src2_arg1_24m;
  assign l_src_arg2[31:0]      = l_src0_arg2_24m;
  assign l_src_arg2[63:32]     = l_src1_arg2_24m;
  assign l_src_arg2[95:64]     = l_src2_arg2_24m;

  uart_log_testsrc1 #(
    .CLK_HZ         (TESTSRC_CLK_HZ),
    .PERIOD_CYCLES  (TESTSRC_PERIOD_CYCLES)
  ) u_uart_log_testsrc1 (
    .I_CLK          (clk_24m),
    .I_RST_N        (rst_fpga_24m_n),
    .I_ENABLE       (l_src_enable[0]),
    .I_EVT_READY    (l_src0_evt_ready_24m),
    .O_EVT_VALID    (l_src0_evt_valid_24m),
    .O_EVT_ID       (l_src0_evt_id_24m),
    .O_ARG0         (l_src0_arg0_24m),
    .O_ARG1         (l_src0_arg1_24m),
    .O_ARG2         (l_src0_arg2_24m)
  );

  sdram_emb_hostif_ctrl u_sdram_emb_hostif_ctrl (
    .I_CLK            (clk_96m_sdram),
    .I_RST_N          (rst_fpga_100m_n),
    .I_CLI_RX_VALID   (l_cli_rx_valid_100m),
    .I_CLI_RX_DATA    (l_cli_rx_data_100m),
    .O_RAW_RX_BYPASS  (l_sdram_raw_rx_bypass_100m),
    .O_RAW_TX_MODE    (l_sdram_raw_tx_mode_100m),
    .O_RAW_TX_VALID   (l_sdram_raw_tx_valid_100m),
    .O_RAW_TX_DATA    (l_sdram_raw_tx_data_100m),
    .I_RAW_TX_READY   (l_sdram_raw_tx_ready_100m),
    .O_TEST_EVT_VALID (l_src1_evt_valid_100m),
    .O_TEST_EVT_ID    (l_src1_evt_id_100m),
    .O_TEST_EVT_ARG0  (l_src1_arg0_100m),
    .O_TEST_EVT_ARG1  (l_src1_arg1_100m),
    .O_TEST_EVT_ARG2  (l_src1_arg2_100m),
    .I_TEST_EVT_READY (l_src1_evt_ready_100m),
    .O_HOST_EVT_VALID (l_src2_evt_valid_100m),
    .O_HOST_EVT_ID    (l_src2_evt_id_100m),
    .O_HOST_EVT_ARG0  (l_src2_arg0_100m),
    .O_HOST_EVT_ARG1  (l_src2_arg1_100m),
    .O_HOST_EVT_ARG2  (l_src2_arg2_100m),
    .I_HOST_EVT_READY (l_src2_evt_ready_100m),
    .O_INIT_DONE      (l_sdram_init_done),
    .O_TEST_ACTIVE    (l_sdram_test_active),
    .O_TEST_PASS      (l_sdram_test_pass),
    .O_TEST_FAIL      (l_sdram_test_fail),
    .O_HOST_BUSY      (l_sdram_host_busy),
    .I_SDRC_RD_DATA   (O_sdrc_data),
    .I_SDRC_BUSY_N    (O_sdrc_busy_n),
    .I_SDRC_RD_VALID  (O_sdrc_rd_valid),
    .I_SDRC_WRD_ACK   (O_sdrc_wrd_ack),
    .I_SDRC_INIT_DONE (O_sdrc_init_done),
    .O_SDRC_WR_N      (l_hostif_sdrc_wr_n),
    .O_SDRC_RD_N      (l_hostif_sdrc_rd_n),
    .O_SDRC_ADDR      (l_hostif_sdrc_addr),
    .O_SDRC_DATA_LEN  (l_hostif_sdrc_data_len),
    .O_SDRC_DQM       (l_hostif_sdrc_dqm),
    .O_SDRC_WR_DATA   (l_hostif_sdrc_data)
  );

	embedded_sdram u_embedded_sdram(
		.O_sdram_clk        (O_sdram_clk), //output O_sdram_clk
		.O_sdram_cke        (O_sdram_cke), //output O_sdram_cke
		.O_sdram_cs_n       (O_sdram_cs_n), //output O_sdram_cs_n
		.O_sdram_cas_n      (O_sdram_cas_n), //output O_sdram_cas_n
		.O_sdram_ras_n      (O_sdram_ras_n), //output O_sdram_ras_n
		.O_sdram_wen_n      (O_sdram_wen_n), //output O_sdram_wen_n
		.O_sdram_dqm        (O_sdram_dqm), //output [3:0] O_sdram_dqm
		.O_sdram_addr       (O_sdram_addr), //output [10:0] O_sdram_addr
		.O_sdram_ba         (O_sdram_ba), //output [1:0] O_sdram_ba
		.IO_sdram_dq        (IO_sdram_dq), //inout [31:0] IO_sdram_dq
		.I_sdrc_rst_n       (I_sdrc_rst_n), //input I_sdrc_rst_n
		.I_sdrc_clk         (I_sdrc_clk), //input I_sdrc_clk
		.I_sdram_clk        (I_sdram_clk), //input I_sdram_clk
		.I_sdrc_selfrefresh (I_sdrc_selfrefresh), //input I_sdrc_selfrefresh
		.I_sdrc_power_down  (I_sdrc_power_down), //input I_sdrc_power_down
		.I_sdrc_wr_n        (I_sdrc_wr_n), //input I_sdrc_wr_n
		.I_sdrc_rd_n        (I_sdrc_rd_n), //input I_sdrc_rd_n
		.I_sdrc_addr        (I_sdrc_addr), //input [20:0] I_sdrc_addr
		.I_sdrc_data_len    (I_sdrc_data_len), //input [7:0] I_sdrc_data_len
		.I_sdrc_dqm         (I_sdrc_dqm), //input [3:0] I_sdrc_dqm
		.I_sdrc_data        (I_sdrc_data), //input [31:0] I_sdrc_data
		.O_sdrc_data        (O_sdrc_data), //output [31:0] O_sdrc_data
		.O_sdrc_init_done   (O_sdrc_init_done), //output O_sdrc_init_done
		.O_sdrc_busy_n      (O_sdrc_busy_n), //output O_sdrc_busy_n
		.O_sdrc_rd_valid    (O_sdrc_rd_valid), //output O_sdrc_rd_valid
		.O_sdrc_wrd_ack     (O_sdrc_wrd_ack) //output O_sdrc_wrd_ack
	);

//	SDRAM_Controller_HS_Top embedded_sdram(
//		.O_sdram_clk           (O_sdram_clk), //output O_sdram_clk
//		.O_sdram_cke           (O_sdram_cke), //output O_sdram_cke
//		.O_sdram_cs_n          (O_sdram_cs_n), //output O_sdram_cs_n
//		.O_sdram_cas_n         (O_sdram_cas_n), //output O_sdram_cas_n
//		.O_sdram_ras_n         (O_sdram_ras_n), //output O_sdram_ras_n
//		.O_sdram_wen_n         (O_sdram_wen_n), //output O_sdram_wen_n
//		.O_sdram_dqm           (O_sdram_dqm), //output [3:0] O_sdram_dqm
//		.O_sdram_addr          (O_sdram_addr), //output [10:0] O_sdram_addr
//		.O_sdram_ba            (O_sdram_ba), //output [1:0] O_sdram_ba
//		.IO_sdram_dq           (IO_sdram_dq), //inout [31:0] IO_sdram_dq
//		.I_sdrc_rst_n          (), //input I_sdrc_rst_n
//		.I_sdrc_clk            (), //input I_sdrc_clk
//		.I_sdram_clk           (), //input I_sdram_clk
//		.I_sdrc_cmd_en         (), //input I_sdrc_cmd_en
//		.I_sdrc_cmd            (), //input [2:0] I_sdrc_cmd
//		.I_sdrc_precharge_ctrl (), //input I_sdrc_precharge_ctrl
//		.I_sdram_power_down    (), //input I_sdram_power_down
//		.I_sdram_selfrefresh   (), //input I_sdram_selfrefresh
//		.I_sdrc_addr           (), //input [20:0] I_sdrc_addr
//		.I_sdrc_dqm            (), //input [3:0] I_sdrc_dqm
//		.I_sdrc_data           (), //input [31:0] I_sdrc_data
//		.I_sdrc_data_len       (), //input [7:0] I_sdrc_data_len
//		.O_sdrc_data           (), //output [31:0] O_sdrc_data
//		.O_sdrc_init_done      (), //output O_sdrc_init_done
//		.O_sdrc_cmd_ack        () //output O_sdrc_cmd_ack
//	);

  uart_log_src_async_bridge #(
    .FIFO_DEPTH(8)
  ) u_sdram_test_evt_bridge (
    .I_SRC_CLK       (clk_96m_sdram),
    .I_SRC_RST_N     (rst_fpga_100m_n),
    .I_DST_CLK       (clk_24m),
    .I_DST_RST_N     (rst_fpga_24m_n),
    .I_DST_ENABLE    (l_src_enable[1]),
    .O_SRC_ENABLE    (l_src1_enable_100m),
    .I_SRC_EVT_VALID (l_src1_evt_valid_100m),
    .I_SRC_EVT_ID    (l_src1_evt_id_100m),
    .I_SRC_ARG0      (l_src1_arg0_100m),
    .I_SRC_ARG1      (l_src1_arg1_100m),
    .I_SRC_ARG2      (l_src1_arg2_100m),
    .O_SRC_EVT_READY (l_src1_evt_ready_100m),
    .O_DST_EVT_VALID (l_src1_evt_valid_24m),
    .O_DST_EVT_ID    (l_src1_evt_id_24m),
    .O_DST_ARG0      (l_src1_arg0_24m),
    .O_DST_ARG1      (l_src1_arg1_24m),
    .O_DST_ARG2      (l_src1_arg2_24m),
    .I_DST_EVT_READY (l_src_evt_ready[1])
  );

  uart_log_src_async_bridge #(
    .FIFO_DEPTH(8)
  ) u_sdram_host_evt_bridge (
    .I_SRC_CLK       (clk_96m_sdram),
    .I_SRC_RST_N     (rst_fpga_100m_n),
    .I_DST_CLK       (clk_24m),
    .I_DST_RST_N     (rst_fpga_24m_n),
    .I_DST_ENABLE    (l_src_enable[2]),
    .O_SRC_ENABLE    (l_src2_enable_100m),
    .I_SRC_EVT_VALID (l_src2_evt_valid_100m),
    .I_SRC_EVT_ID    (l_src2_evt_id_100m),
    .I_SRC_ARG0      (l_src2_arg0_100m),
    .I_SRC_ARG1      (l_src2_arg1_100m),
    .I_SRC_ARG2      (l_src2_arg2_100m),
    .O_SRC_EVT_READY (l_src2_evt_ready_100m),
    .O_DST_EVT_VALID (l_src2_evt_valid_24m),
    .O_DST_EVT_ID    (l_src2_evt_id_24m),
    .O_DST_ARG0      (l_src2_arg0_24m),
    .O_DST_ARG1      (l_src2_arg1_24m),
    .O_DST_ARG2      (l_src2_arg2_24m),
    .I_DST_EVT_READY (l_src_evt_ready[2])
  );

  uart_log_cli_byte_async_bridge #(
    .FIFO_DEPTH(16)
  ) u_cli_rx_bridge (
    .I_SRC_CLK       (clk_24m),
    .I_SRC_RST_N     (rst_fpga_24m_n),
    .I_DST_CLK       (clk_96m_sdram),
    .I_DST_RST_N     (rst_fpga_100m_n),
    .I_SRC_VALID     (l_cli_rx_valid_24m),
    .I_SRC_DATA      (l_cli_rx_data_24m),
    .O_SRC_READY     (),
    .O_DST_VALID     (l_cli_rx_valid_100m),
    .O_DST_DATA      (l_cli_rx_data_100m),
    .I_DST_READY     (1'b1)
  );

  assign l_sdram_raw_tx_ready_100m = 1'b0;
  assign l_sdram_raw_tx_valid_24m  = 1'b0;
  assign l_sdram_raw_tx_data_24m   = 8'h00;

  //---------------------------------------------------------------------------------------------
  // UART ESP-WROOM2 / uart_log_cli
  //---------------------------------------------------------------------------------------------
  uart_log_cli #(
    .CLK_HZ             (UART_LOG_CLK_HZ),
    .BAUD               (UART_LOG_BAUD),
    .NUM_SRC            (UART_LOG_NUM_SRC)
  ) u_uart_log_cli (
    .I_CLK              (clk_24m),
    .I_RST_N            (rst_fpga_24m_n),
    .I_UART_RX          (uart_esp_rx),
    .O_UART_TX          (uart_esp_tx),
    .I_SRC_EVT_VALID    (l_src_evt_valid),
    .I_SRC_EVT_ID       (l_src_evt_id),
    .I_SRC_ARG0         (l_src_arg0),
    .I_SRC_ARG1         (l_src_arg1),
    .I_SRC_ARG2         (l_src_arg2),
    .O_SRC_EVT_READY    (l_src_evt_ready),
    .O_SRC_ENABLE       (l_src_enable),
    .O_LOG_SRC_SEL      (),
    .O_SOFT_RESET_REQ   (soft_rst_req_cli_24m),
    .O_STATUS_REQ_VALID (),
    .O_STATUS_REQ_KEY   (),
    .I_RAW_RX_BYPASS    (l_sdram_raw_rx_bypass_sync2_24m),
    .I_RAW_TX_MODE      (1'b0),
    .I_RAW_TX_VALID     (l_sdram_raw_tx_valid_24m),
    .I_RAW_TX_DATA      (l_sdram_raw_tx_data_24m),
    .O_RAW_TX_READY     (),
    .O_CLI_RX_VALID     (l_cli_rx_valid_24m),
    .O_CLI_RX_DATA      (l_cli_rx_data_24m),
    .O_MIRROR_VALID     (),
    .O_MIRROR_DATA      ()
  );

  assign uart_esp_rx       = PIN18_IOL49B_LED3;
  assign PIN19_IOL51A_LED4 = uart_esp_tx;



endmodule

