# Debug Log Tap Specification

Date: 2026-03-15.
Target: `uart_log_cli` and Ethernet UDP log export on tangmega60k.

## 1. Purpose

This document defines the observable debug log behavior for:

- `uart_log_cli`
- `eth_udp` log export
- host-side decode and filtering expectations

The goal is to let a reviewer understand:

- what log sources exist
- how events are framed
- which event IDs are currently defined
- what triggers each event
- how UART and Ethernet behaviors differ

This document describes the current implemented behavior.
It does not define TCP, syslog, text-mode protocols, or host-side
string rendering rules beyond the shipped decode table.

## 2. System Overview

### 2.1 Producer to consumer flow

Current top-level flow is:

```text
Log source event
  -> uart_log_dual_tap
     -> UART selected-source path
        -> uart_log_cli
        -> UART frame stream
     -> Ethernet all-source path
        -> eth_log_event_arbiter
        -> udp_log_stream_builder
        -> UDP log packet
```

### 2.2 Key difference between UART and Ethernet

UART path:

- only one selected source is emitted at a time
- source selection is controlled by `uart_log_cli`
- CLI/system events share the same UART frame format

Ethernet path:

- all sources are exported regardless of UART selected source
- host filters logs by `src_id`
- one Ethernet UDP log packet carries one 16-byte event payload
- current active stream format is `direct_event`

## 3. Common Event Payload Format

### 3.1 Event payload size

- one event payload is always `16 bytes`
- one payload contains exactly one event

### 3.2 Payload field layout

Logical payload layout is:

| Byte | Field |
|---|---|
| 0-1 | `timestamp[15:0]`, little-endian |
| 2 | `event_id` |
| 3 | `src_id` |
| 4-7 | `arg0[31:0]`, little-endian |
| 8-11 | `arg1[31:0]`, little-endian |
| 12-15 | `arg2[31:0]`, little-endian |

Equivalent 32-bit word view is:

- `word0 = {src_id, event_id, timestamp[15:0]}`
- `word1 = arg0`
- `word2 = arg1`
- `word3 = arg2`

### 3.3 Timestamp

- timestamp width is `16 bits`
- current time base is `1 ms`
- wrap-around is allowed
- host must treat it as modulo-65536 time

## 4. UART Log Specification

### 4.1 UART frame format

UART log frames use fixed-length binary framing.

| Field     | Size | Notes                          |
| --------- | ---: | ------------------------------ |
| `SYNC`    |   1B | fixed `0x7E`                   |
| `SEQ`     |   1B | event sequence modulo 256      |
| `PAYLOAD` |  16B | event payload                  |
| `CRC8`    |   1B | CRC-8/ATM over `SEQ + PAYLOAD` |

Total UART frame size is `19 bytes`.

### 4.2 UART source selection behavior

`uart_log_cli` keeps one active source selection.

Control commands:

- `?` = help
- `Ctrl+R` = soft reset request
- `Ctrl+F` = next source
- `Ctrl+D` = previous source
- `Ctrl+T` = status request

Current UART behavior:

- only the selected source is drained into UART event frames
- system/CLI events use reserved `src_id = 0x00`
- source-switch notification is emitted as a system event

## 5. Ethernet UDP Log Specification

### 5.1 UDP log payload size

One UDP log payload is always `32 bytes`.

### 5.2 UDP log payload fields

| Byte  | Field                       |
| ----- | --------------------------- |
| 0-1   | magic = `0x55AB`            |
| 2     | version                     |
| 3     | `stream_id`                 |
| 4-5   | packet sequence, big-endian |
| 6-7   | flags, big-endian           |
| 8-11  | timestamp field             |
| 12    | `valid_bytes`               |
| 13    | reserved                    |
| 14-29 | event payload bytes         |
| 30-31 | reserved                    |

### 5.3 Implemented stream IDs

| `stream_id` | Name | Meaning |
|---:|---|---|
| `0x01` | `legacy_mirror` | old UART byte-mirror stream |
| `0x02` | `direct_event` | current all-source event stream |

Current FPGA behavior emits `0x02 = direct_event`.

### 5.4 Ethernet log flags

| Bit |     Mask | Name            | Meaning                                  |
| --: | -------: | --------------- | ---------------------------------------- |
|   0 | `0x0001` | `overflow`      | event drop observed in log path          |
|   1 | `0x0002` | `framing_error` | reserved for malformed stream indication |
|   2 | `0x0004` | `source_reset`  | source-reset observed                    |
|   3 | `0x0008` | `partial_chunk` | only meaningful for legacy mirror stream |

