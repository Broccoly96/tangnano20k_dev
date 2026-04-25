# UART テストベンチ補助モジュール

## 目的
`02_tb/uart` にある 4 つの SystemVerilog モジュールは、UART インタフェースを扱うテストベンチを素早く構築するための共通部品です。FPGA 側 DUT とテストベンチの間に 2 本の信号 (`tx`,`rx`) だけで接続できるようにし、ドライバ・レシーバ・モニタ・IF を統一したスタイルで提供します。

## フォルダ構成
| ファイル           | 役割                                                                         |
| ------------------ | ---------------------------------------------------------------------------- |
| `uart_if.sv`       | DUT と TB をつなぐ 2 線式 UART インタフェース。modport を定義。              |
| `uart_driver.sv`   | UART RX ラインに 8-N-1 形式でデータを注入するビットバンギングドライバ。      |
| `uart_receiver.sv` | DUT の TX ラインをパッシブに監視し、受信バイトを mailbox へ投入。            |
| `uart_monitor.sv`  | TX/RX 双方向を同時に解析し、方向・タイムスタンプ付きトランザクションを記録。 |

## 前提条件
* クロックは SystemVerilog `logic` として IF に渡し、`CLOCK_FREQ_HZ` パラメータと一致させてください。
* リセットはアクティブ Low (`RST_N`)、ドライバは解除されるまで Idle レベルを維持します。
* 共通ログユーティリティ `tb_log_pkg` を利用します。`+TB_LOG_LEVEL` などの plusargs でロギング量を調整できます。
* ModelSim/Questa でシミュレーションする場合は `03_sim/vlog.f` に既に追加済みなので、`03_sim/compile.bat` → `03_sim/sim.bat` を実行すればコンパイルされます。

## `uart_if.sv`
* パラメータ
  * `RESET_IDLE_LEVEL` (既定 1) … リセット中に `rx` へ強制するアイドル値。
* 信号
  * `tx`：DUT → TB。テストベンチからは観察のみ。
  * `rx`：TB → DUT。ドライバが駆動、DUT はサンプル。
* modport
  * `dut`：DUT に接続する向き (`input rx`, `output tx`)。
  * `driver`：TB ドライバ用 (`output rx`, `input tx`)。
  * `receiver`：パッシブサンプリング (`input tx`)。
  * `monitor`：TX/RX 両方を同時に観察する用途。

### インスタンス例
```systemverilog
uart_if uart_bus (
  .CLK  (clk_50m_ext),
  .RST_N(l_o_rst_fpga_n)
);

tangmega60k_dev DUT (
  .I_UART_RX(uart_bus.rx),
  .O_UART_TX(uart_bus.tx),
  .I_CLK    (clk_50m_ext),
  .I_PLL_LOCKED(rst_testbench_n)
);
```

## `uart_driver.sv`
UART ドライバは UART RX ラインへスタートビット／データビット／ストップビットを順番に出力し、DUT に送信を模倣します。内部で `CLOCK_FREQ_HZ` と `BAUD_RATE` からビット時間 (`BIT_TICKS`) を算出します。

| パラメータ      | 既定値          | 説明                                           |
| --------------- | --------------- | ---------------------------------------------- |
| `INSTANCE_NAME` | `"UART_DRIVER"` | ログ・エラーメッセージ用インスタンス名         |
| `CLOCK_FREQ_HZ` | 50_000_000      | IF の `CLK` 周波数 (Hz)                        |
| `BAUD_RATE`     | 115_200         | UART ボーレート                                |
| `DATA_BITS`     | 8               | データビット数 (>=1)                           |
| `STOP_BITS`     | 1               | ストップビット数 (>=1)                         |
| `IDLE_LEVEL`    | 1'b1            | リセット中／アイドル時に `rx` へ出力するレベル |

### 主なタスク・関数
* `wait_reset_release()` … `RST_N` が 1 になるまで待機し、その間 `rx` をアイドル維持。
* `idle_cycles(cycles)` … 指定サイクル分だけ何も送らず待機。
* `send_byte(data)` … 1 バイトを LSB ファーストで送信。`byte_sent` イベントをトリガ。
* `send_bytes(data_array[])` … 可変長配列の全要素を順番に送信。
* `send_string(string)` … 文字列を 1 文字ずつ送信。日本語などマルチバイト文字は未対応。
* `send_random(count, seed)` … 疑似乱数で `count` バイト分を送信。`seed`=0 なら `$urandom()` の結果で初期化。
* `get_bytes_sent()` / `get_last_byte()` … 送信済みバイト数と最後のデータを参照。

### 送信例
```systemverilog
initial begin
  uart_drv.wait_reset_release();
  uart_drv.send_string("HELLO\r\n");
  uart_drv.idle_cycles(100);            // 100 クロック待機
  uart_drv.send_random(16, 32'h1BAD_F00D);
end
```

## `uart_receiver.sv`
DUT の `tx` を監視して 8-N-1 データを復号します。受信結果は内部 mailbox に蓄積され、API 経由で読み出します。ストップビットが Low の場合はフレーミングエラーをカウントします。

