# Gowin SDRAM Controller IP 利用設計書（AIエージェント向け / RTL実装用）

## 1. 文書目的

本設計書は、**Gowin SDRAM Controller IP を「ユーザロジック側から正しく使う」ためのRTL設計基準書**である。  
対象は、Gowin が生成する SDRAM Controller IP 自体の再実装ではなく、**そのIPを包むラッパRTL、要求発行ロジック、データ搬送ロジック、検証用TB/アサーション**の実装である。

本書は、特に以下を重視する。

- Working Flow に基づく内部動作の理解
- User Interface Timing に基づく**実際のリクエスト発行契約**
- SDRAM Interface Timing に基づく**内部コマンド列の意味**
- AIエージェントが RTL を書く際に迷いやすい曖昧点の明文化
- データシート記述と、RTL実装上の**保守的な運用ルール**の切り分け

---

## 2. スコープ

### 2.1 対象
- Gowin Software で生成した SDRAM Controller IP
- External SDRAM Controller
- Embedded SDRAM Controller
- それらに接続するユーザロジック側RTL
- 検証用テストベンチ / アサーション / ラッパ

### 2.2 非対象
- SDRAM Controller IP 本体アルゴリズムの再設計
- SDRAM デバイス一般論の完全解説
- ボードレベル SI/PI 詳細設計
- .cst / SDC の完全制約テンプレート

---

## 3. 参照元

- Gowin SDRAM Controller IP User Guide
  - Signal Definition
  - GUI Parameters
  - Principle
  - Working Flow
  - Application
  - Interface Timing

---

## 4. 前提と基本方針

### 4.1 本IPの位置づけ
本IPは、ユーザロジックと SDRAM の間に入り、以下を内部で処理する。

- 初期化
- Read/Write コマンド生成
- Auto-refresh
- Self-refresh
- Power-down
- Precharge
- SDRAMコマンド制御

したがって、ユーザRTLは **SDRAMのRCD/RP/RFC/CL等を直接生成しない**。  
代わりに、**ユーザインタフェース規約**に従って read/write 要求を与える。

### 4.2 ユーザロジック設計の基本方針
ユーザロジックは以下を必ず守ること。

1. `O_sdrc_init_done == 1` になるまで read/write を発行しない  
2. `O_sdrc_busy_n == 1` のときだけ新規要求を発行する  
3. `I_sdrc_wr_n` / `I_sdrc_rd_n` は **active-low 1クロックパルス**で発行する  
4. 1回の要求で指定するデータ長は **`I_sdrc_data_len + 1` beat** である  
5. Read データは **`O_sdrc_rd_valid` と同時にのみ有効**として扱う  
6. Write データは **要求開始後、必要beat数を連続供給する前提**で設計する  
7. Self-refresh / Power-down は **アイドル時のみ遷移させる保守運用**とする

---

## 5. システム構成

## 5.1 推奨ブロック構成

```text
          +------------------+
CLK_in -->|       PLL        |--> I_sdrc_clk
          |                  |--> I_sdram_clk
          +------------------+

                    +---------------------------+
user req/data  <--> |   User Wrapper / Arbiter  |
                    +---------------------------+
                                |
                                v
                    +---------------------------+
                    | Gowin SDRAM Controller IP |
                    +---------------------------+
                                |
                                v
                             SDRAM
```

### 5.2 クロックの役割
- `I_sdrc_clk` : ユーザインタフェース側の動作クロック
- `I_sdram_clk` : SDRAM側クロック

### 5.3 クロックに関する重要注意
- ユーザインタフェースの入出力は **`I_sdrc_clk` 立上り基準**で扱う
- SDRAM側出力も **controller working clock の立上り基準**で整列する
- `I_sdram_clk` の位相は、read/write の setup/hold を満たすように調整できる
- **GW1NR-4 の embedded 32-bit controller のみ**、`I_sdrc_clk` は `I_sdram_clk` の **1/2 周波数**でなければならない
- 上記以外は、`I_sdrc_clk` と `I_sdram_clk` は同周波数運用が基本

### 5.4 実装上の推奨
- `I_sdrc_clk` ドメインにユーザ制御ロジックを統一する
- CPU/別クロックドメインから要求が来る場合は、**必ず手前で CDC/FIFO を設ける**
- SDRAM Controller IP の直近に thin wrapper を置き、上位ロジックからは ready/valid 系に見せるのが望ましい

