# SDRAM UART Control and Bulk Transfer Specification

## 1. Purpose

This document defines the next-step UART host protocol for the
embedded SDRAM access path.

The goal is to separate:

- human-friendly control operations
- high-throughput SDRAM block transfer operations

The new protocol shall replace the current "all-binary over raw CLI
bytes" approach for command entry.
The previous approach collides with `uart_log_cli` control bytes such as
`Ctrl+R` and `Ctrl+F`.


## 2. Design Goal

The protocol shall use two paths with different roles.

### 2.1 ASCII Control Path

The ASCII control path is intended for:

- single address read
- single address write
- mode entry for bulk read
- mode entry for bulk write
- simple status / version / help commands

The ASCII control path shall be:

- printable ASCII only
- line oriented
- terminated by `LF` (`0x0A`)
- easy to type and debug from a terminal

### 2.2 Binary Bulk Path

The binary bulk path is intended for:

- SDRAM map refresh
- file write to SDRAM
- file read from SDRAM
- long sequential transfer

The binary bulk path shall:

- avoid printable ASCII overhead for payload bytes
- avoid collision with `uart_log_cli` single-byte control commands
- be block based
- include explicit size and checksum information


## 3. System Context

### 3.1 Existing Blocks

This specification assumes the existing top-level structure remains.

- `uart_log_cli`
- `sdram_emb_hostif_ctrl`
- `sdram_uart_bridge_ctrl`
- host event source `src_id = 0x03`

### 3.2 Existing UART Log Rules

The existing log/event uplink remains unchanged.

- DUT to PC log transport stays fixed-length framed binary
- `uart_log_cli` system events remain on `src_id = 0x00`
- SDRAM host responses remain on `src_id = 0x03`

This document only changes the PC-to-DUT command entry path for SDRAM
host access.


## 4. Addressing and Data Width

### 4.1 Address Unit

The SDRAM host address is a 21-bit word address.

- One address step equals one 32-bit word
- Byte addressing is not supported
- `addr = 0x00001` means the second 32-bit word

### 4.2 Data Width

All data transfers are 32-bit words.

- single read returns one 32-bit word
- single write writes one 32-bit word
- bulk read/write lengths are measured in words


## 5. High-Level Protocol

### 5.1 Idle Mode

In idle mode, incoming UART bytes are interpreted as ASCII command
characters.

Only printable ASCII, `CR`, and `LF` are valid in this mode.

### 5.2 Bulk Session Mode

When a bulk command is accepted, the controller enters a bulk session.

In bulk session mode:

- ASCII command parsing is suspended
- incoming bytes are consumed by the active bulk transfer engine
- `uart_log_cli` single-byte control commands shall not be interpreted as
  SDRAM payload bytes

This means the bulk engine owns the byte stream until the current bulk
session finishes or aborts.


## 6. ASCII Control Command Set

### 6.1 General Format

Each ASCII command shall be a single line.

Format rules:

- characters are 7-bit printable ASCII
- fields are separated by one or more spaces
- line terminator is `LF`
- optional `CR` before `LF` is allowed
- command name is upper-case ASCII

### 6.2 Required Commands

The first implementation shall support the following commands.

#### `R <addr>`

Single 32-bit read.

- `<addr>` is fixed-width or variable-width hexadecimal
- prefix `0x` is optional
- valid range is `0x00000` to `0x1FFFFF`

Example:

```text
R 100308
```

#### `W <addr> <data>`

Single 32-bit write.

- `<addr>` is hexadecimal word address
- `<data>` is 32-bit hexadecimal data

Example:

```text
W 100308 89ABCDEF
```

#### `BR <addr> <words>`

Begin bulk read session.

- `<addr>` is start word address
- `<words>` is transfer length in words
- no binary payload follows from PC to DUT
- DUT shall return bulk data blocks after command acceptance

Example:

```text
BR 100000 0040
```

#### `BW <addr> <words>`

Begin bulk write session.

- `<addr>` is start word address
- `<words>` is transfer length in words
- binary blocks from PC to DUT shall follow after command acceptance

Example:

```text
BW 100000 0040
```

#### `H`

Help request.

Optional but recommended.

#### `S`

Status request.

Optional but recommended.


## 7. ASCII Parser Rules

### 7.1 Parser State

