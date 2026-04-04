# tangnano20k_dev

Tang Nano 20K 向けの FPGA 開発リポジトリです。
現在は `uart_log_cli` を Tang Nano 20K 実機へ組み込み、
ESP WiFi UART-TCP bridge 経由でホストからログ受信できる
構成を含んでいます。

## Overview

- Target board: Sipeed Tang Nano 20K
- Main user RTL: [01_src](./01_src)
- Simulation assets: [02_tb](./02_tb), [03_sim](./03_sim)
- Gowin implementation project: [05_impl](./05_impl)
- Host tools: [11_app](./11_app)
- Current debug path:
  `FPGA uart_log_cli -> UART -> ESP bridge -> TCP 192.168.10.40:2323`

このリポジトリでは、FPGA 内部イベントを UART ログフレームへ
変換し、ホスト側 `debug_log` ツールでデコード表示できます。

## Directory Layout

- [00_ip](./00_ip): Vendor / third-party IP
- [01_src](./01_src): User RTL
- [02_tb](./02_tb): Testbench common packages and helpers
- [03_sim](./03_sim): Testbench tops and testcases
- [04_simlib](./04_simlib): Precompiled simulation libraries
- [05_impl](./05_impl): Gowin project, SDC, CST, implementation outputs
- [11_app](./11_app): Host-side tools and utility scripts

## UART Log Bring-Up Status

現在の Tang Nano 20K トップ実装は
[tangnano20k_top.sv](./01_src/tangnano20k_top.sv) にて
`uart_log_cli` を有効化しています。

- UART clock: `24 MHz`
- UART baud: `115200`
- Active source: `uart_log_testsrc1`
- Heartbeat source id: `0x01`
- Heartbeat event id: `0x11`
- Heartbeat period: `10 s`
- Host transport: `tcp`
- Default endpoint: `192.168.10.40:2323`

実機確認では、TCP 経由で heartbeat の連続受信と CRC 正常を
確認済みです。

## Host Tool

ユーザー向け起動入口は
[11_app/debug_log_cli](./11_app/debug_log_cli) です。

主な機能:

- TCP 接続で UART ログ受信
- UART log frame parser / CRC check
- YAML decode rule によるイベント表示
- TUI 上のログフィルタ
- TCP 受信統計表示
  - packet count
  - byte count
  - sequence loss
  - CRC error count

起動例:

```powershell
python .\11_app\debug_log_cli\uart_log_tool.py `
  --transport tcp `
  --tcp-host 192.168.10.40 `
  --tcp-port 2323
```

## FPGA Build

Gowin project:
[05_impl/tangnano20k.gprj](./05_impl/tangnano20k.gprj)

Windows PowerShell での `run all` 例:

```powershell
$tcl = "C:\Electronics\GitHubProjects\tangnano20k_dev\05_impl\run_all.tcl"
Set-Content -Path $tcl -Value @(
  "open_project C:/Electronics/GitHubProjects/tangnano20k_dev/05_impl/tangnano20k.gprj"
  "run all"
  "exit"
)
& "C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" $tcl
```

主な出力:

- Bitstream:
  [05_impl/impl/pnr/tangnano20k.fs](./05_impl/impl/pnr/tangnano20k.fs)
- Timing report:
  [05_impl/impl/pnr/tangnano20k_tr_content.html](./05_impl/impl/pnr/tangnano20k_tr_content.html)

## Timing Constraints

SDC は
[05_impl/src/tangnano20k.sdc](./05_impl/src/tangnano20k.sdc)
にあります。

現在の制約:

- `create_clock` for `PIN04_IOL07A_LPLL1` at `27 MHz`
- `create_generated_clock` for PLL output
  `u0_gowin_pll/rpll_inst/CLKOUT` at `24 MHz`

直近の PnR 結果:

- Setup violated endpoints: `0`
- Hold violated endpoints: `0`
- `CLK_FPGA_24M` Actual Fmax: `50.930 MHz`

## Simulation

UART log smoke test は
[03_sim/01_uart_log_cli_smoke](./03_sim/01_uart_log_cli_smoke)
にあります。

Windows 実行例:

```powershell
cd .\03_sim
python sim.py 01_uart_log_cli_smoke\testbench.sv
```

この smoke test では以下を確認します。

- heartbeat frame 出力
- `src_id = 0x01`
- `event_id = 0x11`
- CRC 正常
- help / reset 系の基本動作

## Programming

Windows での SRAM 書き込み例:

```powershell
& "C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" `
  --device GW2AR-18C `
  --run 2 `
  --fsFile C:\Electronics\GitHubProjects\tangnano20k_dev\05_impl\impl\pnr\tangnano20k.fs
```

## Known Notes

- TCP bridge 越しの heartbeat 受信は確認済みです。
- `Ctrl+R` 相当の soft reset byte (`0x12`) は、
  現在の ESP bridge 経路で実機確認未完了です。
  FPGA 実装側には reset 処理を入れていますが、
  bridge 側で制御コードが透過していない可能性があります。
- Gowin PnR では `PR1014` 警告が出ますが、
  現状 timing は満足しています。

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