For current `direct_event` stream:

- `valid_bytes` is normally `16`
- `partial_chunk` is not expected during normal operation
- host should interpret one packet as one event

### 5.5 Host-side filtering rules

Host tools are expected to:

- filter by `src_id`
- switch between `decode` and `raw` display
- distinguish `legacy_mirror` and `direct_event`

Current TUI behavior:

- `11_app/debug_log_tool/eth_udp_reg_tui.py` has `src filter`
- `11_app/debug_log_tool/eth_udp_reg_tui.py` supports `raw/decode`
- `11_app/debug_log_tool/uart_log_tool.py --transport udp` supports `decode`
- `11_app/debug_log_tool/uart_log_tool.py --transport udp` shows current `udp_stream`

## 6. Source Map

Current source numbering in `tangmega60k_top` is fixed as follows.

| `src_id` | Source name           | Module                  | Notes                                  |
| -------: | --------------------- | ----------------------- | -------------------------------------- |
|   `0x00` | system                | `uart_log_cli` internal | CLI/system reserved                    |
|   `0x01` | test source 1         | `uart_log_testsrc1`     | 1 Hz heartbeat                         |
|   `0x02` | PCIe event source     | `uart_log_pcie_ep`      | silent when PCIe debug is disabled     |
|   `0x03` | PCIe status source    | `uart_log_pcie_ep_sts`  | on-demand status, silent when disabled |
|   `0x04` | Ethernet debug source | `eth_debug_source`      | emits snapshot on status request       |

Current build keeps source numbering stable even when PCIe debug is disabled.
That means `src_id = 0x04` remains the Ethernet debug source.

## 7. System and CLI Event Table

Reserved system source is `src_id = 0x00`.

| Event name       | `src_id` | `event_id` | Trigger                  | arg usage                      | Notes                         |
| ---------------- | -------: | ---------: | ------------------------ | ------------------------------ | ----------------------------- |
| `EV_MODE_CHANGE` |   `0x00` |     `0x01` | source selection applied | `arg0=old_sel`, `arg1=new_sel` | emitted on UART source switch |
| `EV_HELP`        |   `0x00` |     `0x02` | `?` command              | ASCII text packed into args    | may be emitted multiple times |
| `EV_RESET_ACK`   |   `0x00` |     `0x03` | `Ctrl+R` accepted        | args unused                    | reset-ack event               |

## 8. Source Event Table

### 8.1 Source `0x01` : `uart_log_testsrc1`

| Event name           | `event_id` | Trigger            | arg0                             | arg1 | arg2 | Notes                    |
| -------------------- | ---------: | ------------------ | -------------------------------- | ---- | ---- | ------------------------ |
| `TESTSRC1_HEARTBEAT` |     `0x11` | periodic 1 Hz tick | heartbeat counter or fixed value | `0`  | `0`  | always-on in current top |

### 8.2 Source `0x02` : `uart_log_pcie_ep`

| Event name          | `event_id` | Trigger                  | arg usage            | Notes                           |
| ------------------- | ---------: | ------------------------ | -------------------- | ------------------------------- |
| `PCIE_RESET_EDGE`   |     `0x01` | PCIe reset edge observed | edge decode payload  | silent when PCIe debug disabled |
| `PCIE_LTSSM_CHANGE` |     `0x02` | LTSSM state changed      | LTSSM decode payload | silent when disabled            |
| `PCIE_LINKUP_EDGE`  |     `0x03` | link-up edge observed    | edge decode payload  | silent when disabled            |
| `PCIE_RX_ERROR`     |     `0x04` | RX error event           | RX error detail      | silent when disabled            |
| `PCIE_RX_TLP_CHUNK` |     `0x05` | RX TLP chunk accepted    | TLP chunk detail     | silent when disabled            |

### 8.3 Source `0x03` : `uart_log_pcie_ep_sts`

| Event name       | `event_id` | Trigger                                           | arg usage             | Notes           |
| ---------------- | ---------: | ------------------------------------------------- | --------------------- | --------------- |
| `PCIE_EP_STATUS` |     `0x01` | status request while PCIe status source is active | PCIe state + DMA-less bridge summary | on-demand event |
| `PCIE_EP_BRIDGE` |     `0x02` | immediately after `PCIE_EP_STATUS`                | RX/TX queue view + BAR0 last access  | on-demand event |

### 8.4 Source `0x04` : `eth_debug_source`

The Ethernet debug source expands one status request into an ordered snapshot.

