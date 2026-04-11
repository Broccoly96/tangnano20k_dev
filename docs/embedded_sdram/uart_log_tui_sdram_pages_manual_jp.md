# UART Log TUI SDRAM Pages Manual

本書は `uart_log_tui` に追加した
`SDRAM Map` / `SDRAM RW` ページの操作方法と、
ファイル入出力仕様をまとめたマニュアルです。

対象ファイル:
- `11_app/uart_log_tool/debug_log_tool/uart_log_tui.py`


## 1. 画面構成

`uart_log_tui` の左端には縦メニューバーがあります。
以下の 3 画面を切り替えます。

- `1 Log`
  既存の UART log 画面です。
- `2 SDRAM Map`
  SDRAM の 256-byte 窓を可視化する画面です。
- `3 SDRAM RW`
  SDRAM の single read/write と
  file read/write を行う画面です。


## 2. SDRAM Map 画面

### 2.1 機能

`SDRAM Map` 画面には以下があります。

- ベースアドレス入力欄
- `Refresh` ボタン
- マップ表示エリア

### 2.2 表示範囲

- 1 回の refresh で 64 word, 256 byte を表示します。
- ベースアドレスを左上起点とします。
- 横方向は `+0x00, +0x04, +0x08, +0x0C`
- 縦方向は `+0x00, +0x10, +0x20 ... +0xF0`

### 2.3 表示形式

`SDRAM Map` は 4 byte を 1 word として固定表示します。

- 4 byte は little-endian として 32-bit 値へ束ねます。
- 表示単位は 32-bit hex 8 桁です。
- 1 行あたり 4 word を表示します。

例:
- `base+0x00 = 00`
- `base+0x01 = 01`
- `base+0x02 = 02`
- `base+0x03 = 03`

この場合、表示は
`03020100`
になります。

### 2.4 Refresh 動作

`Refresh` 実行時の動作は以下です。

1. 現在の source 選択状態を保存します。
2. `src_id=0x03` の SDRAM host source に切り替えます。
3. ベースアドレスから 64 word を順次 read します。
4. `BR` コマンドで 64 word の bulk read session を開始します。
5. raw binary block を受信して 256 byte を画面に反映します。
5. 可能であれば元の source に戻します。

注意:
- 実装上、read は 32-bit word 単位です。
- 表示更新も 4 byte 単位の固定フォーマットです。


## 3. SDRAM RW 画面

`SDRAM RW` 画面には以下 4 つの枠があります。

- `Single Address Read`
- `Single Address Write`
- `File Select Read`
- `File Select Write`

各枠の内部処理はすべて `src_id=0x03` の
SDRAM host interface を利用します。


## 4. Single Address Read

### 4.1 行構成

- `Read` ボタン
- Address 入力欄
- Read 内容表示欄

### 4.2 動作

- ASCII `R <addr>` を送って 32-bit word read を 1 回実行します。
- 応答は `READ_RSP` を待って結果欄に表示します。

### 4.3 表示

結果欄には以下形式で表示します。

- `0xAAAAA -> 0xDDDDDDDD`

ここで
- `AAAAA` は 21-bit アドレス
- `DDDDDDDD` は 32-bit read 値


## 5. Single Address Write

### 5.1 行構成

- `Write` ボタン
- Address 入力欄
- Write 内容入力欄

### 5.2 動作

- ASCII `W <addr> <data>` を送って 32-bit word write を 1 回実行します。
- 応答は `WRITE_ACK` を待って結果欄に表示します。

### 5.3 表示

結果欄には以下形式で表示します。

- `0xDDDDDDDD -> 0xAAAAA OK`


## 6. File Select Read

### 6.1 行構成

- `Read` ボタン
- File path 入力欄

### 6.2 動作

- 現在 `SDRAM Map` 画面で指定されている
  ベースアドレスを開始位置として使います。
- 読み出しサイズは固定で `256 byte` です。
- 内部では ASCII `BR` で bulk read session を開始します。
- 続いて raw binary block を受信して保存します。
- 読み出したデータを raw binary として
  指定 path に保存します。

### 6.3 出力ファイル形式

保存形式は **生バイナリファイル** です。

- 拡張子は任意です。
- ヘッダは付きません。
- read した内容を raw bytes のまま保存します。

### 6.4 byte order

- 内部では 32-bit word 単位で read します。
- 受信した各 word を little-endian byte 列へ戻して
  出力バッファへ連結します。

例:
- read value = `0x03020100`
- file bytes = `00 01 02 03`

### 6.5 実行結果

成功時は結果欄に以下形式を表示します。

- `saved 256 bytes to <path>`


## 7. File Select Write

### 7.1 行構成

- `Write` ボタン
- Base Address 入力欄
- File path 入力欄

### 7.2 ベースアドレス

- `File Select Write` 行で入力した
  ベースアドレスを開始位置として使います。

### 7.3 ファイル形式

入力ファイル形式は **生バイナリファイル** です。

- 拡張子は任意です。
- ヘッダは不要です。
- テキスト形式ではなく、raw bytes をそのまま使います。

具体例:
- `.bin`
- `.dat`
- `.img`
- 拡張子なし

いずれでも中身が raw bytes なら利用可能です。

### 7.4 書き込み単位

- まず ASCII `BW` で bulk write session を開始します。
- 続いて raw binary block として payload を送ります。
- SDRAM host IF は 32-bit word 単位で write します。
- 入力ファイルは 4 byte ごとに 1 word へ変換します。
- 変換時の byte order は little-endian です。

例:
- file bytes = `00 01 02 03`
- write value = `0x03020100`

### 7.5 4 byte 未満の末尾処理

ファイルサイズが 4 byte の倍数でない場合、
最後の word は **0x00 padding** します。

例:
- file bytes tail = `AA BB`
- 実際に書く word bytes = `AA BB 00 00`
- 実際の write value = `0x0000BBAA`

### 7.6 アドレス進み方

- ベースアドレスを `A` とすると、
  1 word ごとに `A+0`, `A+1`, `A+2` と進みます。
- ここでアドレス単位は byte ではなく、
  host IF の 32-bit word address 単位です。

### 7.7 実行結果

成功時は結果欄に
`file write complete`
を表示します。


## 8. 制約事項

- 現在の file read/write は raw binary 前提です。
- Intel HEX, Motorola S-record, ELF, CSV などの
  構造化フォーマットには未対応です。
- アドレスは host IF の 21-bit word address です。
- `File Select Read` の読み出しサイズは固定 `256 byte` です。
- `File Select Read` の開始アドレスは
  `SDRAM Map` 画面のベースアドレスを使います。
- `File Select Write` の開始アドレスは
  `File Select Write` 行のベースアドレス入力値を使います。
- single read/write は ASCII 制御です。
- map refresh / file read / file write は raw bulk path を使います。
- bulk payload は `0x04`, `0x06`, `0x10`, `0x12`, `0x14`, `0x3F`
  を含んでも CLI 制御文字として扱われません。


## 9. 推奨運用

- バイナリパターンの書き込みには `.bin` を使用
- 数百 byte から数 KB 程度でまず確認
- 保存した readback file と元 file を
  バイナリ比較して一致確認

Windows 例:
- `fc /b write_data.bin readback.bin`
