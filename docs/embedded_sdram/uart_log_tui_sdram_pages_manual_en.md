# UART Log TUI SDRAM Pages Manual

This manual describes the current `SDRAM Map` and `SDRAM RW` pages in
`uart_log_tui`.

Target file:
- `11_app/uart_log_tool/debug_log_tool/uart_log_tui.py`

## Current host protocol status

- Single access is supported.
- `Single Address Read` uses printable ASCII `R <addr>`.
- `Single Address Write` uses printable ASCII `W <addr> <data>`.
- Bulk transfer is currently disabled in the host tools.
- The `SRAM Map`, `File Select Read`, and `File Select Write` widgets
  remain visible, but they do not start SDRAM transfer.
- When those disabled functions are requested, the TUI shows
  `INOP: bulk path disabled`.

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
- 64-word display area

### Address window

- One page corresponds to `64 words = 256 bytes`.
- The display uses 32-bit word addresses.
- Four words are shown per row.

### Current behavior

- The page layout remains available for operator convenience.
- `Refresh` does not issue SDRAM read traffic in the current phase.
- Pressing `Refresh` shows `INOP: bulk path disabled`.
- The displayed map content is therefore not refreshed from hardware in
  the current single-access-only release.

## SDRAM RW

The `SDRAM RW` page keeps four panels:

- `Single Address Read`
- `Single Address Write`
- `File Select Read`
- `File Select Write`

Only the single-address read/write panels are active.

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

## File Select Read

- The panel remains visible.
- The path field remains visible.
- The button does not start SDRAM transfer in this phase.
- Pressing the button shows:
  `INOP: bulk path disabled`

## File Select Write

- The panel remains visible.
- The base-address field and path field remain visible.
- The button does not start SDRAM transfer in this phase.
- Pressing the button shows:
  `INOP: bulk path disabled`

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

- Bulk `BR` / `BW` is not active in the current host tools.
- `SRAM Map` refresh is intentionally inoperative in this phase.
- `File Select Read` is intentionally inoperative in this phase.
- `File Select Write` is intentionally inoperative in this phase.
