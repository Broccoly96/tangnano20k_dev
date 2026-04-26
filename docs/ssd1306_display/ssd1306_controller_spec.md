# SSD1306 Display Controller Specification

## 1. Purpose

This document specifies the SSD1306 controller implemented in
`01_src/ssd1306_display`.

The controller targets a monochrome 128 x 32 OLED panel connected over I2C.
It supports initialization, display on/off control, full-screen clear, and
full-frame write through a UART command bridge.

This document describes the implemented behavior in this repository.
It does not attempt to cover every feature of the SSD1306 device.

## 2. RTL Blocks

The implementation is split into the following RTL blocks.

| File                                | Responsibility                                                    |
| ----------------------------------- | ----------------------------------------------------------------- |
| `ssd1306_uart_proto_pkg.sv`         | Shared constants, operation IDs, and bulk/event helpers.          |
| `ssd1306_display_ctrl.sv`           | Request-driven SSD1306 I2C command sequencer.                     |
| `ssd1306_display_stream_ctrl.sv`    | Streaming SSD1306 sequencer that fetches frame bytes on demand.   |
| `ssd1306_uart_bridge_ctrl.sv`       | UART ASCII parser, local frame buffer, and raw frame upload path. |
| `ssd1306_sdram_uart_bridge_ctrl.sv` | UART control bridge that refreshes the panel from SDRAM.          |
| `tangnano20k_top.sv`                | Tang Nano 20K pin mapping and system integration.                 |

## 3. Geometry And Addressing

The implemented target geometry is fixed as follows.

| Property       |       Value |
| -------------- | ----------: |
| Display width  |       `128` |
| Display height |        `32` |
| Page count     |         `4` |
| Frame size     | `512 bytes` |

The frame buffer byte order used by the RTL is page-major.
Byte `0` corresponds to page `0`, column `0`.
Byte `127` corresponds to page `0`, column `127`.
Byte `128` starts page `1`, column `0`.

The SDRAM-backed refresh path uses a fixed frame-buffer window.

| Property                    | Value       |
| --------------------------- | ----------- |
| Base SDRAM word address     | `0x10000`   |
| Window size in words        | `128 words` |
| Window size in bytes        | `512 bytes` |
| Last SDRAM word address     | `0x1007F`   |
| Byte-offset equivalent      | `0x40000`   |
| Last byte-offset equivalent | `0x401FF`   |

Important address-unit rule:

- The SDRAM host bridge uses `21-bit` word addresses, not byte addresses.
- One SDRAM word is `32 bits = 4 bytes`.
- A full SSD1306 frame therefore occupies `128` consecutive SDRAM words.
- `FRAMEBUFFER_BASE_ADDR = 0x10000` means the first frame byte is stored in
  the word at SDRAM address `0x10000`.
- The refresh path reads the full frame from `0x10000` through `0x1007F`.

Host-side examples:

- `BW 10000 00080` writes one full frame into the SSD1306 SDRAM window.
- `BR 10000 00080` reads back the same full-frame window.

The full-frame write path uses horizontal addressing mode.
The controller programs:

- `20h 00h` : horizontal addressing mode
- `21h 00h 7Fh` : full 128-column range
- `22h 00h 03h` : page range for 32-row glass

## 4. I2C Interface

The display path is write-only.
The controller does not issue read transactions.

The RTL exposes a 7-bit slave address parameter.
The default value is `0x3C`.
The resulting on-wire write address byte is `0x78`.

The control bytes used by the implementation are:

| Transfer type  | Control byte |
| -------------- | -----------: |
| Command stream |        `00h` |
| Data stream    |        `40h` |

For `CLEAR` and `FRAME_WRITE`, the implementation uses two I2C transactions.

1. A command transaction writes the addressing setup bytes.
2. A data transaction writes the 512-byte pixel payload.

This split avoids mixing command-mode and data-mode control bytes inside one
transaction.

The top-level pins are open-drain `inout` ports.
The RTL only drives low and otherwise releases the line to `Z`.

## 5. Reset Policy