---

## 6. インタフェース定義

## 6.1 SDRAM側信号

| 信号名 | 方向 | 概要 |
|---|---:|---|
| `O_sdram_clk` | O | SDRAM clock |
| `O_sdram_cke` | O | Clock enable |
| `O_sdram_cs_n` | O | Chip select |
| `O_sdram_cas_n` | O | Column address strobe |
| `O_sdram_ras_n` | O | Row address strobe |
| `O_sdram_wen_n` | O | Write enable |
| `O_sdram_dqm` | O | Data mask |
| `O_sdram_addr` | O | Address |
| `O_sdram_ba` | O | Bank address |
| `IO_sdram_dq` | I/O | Data bus |

> 注記: データシートでは信号方向の基準を「SDRAM基準」で記述している。

## 6.2 ユーザ側信号

| 信号名 | 方向 | 概要 | RTL上の解釈 |
|---|---:|---|---|
| `I_sdrc_rst_n` | I | active-low reset | 同期/非同期仕様は生成IPに従う。wrapper側は reset 後に init 待ちへ入る |
| `I_sdrc_clk` | I | controller working clock | ユーザI/F基準クロック |
| `I_sdram_clk` | I | SDRAM working clock | SDRAM側基準クロック |
| `I_sdrc_selfrefresh` | I | self-refresh enable | 低消費電力要求。保守的には idle 時のみ変更 |
| `I_sdrc_power_down` | I | power-down enable | 低消費電力要求。保守的には idle 時のみ変更 |
| `I_sdrc_wr_n` | I | write request | active-low, 1クロックパルス |
| `I_sdrc_rd_n` | I | read request | active-low, 1クロックパルス |
| `I_sdrc_addr` | I | address | 要求アドレス |
| `I_sdrc_dqm` | I | data mask | write/read マスク制御 |
| `I_sdrc_data_len` | I | length | **実長 = `I_sdrc_data_len + 1`** |
| `I_sdrc_data` | I | write data | write ストリーム |
| `O_sdrc_data` | O | read data | `O_sdrc_rd_valid` と同時のみ有効 |
| `O_sdrc_init_done` | O | init 完了 | 1: 完了 |
| `O_sdrc_busy_n` | O | idle/busy | 1: idle, 0: busy |
| `O_sdrc_rd_valid` | O | read valid | read data とアライン |
| `O_sdrc_wrd_ack` | O | req acknowledge | 要求受領応答。2クロック遅延、1クロック幅 |

---

## 7. 外部SDRAM用 GUI パラメータと設計反映

## 7.1 ジオメトリ系
| パラメータ | 意味 |
|---|---|
| Data Width | SDRAMデータ幅 |
| Bank Width | BANK address幅 |
| Row Width | row address幅 |
| Column Width | column address幅 |

### 設計ルール
- `I_sdrc_addr` の意味は、選択した Row/Column/Bank 構成に依存する
- 上位アドレスマップ仕様書で、**linear address → bank/row/column** の割当を固定すること
- 1アクセス最大長はデータシート上「1~Page」。  
  したがって、**ページ境界を跨ぐ長さを上位が出さない**設計にするのが安全

## 7.2 タイミング系
| パラメータ | 意味 |
|---|---|
| Clock Period | controller動作クロック周期 [ns] |
| Refresh Period | SDRAM全体 refresh 周期 [ns] |
| Refresh Times | refresh 回数 |
| CL Period | CAS Latency [controller clock cycles] |
| tRP Period | PRECHARGE period [cycles] |
| tRFC Period | AUTO REFRESH period [cycles] |
| tMRD Period | LOAD MODE REGISTER → ACTIVE/REFRESH の待ち [cycles] |
| tRCD Period | ACTIVE → READ/WRITE 遅延 [cycles] |
| tWR Period | WRITE recovery [cycles] |

### 実装ルール
- 上記パラメータは **外付けSDRAMのデータシートから逆算して設定**する
- CL / tRP / tRFC / tMRD / tRCD / tWR は、**controller clock cycle 数**で与える
- `Refresh Period / Refresh Times` が、事実上の平均 refresh 間隔を決める  
  例: デフォルト値 `64,000,000ns / 4096 = 15.625us`