The parser shall be implemented as a small line parser FSM.

Minimum states:

- `IDLE`
- `COLLECT_LINE`
- `DECODE_LINE`
- `RESPOND_ERR`

### 7.2 Character Policy

Accepted ASCII bytes in idle/line mode:

- `0x20` space
- `0x30..0x39`
- `0x41..0x46`
- `0x52` `R`
- `0x57` `W`
- `0x42` `B`
- `0x48` `H`
- `0x53` `S`
- `0x0D` `CR`
- `0x0A` `LF`
- optional lower-case hex may be accepted, but upper-case only is
  sufficient for the first version

### 7.3 Error Policy

Malformed ASCII command lines shall not start SDRAM activity.

They shall generate a host error event with enough information to debug
the failure.


## 8. Binary Bulk Transport

### 8.1 Why a Dedicated Bulk Transport Exists

Printable ASCII doubles the payload size for hexadecimal data.
That is acceptable for single-word transactions, but inefficient for:

- SDRAM map refresh
- file read
- file write

Therefore, only the control command shall be ASCII.
The bulk payload itself shall remain binary.

### 8.2 Bulk Framing

The first implementation shall use a simple fixed block protocol.

Each bulk block shall be:

- binary
- length-delimited
- checksum protected

### 8.3 Proposed Block Format

Each block shall have the following byte layout.

```text
SOF0 SOF1 TYPE SEQ LEN0 LEN1 PAYLOAD... CRC16_LO CRC16_HI
```

Field definitions:

- `SOF0 = 0x55`
- `SOF1 = 0xAA`
- `TYPE` identifies payload type
- `SEQ` is block sequence number modulo 256
- `LEN0/LEN1` is payload byte count, little-endian
- `PAYLOAD` is binary
- `CRC16` covers `TYPE`, `SEQ`, `LEN`, and `PAYLOAD`

### 8.4 Required Block Types

The first implementation shall support:

- `0x01` `BULK_WR_DATA`
- `0x02` `BULK_WR_END`
- `0x81` `BULK_RD_DATA`
- `0x82` `BULK_RD_END`
- `0xE0` `BULK_ABORT`

### 8.5 Payload Rules

#### `BULK_WR_DATA`

Payload contains raw write data bytes.

- byte order is little-endian word packing
- payload length shall be a multiple of 4
- each 4 bytes represent one 32-bit word

#### `BULK_RD_DATA`

Payload contains raw read data bytes.

- byte order is little-endian word packing
- payload length shall be a multiple of 4

#### `BULK_WR_END`

Payload is empty.

This marks the normal end of PC-to-DUT bulk write transfer.

#### `BULK_RD_END`

Payload is empty.

This marks the normal end of DUT-to-PC bulk read transfer.


## 9. Bulk Session Behavior

### 9.1 Bulk Write Session

When `BW` is accepted:

1. Controller validates address and length
2. Controller emits a session-start OK event
3. Controller enters bulk-write mode
4. Controller receives `BULK_WR_DATA` blocks
5. Controller writes received words into SDRAM sequentially
6. Controller completes when all requested words are written
7. Controller emits final completion event
8. Controller returns to ASCII idle mode

### 9.2 Bulk Read Session

When `BR` is accepted:

1. Controller validates address and length
2. Controller emits a session-start OK event
3. Controller enters bulk-read mode
4. Controller reads SDRAM sequentially
5. Controller streams `BULK_RD_DATA` blocks to the PC
6. Controller emits `BULK_RD_END`
7. Controller emits final completion event
8. Controller returns to ASCII idle mode

### 9.3 Abort Rules

A bulk session shall terminate on:

- CRC error
- bad block type
- sequence mismatch
- SDRAM timeout
- explicit `BULK_ABORT`

On abort:

- controller emits an error event
- controller discards current bulk context
- controller returns to ASCII idle mode


## 10. Event and Response Policy

### 10.1 Single Access Responses

Single access responses shall continue to use the existing host event
source.

- `0x30` `WRITE_ACK`
- `0x31` `READ_RSP`
- `0x3E` `CMD_ERR`

### 10.2 New Bulk Events

The first implementation shall add bulk-session event IDs under
`src_id = 0x03`.

Recommended event IDs:

