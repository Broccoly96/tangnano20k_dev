# Gowin SDRAM Controller HS IP Design Specification

## 1. Purpose

This document defines the project integration contract for the Gowin
SDRAM Controller HS IP.
It is based on `IPUG756-1.1E_Gowin SDRAM Controller HS IP User Guide.pdf`
and the generated IP instance in `00_ip/embedded_sdram_hs`.

The goal is not to reimplement the Gowin IP.
The goal is to define how user RTL, simulations, synthesis, timing checks,
and hardware tools shall use the HS IP without guessing.

## 2. Repository Instance

The checked-in generated HS IP is:

- IP path: `00_ip/embedded_sdram_hs`
- Module name: `embedded_sdram_hs`
- Target device: `gw2ar18c-000`
- Data width: `32`
- Bank width: `2`
- Row width: `11`
- Column width: `8`
- CAS latency: `CL = 3`
- Precharge timing: `tRP = 3`
- Auto-refresh timing: `tRFC = 9`
- Mode-register delay: `tMRD = 3`
- Active-to-read/write delay: `tRCD = 3`
- Write recovery timing: `tWR = 3`

The user address is packed from high to low as:

```text
I_sdrc_addr = {bank[1:0], row[10:0], column[7:0]}
```

Therefore, a read/write burst shall not cross an 8-bit column page boundary.
For this repository, single-word access remains the default safe hardware
mode until a page-safe burst validation run passes on real hardware.

## 3. Port Contract

### 3.1 SDRAM-Side Signals

The SDRAM-side signal names shall match the generated IP names in the
top-level design when using embedded SDRAM.
These embedded SDRAM signals do not require `.cst` pin constraints.

| Signal | Direction from FPGA RTL | Meaning |
| --- | ---: | --- |
| `O_sdram_clk` | output | SDRAM clock |
| `O_sdram_cke` | output | SDRAM clock enable |
| `O_sdram_cs_n` | output | chip select |
| `O_sdram_cas_n` | output | column address strobe |
| `O_sdram_ras_n` | output | row address strobe |
| `O_sdram_wen_n` | output | write enable |
| `O_sdram_dqm[3:0]` | output | byte/data mask |
| `O_sdram_addr[10:0]` | output | row/column address |
| `O_sdram_ba[1:0]` | output | bank address |
| `IO_sdram_dq[31:0]` | inout | data bus |

### 3.2 User-Side Signals

All user-side signals are aligned to the rising edge of `I_sdrc_clk`.

| Signal | Dir | Required User RTL Behavior |
| --- | ---: | --- |
| `I_sdrc_rst_n` | input | Active-low reset. Wait for init after release. |
| `I_sdrc_clk` | input | HS controller working/user clock. |
| `I_sdram_clk` | input | SDRAM operating clock. |
| `I_sdrc_cmd_en` | input | Active-high one-cycle command pulse. |
| `I_sdrc_cmd[2:0]` | input | SDRAM command encoded as `{RAS#, CAS#, WE#}`. |
| `I_sdrc_precharge_ctrl` | input | `1`: precharge after read/write, `0`: no precharge. |
| `I_sdram_power_down` | input | Power-down request. Tie low unless explicitly tested. |
| `I_sdram_selfrefresh` | input | Self-refresh request. Tie low unless explicitly tested. |
| `I_sdrc_addr[20:0]` | input | Packed bank/row/column address. |
| `I_sdrc_dqm[3:0]` | input | Data mask. Use `4'h0` for full-width access. |
| `I_sdrc_data[31:0]` | input | Write data stream. |
| `I_sdrc_data_len[7:0]` | input | Transfer length minus one. |
| `O_sdrc_data[31:0]` | output | Read data stream. |
| `O_sdrc_init_done` | output | `1` after IP initialization completes. |
| `O_sdrc_cmd_ack` | output | One-cycle pulse when command execution completes. |

The HS IP does not provide the legacy signals `O_sdrc_busy_n`,
`O_sdrc_rd_valid`, or `O_sdrc_wrd_ack`.
User RTL shall not wait for those signals when using the HS IP.

