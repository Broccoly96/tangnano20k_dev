# tangnano20k_dev

FPGA development repository for the Tang Nano 20K.
The current tree includes a working `uart_log_cli` integration for
real hardware, with host-side log reception over an ESP WiFi
UART-to-TCP bridge.

## Overview

- Target board: Sipeed Tang Nano 20K
- Main user RTL: [01_src](./01_src)
- Simulation assets: [02_tb](./02_tb), [03_sim](./03_sim)
- Gowin implementation project: [05_impl](./05_impl)
- Host tools: [11_app](./11_app)
- Current debug path:
  `FPGA uart_log_cli -> UART -> ESP bridge -> TCP 192.168.10.40:2323`

This repository can generate internal FPGA events, serialize them into
UART log frames, and decode them on the host with the `debug_log` tool.

## Directory Layout

- [00_ip](./00_ip): Vendor / third-party IP
- [01_src](./01_src): User RTL
- [02_tb](./02_tb): Testbench common packages and helpers
- [03_sim](./03_sim): Testbench tops and testcases
- [04_simlib](./04_simlib): Precompiled simulation libraries
- [05_impl](./05_impl): Gowin project, SDC, CST, implementation outputs
- [11_app](./11_app): Host-side tools and utility scripts

## UART Log Bring-Up Status

The current Tang Nano 20K top-level implementation enables
`uart_log_cli` in
[tangnano20k_top.sv](./01_src/tangnano20k_top.sv).

- UART clock: `24 MHz`
- UART baud: `115200`
- Active source: `uart_log_testsrc1`
- Heartbeat source id: `0x01`
- Heartbeat event id: `0x11`
- Heartbeat period: `10 s`
- Host transport: `tcp`
- Default endpoint: `192.168.10.40:2323`

Hardware verification has already confirmed continuous heartbeat
reception over TCP with valid CRCs.

## Host Tool

The user-facing launcher is
[11_app/debug_log_cli](./11_app/debug_log_cli).

Main features:

- Receive UART log frames over TCP
- UART log frame parsing and CRC checking
- Event decoding through YAML decode rules
- Log filtering in the TUI
- TCP receive statistics
  - packet count
  - byte count
  - sequence loss
  - CRC error count

Launch example:

```powershell
python .\11_app\debug_log_cli\uart_log_tool.py `
  --transport tcp `
  --tcp-host 192.168.10.40 `
  --tcp-port 2323
```

## FPGA Build

Gowin project:
[05_impl/tangnano20k.gprj](./05_impl/tangnano20k.gprj)

Example `run all` command on Windows PowerShell:

```powershell
$tcl = "C:\Electronics\GitHubProjects\tangnano20k_dev\05_impl\run_all.tcl"
Set-Content -Path $tcl -Value @(
  "open_project C:/Electronics/GitHubProjects/tangnano20k_dev/05_impl/tangnano20k.gprj"
  "run all"
  "exit"
)
& "C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" $tcl
```

Main outputs:

- Bitstream:
  [05_impl/impl/pnr/tangnano20k.fs](./05_impl/impl/pnr/tangnano20k.fs)
- Timing report:
  [05_impl/impl/pnr/tangnano20k_tr_content.html](./05_impl/impl/pnr/tangnano20k_tr_content.html)

## Timing Constraints

The SDC file is located at
[05_impl/src/tangnano20k.sdc](./05_impl/src/tangnano20k.sdc).

Current constraints:

- `create_clock` for `PIN04_IOL07A_LPLL1` at `27 MHz`
- `create_generated_clock` for PLL output
  `u0_gowin_pll/rpll_inst/CLKOUT` at `24 MHz`

Latest PnR results:

- Setup violated endpoints: `0`
- Hold violated endpoints: `0`
- `CLK_FPGA_24M` Actual Fmax: `50.930 MHz`

## Simulation

The UART log smoke test is located in
[03_sim/01_uart_log_cli_smoke](./03_sim/01_uart_log_cli_smoke).

Example run on Windows:

```powershell
cd .\03_sim
python sim.py 01_uart_log_cli_smoke\testbench.sv
```

This smoke test checks:

- heartbeat frame generation
- `src_id = 0x01`
- `event_id = 0x11`
- valid CRC
- basic help / reset behavior

## Programming

Example SRAM programming command on Windows:

```powershell
& "C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" `
  --device GW2AR-18C `
  --run 2 `
  --fsFile C:\Electronics\GitHubProjects\tangnano20k_dev\05_impl\impl\pnr\tangnano20k.fs
```

## Known Notes

- Heartbeat reception over the TCP bridge has been verified.
- The soft-reset byte for `Ctrl+R` (`0x12`) has not yet been fully
  verified on the current ESP bridge path.
  The FPGA-side reset handling is implemented, but the bridge may not
  be forwarding this control code transparently.
- Gowin PnR reports warning `PR1014`, but current timing still meets
  the design requirements.

## Related Files

- FPGA top:
  [01_src/tangnano20k_top.sv](./01_src/tangnano20k_top.sv)
- UART log core:
  [01_src/uart_log_cli/uart_log_cli.sv](./01_src/uart_log_cli/uart_log_cli.sv)
- Test source:
  [01_src/uart_log_cli/uart_log_testsrc1.sv](./01_src/uart_log_cli/uart_log_testsrc1.sv)
- Host launcher:
  [11_app/debug_log_cli/uart_log_tool.py](./11_app/debug_log_cli/uart_log_tool.py)
- Host TUI:
  [11_app/uart_log_tool/debug_log_tool/uart_log_tui.py](./11_app/uart_log_tool/debug_log_tool/uart_log_tui.py)