The current implementation does not drive a dedicated `RES#` signal.
Initialization is performed through I2C commands only.

If a future board revision requires explicit reset timing, that signal must be
added outside the current controller block.

## 6. Supported Operations

The controller supports the following request operations.

| Operation             | Description                                           |
| --------------------- | ----------------------------------------------------- |
| `DISP_OP_INIT`        | Send the standard 128 x 32 SSD1306 init sequence.     |
| `DISP_OP_CLEAR`       | Clear the full 512-byte GDDRAM window with zero data. |
| `DISP_OP_FRAME_WRITE` | Write one complete 512-byte frame.                    |
| `DISP_OP_ON`          | Send `AFh`.                                           |
| `DISP_OP_OFF`         | Send `AEh`.                                           |

The request interface is `valid/ready` based.
Only one request may be in flight at a time.

Completion is returned through:

- `O_DONE_VALID`
- `O_DONE_OP`
- `O_DONE_OK`
- `O_DONE_STATUS`

`O_DONE_STATUS = 0` indicates success.
The current controller reports `ERR_I2C_NACK` when a byte write is not ACKed.

## 7. Initialization Sequence

The implemented `INIT` sequence contains the following command bytes.

```text
AE
D5 80
A8 1F
D3 00
40
8D 14
20 00
A1
C8
DA 02
81 8F
D9 F1
DB 40
A4
A6
AF
```

The intent of these values is:

- display off during setup
- multiplex ratio `1Fh` for 32-row glass
- zero display offset and start line
- internal charge pump enabled
- horizontal addressing selected
- segment remap enabled
- COM scan direction remapped
- COM pins configured for 128 x 32 glass with `DAh 02h`
- normal display mode and non-inverted pixels
- display on at the end of the sequence

## 8. Full-Frame Write

The full-frame write path expects exactly `512` bytes.
No partial update API is implemented in the current RTL.

The command phase is:

```text
20 00 21 00 7F 22 00 03
```

The data phase is one control byte `40h` followed by `512` payload bytes.

The clear path reuses the same command phase and emits `512` bytes of `00h`.

## 9. UART Command Bridge

The UART bridge accepts one ASCII command per line.

| Command | Meaning                                        |
| ------- | ---------------------------------------------- |
| `I`     | Run initialization                             |
| `C`     | Clear full frame                               |
| `O`     | Display on                                     |
| `X`     | Display off                                    |
| `W`     | Start a 512-byte raw bulk frame upload session |

`W` does not carry the frame payload inline.
After the bridge accepts `W`, the host must send raw bulk blocks.

The current implementation uses:

- `64-byte` payload chunks
- `8` data blocks per frame
- one final `WR_END` block after the last chunk

The host shall wait for one progress event after each data block before
sending the next block.

## 10. UART Events

The display path uses UART source index `3`.
`uart_log_cli` therefore emits display events with `src_id = 0x04`.

The implemented event IDs are:

| Event               |    ID |
| ------------------- | ----: |
| Command acknowledge | `30h` |
| Frame accept        | `32h` |
| Frame error         | `33h` |
| Frame progress      | `34h` |
| Frame done          | `35h` |
| Frame abort         | `36h` |
| Command error       | `3Eh` |

`EVT_FRAME_PROG.arg0` packs:

```text
{chunk_index[7:0], chunk_bytes[7:0], total_bytes[15:0]}
```

## 11. Simulation Coverage

The current SSD1306 unit-level simulations are:

| Folder                               | Purpose                                       |
| ------------------------------------ | --------------------------------------------- |
| `03_sim/29_ssd1306_display_ctrl`     | Controller byte-stream and GDDRAM smoke test  |
| `03_sim/30_ssd1306_uart_bridge_ctrl` | ASCII command and raw frame upload smoke test |

Both tests use `02_tb/ssd1306_display/ssd1306_i2c_model.sv`.

The model is intentionally write-only.
It ACKs the address, control, command, and data path used by the RTL and
tracks a 512-byte GDDRAM shadow for comparison.