## 4. Command Encoding

`I_sdrc_cmd[2:0]` is encoded in descending command-pin order:

```text
I_sdrc_cmd = {O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n}
```

| Command | Encoding | Use |
| --- | ---: | --- |
| `NOP` | `3'b111` | no operation |
| `ACTIVE` | `3'b011` | open a bank/row before read or write |
| `READ` | `3'b101` | read the selected bank/column |
| `WRITE` | `3'b100` | write the selected bank/column |
| `BURST_TERMINATE` | `3'b110` | terminate burst |
| `PRECHARGE` | `3'b010` | precharge bank/all banks |
| `AUTO_REFRESH` | `3'b001` | perform one auto-refresh command |
| `LOAD_MODE` | `3'b000` | load SDRAM mode register |

The command pulse shall be exactly one `I_sdrc_clk` cycle.
The user logic shall hold address, mask, precharge control, transfer length,
and first write-data beat stable on the command cycle.

## 5. Read and Write Rules

Before every read or write, user RTL shall issue `ACTIVE` for the target
bank and row and wait for `O_sdrc_cmd_ack`.

After `ACTIVE` acknowledgement:

- issue `WRITE` for write transactions,
- issue `READ` for read transactions,
- use the same `I_sdrc_addr` bank and row,
- set the column field to the burst start column,
- set `I_sdrc_data_len = transfer_words - 1`,
- set `I_sdrc_precharge_ctrl = 1` for this migration.

The effective read/write transfer length is:

```text
transfer_words = I_sdrc_data_len + 1
```

The legal 8-bit length input range is `0..255`.
The corresponding transfer length range is `1..256`.

For writes, user RTL shall drive the first word on the `WRITE` command cycle.
It shall continue driving the following write words on consecutive
`I_sdrc_clk` cycles until the requested length has been supplied.

For reads in this repository, sample `O_sdrc_data` after:

```text
READ_DATA_LATENCY_CYCLES = SDRAM_CL + 2 = 5
```

Then sample each following burst word on consecutive `I_sdrc_clk` cycles.
This latency is a project integration constant and shall be validated in
vendor-IP simulation before relying on it in hardware.

## 6. Refresh Rules

The HS IP exposes auto-refresh as a user command.
The user logic is responsible for issuing refresh often enough.

For the current 48 MHz SDRAM clock, this repository shall issue one
`AUTO_REFRESH` command every `720` `I_sdrc_clk` cycles after
`O_sdrc_init_done` is high.

This is earlier than the nominal interval:

```text
64 ms / 4096 refreshes = 15.625 us
15.625 us * 48 MHz = 750 cycles
```

Refresh insertion rules:

- never issue refresh before `O_sdrc_init_done`,
- never issue refresh between `ACTIVE` and the paired `READ` or `WRITE`,
- if refresh becomes due during a transaction, defer it,
- service a deferred refresh before launching the next `ACTIVE`,
- expose refresh pending, active, and defer counters in the status map.

## 7. Clock and Constraint Rules

The current top-level design drives both `I_sdrc_clk` and `I_sdram_clk`
from the existing 48 MHz SDRAM clock.

The SDC shall keep the existing clocks:

- 27 MHz board input clock,
- 48 MHz SDRAM clock,
- 24 MHz system/UART clock.

For embedded SDRAM, do not add `.cst` constraints for the SDRAM-side
embedded memory signals.
The HS IP user guide states that embedded SDRAM applications shall keep the
top-level signal names consistent with the SDRAM-side IP signal names.

## 8. Verification Contract

Simulation shall verify the native HS command sequence directly.

Minimum command checks:

- no command is issued before `O_sdrc_init_done`,
- every read/write is preceded by `ACTIVE`,
- `I_sdrc_cmd_en` is one clock wide,
- refresh is not inserted between `ACTIVE` and `READ` or `WRITE`,
- read sample timing uses the configured latency,
- page-crossing bursts are rejected or split before issue.

Hardware bring-up shall first pass single-word full-range self-test.
After that, run host single-word read/write checks and retention checks.
Only after those pass shall burst mode be enabled for page-safe validation.
