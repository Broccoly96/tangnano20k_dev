`timescale 1ns / 1ps

module testbench;

  import tb_log_pkg::*;

  localparam time CLK_PERIOD = 20ns;

  logic       tb_clk;
  logic       tb_rst_n;
  logic       tb_tx_valid;
  logic       tb_tx_ready;
  logic [7:0] tb_tx_data;
  logic       tb_tx_dc;
  logic       tb_tx_first;
  logic       tb_tx_last;
  logic       tb_tx_done;
  logic       tb_busy;
  logic       tb_cs_n;
  logic       tb_sclk;
  logic       tb_sdin;
  logic       tb_dc;

  logic [7:0] cap_bytes [0:2];
  logic       cap_dcs [0:2];
  integer     cap_byte_count;
  integer     cap_bit_count;
  logic [7:0] cap_shift;
  integer     cap_cs_assert_count;
  integer     cap_cs_deassert_count;

  initial begin
    configure_logging(LOG_DEBUG);
    tb_clk = 1'b0;
    forever #(CLK_PERIOD / 2) tb_clk = ~tb_clk;
  end

  initial begin
    tb_rst_n = 1'b0;
    tb_tx_valid = 1'b0;
    tb_tx_data = 8'h00;
    tb_tx_dc = 1'b0;
    tb_tx_first = 1'b0;
    tb_tx_last = 1'b0;
    cap_byte_count = 0;
    cap_bit_count = 0;
    cap_shift = 8'h00;
    cap_cs_assert_count = 0;
    cap_cs_deassert_count = 0;
    repeat (8) @(posedge tb_clk);
    tb_rst_n = 1'b1;
  end

  initial begin
    #(2ms);
    log_fatal(1, "SSD1331 SPI TB", "simulation timeout");
  end

  ssd1331_spi_master #(
    .CLK_DIV (2)
  ) u_dut (
    .I_CLK      (tb_clk),
    .I_RST_N    (tb_rst_n),
    .I_TX_VALID (tb_tx_valid),
    .O_TX_READY (tb_tx_ready),
    .I_TX_DATA  (tb_tx_data),
    .I_TX_DC    (tb_tx_dc),
    .I_TX_FIRST (tb_tx_first),
    .I_TX_LAST  (tb_tx_last),
    .O_TX_DONE  (tb_tx_done),
    .O_BUSY     (tb_busy),
    .O_SPI_CS_N (tb_cs_n),
    .O_SPI_SCLK (tb_sclk),
    .O_SPI_SDIN (tb_sdin),
    .O_SPI_DC   (tb_dc)
  );

  always @(negedge tb_cs_n) begin
    if (tb_rst_n) begin
      cap_cs_assert_count = cap_cs_assert_count + 1;
    end
  end

  always @(posedge tb_cs_n) begin
    if (tb_rst_n) begin
      cap_cs_deassert_count = cap_cs_deassert_count + 1;
    end
  end

  always @(posedge tb_sclk) begin
    if (!tb_cs_n) begin
      cap_shift = {cap_shift[6:0], tb_sdin};
      cap_bit_count = cap_bit_count + 1;
      if (cap_bit_count == 8) begin
        if (cap_byte_count > 2) begin
          log_fatal(1, "SSD1331 SPI TB", "captured more bytes than expected");
        end
        cap_bytes[cap_byte_count] = cap_shift;
        cap_dcs[cap_byte_count] = tb_dc;
        cap_byte_count = cap_byte_count + 1;
        cap_bit_count = 0;
        cap_shift = 8'h00;
      end
    end
  end

  task automatic send_byte(
    input logic [7:0] tx_data,
    input logic       tx_dc,
    input logic       tx_first,
    input logic       tx_last
  );
    begin
      while (!tb_tx_ready) @(posedge tb_clk);
      @(negedge tb_clk);
      tb_tx_valid = 1'b1;
      tb_tx_data = tx_data;
      tb_tx_dc = tx_dc;
      tb_tx_first = tx_first;
      tb_tx_last = tx_last;
      @(posedge tb_clk);
      @(negedge tb_clk);
      tb_tx_valid = 1'b0;
      tb_tx_data = 8'h00;
      tb_tx_dc = 1'b0;
      tb_tx_first = 1'b0;
      tb_tx_last = 1'b0;
    end
  endtask

`include "testcase_smoke.svh"

endmodule