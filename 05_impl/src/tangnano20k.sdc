create_clock -name CLK_IN_27M -period 37.037 -waveform {0 18.518} [get_ports {PIN04_IOL07A_LPLL1}] -add
create_generated_clock -name CLK_SDRAM_96M -source [get_ports {PIN04_IOL07A_LPLL1}] -multiply_by 32 -divide_by 9 [get_pins {u0_gowin_pll/rpll_inst/CLKOUT}] -add
create_generated_clock -name CLK_SYS_24M -source [get_pins {u0_gowin_pll/rpll_inst/CLKOUT}] -divide_by 4 [get_pins {u0_gowin_pll/rpll_inst/CLKOUTD}] -add
