# tangnano20k_dev

FPGA development repository for the Sipeed Tang Nano 20K.
The current top design focuses on the Gowin embedded SDRAM HS controller
and a TCP-accessible `uart_log_cli` debug path.

The verified hardware path is:

```text
FPGA uart_log_cli -> UART -> ESP UART-to-TCP bridge -> 192.168.10.40:2323
```

## Overview

- Target board: Sipeed Tang Nano 20K
- Target device: Gowin GW2AR-18C
- Main user RTL: [01_src](./01_src)
- Simulation assets: [02_tb](./02_tb), [03_sim](./03_sim)
- Gowin implementation project: [05_impl](./05_impl)
- Host tools: [11_app](./11_app)
- Vendor IP: [00_ip](./00_ip), treated as read-only

The current production top is [tangnano20k_top.sv](./01_src/tangnano20k_top.sv).
It instantiates `embedded_sdram_hs`, the SDRAM host/test control layer,
and `uart_log_cli`.

## Directory Layout

- [00_ip](./00_ip): Vendor / third-party IP sources
- [01_src](./01_src): User RTL
- [02_tb](./02_tb): Common testbench packages, helpers, and BFMs
- [03_sim](./03_sim): Testbench tops and testcases
- [05_impl](./05_impl): Gowin project, constraints, and build outputs
- [11_app](./11_app): Host-side tools and utility scripts
- [docs](./docs): Design notes and SDRAM / TUI documentation

## Current RTL Status

The active SDRAM implementation uses the Gowin embedded SDRAM HS IP:

- IP instance path: [00_ip/embedded_sdram_hs](./00_ip/embedded_sdram_hs)
- Controller clock: `48 MHz`
- Host / UART clock: `24 MHz`
- SDRAM status-map version: `0x05`
- Startup self-test: 256 words, single-word access pattern
- Refresh scheduling: native HS `AUTO_REFRESH` command from user RTL
- Raw `BR` / `BW` bulk transport: reserved and intentionally unsupported
- Burst test commands: `BWT` and `BRT`, with RTL-generated data pattern

The HS native command interface is driven directly by user RTL.
The old `busy_n`, `rd_valid`, and `wrd_ack` style interface is no longer
used by the production top.

## UART Log Sources

`uart_log_cli` is configured with three source slots.
Production enables source indices 1 and 2 only.

| Source index | Frame `src_id` | Producer             | Purpose                              |
| ------------ | -------------- | -------------------- | ------------------------------------ |
| 0            | `0x01`         | disabled             | Reserved / production disabled       |
| 1            | `0x02`         | SDRAM self-test      | Startup and restart self-test events |
| 2            | `0x03`         | SDRAM host interface | Status, single R/W, and burst events |

Source selection is controlled by `uart_log_cli` control bytes and is
reported through system `EV_MODE_CHANGE` events.  There is no external
`O_LOG_SRC_SEL` port in the production RTL.

## Host Tools

The compatibility launcher is:

[11_app/debug_log_cli/uart_log_tool.py](./11_app/debug_log_cli/uart_log_tool.py)

Launch the TUI over TCP:

```powershell
python .\11_app\debug_log_cli\uart_log_tool.py `
  --transport tcp `
  --tcp-host 192.168.10.40 `
  --tcp-port 2323
```

The TUI includes SDRAM pages for:

- `SDRAM STS`: status-map decode and raw word view
- `SDRAM RW`: single-word read/write and map-style reads
- `SDRAM Map`: repeated single-word map read
- `SDRAM Burst`: `BWT` / `BRT` burst test mode

The command-line SDRAM helper is:

[11_app/debug_log_cli/sdram_hostif_tool.py](./11_app/debug_log_cli/sdram_hostif_tool.py)

Example TCP flow:

```powershell
python .\11_app\debug_log_cli\sdram_hostif_tool.py `
  --transport tcp `
  select-host

python .\11_app\debug_log_cli\sdram_hostif_tool.py `
  --transport tcp `
  status-read 0x00000 --select-host

python .\11_app\debug_log_cli\sdram_hostif_tool.py `
  --transport tcp `
  write 0x00100 0x89ABCDEF --select-host

python .\11_app\debug_log_cli\sdram_hostif_tool.py `
  --transport tcp `
  read 0x00100 --select-host
