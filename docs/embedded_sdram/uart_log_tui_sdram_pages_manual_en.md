# UART Log TUI SDRAM Pages Manual

This manual describes the `SDRAM Map` and `SDRAM RW` pages in
`uart_log_tui`.

Target file:
- `11_app/uart_log_tool/debug_log_tool/uart_log_tui.py`

## Protocol split

- Single read/write uses printable ASCII commands:
  `R <addr>` and `W <addr> <data>`.
- Map refresh and file transfer use the split bulk flow:
  ASCII `BR` / `BW` session begin, then raw binary bulk blocks.
- The TUI keeps the existing 256-byte map window and file-read-save size.

## SDRAM Map

- The page still displays 64 words, 256 bytes, from the selected base
  address.
- Refresh sends one ASCII `BR` command for 64 words.
- After the `BULK_BEGIN_OK` host event, the TUI receives raw
  `BULK_RD_DATA` blocks, stops at `BULK_RD_END`, and then waits for the
  framed `BULK_DONE` event.

## SDRAM RW

- `Single Address Read` sends ASCII `R <addr>`.
- `Single Address Write` sends ASCII `W <addr> <data>`.
- `File Select Read` uses the current map base address and reads exactly
  256 bytes through the bulk read path.
- `File Select Write` starts ASCII `BW`, then sends raw binary write
  blocks with zero padding to the next 32-bit word when the file size is
  not a multiple of four bytes.

## Raw bulk block notes

- Bulk payload bytes are binary and may include values that collide with
  legacy CLI controls.
- Raw blocks use:
  `55 AA TYPE SEQ LEN0 LEN1 PAYLOAD CRC16_LO CRC16_HI`
- CRC is CRC-16/CCITT-FALSE.
- Maximum payload per raw block is 104 bytes.