| Event name        | `event_id` | Trigger        | arg0                     | arg1                       | arg2                       |
| ----------------- | ---------: | -------------- | ------------------------ | -------------------------- | -------------------------- |
| `ETH_STATUS`      |     `0x61` | status request | `phy_status`             | `last_cmd_status`          | `error_count`              |
| `ETH_COUNTERS0`   |     `0x62` | status request | `rx_packet_count`        | `tx_packet_count`          | `arp_count`                |
| `ETH_COUNTERS1`   |     `0x63` | status request | `udp_command_count`      | `rx_drop_count`            | `tx_drop_count`            |
| `ETH_LAST_PKT`    |     `0x64` | status request | `last_ethertype`         | `last_src_ip`              | `last_dst_udp_port`        |
| `ETH_RX_STREAM`   |     `0x65` | status request | `rx_stream_valid_count`  | `rx_stream_last_count`     | `rx_stream_error_count`    |
| `ETH_ARP_DECODE`  |     `0x66` | status request | `arp_dbg_word0`          | `arp_dbg_word1`            | `arp_dbg_word2`            |
| `ETH_RX_MAC`      |     `0x67` | status request | `rx_mac_valid_count`     | `rx_mac_last_count`        | `rx_mac_error_count`       |
| `ETH_TX_MAC`      |     `0x68` | status request | `tx_mac_valid_count`     | `tx_mac_last_count`        | `tx_mac_error_count`       |
| `ETH_TX_STATS`    |     `0x69` | status request | `tx_stats_valid_count`   | `tx_stats_vector`          | `tx_stats_summary`         |
| `ETH_MDIO_CTRL`   |     `0x6A` | status request | `mdio_target_page`       | `mdio_target_info`         | reserved                   |
| `ETH_MDIO_LAST`   |     `0x6B` | status request | `mdio_read_count`        | `mdio_last_page`           | `mdio_last_data`           |
| `ETH_MDIO_DUMP`   |     `0x6C` | status request | dump index               | page                       | register data              |
| `ETH_MDIO_INIT`   |     `0x6D` | status request | `phy_id1`                | `phy_id2`                  | `bmsr`                     |
| `ETH_MIIM_BUS`    |     `0x6E` | status request | `miim_counts`            | `miim_last_cmd`            | `miim_last_rsp`            |
| `ETH_PHY_SCAN`    |     `0x6F` | status request | `phy_scan_info`          | `phy_scan_id1`             | `phy_scan_id2`             |
| `ETH_CLOCKS`      |     `0x70` | status request | `clk_125m_div1024_count` | `tx_mac_clk_div1024_count` | `rx_mac_clk_div1024_count` |
| `ETH_RX_MAC_HDR0` |     `0x71` | status request | `rx_mac_hdr_word0`       | `rx_mac_hdr_word1`         | `rx_mac_hdr_word2`         |
| `ETH_RX_MAC_HDR1` |     `0x72` | status request | `rx_mac_hdr_word3`       | `rx_mac_hdr_info`          | reserved                   |

## 9. Trigger Summary

| Trigger source                  | Affected events                 | Transport                                                |
| ------------------------------- | ------------------------------- | -------------------------------------------------------- |
| 1 Hz internal timer             | `TESTSRC1_HEARTBEAT`            | UART if selected, Ethernet always                        |
| UART `Ctrl+F` / `Ctrl+D`        | `EV_MODE_CHANGE`                | UART only                                                |
| UART `?`                        | `EV_HELP`                       | UART only                                                |
| UART `Ctrl+R`                   | `EV_RESET_ACK`                  | UART only                                                |
| UART `Ctrl+T`                   | Ethernet status snapshot events | UART if Ethernet source selected, Ethernet always        |
| PCIe internal state transitions | PCIe source events              | UART if selected, Ethernet always when source is enabled |

## 10. Observation and Verification Notes

### 10.1 Expected UART behavior

- selecting source 1 on UART shows only heartbeat and system events
- selecting Ethernet debug source on UART and sending `Ctrl+T`
  shows the Ethernet snapshot sequence

### 10.2 Expected Ethernet behavior

- heartbeat from `src_id = 0x01` appears without any source selection
- Ethernet snapshot from `src_id = 0x04` appears after UART `Ctrl+T`
- `src filter` in the host tool is display-only
- Ethernet logging does not change the UART selected source

### 10.3 Current implemented stream mode

Current FPGA build uses:

- `stream_id = 0x02`
- one event per UDP packet
- no normal `partial_chunk`

Legacy mirror decode support remains in host tools for compatibility,
but is not the primary active mode in the current bitstream.