> 注意: refresh 間隔の式はユーザガイド記述からの自然な解釈であり、実際の設定値は必ず対象SDRAMの仕様書で再確認すること。

---

## 8. SDRAMコマンド定義（IP内部理解用）

| Command | CS | RAS | CAS | WE |
|---|---|---|---|---|
| Command Inhibit | H | X | X | X |
| NOP | L | H | H | H |
| Active | L | L | H | H |
| Read | L | H | L | H |
| Write | L | H | L | L |
| Burst Terminate | L | H | H | L |
| Pre-charge | L | L | H | L |
| Auto Refresh / Self Refresh | L | L | L | H |
| Configuration Mode Register | L | L | L | L |

### 補足
- `X`: don't care
- `L`: low
- `H`: high

### RTL利用上の意味
ユーザロジックはこれらのコマンドを直接駆動しない。  
ただし、**タイミング図を読むためには必須**である。

---

## 9. 動作の本質

## 9.1 初期化の本質
SDRAM は power-up 後すぐには使えない。IP内部では次を実行する。

1. power-up 後、100us 待機
2. Precharge
3. Auto-refresh
4. Auto-refresh
5. Load Mode Register
6. `tMRD` 待ち
7. 通常動作開始

### ユーザRTLが守るべきこと
- `O_sdrc_init_done == 1` まで一切アクセスしない
- reset解除後に一定時間でアクセス可能になるとは**仮定しない**
- `init_done` を唯一の使用開始条件とする

## 9.2 Read の本質
内部では概ね以下。

1. 対象 bank / row を `ACTIVE`
2. `tRCD` 待ち
3. 対象 column に対して `READ`
4. `CL` 後に read data 出力
5. 必要に応じて `PRECHARGE`
6. `tRP` 後に次アクセス可能

## 9.3 Write の本質
内部では概ね以下。

1. 対象 bank / row を `ACTIVE`
2. `tRCD` 待ち
3. 対象 column に対して `WRITE`
4. write data を SDRAM に転送
5. `tWR` 待ち
6. `PRECHARGE`
7. `tRP` 後に次アクセス可能

## 9.4 Auto-refresh の本質
- 定期的に内部で refresh が必要
- refresh 前に precharge を伴う動きが見える
- refresh 中は controller はユーザ要求を新規受付しない

### 重要解釈
ユーザインタフェース上、**auto-refresh 専用の要求信号は無い**。  
したがって auto-refresh は **内部自律イベント**と解釈する。

## 9.5 Self-refresh / Power-down の本質
- `I_sdrc_selfrefresh` と `I_sdrc_power_down` は低消費電力制御入力
- ユーザガイドの flow 図には記述ゆれ / typo があり、auto-refresh と self-refresh の説明が混在する箇所がある
- 実運用では、これらを**外部から明示制御するモード遷移要求**として扱う

---

## 10. Working Flow の整理

## 10.1 Read/Write Working Flow の設計解釈

データシートのフローを、ユーザRTL視点で整理すると以下。

```text
RESET/POWERUP
  -> INIT_WAIT
  -> INIT_SEQUENCE
  -> IDLE
      -> (internal refresh needed) REFRESH
      -> (user request) ISSUE_ACCESS
           -> ACTIVE + READ/WRITE internal sequence
           -> DATA_TRANSFER
           -> PRECHARGE
           -> IDLE
```

### ユーザRTLへの影響
- controller が idle (`O_sdrc_busy_n=1`) になるまで新規要求は不可
- refresh は内部で割り込むため、**要求受理遅延は固定ではない可能性**がある
- ただしデータシート波形上は、要求受理後 `ack` と `busy` の出方は一定パターンで示される

## 10.2 Initialization Flow の設計解釈

```text
Power-up
  -> wait >=100us
  -> PRECHARGE
  -> wait tRP
  -> AUTO REFRESH
  -> wait tRFC
  -> AUTO REFRESH
  -> wait tRFC
  -> LOAD MODE REGISTER
  -> wait tMRD
  -> INIT_DONE
```

### 実装上の意味
- `O_sdrc_init_done` は、上記シーケンス全完了の後でのみ 1 になる
- 上位は内部状態を知らなくてよい
- 上位は `init_done` を待つだけでよい

