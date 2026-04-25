// File list for ModelSim compilation (relative to 03_sim)
+incdir+..\01_src
+incdir+..\02_tb
+define+SIM
+define+DISABLE_TIMING_CHECKS

..\00_ip\embedded_sdram_hs\embedded_sdram_hs.vo

..\02_tb\tb_log_pkg.sv
..\02_tb\embedded_sdram\embedded_sdram_tb_pkg.sv

..\01_src\sync_fifo_ae_af.sv
..\01_src\uart_log_cli\uart_log_cli_pkg.sv
..\01_src\uart_log_cli\uart_log_evt_if.sv
..\01_src\uart_log_cli\uart_log_src_async_bridge.sv
..\01_src\uart_log_cli\uart_log_cli_byte_async_bridge.sv
..\02_tb\uart_log_cli\uart_log_cli_tb_pkg.sv
..\01_src\embedded_sdram\sdram_hs_cmd_pkg.sv
..\01_src\embedded_sdram\sdram_uart_proto_pkg.sv
..\01_src\embedded_sdram\sdram_uart_ascii_ctrl.sv
..\01_src\embedded_sdram\sdram_uart_bulk_rx.sv
..\01_src\embedded_sdram\sdram_uart_access_engine.sv
..\01_src\embedded_sdram\sdram_status_reg_map.sv
..\01_src\embedded_sdram\sdram_memtest_ctrl.sv
..\01_src\embedded_sdram\sdram_uart_bridge_ctrl.sv
..\01_src\embedded_sdram\sdram_emb_hostif_ctrl.sv
..\01_src\uart_lite\uart_rx_stream.sv
..\01_src\uart_lite\uart_tx_stream.sv
..\01_src\uart_log_cli\uart_log_tap.sv
..\01_src\uart_log_cli\uart_log_cli_evt_fifo.sv
..\01_src\uart_log_cli\uart_log_testsrc1.sv
..\01_src\uart_log_cli\uart_log_cli.sv
