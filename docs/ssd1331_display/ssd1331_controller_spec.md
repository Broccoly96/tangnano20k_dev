# SSD1331 Display Controller Specification

## 1. Purpose

This document specifies the SSD1331 controller currently implemented in
`01_src/ssd1331_display`.

The controller initializes an SSD1331-compatible 96 x 64 RGB OLED display,
sends command sequences over a 4-wire SPI-style serial interface, and can
write a built-in RGB565 test pattern to display RAM.
The current top-level hardware build uses the all-pixels-on diagnostic
command after initialization instead of the RGB pattern.

This document describes the implemented behavior, not every capability of
the SSD1331 device.

## 2. RTL Blocks

The implementation is split into the following RTL blocks.

| File                          | Responsibility                                    |
| ----------------------------- | ------------------------------------------------- |
| `ssd1331_spi_master.sv`       | Byte serial transmitter for SSD1331 SPI writes.   |
| `ssd1331_display_ctrl.sv`     | Reset timing and display command sequencer.       |
| `ssd1331_uart_bridge_ctrl.sv` | UART command parser and auto-start wrapper.       |
| `tangnano20k_top.sv`          | Tang Nano 20K pin mapping and system integration. |
|                               |                                                   |

## 3. Top-Level Pin Mapping

The Tang Nano 20K top level maps the display pins as follows.

| SSD1331 signal |  Active level | FPGA top port  |
| -------------- | ------------: | -------------- |
| `CS_N`         |           Low | `PIN73_IOT40A` |
| `SCLK` / `D0`  |           N/A | `PIN74_IOT34B` |
| `SDIN` / `D1`  |           N/A | `PIN75_IOT34A` |
| `RES_N`        |           Low | `PIN26_IOB06B` |
| `DC` / `D/C#`  | Low = command | `PIN29_IOB14A` |

Unused previous display outputs are parked to static levels.

| FPGA top port  | Driven value |
| -------------- | -----------: |
| `PIN77_IOT30A` |          `0` |
| `PIN85_IOT4B`  |          `1` |

## 4. Serial Interface

The serial interface is write-only from the FPGA to the display.

The current transmitter behavior is:

| Property                | Value                           |
| ----------------------- | ------------------------------- |
| Bit order               | MSB first                       |
| `SCLK` idle level       | High                            |
| Data update phase       | Before the rising sampling edge |
| Logic analyzer SPI mode | CPOL = 1, CPHA = 1              |
| `CS_N` framing          | One byte per `CS_N` low pulse   |
| Readback support        | Not implemented                 |

In the Tang Nano 20K top level, the system clock is 24 MHz and
`SSD1331_SPI_CLK_DIV` is set to 12.

The resulting serial clock is:

```text
SCLK = 24 MHz / (2 * 12) = 1 MHz
```

This gives a 1000 ns clock period, which is slower than the SSD1331
150 ns minimum serial clock cycle time.

## 5. DC Policy

The current implementation uses the following `DC` policy.

| Transfer type                 | `DC` level |
| ----------------------------- | ---------: |
| SSD1331 command byte          |        Low |
| SSD1331 command argument byte |        Low |
| GDDRAM pixel byte after `5Ch` |       High |

This policy was selected during hardware debug because the SSD1331 command
lock table describes the `FDh` argument byte as a command-mode byte.

If a target OLED module expects command arguments with `DC` high, this
policy must be revisited.

## 6. Reset And Auto-Start Timing

The top-level instantiation enables automatic initialization and pattern
generation after FPGA reset release.

| Parameter                   | Top-level value | Time at 24 MHz |
| --------------------------- | --------------: | -------------: |
| `RESET_ASSERT_CYCLES`       |       `240_000` |          10 ms |
| `RESET_RELEASE_CYCLES`      |     `2_400_000` |         100 ms |
| `AUTO_PATTERN_DELAY_CYCLES` |    `12_000_000` |         500 ms |
| `AUTO_ALL_ON_AFTER_INIT`    |             `1` |     Enabled    |
| `AUTO_PATTERN_AFTER_INIT`   |             `0` |     Disabled   |

The automatic sequence is:

1. Wait for FPGA reset release.
2. Issue `DISP_OP_INIT`.
3. Drive `RES_N` low for 10 ms.
4. Drive `RES_N` high and wait 100 ms.
5. Send the SSD1331 initialization command sequence.
6. Wait for the init operation to complete.
7. Wait 500 ms.
8. Issue `DISP_OP_ALL_ON`, which sends `A5h`.

This diagnostic mode bypasses GDDRAM writes.
If the panel lights up in this mode, the reset, serial command path,
display-on state, and OLED drive path are likely working.
If it stays dark, the next suspected area is panel power, reset wiring,
serial command acceptance, or a module-specific power requirement.

The controller does not drive a separate SSD1331 `VCC` enable pin.
If the OLED module exposes a separate panel supply enable, that signal must
be added outside this controller.

## 7. Initialization Sequence

The implemented `DISP_OP_INIT` sequence contains 39 serial bytes.

All bytes in this table are currently sent with `DC = Low`.