## 10.3 Auto-refresh Flow の設計解釈

ユーザガイド図は文言に曖昧さがあるが、設計上は以下で扱う。

```text
IDLE
  -> internal refresh trigger
  -> PRECHARGE (if needed)
  -> AUTO REFRESH
  -> wait tRFC
  -> IDLE
```

### ユーザRTLのルール
- refresh 開始を予測しない
- `busy_n==1` のときのみ要求を出す
- refresh のため request issue 機会が後ろ倒しになる前提で FIFO 深さを見積もる

## 10.4 Power-down Flow の設計解釈

```text
IDLE
  -> if power_down request asserted
  -> enter power-down
  -> wait exit request
  -> exit power-down
  -> IDLE
```

### 推奨運用
- power-down 要求は idle 時のみアサート
- power-down 中は read/write を禁止
- 復帰後に busy / init_done / idle を再確認してからアクセス再開

---

## 11. User Interface Timing 仕様（最重要）

本章は、**AIエージェントが wrapper RTL を書く際の最重要契約**である。

## 11.1 共通仕様
- すべてのユーザI/F入出力は **`I_sdrc_clk` の立上り**で扱う
- `I_sdrc_wr_n`, `I_sdrc_rd_n` は **active-low 1クロックパルス**
- `I_sdrc_data_len` の意味は **length-1**
  - `0` なら 1 beat
  - `19` なら 20 beat
- `O_sdrc_wrd_ack` は **要求受領の応答**
  - **要求受信から 2クロック遅延**
  - **1クロック幅**
- `O_sdrc_busy_n` は controller の idle/busy を表す
  - `1`: idle
  - `0`: busy
- データシート波形では、`busy_n` は**要求から 3クロック遅れて busy 側へ遷移**

---

## 11.2 Read 要求プロトコル

### 11.2.1 要求発行条件
以下をすべて満たすクロックで read 要求を出す。

- `O_sdrc_init_done == 1`
- `O_sdrc_busy_n == 1`
- self-refresh / power-down を要求していない

### 11.2.2 要求発行方法
- `I_sdrc_rd_n <= 0` を **1クロックだけ**アサート
- 同じサイクルで以下を有効値に設定する
  - `I_sdrc_addr`
  - `I_sdrc_dqm`
  - `I_sdrc_data_len`

### 11.2.3 Read データの受け取り
- `O_sdrc_wrd_ack` は要求の **2クロック後**に 1クロックだけ High
- `O_sdrc_busy_n` は要求の **3クロック後**に Low へ遷移
- `O_sdrc_rd_valid == 1` のサイクルでのみ `O_sdrc_data` を取り込む
- 取り込む beat 数は **`I_sdrc_data_len + 1`**

### 11.2.4 Read 実装ルール（保守運用）
- `I_sdrc_addr`, `I_sdrc_dqm`, `I_sdrc_data_len` は、少なくとも**要求パルス時点では安定**させる
- データシート波形に合わせ、wrapper では **要求発行から `ack` 観測まで安定保持**する実装を推奨
- `O_sdrc_data` は `rd_valid=0` のとき無視する

### 11.2.5 Read 受信カウンタ
```text
expected_beats = I_sdrc_data_len + 1
count rd_valid pulses
read complete when count == expected_beats
```

---

## 11.3 Write 要求プロトコル

### 11.3.1 要求発行条件
以下をすべて満たすクロックで write 要求を出す。

- `O_sdrc_init_done == 1`
- `O_sdrc_busy_n == 1`
- self-refresh / power-down を要求していない

### 11.3.2 要求発行方法
- `I_sdrc_wr_n <= 0` を **1クロックだけ**アサート
- 同じサイクルで以下を有効値に設定する
  - `I_sdrc_addr`
  - `I_sdrc_dqm`
  - `I_sdrc_data_len`

### 11.3.3 Write データ供給
データシートの write 波形から、`I_sdrc_data` は**要求開始直後から連続供給される前提**で描かれている。  
したがって wrapper RTL では、**request cycle から write data stream を切れ目なく出せる**構成にすること。