| パラメータ                                             | 既定値            | 説明       |
| ------------------------------------------------------ | ----------------- | ---------- |
| `INSTANCE_NAME`                                        | `"UART_RECEIVER"` | ログ識別子 |
| `CLOCK_FREQ_HZ`, `BAUD_RATE`, `DATA_BITS`, `STOP_BITS` | ドライバと同義    |            |

### API
* `wait_reset_release()` … リセット解除待ち。
* `get_byte(output data)` … mailbox から 1 バイト取り出し (blocking)。
* `try_get_byte(output data)` … 非ブロッキング取得。成功すれば 1 を返す。
* `pending_bytes()` … mailbox に溜まっている要素数。
* `get_framing_errors()` / `get_last_byte()` … 統計情報。
* `event byte_received` … 受信完了時にトリガされるので、`@(u_uart_rx.byte_received)` のように待受可能。

### 受信監視例
```systemverilog
initial begin
  logic [7:0] data;
  forever begin
    u_uart_rx.get_byte(data);  // 受信まで待機
    $display("[%0t] RX=0x%02h", $time, data);
  end
end
```

## `uart_monitor.sv`
`tx` と `rx` の両方向を同一 FSM でサンプリングし、`uart_transaction_t` 構造体にまとめて mailbox へ投入します。方向 (`UART_DIR_FROM_DUT`/`UART_DIR_TO_DUT`)、データ、開始/終了時刻、フレーミングエラーの有無を確認できます。

| パラメータ                                             | 既定値           | 説明                                   |
| ------------------------------------------------------ | ---------------- | -------------------------------------- |
| `INSTANCE_NAME`                                        | `"UART_MONITOR"` | ログ識別子                             |
| `DEFAULT_ENABLE`                                       | 1                | リセット解除後に自動で監視を開始するか |
| `CLOCK_FREQ_HZ`, `BAUD_RATE`, `DATA_BITS`, `STOP_BITS` | ドライバと同義   |                                        |

### API / 機能
* `set_enable(bit enable)` … 途中でモニタを ON/OFF 可能。
* `wait_reset_release()` … リセット解除待ち。
* `get_transaction(output uart_monitor_pkg::uart_transaction_t txn)` … mailbox から 1 件取得 (blocking)。型は `uart_monitor_pkg::uart_transaction_t` で参照可能。
* `try_get_transaction(...)` … 非ブロッキング版。
* `get_tx_count()` / `get_rx_count()` … 方向別の累積件数。
* `get_error_count()` … フレーミングエラー件数。
* `event transaction_seen` … トランザクションごとに通知。

### 解析例
```systemverilog
initial begin
  import uart_monitor_pkg::*;
  uart_monitor_pkg::uart_transaction_t txn;
  forever begin
    u_uart_mon.get_transaction(txn);
    $display("[%0t] %s byte=0x%02h err=%0b latency=%0t",
             txn.end_time,
             (txn.direction == UART_DIR_FROM_DUT) ? "TX" : "RX",
             txn.data, txn.framing_error, txn.end_time - txn.start_time);
  end
end
```

## まとめて接続する場合のテンプレート
```systemverilog
uart_if uart_bus (.CLK(clk_50m_ext), .RST_N(l_o_rst_fpga_n));

uart_driver #(
  .CLOCK_FREQ_HZ(50_000_000),
  .BAUD_RATE    (115_200)
) u_uart_drv (.uart(uart_bus));

uart_receiver #(
  .CLOCK_FREQ_HZ(50_000_000),
  .BAUD_RATE    (115_200)
) u_uart_rx (.uart(uart_bus));

uart_monitor #(
  .CLOCK_FREQ_HZ(50_000_000),
  .BAUD_RATE    (115_200)
) u_uart_mon (.uart(uart_bus));
```

## シミュレーションの流れ
1. `03_sim/compile.bat` を実行し、`vlog.f` に基づいて ModelSim/Questa でコンパイルします。`02_tb/uart/*.sv` は既にリストに含まれています。
2. テストベンチ内で `uart_if` と各モジュールをインスタンスし、DUT の UART ピンへ接続します。
3. ドライバ API を使って刺激を与え、レシーバ／モニタから得られるデータで DUT の応答を検証します。
4. 必要に応じて `tb_log_pkg` の plusargs でログレベルや時間表示を調整します。

## トラブルシューティングヒント
* `CLOCK_FREQ_HZ` と実際のテストベンチクロックが一致しないと、受信側でビット境界がずれてエラーになります。PLL で周波数を変更している場合も必ず同じ値を設定してください。
* リセット中に DUT 側が `rx` を駆動しない設計であることを確認してください。外部プルアップ/プルダウンが必要な場合は `RESET_IDLE_LEVEL` を変更します。
* `send_random()` を使うときに `seed=0` を指定すると、実行ごとに異なるデータ列になります。再現性が必要なテストでは固定 seed を渡してください。
* フレーミングエラーが頻発する場合、ストップビット数 (`STOP_BITS`) が DUT と一致しているか、ボーレート設定が正しいか見直してください。