| Step |  Byte |  DC | Meaning                             |
| ---: | ----: | --: | ----------------------------------- |
|    0 | `FDh` | Low | Set command lock.                   |
|    1 | `12h` | Low | Unlock command interface.           |
|    2 | `AEh` | Low | Display off.                        |
|    3 | `A0h` | Low | Set remap and color depth.          |
|    4 | `72h` | Low | RGB color order, 65k color mode.    |
|    5 | `A1h` | Low | Set display start line.             |
|    6 | `00h` | Low | Start line = 0.                     |
|    7 | `A2h` | Low | Set display offset.                 |
|    8 | `00h` | Low | Display offset = 0.                 |
|    9 | `A4h` | Low | Normal display mode.                |
|   10 | `A8h` | Low | Set multiplex ratio.                |
|   11 | `3Fh` | Low | Multiplex ratio = 63.               |
|   12 | `ADh` | Low | Set master configuration.           |
|   13 | `8Eh` | Low | Master configuration value.         |
|   14 | `B0h` | Low | Set power save mode.                |
|   15 | `0Bh` | Low | Power save mode value.              |
|   16 | `B1h` | Low | Set phase period.                   |
|   17 | `31h` | Low | Phase period value.                 |
|   18 | `B3h` | Low | Set display clock divider.          |
|   19 | `F0h` | Low | Clock divider and oscillator value. |
|   20 | `8Ah` | Low | Set precharge A.                    |
|   21 | `64h` | Low | Precharge A value.                  |
|   22 | `8Bh` | Low | Set precharge B.                    |
|   23 | `78h` | Low | Precharge B value.                  |
|   24 | `8Ch` | Low | Set precharge C.                    |
|   25 | `64h` | Low | Precharge C value.                  |
|   26 | `BBh` | Low | Set precharge voltage.              |
|   27 | `3Ah` | Low | Precharge voltage value.            |
|   28 | `BEh` | Low | Set VCOMH voltage.                  |
|   29 | `3Eh` | Low | VCOMH voltage value.                |
|   30 | `87h` | Low | Set master current.                 |
|   31 | `06h` | Low | Master current value.               |
|   32 | `81h` | Low | Set contrast A.                     |
|   33 | `91h` | Low | Contrast A value.                   |
|   34 | `82h` | Low | Set contrast B.                     |
|   35 | `50h` | Low | Contrast B value.                   |
|   36 | `83h` | Low | Set contrast C.                     |
|   37 | `7Dh` | Low | Contrast C value.                   |
|   38 | `AFh` | Low | Display on.                         |

The expected logic analyzer prefix after reset release is:

```text
FD 12 AE A0 72 A1 00 A2 00 A4 A8 3F ...
```

`DC` should remain low across this entire prefix.

## 8. Built-In RGB Pattern Sequence

The automatic test pattern writes directly to GDDRAM.

The prefix selects the full 96 x 64 display window and enters RAM write
mode.

| Step |         Byte |   DC | Meaning             |
| ---: | -----------: | ---: | ------------------- |
|    0 |        `15h` |  Low | Set column address. |
|    1 |        `00h` |  Low | Column start = 0.   |
|    2 |        `5Fh` |  Low | Column end = 95.    |
|    3 |        `75h` |  Low | Set row address.    |
|    4 |        `00h` |  Low | Row start = 0.      |
|    5 |        `3Fh` |  Low | Row end = 63.       |
|    6 |        `5Ch` |  Low | Write RAM.          |
|   7+ | RGB565 bytes | High | Pixel data.         |

The pixel payload contains 96 x 64 pixels, two bytes per pixel.
The total payload is 12,288 bytes.

The total `DISP_OP_PATTERN` sequence length is:

```text
7 prefix bytes + 12,288 pixel bytes = 12,295 bytes
```

The pattern is three vertical color bars.

| Pixel range      | Color | RGB565 value |
| ---------------- | ----- | -----------: |
| Columns 0 to 31  | Red   |      `F800h` |
| Columns 32 to 63 | Green |      `07E0h` |
| Columns 64 to 95 | Blue  |      `001Fh` |

The expected logic analyzer prefix for the pattern is:

```text
15 00 5F 75 00 3F 5C F8 00 F8 00 ...
```

`DC` should be low through `5Ch` and high starting at the first `F8h`
pixel byte.

## 9. Other Display Operations

The controller also supports the following operations.

| Operation         | Byte sequence              | DC policy |
| ----------------- | -------------------------- | --------- |
| Clear full screen | `25 00 00 5F 3F`           | All low   |
| Fill full screen  | `26 01 22 00 00 5F 3F ...` | All low   |
| All pixels on     | `A5`                       | Low       |
| Display on        | `AF`                       | Low       |
| Display off       | `AE`                       | Low       |

`DISP_OP_FILL` uses the SSD1331 rectangle command path.
The automatic pattern does not use rectangle drawing.

## 10. UART Control Interface

`ssd1331_uart_bridge_ctrl` accepts simple ASCII command lines.

| Command    | Operation                               |
| ---------- | --------------------------------------- |
| `I`        | Run initialization.                     |
| `C`        | Clear full screen.                      |
| `P`        | Send built-in RGB pattern.              |
| `A`        | Force all pixels on with `A5h`.         |
| `O`        | Display on.                             |
| `X`        | Display off.                            |
| `F RRGGBB` | Fill full screen with one RGB888 color. |

Commands are ignored with a busy error event if a display operation is
already active.

## 11. Verification Coverage

The following simulations cover the SSD1331 controller blocks.

| Simulation folder                    | Coverage focus                      |
| ------------------------------------ | ----------------------------------- |
| `03_sim/26_ssd1331_spi_master`       | SPI byte framing and idle behavior. |
| `03_sim/27_ssd1331_display_ctrl`     | Init, clear, fill, on/off, pattern. |
| `03_sim/28_ssd1331_uart_bridge_ctrl` | UART parsing and display requests.  |

The display controller testbench checks the initialization byte values,
their `DC` values, and the RGB565 pattern prefix and color boundaries.