### 11.3.4 Write 実装ルール（保守運用）
- `I_sdrc_data` は **要求サイクルから連続beat出力**する
- beat 数は **`I_sdrc_data_len + 1`**
- 途中で gap を入れない
- `O_sdrc_wrd_ack` は要求の **2クロック後**
- `O_sdrc_busy_n` は要求の **3クロック後に busy へ遷移**
- `busy_n` が idle に戻るまでは新規要求禁止

### 11.3.5 推奨データ供給方法
- 上位が ready/valid なら、IP手前で **write FIFO** に詰める
- 要求を出せるのは、**必要beat数が FIFO に揃っているときのみ**
- 「途中でデータ切れ」が起きないようにする

---

## 12. SDRAM Interface Timing の設計解釈

## 12.1 初期化タイミング
データシートの SDRAM 初期化波形は以下を示す。

1. Power-up 後、**100us 以上**待機
2. `PRECHARGE`
   - precharge 時、`addr[10]` は all-bank / single-bank 指定に使われる
3. `AUTO REFRESH`
4. `AUTO REFRESH`
5. `LOAD MODE REGISTER`
   - address ラインに mode code を出す
6. `tMRD` 待ち
7. その後 `ACTIVE` 可能

### 設計上のポイント
- この流れは **IP内部が行う**
- ユーザRTLは `init_done` 待ちのみ
- mode register の code はIP内部の設定に依存し、通常ユーザI/Fから触らない

---

## 12.2 SDRAM Read タイミング
波形上、read は以下で構成される。

```text
ACTIVE(row, bank)
  -> wait tRCD
READ(column, bank)
  -> wait CL
read data appears on DQ
  -> PRECHARGE
  -> wait tRP
next ACTIVE
```

### 行/列/バンクの見え方
- `ACTIVE` 時
  - `addr` = ROW
  - `ba`   = Bank Address
- `READ` 時
  - `addr` = Column
  - `ba`   = Bank Address

### 設計上の意味
- row open / close はIP内部で管理される
- ユーザ側は linear address を与えるだけでよい
- ただし burst 長が page を跨ぐ設計は避ける

---

## 12.3 SDRAM Write タイミング
波形上、write は以下で構成される。

```text
ACTIVE(row, bank)
  -> wait tRCD
WRITE(column, bank)
  -> write data on DQ
  -> wait tWR
PRECHARGE
  -> wait tRP
next ACTIVE
```

### 設計上の意味
- write 後は `tWR` が必要なため、controller は即座には次行遷移できない
- 上位は `busy_n` を信用し、内部詳細を追わない

---

## 12.4 SDRAM Auto-refresh タイミング
波形上、refresh は概ね以下で構成される。

```text
PRECHARGE
  -> wait tRP
AUTO REFRESH
  -> wait tRFC
next ACTIVE
```

### 設計上の意味
- refresh の前後ではメモリアクセスが一時停止する
- レイテンシ保証が必要な上位回路では、refresh 起因の遅延を見込むこと
- 定周期処理で厳しい場合は request queue を持つ

---

## 13. AIエージェント向け RTL 実装契約

## 13.1 実装してよい責務
AIエージェントは以下を実装してよい。

- IP ラッパモジュール
- 上位 ready/valid 変換
- req FIFO / write data FIFO / read data FIFO
- length カウンタ
- busy/init_done 監視
- self-refresh / power-down 遷移制御
- テストベンチ / assertion / cover

## 13.2 実装してはいけない責務
AIエージェントは以下をユーザラッパ内で再実装しない。

- SDRAM command sequence 生成
- SDRAM row state machine の詳細最適化
- refresh timing engine
- tRCD / CL / tRP / tRFC / tWR の生管理
- mode register 直接書き込み制御

---

## 14. 推奨ラッパインタフェース

上位とは次のような ready/valid に変換することを推奨する。

```text
req_valid
req_ready
req_write        // 1:write, 0:read
req_addr
req_len_m1
req_wmask

wdata_valid
wdata_ready
wdata

rdata_valid
rdata_ready
rdata
rdata_last
```

### 14.1 req_ready の推奨条件
```text
req_ready = init_done
         && busy_n
         && !selfrefresh_mode
         && !powerdown_mode
         && (writeなら必要データがFIFOに揃っている)
```

