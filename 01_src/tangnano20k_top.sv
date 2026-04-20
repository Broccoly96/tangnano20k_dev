//---------------------------------------------------------------------------------------------
// Name         : tangnano20k_top
// Description  : top module
//---------------------------------------------------------------------------------------------
`include "uart_log_cli/uart_log_evt_if.sv"
`include "uart_log_cli/uart_log_src_async_bridge.sv"
`include "uart_log_cli/uart_log_cli_byte_async_bridge.sv"

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
  // Embedded SDRAM ports
  output           O_sdram_clk,
  output           O_sdram_cke,
  output           O_sdram_cs_n,
  output           O_sdram_cas_n,
  output           O_sdram_ras_n,
  output           O_sdram_wen_n,
  output   [3:0]   O_sdram_dqm,
  output   [10:0]  O_sdram_addr,
  output   [1:0]   O_sdram_ba,
  inout    [31:0]  IO_sdram_dq
  );

  localparam int unsigned                 FPGA_INIT_WAIT                      = 24000;
  localparam int unsigned                 UART_LOG_CLK_HZ                     = 24_000_000;
  localparam int unsigned                 UART_LOG_BAUD                       = 115_200;
  localparam int unsigned                 UART_LOG_NUM_SRC                    = 3;
  localparam logic [UART_LOG_NUM_SRC-1:0] UART_LOG_SRC_ENABLE_MASK            = 3'b110;
  localparam int unsigned                 SOFT_RESET_HOLD_CYCLES              = UART_LOG_CLK_HZ;
  localparam int unsigned                 SOFT_RESET_CNT_W                    = $clog2(SOFT_RESET_HOLD_CYCLES + 1);
  localparam bit                          SDRAM_MEMTEST_USE_FIXED_WINDOW_ADDR = 1'b0;
  localparam logic [1:0]                  SDRAM_MEMTEST_FIXED_BANK_ADDR       = 2'd2;
  localparam logic [10:0]                 SDRAM_MEMTEST_FIXED_ROW_ADDR        = 11'd2;
  localparam logic [7:0]                  SDRAM_MEMTEST_FIXED_COL_START       = 8'd5;
  localparam int unsigned                 SDRAM_MEMTEST_BURST_WORDS           = 1;
  localparam int unsigned                 SDRAM_MEMTEST_TEST_WORDS            = 256;
  localparam int unsigned                 SDRAM_MEMTEST_CLEAR_WORDS           = 256;

  // Interface
  uart_log_evt_if                l_uart_src_if [UART_LOG_NUM_SRC] ();
  uart_log_evt_if                l_sdram_test_evt_if ();
  uart_log_evt_if                l_sdram_host_evt_if ();

  // PLL
  wire        clk_24m_sys;
  wire        clk_48m_sdram;
  wire        clk_48m_unused;
  wire        pll_lock;
  wire        rst_fpga_24m_n;
  logic       rst_fpga_48m_n;
  // Button
  logic       button_s1;
  logic       button_s2;

  // UART to ESP_WROOM2
  logic                         uart_esp_tx;
  logic                         uart_esp_rx;
  logic                         soft_rst_req_24m;
  logic                         soft_rst_req_cli_24m;
  logic                         soft_rst_n;
  logic [SOFT_RESET_CNT_W-1:0]  soft_reset_cnt;




  logic                          l_sdram_init_done;
  logic                          l_sdram_test_active;
  logic                          l_sdram_test_pass;
  logic                          l_sdram_test_fail;
  logic                          l_sdram_host_busy;
  logic                          l_cli_rx_valid_24m;
  logic [7:0]                    l_cli_rx_data_24m;
  logic                          l_cli_rx_valid_48m;
  logic [7:0]                    l_cli_rx_data_48m;
  logic                          I_sdrc_rst_n;
  logic                          I_sdrc_clk;
  logic                          I_sdram_clk;
  logic                          I_sdrc_cmd_en;
  logic [2:0]                    I_sdrc_cmd;
  logic                          I_sdrc_precharge_ctrl;
  logic                          I_sdram_selfrefresh;
  logic                          I_sdram_power_down;
  logic [20:0]                   I_sdrc_addr;
  logic [7:0]                    I_sdrc_data_len;
  logic [3:0]                    I_sdrc_dqm;
  logic [31:0]                   I_sdrc_data;
  logic [31:0]                   O_sdrc_data;
  logic                          O_sdrc_init_done;
  logic                          O_sdrc_cmd_ack;
  logic                          l_hostif_sdrc_cmd_en;
  logic [2:0]                    l_hostif_sdrc_cmd;
  logic                          l_hostif_sdrc_precharge_ctrl;
  logic                          l_hostif_sdrc_rst_n;
  logic [20:0]                   l_hostif_sdrc_addr;
  logic [7:0]                    l_hostif_sdrc_data_len;
  logic [3:0]                    l_hostif_sdrc_dqm;
  logic [31:0]                   l_hostif_sdrc_data;
  logic                          l_hostif_sdrc_read_sample_valid;

  //---------------------------------------------------------------------------------------------
  // System Onboard LED
  //---------------------------------------------------------------------------------------------
  assign PIN15_IOL47A_LED0 = ~rst_fpga_48m_n;
  assign PIN16_IOL47B_LED1 = ~l_sdram_init_done;
  assign PIN17_IOL49A_LED2 = ~l_sdram_test_pass;
  assign PIN20_IOL51B_LED5 = ~l_sdram_test_fail;


  //---------------------------------------------------------------------------------------------
  // PLL
  //---------------------------------------------------------------------------------------------
  gowin_pll u0_gowin_pll(
    .clkin    (PIN04_IOL07A_LPLL1),
    .lock     (pll_lock),
    .clkout   (clk_48m_sdram),
    .clkoutp  (clk_48m_unused),
    .clkoutd  (clk_24m_sys)
  );

  //---------------------------------------------------------------------------------------------
  // Reset Management
  //---------------------------------------------------------------------------------------------
  reset_mng #(
    .FPGA_INIT_WAIT     (FPGA_INIT_WAIT)
    ) u0_reset_mng(
    .I_CLK_24M          (clk_24m_sys),
    .I_CLK_48M          (clk_48m_sdram),
    .I_PLL_LOCK         (pll_lock),
    .I_SOFT_RST_N       (1'b1),
    .O_RST_FPGA_24M_N   (rst_fpga_24m_n),
    .O_RST_FPGA_48M_N   (rst_fpga_48m_n)
  );

  assign soft_rst_req_24m       = 1'b0;


  //---------------------------------------------------------------------------------------------
  // Soft reset pulse stretcher
  //---------------------------------------------------------------------------------------------
  // Holds reset_mng.I_SOFT_RST_N low for at least 1ms after Ctrl+R.
  // This logic is intentionally independent from rst_fpga_24m_n so the hold
  // time survives the user-logic reset it requests.
  always_ff @(posedge clk_24m_sys or negedge rst_fpga_24m_n) begin
    if (~rst_fpga_24m_n) begin
      soft_reset_cnt <= '0;
      soft_rst_n       <= 1'b1;
    end else if (soft_rst_req_24m || soft_rst_req_cli_24m) begin
      soft_reset_cnt <= SOFT_RESET_HOLD_CYCLES - 1;
      soft_rst_n       <= 1'b0;
    end else if (soft_reset_cnt != 0) begin
      soft_reset_cnt <= soft_reset_cnt - 1'b1;
      soft_rst_n       <= 1'b0;
//    end else if (button_s1) begin
//      soft_rst_n       <= 1'b0;
    end else begin
      soft_reset_cnt <= '0;
      soft_rst_n       <= 1'b1;
    end
  end

  assign button_s1 = PIN88_IOT30A;
  assign button_s2 = PIN87_IOT30B;



  //---------------------------------------------------------------------------------------------
  // UART debug log source wiring
  //---------------------------------------------------------------------------------------------
  assign l_uart_src_if[0].evt_valid = 1'b0;
  assign l_uart_src_if[0].evt_id    = 8'h00;
  assign l_uart_src_if[0].arg0      = 32'h0000_0000;
  assign l_uart_src_if[0].arg1      = 32'h0000_0000;
  assign l_uart_src_if[0].arg2      = 32'h0000_0000;

  uart_log_src_async_bridge u_sdram_test_evt_bridge (
    .I_SRC_CLK        (clk_48m_sdram),
    .I_SRC_RST_N      (rst_fpga_48m_n),
    .I_DST_CLK        (clk_24m_sys),
    .I_DST_RST_N      (rst_fpga_24m_n),
    .SRC_IF           (l_sdram_test_evt_if),
    .DST_IF           (l_uart_src_if[1])
  );

  uart_log_src_async_bridge u_sdram_host_evt_bridge (
    .I_SRC_CLK        (clk_48m_sdram),
    .I_SRC_RST_N      (rst_fpga_48m_n),
    .I_DST_CLK        (clk_24m_sys),
    .I_DST_RST_N      (rst_fpga_24m_n),
    .SRC_IF           (l_sdram_host_evt_if),
    .DST_IF           (l_uart_src_if[2])
  );

  uart_log_cli_byte_async_bridge u_cli_rx_bridge (
    .I_SRC_CLK        (clk_24m_sys),
    .I_SRC_RST_N      (rst_fpga_24m_n),
    .I_DST_CLK        (clk_48m_sdram),
    .I_DST_RST_N      (rst_fpga_48m_n),
    .I_SRC_VALID      (l_cli_rx_valid_24m),
    .I_SRC_DATA       (l_cli_rx_data_24m),
    .O_SRC_READY      (),
    .O_DST_VALID      (l_cli_rx_valid_48m),
    .O_DST_DATA       (l_cli_rx_data_48m),
    .I_DST_READY      (1'b1)
  );

  sdram_emb_hostif_ctrl #(
    .MEMTEST_USE_FIXED_WINDOW_ADDR (SDRAM_MEMTEST_USE_FIXED_WINDOW_ADDR),
    .MEMTEST_FIXED_BANK_ADDR (SDRAM_MEMTEST_FIXED_BANK_ADDR),
    .MEMTEST_FIXED_ROW_ADDR (SDRAM_MEMTEST_FIXED_ROW_ADDR),
    .MEMTEST_FIXED_COL_START (SDRAM_MEMTEST_FIXED_COL_START),
    .MEMTEST_BURST_WORDS (SDRAM_MEMTEST_BURST_WORDS),
    .MEMTEST_TEST_WORDS (SDRAM_MEMTEST_TEST_WORDS),
    .MEMTEST_CLEAR_WORDS(SDRAM_MEMTEST_CLEAR_WORDS),
    .MEMTEST_POST_INIT_WAIT_CYCLES (2_400_000),
    .MEMTEST_POST_WRITE_TO_READ_GAP_CYCLES (16)
  ) u_sdram_emb_hostif_ctrl (
    .I_CLK                    (clk_48m_sdram),
    .I_RST_N                  (rst_fpga_48m_n),
    .I_CLI_RX_VALID           (l_cli_rx_valid_48m),
    .I_CLI_RX_DATA            (l_cli_rx_data_48m),
    .O_INIT_DONE              (l_sdram_init_done),
    .O_TEST_ACTIVE            (l_sdram_test_active),
    .O_TEST_PASS              (l_sdram_test_pass),
    .O_TEST_FAIL              (l_sdram_test_fail),
    .O_HOST_BUSY              (l_sdram_host_busy),
    // SDRAM User Interface
    .O_SDRC_RST_N             (l_hostif_sdrc_rst_n),
    .I_SDRC_RD_DATA           (O_sdrc_data),
    .I_SDRC_CMD_ACK           (O_sdrc_cmd_ack),
    .I_SDRC_INIT_DONE         (O_sdrc_init_done),
    .O_SDRC_CMD_EN            (l_hostif_sdrc_cmd_en),
    .O_SDRC_CMD               (l_hostif_sdrc_cmd),
    .O_SDRC_PRECHARGE_CTRL    (l_hostif_sdrc_precharge_ctrl),
    .O_SDRC_ADDR              (l_hostif_sdrc_addr),
    .O_SDRC_DATA_LEN          (l_hostif_sdrc_data_len),
    .O_SDRC_DQM               (l_hostif_sdrc_dqm),
    .O_SDRC_WR_DATA           (l_hostif_sdrc_data),
    .O_SDRC_READ_SAMPLE_VALID (l_hostif_sdrc_read_sample_valid),
    //
    .TEST_EVT_IF              (l_sdram_test_evt_if),
    .HOST_EVT_IF              (l_sdram_host_evt_if)
  );


  //---------------------------------------------------------------------------------------------
  // GW2AR-18 embedded SDRAM controller IP
  //    - O_sdram_* signals should be instantiated as I/O ports in the top module.
  //      Gowin EDA will automatically connect them to the SDRAM.
  //---------------------------------------------------------------------------------------------
  assign I_sdrc_rst_n           = l_hostif_sdrc_rst_n;
  assign I_sdrc_clk             = clk_48m_sdram;
  assign I_sdram_clk            = clk_48m_sdram;
  assign I_sdrc_cmd_en          = l_hostif_sdrc_cmd_en;
  assign I_sdrc_cmd             = l_hostif_sdrc_cmd;
  assign I_sdrc_precharge_ctrl  = l_hostif_sdrc_precharge_ctrl;
  assign I_sdram_selfrefresh    = 1'b0;
  assign I_sdram_power_down     = 1'b0;
  assign I_sdrc_addr            = l_hostif_sdrc_addr;
  assign I_sdrc_data_len        = l_hostif_sdrc_data_len;
  assign I_sdrc_dqm             = l_hostif_sdrc_dqm;
  assign I_sdrc_data            = l_hostif_sdrc_data;


	embedded_sdram_hs u_embedded_sdram_hs(
		.O_sdram_clk            (O_sdram_clk),           // output O_sdram_clk
		.O_sdram_cke            (O_sdram_cke),           // output O_sdram_cke
		.O_sdram_cs_n           (O_sdram_cs_n),          // output O_sdram_cs_n
		.O_sdram_cas_n          (O_sdram_cas_n),         // output O_sdram_cas_n
		.O_sdram_ras_n          (O_sdram_ras_n),         // output O_sdram_ras_n
		.O_sdram_wen_n          (O_sdram_wen_n),         // output O_sdram_wen_n
		.O_sdram_dqm            (O_sdram_dqm),           // output [3:0] O_sdram_dqm
		.O_sdram_addr           (O_sdram_addr),          // output [10:0] O_sdram_addr
		.O_sdram_ba             (O_sdram_ba),            // output [1:0] O_sdram_ba
		.IO_sdram_dq            (IO_sdram_dq),           // inout [31:0] IO_sdram_dq
		.I_sdrc_rst_n           (I_sdrc_rst_n),          // input I_sdrc_rst_n
		.I_sdrc_clk             (I_sdrc_clk),            // input I_sdrc_clk
		.I_sdram_clk            (I_sdram_clk),           // input I_sdram_clk
		.I_sdrc_cmd_en          (I_sdrc_cmd_en),         // input I_sdrc_cmd_en
		.I_sdrc_cmd             (I_sdrc_cmd),            // input [2:0] I_sdrc_cmd
		.I_sdrc_precharge_ctrl  (I_sdrc_precharge_ctrl), // input I_sdrc_precharge_ctrl
		.I_sdram_power_down     (I_sdram_power_down),    // input I_sdram_power_down
		.I_sdram_selfrefresh    (I_sdram_selfrefresh),   // input I_sdram_selfrefresh
		.I_sdrc_addr            (I_sdrc_addr),           // input [20:0] I_sdrc_addr
		.I_sdrc_dqm             (I_sdrc_dqm),            // input [3:0] I_sdrc_dqm
		.I_sdrc_data            (I_sdrc_data),           // input [31:0] I_sdrc_data
		.I_sdrc_data_len        (I_sdrc_data_len),       // input [7:0] I_sdrc_data_len
		.O_sdrc_data            (O_sdrc_data),           // output [31:0] O_sdrc_data
		.O_sdrc_init_done       (O_sdrc_init_done),      // output O_sdrc_init_done
		.O_sdrc_cmd_ack         (O_sdrc_cmd_ack)         // output O_sdrc_cmd_ack
	);

  //---------------------------------------------------------------------------------------------
  // UART ESP-WROOM2 / uart_log_cli
  //---------------------------------------------------------------------------------------------
  uart_log_cli #(
    .CLK_HZ             (UART_LOG_CLK_HZ),
    .BAUD               (UART_LOG_BAUD),
    .NUM_SRC            (UART_LOG_NUM_SRC),
    .SRC_ENABLE_MASK    (UART_LOG_SRC_ENABLE_MASK)
  ) u_uart_log_cli (
    .I_CLK              (clk_24m_sys),
    .I_RST_N            (rst_fpga_24m_n),
    .I_UART_RX          (uart_esp_rx),
    .O_UART_TX          (uart_esp_tx),
    .SRC_IF             (l_uart_src_if),
    .O_LOG_SRC_SEL      (),
    .O_SOFT_RESET_REQ   (soft_rst_req_cli_24m),
    .O_CLI_RX_VALID     (l_cli_rx_valid_24m),
    .O_CLI_RX_DATA      (l_cli_rx_data_24m)
  );

  assign uart_esp_rx       = PIN18_IOL49B_LED3;
  assign PIN19_IOL51A_LED4 = uart_esp_tx;



endmodule
