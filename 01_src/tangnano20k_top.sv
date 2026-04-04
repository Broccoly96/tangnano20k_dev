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
  // Simulation
  output  wire      O_RST_FPGA_N
);

  localparam int unsigned FPGA_INIT_WAIT         = 24000;
  localparam int unsigned UART_LOG_CLK_HZ        = 24_000_000;
  localparam int unsigned UART_LOG_BAUD          = 115_200;
  localparam int unsigned UART_LOG_NUM_SRC       = 1;
  localparam int unsigned SOFT_RESET_HOLD_CYCLES = UART_LOG_CLK_HZ;
  localparam int unsigned SOFT_RESET_CNT_W       = $clog2(SOFT_RESET_HOLD_CYCLES + 1);
  localparam int unsigned TESTSRC_PERIOD_CYCLES  = UART_LOG_CLK_HZ * 10;

  // PLL
  wire        clk_24m;
  wire        pll_lock;
  // Reset Management
  wire        rst_fpga_24m_n;
  // LED
  logic [5:0] sys_led_n;
  // Button
  logic       button_s1;
  logic       button_s2;

  // UART to ESP_WROOM2
  logic       uart_esp_tx;
  logic       uart_esp_rx;
  logic       soft_rst_req;
  logic       soft_rst_n;
  logic [SOFT_RESET_CNT_W-1:0] r_soft_reset_cnt;

  logic [UART_LOG_NUM_SRC-1:0]  l_src_evt_valid;
  logic [UART_LOG_NUM_SRC*8-1:0] l_src_evt_id;
  logic [UART_LOG_NUM_SRC*32-1:0] l_src_arg0;
  logic [UART_LOG_NUM_SRC*32-1:0] l_src_arg1;
  logic [UART_LOG_NUM_SRC*32-1:0] l_src_arg2;
  logic [UART_LOG_NUM_SRC-1:0]  l_src_evt_ready;
  logic [UART_LOG_NUM_SRC-1:0]  l_src_enable;
  logic                         l_src0_evt_valid;
  logic [7:0]                   l_src0_evt_id;
  logic [31:0]                  l_src0_arg0;
  logic [31:0]                  l_src0_arg1;
  logic [31:0]                  l_src0_arg2;

  //---------------------------------------------------------------------------------------------
  // PLL
  //---------------------------------------------------------------------------------------------
  gowin_pll u0_gowin_pll(
    .clkin    (PIN04_IOL07A_LPLL1),
    .lock     (pll_lock),
    .clkout   (clk_24m)
  );


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
    end else if (soft_rst_req) begin
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


  //---------------------------------------------------------------------------------------------
  // System Onboard LED
  //---------------------------------------------------------------------------------------------
  assign sys_led_n = {5'b11111, ~rst_fpga_24m_n};

  assign PIN15_IOL47A_LED0 = sys_led_n[0];
  assign PIN16_IOL47B_LED1 = sys_led_n[1];
  assign PIN17_IOL49A_LED2 = sys_led_n[2];
  // assign PIN18_IOL49B_LED3 = sys_led_n[3];
  // assign PIN19_IOL51A_LED4 = sys_led_n[4];
  assign PIN20_IOL51B_LED5 = sys_led_n[5];


  //---------------------------------------------------------------------------------------------
  // UART debug log source wiring
  //---------------------------------------------------------------------------------------------
  assign l_src_evt_valid[0]   = l_src0_evt_valid;
  assign l_src_evt_id[7:0]    = l_src0_evt_id;
  assign l_src_arg0[31:0]     = l_src0_arg0;
  assign l_src_arg1[31:0]     = l_src0_arg1;
  assign l_src_arg2[31:0]     = l_src0_arg2;

  uart_log_testsrc1 #(
    .CLK_HZ         (UART_LOG_CLK_HZ),
    .PERIOD_CYCLES  (TESTSRC_PERIOD_CYCLES)
  ) u_uart_log_testsrc1 (
    .I_CLK          (clk_24m),
    .I_RST_N        (rst_fpga_24m_n),
    .I_ENABLE       (l_src_enable[0]),
    .I_EVT_READY    (l_src_evt_ready[0]),
    .O_EVT_VALID    (l_src0_evt_valid),
    .O_EVT_ID       (l_src0_evt_id),
    .O_ARG0         (l_src0_arg0),
    .O_ARG1         (l_src0_arg1),
    .O_ARG2         (l_src0_arg2)
  );

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
    .O_SOFT_RESET_REQ   (soft_rst_req),
    .O_STATUS_REQ_VALID (),
    .O_STATUS_REQ_KEY   (),
    .O_CLI_RX_VALID     (),
    .O_CLI_RX_DATA      (),
    .O_MIRROR_VALID     (),
    .O_MIRROR_DATA      ()
  );

  assign uart_esp_rx       = PIN18_IOL49B_LED3;
  assign PIN19_IOL51A_LED4 = uart_esp_tx;



endmodule