### 14.2 write 要求受理条件
- req handshake 成立時に
  - `I_sdrc_wr_n` を1クロックだけ Low
  - `I_sdrc_addr`, `I_sdrc_dqm`, `I_sdrc_data_len` を提示
  - write FIFO から `len+1` beat をそのまま連続送出開始

### 14.3 read 要求受理条件
- req handshake 成立時に
  - `I_sdrc_rd_n` を1クロックだけ Low
  - `I_sdrc_addr`, `I_sdrc_dqm`, `I_sdrc_data_len` を提示
- `O_sdrc_rd_valid` に応じて read FIFO へ格納

---

## 15. 推奨FSM

## 15.1 Read/Write 共通 wrapper FSM

```text
ST_RESET
  -> ST_WAIT_INIT

ST_WAIT_INIT
  if init_done -> ST_IDLE

ST_IDLE
  if selfrefresh_req -> ST_SELFREFRESH
  else if powerdown_req -> ST_POWERDOWN
  else if req_valid && req_ready && req_write -> ST_WRITE_ISSUE
  else if req_valid && req_ready && !req_write -> ST_READ_ISSUE

ST_WRITE_ISSUE
  pulse wr_n low for 1 cycle
  -> ST_WRITE_STREAM

ST_WRITE_STREAM
  send exactly len+1 beats
  wait until busy_n returns high
  -> ST_IDLE

ST_READ_ISSUE
  pulse rd_n low for 1 cycle
  -> ST_READ_WAIT

ST_READ_WAIT
  capture data on rd_valid
  when captured len+1 beats and busy_n returns high
  -> ST_IDLE

ST_SELFREFRESH
  assert selfrefresh control
  wait exit request
  deassert selfrefresh
  wait idle
  -> ST_IDLE

ST_POWERDOWN
  assert power_down control
  wait exit request
  deassert power_down
  wait idle
  -> ST_IDLE
```

---

## 16. RTLルール（必須）

## 16.1 要求生成
- `I_sdrc_wr_n` と `I_sdrc_rd_n` を**同時にLowにしない**
- パルス幅は **必ず1クロック**
- `busy_n=0` 中は新規要求禁止

## 16.2 length 取扱い
- `I_sdrc_data_len` は length-1
- internal counter は必ず
  ```text
  total_beats = unsigned(I_sdrc_data_len) + 1
  ```
  で計算する

## 16.3 Read データ捕捉
- `O_sdrc_data` のサンプリング条件は `O_sdrc_rd_valid==1` のみ
- `rd_valid` 立上り/連続High期間をそのまま beat カウントに使う

## 16.4 Write データ供給
- request accepted 時点で全beatを供給可能であること
- `I_sdrc_data` に bubble を入れない

## 16.5 低消費電力制御
- `selfrefresh` / `power_down` は idle 時のみ変更
- 低消費電力要求中は req_ready を落とす

---

## 17. アサーション推奨

## 17.1 基本アサーション
```systemverilog
assert property (@(posedge I_sdrc_clk) !(~I_sdrc_wr_n && ~I_sdrc_rd_n));
assert property (@(posedge I_sdrc_clk) (~I_sdrc_wr_n) |=> I_sdrc_wr_n);
assert property (@(posedge I_sdrc_clk) (~I_sdrc_rd_n) |=> I_sdrc_rd_n);
```

## 17.2 アクセス条件
```systemverilog
assert property (@(posedge I_sdrc_clk) (~I_sdrc_wr_n || ~I_sdrc_rd_n) |-> O_sdrc_init_done);
assert property (@(posedge I_sdrc_clk) (~I_sdrc_wr_n || ~I_sdrc_rd_n) |-> O_sdrc_busy_n);
```

## 17.3 Read beat 数
- read request ごとに `len+1` 個の `rd_valid` が来ることをチェック

## 17.4 Write beat 数
- write request ごとに `len+1` beat 分、`I_sdrc_data` を供給したことをチェック

---

## 18. テストベンチ観点

## 18.1 最低限のテスト項目
1. reset 後、`init_done` が上がるまでアクセスしない
2. 1 beat read
3. 1 beat write
4. 複数beat read
5. 複数beat write
6. `data_len=0` が 1 beat として解釈されること
7. `data_len=19` が 20 beat として動くこと
8. busy 中の二重要求抑止
9. refresh が混ざってもデータ破綻しないこと
10. self-refresh 入口/出口
11. power-down 入口/出口