- `0x32` `BULK_BEGIN_OK`
- `0x33` `BULK_BEGIN_ERR`
- `0x34` `BULK_PROGRESS`
- `0x35` `BULK_DONE`
- `0x36` `BULK_ABORTED`

Recommended arguments:

- `arg0`: start address
- `arg1`: total words or completed words
- `arg2`: status or error code

### 10.3 Error Code Classes

Recommended error classes:

- bad ASCII command
- bad ASCII field
- out-of-range address
- out-of-range word count
- busy
- SDRAM read timeout
- SDRAM write timeout
- bulk CRC mismatch
- bulk block type mismatch
- bulk sequence mismatch
- bulk length mismatch


## 11. RTL Partitioning

### 11.1 Current Module Split

The current repository keeps the implemented bulk path in active production
modules rather than the older proposed split-out helpers.

- `sdram_uart_ascii_ctrl.sv`
  ASCII line parser and command classifier
- `sdram_uart_bulk_rx.sv`
  binary bulk write block receiver
- `sdram_uart_bridge_ctrl.sv`
  command admission, bulk-session control, and event response staging
- `sdram_uart_access_engine.sv`
  SDRAM command execution for single, burst-test, and raw bulk accesses

The historical proposal modules `sdram_uart_bulk_tx.sv` and
`sdram_uart_host_mux.sv` are not part of the current repository.

### 11.2 Reuse Policy

The current `sdram_uart_bridge_ctrl.sv` should not be extended with a
large monolithic parser.
It should either be replaced or refactored into smaller modules.

### 11.3 FSM Separation

Separate FSMs are strongly recommended for:

- ASCII line parsing
- SDRAM single-access execution
- bulk RX framing
- bulk TX framing
- bulk session control
- event generation


## 12. Throughput Policy

### 12.1 Expected Benefit

This split protocol keeps interactive access simple while preserving bulk
efficiency.

The expected tradeoff is:

- single read/write: slower than pure binary, but acceptable
- map refresh and file transfer: much faster than printable ASCII-only

### 12.2 Map Refresh Requirement

The SDRAM map page shall use the bulk read path, not repeated ASCII
single-word reads.

That is mandatory for acceptable UI responsiveness.


## 13. Host Tool Policy

### 13.1 TUI Behavior

The TUI shall use:

- ASCII `R` and `W` for single access
- ASCII `BR` and `BW` for map/file operations
- binary block mode only after bulk session acceptance

### 13.2 File Format

File read/write shall continue to use raw binary files.

- file bytes map directly to little-endian SDRAM word payload
- no Intel HEX or S-record support is required in the first version


## 14. Verification Requirements

### 14.1 Simulation Cases

The next implementation shall add dedicated simulation for:

- ASCII single read
- ASCII single write
- ASCII syntax error
- ASCII range error
- bulk write of multiple blocks
- bulk read of multiple blocks
- bulk CRC error
- bulk abort
- command issue while busy
- transition from bulk mode back to ASCII idle

### 14.2 Required Collision Test

Verification shall explicitly include payload bytes that collide with
legacy CLI commands.

Examples:

- `0x04`
- `0x06`
- `0x10`
- `0x12`
- `0x14`
- `0x3F`

Both simulation and hardware smoke test shall prove that these bytes are
handled correctly inside bulk payload or ASCII-free binary blocks.

### 14.3 Hardware Smoke Test

At minimum, hardware validation shall confirm:

1. ASCII single write to a safe address
2. ASCII single read from the same address
3. bulk write of a raw binary file
4. bulk read-back of the same region
5. byte-for-byte host-side compare


## 15. Non-Goals for the First Version

The first version does not need:

- XMODEM interoperability
- YMODEM interoperability
- terminal-side manual bulk operation
- multiple concurrent bulk sessions
- compression
- encryption

XMODEM can be considered later if interoperability becomes more important
than implementation simplicity.


## 16. Recommended First Implementation Boundary

The next implementation should proceed in this order.

1. Introduce ASCII single read/write only
2. Keep existing event response format
3. Add `BR` / `BW` session entry commands
4. Add simple proprietary binary bulk block framing
5. Convert TUI map refresh and file transfer to the bulk path
6. Remove legacy raw-binary single-access injection path

This phased approach reduces risk and keeps regression scope small.
