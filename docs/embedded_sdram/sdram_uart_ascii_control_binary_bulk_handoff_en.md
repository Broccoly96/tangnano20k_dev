# Handoff Instructions for the Next AI Agent

## 1. Mission

Implement the SDRAM host UART protocol redesign described in:

- `docs/embedded_sdram/sdram_uart_ascii_control_binary_bulk_spec_en.md`

The redesign shall split the host protocol into:

- printable ASCII control for single access
- binary bulk transfer for SDRAM map and file transfer


## 2. Why This Work Is Needed

The current host path mixes raw binary command bytes with `uart_log_cli`
control bytes.
That causes collisions with bytes such as:

- `0x04`
- `0x06`
- `0x12`
- `0x14`
- `0x3F`

The collision was reproduced on hardware.

Observed behavior:

- safe addresses such as `0x100308` work
- low addresses and data containing control-like bytes may trigger
  `RESET_ACK` or other unexpected system-side behavior

Simulation already shows that an escape-based workaround can function,
but the required protocol should move to the new split architecture
instead of extending the workaround further.


## 3. What To Implement

### 3.1 FPGA RTL

Refactor the SDRAM host side around these modules.

- ASCII command parser for `R`, `W`, `BR`, `BW`
- bulk binary RX engine
- bulk binary TX engine
- clean arbitration layer to the SDRAM access engine

Do not keep all new logic inside one oversized `always_ff`.

### 3.2 Host Tools

Update:

- `11_app/uart_log_tool/debug_log_tool/uart_log_tui.py`
- `11_app/debug_log_cli/sdram_hostif_tool.py`

Required behavior:

- single read/write use ASCII
- map refresh uses bulk read
- file write uses bulk write
- file read-save uses bulk read

### 3.3 Documentation

Update manuals after implementation.

At minimum:

- SDRAM TUI manual
- any host protocol notes that mention the old raw binary single-access
  format


## 4. What To Keep

Do not change these baseline behaviors unless necessary.

- UART log framing from DUT to host
- `uart_log_cli` event framing
- existing `src_id = 0x03` host event source
- SDRAM data width of 32-bit words
- SDRAM address semantics as 21-bit word addresses


## 5. Suggested File Ownership

Recommended primary write targets:

- `01_src/embedded_sdram/sdram_uart_bridge_ctrl.sv`
- new helper modules under `01_src/embedded_sdram/`
- `11_app/uart_log_tool/debug_log_tool/uart_log_tui.py`
- `11_app/debug_log_cli/sdram_hostif_tool.py`
- new or updated TB under `03_sim/`

Do not modify vendor IP under `00_ip/`.


## 6. Required Verification

### 6.1 Simulation

You must add or update simulation so the following pass.

1. ASCII single read
2. ASCII single write
3. ASCII command syntax error
4. bulk write of multiple blocks
5. bulk read of multiple blocks
6. bulk read/write with payload bytes containing legacy control values
7. clean return from bulk mode to ASCII idle mode

### 6.2 Hardware

After simulation, run:

- synthesis
- PnR
- timing review
- FPGA programming
- TCP host validation against the actual board

Hardware checks shall include:

1. single write/read on a safe address
2. single write/read on an address or data pattern containing `0x12`
3. bulk write/read round-trip of a binary file
4. SDRAM map refresh from the TUI without timeout


## 7. Current Known Status

These facts are already confirmed.

- The existing TUI source-switch timeout bug was addressed
- A 100MHz SDRAM-side + 24MHz `uart_log_cli` CDC bridge build exists
- Safe-address host access is working on hardware
- Escape-assisted collision handling works in simulation
- Current 100MHz build still reports setup timing violations

The next implementation should not rely on "safe address only" behavior.


## 8. Design Recommendation

Implement the new protocol in phases.

### Phase 1

- ASCII `R`
- ASCII `W`
- keep current event response IDs

### Phase 2

- ASCII `BR`
- ASCII `BW`
- binary bulk block framing

### Phase 3

- migrate TUI map and file operations to bulk mode
- remove legacy raw binary single-access injection


## 9. Important Caution

Do not assume the previous "raw binary command packet" format is safe to
keep for single access.
The hardware issue is real, and the redesign is intended to eliminate that
class of bug, not merely patch one address case.


## 10. Definition of Done

This task is complete only when all conditions below are true.

1. English spec is implemented faithfully
2. simulation passes for ASCII single access and binary bulk transfer
3. TUI single read/write works
4. TUI map refresh works without timeout
5. file write/read works through the new bulk path
6. programmed hardware passes the same smoke tests
7. updated docs are committed with the code changes
