# UART Log TUI SDRAM Pages Manual

本書は `uart_log_tui` の `SDRAM Map` と `SDRAM RW` の
現行動作をまとめたマニュアルです。

対象ファイル:
- `11_app/uart_log_tool/debug_log_tool/uart_log_tui.py`

## 1. 現行 host protocol の状態

- single access と bulk access が有効です。
- `Single Address Read` は ASCII `R <addr>` を使います。
- `Single Address Write` は ASCII `W <addr> <data>` を使います。
- `SDRAM Map` は ASCII `BR <addr> <words>` を使います。
- `SDRAM RW` の bulk file write は ASCII `BW <addr> <words>` を
  使います。

## 2. 起動時動作

- FPGA 書き込み後、embedded SDRAM host path は
  `write pattern -> read verify -> full zero clear`
  を順に実行します。
- `SDRAM_TEST_PASS` は、
  verify 成功に加えて full zero clear 完了まで含みます。
- そのため、未書き込み領域は self-test pass 後に
  `0x00000000` を返します。
- 以前の verify-only 構成よりも、
  host access が有効になるまでの時間は少し長くなります。

## 3. SDRAM Map 画面

### 3.1 画面要素

- Base Address 入力欄
- `Refresh` ボタン
- 256-word 表示エリア

### 3.2 表示窓

- 1 画面は `256 word = 1024 byte` 固定です。
- アドレス単位は 32-bit word address です。
- 横軸は word address の下位 offset `00` から `0F` です。
- 縦軸は word address offset `00` から `F0` です。
- 1 行に 16 word を表示します。

### 3.3 現行動作

- `Refresh` を押すと `BR <base> 00100` を 1 回送信します。
- `BULK_PROGRESS` イベントを受けるたび、対応する word を
  表示バッファへ反映します。
- `BULK_DONE` で 256 word すべてを受信済みなら
  `refresh complete` を表示します。
- timeout または bulk error の場合は最大 3 回 retry します。

## 4. SDRAM RW 画面

`SDRAM RW` 画面には以下 3 枠があります。

- `Single Address Read`
- `Single Address Write`
- `Bulk File Write`

3 枠すべて有効です。`Bulk File Write` は `.bin` / `.hex` を受け取り、
SDRAM bulk-write 経路で書き込みます。

## 5. Single Address Read

### 5.1 UI 構成

- `Read` ボタン
- Address 入力欄
- 結果表示欄

### 5.2 動作

- TUI は SDRAM host source `src_id = 0x03` に切り替えます。
- ASCII `R <addr>` を送信します。
- `READ_RSP (0x31)` を待って結果を表示します。

### 5.3 表示形式

- `0xAAAAA -> 0xDDDDDDDD`

ここで

- `AAAAA` は 21-bit SDRAM word address
- `DDDDDDDD` は 32-bit read 値

です。

## 6. Single Address Write

### 6.1 UI 構成

- `Write` ボタン
- Address 入力欄
- Data 入力欄
- 結果表示欄

### 6.2 動作

- TUI は SDRAM host source `src_id = 0x03` に切り替えます。
- ASCII `W <addr> <data>` を送信します。
- `WRITE_ACK (0x30)` を待って結果を表示します。

### 6.3 表示形式

- `0xDDDDDDDD -> 0xAAAAA OK`

これは host write 要求が完了したことを示します。

## 7. Bulk File Write

- 枠は `SDRAM RW` 画面内にあります。
- Base Address は single read/write と同じ 21-bit SDRAM word address
  形式です。
- path 入力欄は `.bin` / `.hex` を受け付けます。
- `Write File` を押すと `BW <base> <words>` を送信します。
- payload byte は CRC 付き raw bulk block として送信します。
- ファイル長が 4 byte 境界でない場合、通信上は次の SDRAM word
  境界まで 0 padding します。

## 8. source 切替に関する注意

- SDRAM host event は `src_id = 0x03` を使います。
- heartbeat source は元の source index に残っています。
- single SDRAM 操作時は、host tool が一時的に SDRAM source に
  切り替えて command/response をやり取りします。

## 9. event の意味

- `SDRAM_INIT_DONE (0x20)`
  embedded SDRAM controller の初期化完了です。
- `SDRAM_TEST_START (0x21)`
  self-test の test words、burst 数、
  zero clear words を報告します。
- `SDRAM_TEST_PASS (0x22)`
  read verify 成功と full zero clear 完了の両方を表します。
- `SDRAM_TEST_FAIL (0x23)`
  read verify fail を表し、
  zero clear は実行されません。
- `WRITE_ACK (0x30)`
  single write command 完了応答です。
- `READ_RSP (0x31)`
  single read command 応答です。
- `CMD_ERR (0x3E)`
  不正または未対応の host command を示します。

## 10. 現行制約

- `SDRAM Bulk` と `SDRAM File` は独立した TUI 画面としては
  存在しません。
- SDRAM bulk file read/save は現行 TUI layout では公開していません。
