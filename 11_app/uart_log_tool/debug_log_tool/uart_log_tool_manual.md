# UART Log Tool (`11_app/debug_log_cli`)

`tangnano20k` の `uart_log_cli` フレーム（19B固定）を受信して表示するホストツールです。

- UI: Textual TUI（ターミナルGUI）
- 受信解析: `SYNC(0x7E) + SEQ + PAYLOAD(16B) + CRC8`
- 表示モード: `Raw` / `Decode`
- Decode: YAMLルール読み込み（ホットリロード対応）
- ログ再生: 既存 `.log` のリプレイ表示
- 送信コマンド: `?`, `Ctrl+R`, `Ctrl+F`, `Ctrl+D`, `Ctrl+T`
- `tcp` transport: `192.168.10.40:2323` をデフォルト使用
- `HEARTBEAT` は `uart_log_testsrc1` の単調増加カウンタを表示
- ハートビート周期は実機で 10 秒
- `Ctrl+R` は FPGA 全体ソフトリセットを要求
- TUI はログフィルタを持ち、表示行を部分一致で絞り込み可能
- `PCIE_EP_STATUS` 表示:
  `ltssm/linkup/rst/rx_err/sticky/mmio/tx/rx`
- `PCIE_EP_BRIDGE` 表示:
  `rx_len/rx_avail/tx_fifo/irq/last_bar0_addr/last_bar0_access`
- 任意ログ出力: `.log`

## インストール

```bash
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\\Scripts\\activate
pip install textual pyserial pyyaml
```

## 起動

通常起動:

```bash
python3 11_app/debug_log_cli/uart_log_tool.py
```

起動ラッパー:

```bash
# Linux/macOS
python3 11_app/debug_log_cli/uart_log_tool.py --transport tcp

# Windows
python 11_app\\debug_log_cli\\uart_log_tool.py --transport tcp
```

リプレイ起動:

```bash
python3 11_app/debug_log_cli/uart_log_tool.py --replay logs/uart_session.log
```

オプション例:

```bash
python3 11_app/debug_log_cli/uart_log_tool.py --transport tcp --tcp-host 192.168.10.40 --tcp-port 2323
python3 11_app/debug_log_cli/uart_log_tool.py --transport serial --port COM5 --baud 115200 --mode decode --decoder 11_app/uart_log_tool/debug_log_tool/decode_rules.default.yaml
python3 11_app/debug_log_cli/uart_log_tool.py --log-file logs/uart_session.log
python3 11_app/debug_log_cli/uart_log_tool.py --no-color
```

## CLIオプション

- `--port COMx`: 初期接続ポート
- `--baud 115200`: ボーレート（デフォルト 115200）
- `--transport serial|tcp`: 受信トランスポート
- `--tcp-host <ip>`: TCP受信用ホスト
- `--tcp-port <port>`: TCP受信用ポート
- `--mode raw|decode`: 表示モード（デフォルト `decode`）
- `--decoder <path>`: YAMLデコード定義
- `--log-file <path>`: ログ保存先（省略時は保存しない）
- `--replay <path>`: `.log` ファイルを再生（この場合シリアル接続UIは無効）
- `--no-color`: 色表示を無効化

## キー操作（TUI）

- `p`: COMポート再スキャン
- `c`: 接続/切断
- `m`: Raw/Decode 切替
- `u`: デコーダYAML手動リロード
- `l`: ログ保存 ON/OFF
- `x`: ログ画面クリア
- `r`: `Ctrl+R` 送信
- `f`: フィルタ入力へフォーカス
- `q`: 終了

`--decoder` で指定したYAMLは、ファイル更新時に自動でホットリロードされます。

## YAMLデコード定義

`decode_rules.default.yaml` は以下優先順位で適用されます。

1. `src:event` 完全一致
2. `src:*`
3. `*:event`
4. `default`

使用可能プレースホルダ:

- `{src_id}` `{event_id}` `{timestamp}`
- `{arg0}` `{arg1}` `{arg2}`
- `{arg0_u8}` `{arg1_u8}` `{arg2_u8}`
- `EV_HELP` 向けに `decode: help_ascii` を指定した場合は `{help_ascii}` も利用可能

## テスト

```bash
python3 -m unittest discover -s 11_app/uart_log_tool/debug_log_tool/tests -p 'test_*.py'
```