## 18.2 波形照合ポイント
- request から `wrd_ack` まで 2クロック
- request から `busy` 化まで 3クロック
- read のみ `rd_valid` と `O_sdrc_data` が一致
- read/write 実長が `len+1`

---

## 19. 曖昧点と本設計書の採用方針

## 19.1 Auto-refresh Flow の文言揺れ
ユーザガイドの auto-refresh flow 図/説明には、self-refresh と混在したように見える記述がある。  
本設計書では以下を採用する。

- **auto-refresh**: controller 内部自律動作
- **self-refresh**: `I_sdrc_selfrefresh` による外部要求モード

## 19.2 `O_sdrc_wrd_ack` の意味
名称は read/write 共通 ack。  
本設計書では **「request accepted indication」** として扱う。

## 19.3 入力保持期間
データシートは addr / dqm / len の厳密 hold 期間を文章で明示していない。  
本設計書では、安全側として以下を採用する。

- request パルス時に valid
- **最低でも `ack` が返るまで保持**
- 実装簡潔性のため、wrapper 内では **busy が立つまで保持**してもよい

## 19.4 write data 開始タイミング
waveform では write data は要求開始直後から並ぶ。  
本設計書では、安全側として以下を採用する。

- **write request 発行サイクルから連続送出開始**

---

## 20. 実装チェックリスト

- [ ] `init_done` 待ちを入れた
- [ ] `busy_n` を見て要求を出している
- [ ] `wr_n` / `rd_n` は1クロック active-low pulse
- [ ] `wr_n` と `rd_n` を同時発行しない
- [ ] `data_len` は length-1 で扱った
- [ ] read は `rd_valid` のみで捕捉した
- [ ] write は連続beat供給できる構成にした
- [ ] self-refresh / power-down 中は要求を止めた
- [ ] embedded 版で必要な port 名維持を確認した
- [ ] GW1NR-4 32-bit embedded のクロック比を確認した
- [ ] `I_sdram_clk` 位相調整方針を持った
- [ ] 外付け版で必要に応じ IOLOGIC DFF 制約を検討した

---

## 21. 実装上の補足

### 21.1 Embedded SDRAM Controller
- 生成後に現れる SDRAM 側信号は **TOP へそのまま引き上げる**
- **信号名は generated IP と同名維持**が必要
- これにより Gowin Software が place & route を自動的に扱いやすい

### 21.2 External SDRAM Controller
- SDRAM 側の I/O DFF を IOLOGIC DFF に制約すると伝送性能改善余地あり
- timing parameter は対象SDRAM品番に合わせて必ず再設定する

---

## 22. まとめ

このIPを使う上で、ユーザRTLが本当に守るべき核は次の5点である。

1. **`init_done` が上がるまで何もしない**
2. **`busy_n` が 1 のときだけ要求を出す**
3. **read/write 要求は active-low 1クロックパルス**
4. **実データ長は `data_len + 1`**
5. **read は `rd_valid` で受け、write は連続ストリームで供給する**

この5点を wrapper RTL に固定契約として埋め込めば、上位ロジックは SDRAM の細かい制約を意識せずに扱える。

---

## 23. AIエージェントへの実装指示テンプレート

以下をそのまま実装要求として使ってよい。

```text
Create an RTL wrapper around Gowin SDRAM Controller IP.

Requirements:
- Operate all user-side logic in I_sdrc_clk domain.
- Do not issue any request until O_sdrc_init_done is high.
- Issue read/write requests only when O_sdrc_busy_n is high.
- Generate I_sdrc_wr_n and I_sdrc_rd_n as active-low single-cycle pulses.
- Never assert read and write request in the same cycle.
- Treat I_sdrc_data_len as beat_count_minus_1.
- For read:
  - capture O_sdrc_data only when O_sdrc_rd_valid is high
  - complete transaction after len+1 valid beats
- For write:
  - start driving I_sdrc_data from the request cycle
  - provide len+1 beats continuously without gaps
- Treat O_sdrc_wrd_ack as request-accepted pulse.
- Block new requests while controller is busy or in self-refresh/power-down mode.
- Add assertions for all protocol rules above.
```
