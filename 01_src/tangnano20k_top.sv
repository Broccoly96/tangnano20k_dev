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
  output  wire      PIN26_IOB06B,   // SSD1331_RES_N
  input   wire      PIN27_IOB08A,
  input   wire      PIN28_IOB08B,
  output  wire      PIN29_IOB14A,   // SSD1331_DC
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
  inout   wire      PIN42_IOB42B,   // EEPROM_SDA
  input   wire      PIN48_IOR49B,
  inout   wire      PIN49_IOR49A,   // SSD1306_SDA
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
  output  wire      PIN73_IOT40A,   // SSD1331_CS_N
  output  wire      PIN74_IOT34B,   // SSD1331_D0_SCLK
  output  wire      PIN75_IOT34A,   // SSD1331_D1_SDIN
  output  wire      PIN76_IOT30B,   // EEPROM_WP
  output  wire      PIN77_IOT30A,
  input   wire      PIN79_IOT27B,
  inout   wire      PIN80_IOT27A,   // EEPROM_SCL
  input   wire      PIN81_IOT17B,
  input   wire      PIN82_IOT17A,
  input   wire      PIN83_IOT6B,
  input   wire      PIN84_IOT6A,
  output  wire      PIN85_IOT4B,
  inout   wire      PIN86_IOT4A,    // SSD1306_SCL
  input   wire      PIN87_IOT30B,
  input   wire      PIN88_IOT30A,
  // Embedded SDRAM ports
  output            O_sdram_clk,
  output            O_sdram_cke,
  output            O_sdram_cs_n,
  output            O_sdram_cas_n,
  output            O_sdram_ras_n,
  output            O_sdram_wen_n,
  output   [3:0]    O_sdram_dqm,
  output   [10:0]   O_sdram_addr,
  output   [1:0]    O_sdram_ba,
  inout    [31:0]   IO_sdram_dq
  );

  localparam int unsigned FPGA_INIT_WAIT            = 24000;

  localparam int unsigned UART_LOG_CLK_HZ           = 24_000_000;
  localparam int unsigned UART_LOG_BAUD             = 115_200;
  localparam int unsigned UART_LOG_NUM_SRC          = 4;
  // Source index assignment:
  //   0 -> EEPROM host bridge
  //   1 -> SDRAM self-test event stream
  //   2 -> SDRAM host bridge used by uart_log_tool STS/RW/Map
  //   3 -> SSD1306 control/status bridge
  //
  // The GW2AR-18 build does not currently close PnR with every tap enabled.
  // Keep the functional host-facing bridges enabled:
  //   - EEPROM host control
  //   - SDRAM host control
  //   - SSD1306 control
  // The standalone SDRAM self-test event stream remains disabled because the
  // tool features fixed in this change use the status-map on source index 2.
  localparam logic [UART_LOG_NUM_SRC-1:0] UART_LOG_SRC_ENABLE_MASK = 4'b1101;

  localparam int unsigned SOFT_RESET_HOLD_CYCLES    = UART_LOG_CLK_HZ;
  localparam int unsigned EEPROM_I2C_BIT_RATE_HZ    = 1_000_000;
  localparam int unsigned SSD1306_I2C_BIT_RATE_HZ   = 1_000_000;
  localparam logic [6:0]  SSD1306_I2C_SLAVE_ADDR    = 7'h3C;
  localparam logic [20:0] SSD1306_FRAMEBUFFER_BASE_ADDR = 21'h10000;
  localparam int unsigned SDRAM_MEMTEST_BURST_WORDS = 1;
  localparam int unsigned SDRAM_MEMTEST_TEST_WORDS  = 256;
  localparam int unsigned SDRAM_MEMTEST_CLEAR_WORDS = 256;

  // Interface
  uart_log_evt_if  l_uart_src_if [UART_LOG_NUM_SRC] ();
  uart_log_evt_if  l_eeprom_evt_if ();
  uart_log_evt_if  l_sdram_test_evt_if ();
  uart_log_evt_if  l_sdram_host_evt_if ();
  uart_log_evt_if  l_ssd1306_evt_if ();

  // PLL
  wire        clk_24m_sys;
  wire        clk_48m_sdram;
  wire        clk_48m_unused;
  wire        pll_lock;
  wire        rst_fpga_24m_n;
  logic       rst_fpga_48m_n;
  // UART to ESP_WROOM2
  logic       uart_esp_tx;
  logic       uart_esp_rx;
  logic       soft_rst_req_cli_24m;
  logic       l_eeprom_i2c_sda_drive_low;
  logic       l_eeprom_i2c_scl_drive_low;
  logic       l_eeprom_i2c_sda_in;
  logic       l_eeprom_i2c_scl_in;
  logic       l_ssd1306_i2c_sda_drive_low;
  logic       l_ssd1306_i2c_scl_drive_low;
  logic       l_ssd1306_i2c_sda_in;
  logic       l_ssd1306_i2c_scl_in;

  logic         l_sdram_init_done;
  logic         l_sdram_test_active;
  logic         l_sdram_test_pass;
  logic         l_sdram_test_fail;
  logic         l_sdram_host_busy;
  logic         l_cli_rx_valid_24m;
  logic [7:0]   l_cli_rx_data_24m;
  logic         l_cli_rx_valid_48m;
  logic [7:0]   l_cli_rx_data_48m;
  logic         I_sdrc_rst_n;
  logic         I_sdrc_clk;
  logic         I_sdram_clk;
  logic         I_sdrc_cmd_en;
  logic [2:0]   I_sdrc_cmd;
  logic         I_sdrc_precharge_ctrl;
  logic         I_sdram_selfrefresh;
  logic         I_sdram_power_down;
  logic [20:0]  I_sdrc_addr;
  logic [7:0]   I_sdrc_data_len;
  logic [3:0]   I_sdrc_dqm;
  logic [31:0]  I_sdrc_data;
  logic [31:0]  O_sdrc_data;
  logic         O_sdrc_init_done;
  logic         O_sdrc_cmd_ack;
  logic         l_hostif_sdrc_cmd_en;
  logic [2:0]   l_hostif_sdrc_cmd;
  logic         l_hostif_sdrc_precharge_ctrl;
  logic         l_hostif_sdrc_rst_n;
  logic [20:0]  l_hostif_sdrc_addr;
  logic [7:0]   l_hostif_sdrc_data_len;
  logic [3:0]   l_hostif_sdrc_dqm;
  logic [31:0]  l_hostif_sdrc_data;
  logic         l_hostif_sdrc_read_sample_valid;
  logic         l_ssd1306_cmd_busy;
  logic         l_ssd1306_mem_req_valid;
  logic         l_ssd1306_mem_req_ready;
  logic [20:0]  l_ssd1306_mem_req_addr;
  logic [8:0]   l_ssd1306_mem_req_words;
  logic         l_ssd1306_mem_raw_done;
  logic         l_ssd1306_mem_raw_err_valid;
  logic [31:0]  l_ssd1306_mem_raw_err_code;
  logic         l_ssd1306_mem_raw_rd_valid;
  logic         l_ssd1306_mem_raw_rd_ready;
  logic [8:0]   l_ssd1306_mem_raw_rd_index;
  logic [31:0]  l_ssd1306_mem_raw_rd_data;
  logic         l_ssd1306_mem_raw_rd_last;

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
    .FPGA_INIT_WAIT          (FPGA_INIT_WAIT),
    .SOFT_RESET_HOLD_CYCLES  (SOFT_RESET_HOLD_CYCLES)
    ) u0_reset_mng(
    .I_CLK_24M          (clk_24m_sys),
    .I_CLK_48M          (clk_48m_sdram),
    .I_PLL_LOCK         (pll_lock),
    .I_SOFT_RST_N       (1'b1),
    .I_SOFT_RST_REQ     (soft_rst_req_cli_24m),
    .O_RST_FPGA_24M_N   (rst_fpga_24m_n),
    .O_RST_FPGA_48M_N   (rst_fpga_48m_n)
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
    .O_SOFT_RESET_REQ   (soft_rst_req_cli_24m),
    .O_CLI_RX_VALID     (l_cli_rx_valid_24m),
    .O_CLI_RX_DATA      (l_cli_rx_data_24m)
  );

  assign uart_esp_rx       = PIN18_IOL49B_LED3;
  assign PIN19_IOL51A_LED4 = uart_esp_tx;
  assign l_eeprom_i2c_sda_in = PIN42_IOB42B;
  assign l_eeprom_i2c_scl_in = PIN80_IOT27A;
  assign l_ssd1306_i2c_sda_in = PIN49_IOR49A;
  assign l_ssd1306_i2c_scl_in = PIN86_IOT4A;
  assign PIN42_IOB42B = l_eeprom_i2c_sda_drive_low ? 1'b0 : 1'bz;
  assign PIN80_IOT27A = l_eeprom_i2c_scl_drive_low ? 1'b0 : 1'bz;
  assign PIN49_IOR49A = l_ssd1306_i2c_sda_drive_low ? 1'b0 : 1'bz;
  assign PIN86_IOT4A = l_ssd1306_i2c_scl_drive_low ? 1'b0 : 1'bz;
  assign PIN76_IOT30B = 1'b0;
  assign PIN73_IOT40A = 1'b1;
  assign PIN74_IOT34B = 1'b1;
  assign PIN75_IOT34A = 1'b0;
  assign PIN26_IOB06B = 1'b1;
  assign PIN29_IOB14A = 1'b0;
  assign PIN77_IOT30A = 1'b0;
  assign PIN85_IOT4B  = 1'b1;


  //---------------------------------------------------------------------------------------------
  // UART debug log source wiring
  //---------------------------------------------------------------------------------------------
  uart_log_src_async_bridge u_eeprom_evt_bridge (
    .I_SRC_CLK        (clk_48m_sdram),
    .I_SRC_RST_N      (rst_fpga_48m_n),
    .I_DST_CLK        (clk_24m_sys),
    .I_DST_RST_N      (rst_fpga_24m_n),
    .SRC_IF           (l_eeprom_evt_if),
    .DST_IF           (l_uart_src_if[0])
  );

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

  uart_log_src_async_bridge u_ssd1306_evt_bridge (
    .I_SRC_CLK        (clk_48m_sdram),
    .I_SRC_RST_N      (rst_fpga_48m_n),
    .I_DST_CLK        (clk_24m_sys),
    .I_DST_RST_N      (rst_fpga_24m_n),
    .SRC_IF           (l_ssd1306_evt_if),
    .DST_IF           (l_uart_src_if[3])
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

  eeprom_uart_bridge_ctrl #(
    .I2C_BIT_RATE_HZ        (EEPROM_I2C_BIT_RATE_HZ)
  ) u_eeprom_uart_bridge_ctrl (
    .I_CLK                (clk_48m_sdram),
    .I_RST_N              (rst_fpga_48m_n),
    .I_ENABLE             (1'b1),
    .I_CLI_RX_VALID       (l_cli_rx_valid_48m),
    .I_CLI_RX_DATA        (l_cli_rx_data_48m),
    .I_I2C_SDA_IN         (l_eeprom_i2c_sda_in),
    .I_I2C_SCL_IN         (l_eeprom_i2c_scl_in),
    .O_I2C_SDA_DRIVE_LOW  (l_eeprom_i2c_sda_drive_low),
    .O_I2C_SCL_DRIVE_LOW  (l_eeprom_i2c_scl_drive_low),
    .O_CMD_BUSY           (),
    .HOST_EVT_IF          (l_eeprom_evt_if)
  );

  ssd1306_sdram_uart_bridge_ctrl #(
    .CLK_HZ                (48_000_000),
    .I2C_BIT_RATE_HZ       (SSD1306_I2C_BIT_RATE_HZ),
    .I2C_SLAVE_ADDR        (SSD1306_I2C_SLAVE_ADDR),
    .FRAMEBUFFER_BASE_ADDR (SSD1306_FRAMEBUFFER_BASE_ADDR)
  ) u_ssd1306_uart_bridge_ctrl (
    .I_CLK                (clk_48m_sdram),
    .I_RST_N              (rst_fpga_48m_n),
    .I_ENABLE             (1'b1),
    .I_CLI_RX_VALID       (l_cli_rx_valid_48m),
    .I_CLI_RX_DATA        (l_cli_rx_data_48m),
    .O_MEM_REQ_VALID      (l_ssd1306_mem_req_valid),
    .I_MEM_REQ_READY      (l_ssd1306_mem_req_ready),
    .O_MEM_REQ_ADDR       (l_ssd1306_mem_req_addr),
    .O_MEM_REQ_WORDS      (l_ssd1306_mem_req_words),
    .I_MEM_RAW_DONE       (l_ssd1306_mem_raw_done),
    .I_MEM_RAW_ERR_VALID  (l_ssd1306_mem_raw_err_valid),
    .I_MEM_RAW_ERR_CODE   (l_ssd1306_mem_raw_err_code),
    .I_MEM_RAW_RD_VALID   (l_ssd1306_mem_raw_rd_valid),
    .O_MEM_RAW_RD_READY   (l_ssd1306_mem_raw_rd_ready),
    .I_MEM_RAW_RD_INDEX   (l_ssd1306_mem_raw_rd_index),
    .I_MEM_RAW_RD_DATA    (l_ssd1306_mem_raw_rd_data),
    .I_MEM_RAW_RD_LAST    (l_ssd1306_mem_raw_rd_last),
    .I_I2C_SDA_IN         (l_ssd1306_i2c_sda_in),
    .I_I2C_SCL_IN         (l_ssd1306_i2c_scl_in),
    .O_I2C_SDA_DRIVE_LOW  (l_ssd1306_i2c_sda_drive_low),
    .O_I2C_SCL_DRIVE_LOW  (l_ssd1306_i2c_scl_drive_low),
    .O_CMD_BUSY           (l_ssd1306_cmd_busy),
    .HOST_EVT_IF          (l_ssd1306_evt_if)
  );

  sdram_emb_hostif_ctrl #(
    .MEMTEST_BURST_WORDS  (SDRAM_MEMTEST_BURST_WORDS),
    .MEMTEST_TEST_WORDS   (SDRAM_MEMTEST_TEST_WORDS),
    .MEMTEST_CLEAR_WORDS  (SDRAM_MEMTEST_CLEAR_WORDS),
    .MEMTEST_POST_INIT_WAIT_CYCLES (2_400_000)
  ) u_sdram_emb_hostif_ctrl (
    .I_CLK                    (clk_48m_sdram),
    .I_RST_N                  (rst_fpga_48m_n),
    .I_CLI_RX_VALID           (l_cli_rx_valid_48m),
    .I_CLI_RX_DATA            (l_cli_rx_data_48m),
    .I_DISP_BUSY              (l_ssd1306_cmd_busy),
    .I_DISP_ACCESS_REQ_VALID  (l_ssd1306_mem_req_valid),
    .I_DISP_ACCESS_REQ_ADDR   (l_ssd1306_mem_req_addr),
    .I_DISP_ACCESS_REQ_WORDS  (l_ssd1306_mem_req_words),
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
    .O_DISP_ACCESS_REQ_READY  (l_ssd1306_mem_req_ready),
    .O_DISP_ACCESS_RAW_DONE   (l_ssd1306_mem_raw_done),
    .O_DISP_ACCESS_RAW_ERR_VALID (l_ssd1306_mem_raw_err_valid),
    .O_DISP_ACCESS_RAW_ERR_CODE  (l_ssd1306_mem_raw_err_code),
    .O_DISP_ACCESS_RAW_RD_VALID  (l_ssd1306_mem_raw_rd_valid),
    .I_DISP_ACCESS_RAW_RD_READY  (l_ssd1306_mem_raw_rd_ready),
    .O_DISP_ACCESS_RAW_RD_INDEX  (l_ssd1306_mem_raw_rd_index),
    .O_DISP_ACCESS_RAW_RD_DATA   (l_ssd1306_mem_raw_rd_data),
    .O_DISP_ACCESS_RAW_RD_LAST   (l_ssd1306_mem_raw_rd_last),
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




endmodule