```

`sdram_hostif_tool.py` supports status read/write, self-test restart,
and single-word SDRAM read/write.  Burst tests are available from the
TUI and shared protocol helpers; raw bulk file transfer remains `INOP`.

## Simulation

Simulation is run from [03_sim](./03_sim).
Use `recompile` after RTL changes.

Windows ModelSim / Lattice OEM examples:

```powershell
cd .\03_sim
python sim.py 20_uart_log_cli_smoke\testbench.sv recompile
python sim.py 08_sdram_uart_bridge_ctrl\testbench.sv recompile
python sim.py 10_sdram_emb_hostif_ctrl\testbench.sv recompile
python sim.py 01_tangnano20k_top\testbench.sv recompile
```

Linux Questa example:

```bash
cd 03_sim
python3 sim_questa_linux.py 01_tangnano20k_top/testbench.sv recompile
```

Important current tests:

- `01_tangnano20k_top`: top-level HS SDRAM integration smoke
- `08_sdram_uart_bridge_ctrl`: ASCII bridge, status, single R/W, burst
- `10_sdram_emb_hostif_ctrl`: host interface and self-test integration
- `20_uart_log_cli_smoke`: UART log source selection and system events

Latest checked simulations:

```text
08_sdram_uart_bridge_ctrl    PASS
10_sdram_emb_hostif_ctrl     PASS
01_tangnano20k_top           PASS
20_uart_log_cli_smoke        PASS
```

## FPGA Build

Gowin project:

[05_impl/tangnano20k.gprj](./05_impl/tangnano20k.gprj)

Run all on Windows:

```powershell
& "C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" `
  C:\Electronics\GitHubProjects\tangnano20k_dev\05_impl\run_all.tcl
```

If direct script invocation opens an interactive console, pipe commands:

```powershell
@'
open_project C:/Electronics/GitHubProjects/tangnano20k_dev/05_impl/tangnano20k.gprj
run all
exit
'@ | & "C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe"
```

Main outputs:

- Bitstream:
  [05_impl/impl/pnr/tangnano20k.fs](./05_impl/impl/pnr/tangnano20k.fs)
- PnR report:
  [05_impl/impl/pnr/tangnano20k.rpt.txt](./05_impl/impl/pnr/tangnano20k.rpt.txt)
- Timing report:
  [05_impl/impl/pnr/tangnano20k_tr_content.html](./05_impl/impl/pnr/tangnano20k_tr_content.html)

Latest checked build:

```text
GowinSynthesis finish
Placement and routing completed
Bitstream generation completed

Setup violated endpoints: 0
Hold violated endpoints : 0
CLK_SDRAM_48M Fmax      : 62.954 MHz
CLK_SYS_24M Fmax        : 47.859 MHz
LUT                     : 4315
Register                : 2506
BSRAM                   : 17
```

The current PnR still reports warning `PR1014` for the input clock route.
Timing nevertheless meets the 48 MHz SDRAM and 24 MHz system clocks.

## Programming

SRAM programming command on Windows:

```powershell
& "C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" `
  --device GW2AR-18C `
  --run 2 `
  --fsFile C:\Electronics\GitHubProjects\tangnano20k_dev\05_impl\impl\pnr\tangnano20k.fs
```

Latest checked programming result:

```text
Programming... 100%
Status Code is: 0x00006020
Finished.
```

## Hardware Checks

Latest TCP hardware checks were run through `192.168.10.40:2323`.

Status:

```text
STATUS_READ_RSP addr=0x00000 data=0x051500A8 status=0x00000000
```

This confirms status-map version `0x05` and a passing SDRAM self-test.

Single-word write/read passed at:

```text
0x00000
0x00001
0x000FF
0x00100
0x1FFFFF
```

Burst test mode also passed:

```text
BWT 00000 00010 -> DONE
BRT 00000 00010 -> 16 words, mismatch=0
BWT 00100 00100 -> DONE
BRT 00100 00100 -> 256 words, mismatch=0
BRT 000F8 00010 -> ERR_ADDR_RANGE
```

## Related Documentation

- HS SDRAM IP summary:
  [docs/embedded_sdram/embedded_sdram_hs_spec_en.md](./docs/embedded_sdram/embedded_sdram_hs_spec_en.md)
- Legacy SDRAM IP summary:
  [docs/embedded_sdram/embedded_sdram_spec_en.md](./docs/embedded_sdram/embedded_sdram_spec_en.md)
- SDRAM TUI pages:
  [docs/embedded_sdram/uart_log_tui_sdram_pages_manual_en.md](./docs/embedded_sdram/uart_log_tui_sdram_pages_manual_en.md)
- UART log tool manual:
  [11_app/uart_log_tool/debug_log_tool/uart_log_tool_manual.md](./11_app/uart_log_tool/debug_log_tool/uart_log_tool_manual.md)

## Related RTL

- Top:
  [01_src/tangnano20k_top.sv](./01_src/tangnano20k_top.sv)
- UART log core:
  [01_src/uart_log_cli/uart_log_cli.sv](./01_src/uart_log_cli/uart_log_cli.sv)
- Event interface:
  [01_src/uart_log_cli/uart_log_evt_if.sv](./01_src/uart_log_cli/uart_log_evt_if.sv)
- SDRAM host/control:
  [01_src/embedded_sdram/sdram_emb_hostif_ctrl.sv](./01_src/embedded_sdram/sdram_emb_hostif_ctrl.sv)
- SDRAM UART bridge:
  [01_src/embedded_sdram/sdram_uart_bridge_ctrl.sv](./01_src/embedded_sdram/sdram_uart_bridge_ctrl.sv)
- SDRAM access engine:
  [01_src/embedded_sdram/sdram_uart_access_engine.sv](./01_src/embedded_sdram/sdram_uart_access_engine.sv)
