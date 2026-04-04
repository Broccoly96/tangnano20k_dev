//Copyright (C)2014-2025 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//GOWIN Version: 1.9.8.11 Education
//Created Time: 2025-04-13 11:55:03
create_clock -name CLK_IN_27M -period 37.037 -waveform {0 18.518} [get_ports {PIN04_IOL07A_LPLL1}] -add
create_generated_clock -name CLK_FPGA_24M -source [get_ports {PIN04_IOL07A_LPLL1}] -multiply_by 8 -divide_by 9 [get_pins {u0_gowin_pll/rpll_inst/CLKOUT}] -add
