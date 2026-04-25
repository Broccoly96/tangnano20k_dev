# UART Log TUI SDRAM Pages Manual

This manual describes the current `SDRAM Map` and `SDRAM RW` pages in
`uart_log_tui`.

Target file:
- `11_app/uart_log_tool/debug_log_tool/uart_log_tui.py`

## Current host protocol status

- Single access and bulk access are supported.
- `Single Address Read` uses printable ASCII `R <addr>`.
- `Single Address Write` uses printable ASCII `W <addr> <data>`.
- `SDRAM Map` uses printable ASCII `BR <addr> <words>`.
- `SDRAM RW` bulk file write uses printable ASCII `BW <addr> <words>`.

## Startup behavior

- After FPGA configuration, the embedded SDRAM host path runs:
  `write pattern -> read verify -> full zero clear`.
- `SDRAM_TEST_PASS` means both the verify phase and the zero-clear phase
  completed.
- Untouched SDRAM locations therefore read back as `0x00000000` after
  startup pass.
- Startup takes longer than the earlier verify-only flow because the
  entire SDRAM word space is cleared before host access is enabled.

## SDRAM Map

### Layout

- Base address input
- `Refresh` button
- 256-word display area

### Address window

- One page corresponds to `256 words = 1024 bytes`.
- The display uses 32-bit word addresses.
- The horizontal axis is word-address offset `00` through `0F`.
- The vertical axis is word-address offset `00` through `F0`.
- Sixteen words are shown per row.

### Current behavior

- Pressing `Refresh` sends one `BR <base> 00100` command.
- Each `BULK_PROGRESS` event updates the corresponding word in the
  display buffer.
- `BULK_DONE` reports `refresh complete` after all 256 words have been
  received.
- Timeout or bulk error conditions are retried up to three times.

## SDRAM RW

The `SDRAM RW` page keeps three panels:

- `Single Address Read`
- `Single Address Write`
- `Bulk File Write`

All three panels are active.  `Bulk File Write` accepts `.bin` and `.hex`
payloads and writes them through the SDRAM bulk-write path.

## Single Address Read

### UI elements

- `Read` button
- Address input
- Result field

### Operation

- The TUI switches to SDRAM host source `src_id = 0x03`.
- It sends ASCII `R <addr>`.
- It waits for event `READ_RSP (0x31)`.

### Result format

- `0xAAAAA -> 0xDDDDDDDD`

Where:

- `AAAAA` is the 21-bit SDRAM word address
- `DDDDDDDD` is the returned 32-bit data

## Single Address Write

### UI elements

- `Write` button
- Address input
- Data input
- Result field

### Operation

- The TUI switches to SDRAM host source `src_id = 0x03`.
- It sends ASCII `W <addr> <data>`.
- It waits for event `WRITE_ACK (0x30)`.

### Result format

- `0xDDDDDDDD -> 0xAAAAA OK`

This indicates that the host write request completed successfully.

## Bulk File Write

- The panel is part of `SDRAM RW`.
- The base-address field uses the same 21-bit SDRAM word address format as
  single read/write.
- The path field accepts `.bin` and `.hex` files.
- Pressing `Write File` sends `BW <base> <words>`.
- Payload bytes are sent as CRC-protected raw bulk blocks.
- Files whose byte length is not a multiple of four are padded on the wire
  to the next whole SDRAM word.

## Source selection notes

- SDRAM host events use `src_id = 0x03`.
- The heartbeat source remains available on its original source index.
- Single SDRAM actions temporarily switch the host tool to the SDRAM
  source for command/response exchange.

## Event notes

- `SDRAM_INIT_DONE (0x20)`
  means the embedded SDRAM controller completed initialization.
- `SDRAM_TEST_START (0x21)`
  reports:
  test words, burst count, and zero-clear words.
- `SDRAM_TEST_PASS (0x22)`
  means read verification succeeded and full zero clear completed.
- `SDRAM_TEST_FAIL (0x23)`
  means read verification failed and zero clear was skipped.
- `WRITE_ACK (0x30)`
  acknowledges a single write command.
- `READ_RSP (0x31)`
  returns the result of a single read command.
- `CMD_ERR (0x3E)`
  reports malformed or unsupported host commands.

## Current limitations

- `SDRAM Bulk` and `SDRAM File` are no longer separate TUI pages.
- SDRAM bulk file read/save is not exposed in the current TUI layout.
