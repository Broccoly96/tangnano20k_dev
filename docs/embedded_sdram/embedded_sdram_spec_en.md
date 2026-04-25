# Gowin SDRAM Controller IP Design Specification (for AI Agents / RTL Implementation)

## 1. Purpose

This document defines the **RTL design contract for correctly using the Gowin SDRAM Controller IP from user logic**.
The target is not reimplementation of the Gowin-generated SDRAM Controller IP itself, but rather the implementation of:

- wrapper RTL around the IP
- request issue logic
- data path logic
- verification testbenches and assertions

This specification focuses especially on:

- understanding the controller behavior from the Working Flow descriptions
- extracting the **actual request/response contract** from the User Interface Timing diagrams
- understanding the internal SDRAM command meaning from the SDRAM Interface Timing diagrams
- eliminating ambiguity for AI agents that generate RTL
- distinguishing between direct datasheet statements and **conservative integration rules** for robust RTL design

---

## 2. Scope

### 2.1 In Scope
- Gowin-generated SDRAM Controller IP
- External SDRAM Controller
- Embedded SDRAM Controller
- user-side RTL connected to the controller
- verification testbenches, assertions, and wrappers

### 2.2 Out of Scope
- redesign of the SDRAM Controller IP internals
- a complete SDRAM tutorial
- detailed board-level SI/PI design
- a full .cst / SDC constraint template

---

## 3. Reference

- Gowin SDRAM Controller IP User Guide
  - Signal Definition
  - GUI Parameters
  - Principle
  - Working Flow
  - Application
  - Interface Timing

---

## 4. Assumptions and Basic Policy

### 4.1 Role of the IP
This IP sits between user logic and SDRAM and internally handles:

- initialization
- read/write command sequencing
- auto-refresh
- self-refresh
- power-down
- precharge
- SDRAM command control

Therefore, user RTL does **not** directly generate SDRAM timing such as RCD/RP/RFC/CL.
Instead, the user RTL must follow the **user interface contract** of this IP.

### 4.2 Basic Policy for User Logic
User logic shall always obey the following rules:

1. Do not issue read/write requests until `O_sdrc_init_done == 1`
2. Issue a new request only when `O_sdrc_busy_n == 1`
3. Drive `I_sdrc_wr_n` / `I_sdrc_rd_n` as **active-low one-cycle pulses**
4. For each request, the effective transfer length is **`I_sdrc_data_len + 1` beats**
5. Treat read data as valid **only when `O_sdrc_rd_valid == 1`**
6. For write operations, assume the write data stream must be supplied **continuously for the requested number of beats**
7. Use self-refresh / power-down only during idle state as a conservative integration rule

---

## 5. System Architecture

## 5.1 Recommended Block Structure

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

### 5.2 Clock Roles
- `I_sdrc_clk` : user interface / controller working clock
- `I_sdram_clk` : SDRAM-side working clock

### 5.3 Important Clock Notes
- User interface I/O is aligned to the **rising edge of `I_sdrc_clk`**
- SDRAM-side output timing is also aligned to the controller working clock
- The phase of `I_sdram_clk` can be adjusted to satisfy read/write setup and hold timing
- For the **GW1NR-4 embedded 32-bit controller only**, `I_sdrc_clk` must be **half the frequency** of `I_sdram_clk`
- In other cases, `I_sdrc_clk` and `I_sdram_clk` are typically operated at the same frequency

### 5.4 Implementation Recommendations
- Keep all user-side control logic in the `I_sdrc_clk` domain
- If requests come from another clock domain, insert a CDC bridge or FIFO before the wrapper
- Place a thin wrapper directly in front of the SDRAM Controller IP and expose a ready/valid style interface to upper logic

### 5.5 Project Note for This Repository
- In this repository, the active embedded SDRAM integration uses the
  same `96MHz` clock for both `I_sdrc_clk` and `I_sdram_clk`.
- The UART log host path remains in a slower system clock domain and
  crosses into the SDRAM host interface through explicit CDC bridges.
- This project choice is based on observed behavior of the generated
  embedded SDRAM IP in simulation and hardware bring-up.
- Do not assume that a generated embedded SDRAM instance safely supports
  arbitrary `I_sdrc_clk` / `I_sdram_clk` frequency ratios unless that
  exact configuration has been verified for the selected IP variant.

---

## 6. Interface Definition

## 6.1 SDRAM-Side Signals

| Signal Name     | Dir | Description           |
| --------------- | --: | --------------------- |
| `O_sdram_clk`   |   O | SDRAM clock           |
| `O_sdram_cke`   |   O | Clock enable          |
| `O_sdram_cs_n`  |   O | Chip select           |
| `O_sdram_cas_n` |   O | Column address strobe |
| `O_sdram_ras_n` |   O | Row address strobe    |
| `O_sdram_wen_n` |   O | Write enable          |
| `O_sdram_dqm`   |   O | Data mask             |
| `O_sdram_addr`  |   O | Address               |
| `O_sdram_ba`    |   O | Bank address          |
| `IO_sdram_dq`   | I/O | Data bus              |

> Note: In the user guide, I/O directions are described with the SDRAM as the reference point.

## 6.2 User-Side Signals

| Signal Name          | Dir | Description              | RTL Interpretation                                                                                              |
| -------------------- | --: | ------------------------ | --------------------------------------------------------------------------------------------------------------- |
| `I_sdrc_rst_n`       |   I | active-low reset         | Follow generated IP behavior for sync/async details; wrapper shall wait for init completion after reset release |
| `I_sdrc_clk`         |   I | controller working clock | User-interface clock                                                                                            |
| `I_sdram_clk`        |   I | SDRAM working clock      | SDRAM-side clock                                                                                                |
| `I_sdrc_selfrefresh` |   I | self-refresh enable      | Low-power mode request; conservatively change only during idle                                                  |
| `I_sdrc_power_down`  |   I | power-down enable        | Low-power mode request; conservatively change only during idle                                                  |
| `I_sdrc_wr_n`        |   I | write request            | active-low, one-cycle pulse                                                                                     |
| `I_sdrc_rd_n`        |   I | read request             | active-low, one-cycle pulse                                                                                     |
| `I_sdrc_addr`        |   I | address                  | request address                                                                                                 |
| `I_sdrc_dqm`         |   I | data mask                | mask control                                                                                                    |
| `I_sdrc_data_len`    |   I | transfer length          | **effective length = `I_sdrc_data_len + 1`**                                                                    |
| `I_sdrc_data`        |   I | write data               | write data stream                                                                                               |
| `O_sdrc_data`        |   O | read data                | valid only when `O_sdrc_rd_valid` is asserted                                                                   |
| `O_sdrc_init_done`   |   O | init complete            | 1: done                                                                                                         |
| `O_sdrc_busy_n`      |   O | idle/busy indication     | 1: idle, 0: busy                                                                                                |
| `O_sdrc_rd_valid`    |   O | read valid               | aligned with valid read data                                                                                    |
| `O_sdrc_wrd_ack`     |   O | request acknowledge      | response to read/write request; 2-cycle delay, 1-cycle width                                                    |

---

## 7. External SDRAM GUI Parameters and Design Impact

## 7.1 Geometry Parameters
| Parameter    | Meaning              |
| ------------ | -------------------- |
| Data Width   | SDRAM data bus width |
| Bank Width   | BANK address width   |
| Row Width    | row address width    |
| Column Width | column address width |

### Design Rules
- The meaning of `I_sdrc_addr` depends on the selected row/column/bank geometry
- The upper-level address mapping specification must define the conversion from **linear address → bank/row/column**
- The datasheet states that supported transfer length is within **1 to Page**
- Therefore, upper logic should **avoid issuing a burst that crosses a page boundary**

## 7.2 Timing Parameters
| Parameter      | Meaning                                            |
| -------------- | -------------------------------------------------- |
| Clock Period   | controller operating clock period [ns]             |
| Refresh Period | full SDRAM refresh period [ns]                     |
| Refresh Times  | number of refresh operations                       |
| CL Period      | CAS latency [controller clock cycles]              |
| tRP Period     | PRECHARGE period [cycles]                          |
| tRFC Period    | AUTO REFRESH period [cycles]                       |
| tMRD Period    | LOAD MODE REGISTER to ACTIVE/REFRESH wait [cycles] |
| tRCD Period    | ACTIVE to READ/WRITE delay [cycles]                |
| tWR Period     | WRITE recovery [cycles]                            |

### Implementation Rules
- These parameters must be derived from the target SDRAM datasheet
- CL / tRP / tRFC / tMRD / tRCD / tWR are configured in **controller clock cycles**
- `Refresh Period / Refresh Times` effectively determines the average refresh interval
  Example: default `64,000,000ns / 4096 = 15.625us`

> Note: The refresh interval expression above is a natural interpretation of the user guide. The final values must be verified against the target SDRAM datasheet.

---

## 8. SDRAM Command Definition (for Understanding IP Internal Behavior)

| Command                     | CS  | RAS | CAS | WE  |
| --------------------------- | --- | --- | --- | --- |
| Command Inhibit             | H   | X   | X   | X   |
| NOP                         | L   | H   | H   | H   |
| Active                      | L   | L   | H   | H   |
| Read                        | L   | H   | L   | H   |
| Write                       | L   | H   | L   | L   |
| Burst Terminate             | L   | H   | H   | L   |
| Pre-charge                  | L   | L   | H   | L   |
| Auto Refresh / Self Refresh | L   | L   | L   | H   |
| Configuration Mode Register | L   | L   | L   | L   |

### Notes
- `X`: don't care
- `L`: low
- `H`: high

### Meaning for RTL Integration
User logic does not directly drive these commands.
However, understanding them is necessary to interpret the timing diagrams correctly.

---

## 9. Behavioral Essentials

## 9.1 Initialization Essence
SDRAM cannot be used immediately after power-up. Internally, the IP performs:

1. wait 100us after power-up
2. Precharge
3. Auto-refresh
4. Auto-refresh
5. Load Mode Register
6. wait `tMRD`
7. enter normal operation

### What User RTL Must Do
- Never access the controller until `O_sdrc_init_done == 1`
- Do not assume access becomes available after a fixed number of cycles
- Use `init_done` as the only valid start condition

## 9.2 Read Essence
Internally, a read is approximately:

1. `ACTIVE` target bank/row
2. wait `tRCD`
3. issue `READ` to target column
4. read data appears after `CL`
5. precharge if needed
6. next access after `tRP`

## 9.3 Write Essence
Internally, a write is approximately:

1. `ACTIVE` target bank/row
2. wait `tRCD`
3. issue `WRITE` to target column
4. transfer write data to SDRAM
5. wait `tWR`
6. `PRECHARGE`
7. next access after `tRP`

## 9.4 Auto-refresh Essence
- Refresh is required periodically
- A precharge-like step may appear before refresh
- During refresh, the controller does not accept a new user request

### Important Interpretation
There is no dedicated auto-refresh request input in the user interface.
Therefore, auto-refresh is treated as an **internal autonomous controller event**.

## 9.5 Self-refresh / Power-down Essence
- `I_sdrc_selfrefresh` and `I_sdrc_power_down` are low-power control inputs
- The user guide contains some wording inconsistencies and mixed terminology around auto-refresh and self-refresh
- In real integration, these should be treated as **externally requested operating modes**

---

## 10. Working Flow Interpretation

## 10.1 Read/Write Working Flow

The user-guide flow can be summarized from the user RTL point of view as:

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

### Impact on User RTL
- A new request is not allowed until the controller is idle (`O_sdrc_busy_n = 1`)
- Refresh may intervene internally, so **request acceptance latency is not guaranteed to be constant**
- However, the timing diagrams show a consistent visible pattern for `ack` and `busy`

## 10.2 Initialization Flow

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

### Implementation Meaning
- `O_sdrc_init_done` shall only assert after the full sequence above is complete
- Upper-level logic does not need visibility into internal states
- Upper-level logic only needs to wait for `init_done`

## 10.3 Auto-refresh Flow

The wording in the user guide is somewhat ambiguous, but for integration use the following model:

```text
IDLE
  -> internal refresh trigger
  -> PRECHARGE (if needed)
  -> AUTO REFRESH
  -> wait tRFC
  -> IDLE
```

### User RTL Rules
- Do not try to predict refresh start
- Issue requests only when `busy_n == 1`
- Dimension upstream FIFOs assuming request issue opportunities can be delayed by refresh

## 10.4 Power-down Flow

```text
IDLE
  -> if power_down request asserted
  -> enter power-down
  -> wait exit request
  -> exit power-down
  -> IDLE
```

### Recommended Usage
- Assert power-down only in idle state
- Block read/write while in power-down
- After exit, check busy / init_done / idle again before resuming access

---

## 11. User Interface Timing Specification (Most Important Section)

This section is the **primary integration contract** for AI-generated wrapper RTL.

## 11.1 Common Rules
- All user interface I/O is sampled/driven on the **rising edge of `I_sdrc_clk`**
- `I_sdrc_wr_n` and `I_sdrc_rd_n` are **active-low one-cycle pulses**
- `I_sdrc_data_len` is **length minus 1**
  - `0` means 1 beat
  - `19` means 20 beats
- `O_sdrc_wrd_ack` is the **request acceptance response**
  - asserted **2 cycles after request**
  - pulse width is **1 cycle**
- `O_sdrc_busy_n` indicates controller idle/busy
  - `1`: idle
  - `0`: busy
- In the timing diagrams, `busy_n` transitions to busy **3 cycles after the request**

---

## 11.2 Read Request Protocol

### 11.2.1 Request Issue Conditions
A read request may be issued only when all of the following are true:

- `O_sdrc_init_done == 1`
- `O_sdrc_busy_n == 1`
- self-refresh / power-down is not being requested

### 11.2.2 Request Issue Method
- Drive `I_sdrc_rd_n <= 0` for **exactly one cycle**
- In the same cycle, present valid values for:
  - `I_sdrc_addr`
  - `I_sdrc_dqm`
  - `I_sdrc_data_len`

### 11.2.3 Read Data Reception
- `O_sdrc_wrd_ack` is asserted **2 cycles after the request** for one cycle
- `O_sdrc_busy_n` goes Low **3 cycles after the request**
- Sample `O_sdrc_data` only on cycles where `O_sdrc_rd_valid == 1`
- The total number of valid beats to capture is **`I_sdrc_data_len + 1`**

### 11.2.4 Conservative Read Integration Rule
- `I_sdrc_addr`, `I_sdrc_dqm`, and `I_sdrc_data_len` shall be stable at least in the request cycle
- To match the waveform conservatively, the wrapper should keep them stable **until `ack` is observed**
- `O_sdrc_data` shall be ignored whenever `rd_valid == 0`

### 11.2.5 Read Beat Counter
```text
expected_beats = I_sdrc_data_len + 1
count rd_valid pulses
read complete when count == expected_beats
```

---

## 11.3 Write Request Protocol

### 11.3.1 Request Issue Conditions
A write request may be issued only when all of the following are true:

- `O_sdrc_init_done == 1`
- `O_sdrc_busy_n == 1`
- self-refresh / power-down is not being requested

### 11.3.2 Request Issue Method
- Drive `I_sdrc_wr_n <= 0` for **exactly one cycle**
- In the same cycle, present valid values for:
  - `I_sdrc_addr`
  - `I_sdrc_dqm`
  - `I_sdrc_data_len`

### 11.3.3 Write Data Supply
From the write timing diagram, `I_sdrc_data` is shown as being supplied immediately after request start.
Therefore, wrapper RTL shall be designed so that **write data can be driven continuously starting from the request cycle**.

### 11.3.4 Conservative Write Integration Rule
- `I_sdrc_data` shall be driven as a **continuous stream starting in the request cycle**
- Number of beats is **`I_sdrc_data_len + 1`**
- No bubble cycles shall be inserted
- `O_sdrc_wrd_ack` appears **2 cycles after the request**
- `O_sdrc_busy_n` goes busy **3 cycles after the request**
- No new request is allowed until `busy_n` returns to idle

### 11.3.5 Recommended Data Supply Method
- If upper logic is ready/valid based, place a **write FIFO** in front of the IP
- Only issue the request when the FIFO already contains the full required number of beats
- Avoid any possibility of write data starvation in the middle of a burst

---

## 12. SDRAM Interface Timing Interpretation

## 12.1 Initialization Timing
The SDRAM initialization waveform shows:

1. wait **at least 100us** after power-up
2. issue `PRECHARGE`
   - during precharge, `addr[10]` selects all-bank or single-bank behavior
3. issue `AUTO REFRESH`
4. issue `AUTO REFRESH`
5. issue `LOAD MODE REGISTER`
   - mode code is placed on the address lines
6. wait `tMRD`
7. `ACTIVE` becomes possible afterward

### Design Meaning
- This flow is handled **inside the IP**
- User RTL only waits for `init_done`
- The mode register code depends on IP configuration and is normally not controlled from the user interface

---

## 12.2 SDRAM Read Timing
The read waveform is approximately:

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

### Visible Meaning of Row / Column / Bank
- During `ACTIVE`
  - `addr` = ROW
  - `ba`   = Bank Address
- During `READ`
  - `addr` = Column
  - `ba`   = Bank Address

### Design Meaning
- Row open/close handling is internal to the IP
- User logic only provides a linear address
- Bursts that cross a page boundary should be avoided

---

## 12.3 SDRAM Write Timing
The write waveform is approximately:

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

### Design Meaning
- Because `tWR` is required after a write, the controller cannot immediately proceed to the next row action
- Upper-level logic should trust `busy_n` instead of modeling SDRAM internals itself

---

## 12.4 SDRAM Auto-refresh Timing
The refresh waveform is approximately:

```text
PRECHARGE
  -> wait tRP
AUTO REFRESH
  -> wait tRFC
next ACTIVE
```

### Design Meaning
- Memory access is temporarily stalled around refresh
- If the upper-level system has latency requirements, it must budget for refresh-induced delay
- Use a request queue/FIFO if deterministic upstream behavior is required

---

## 13. RTL Implementation Contract for AI Agents

## 13.1 Responsibilities Allowed for AI-Generated RTL
An AI agent may implement:

- an IP wrapper module
- ready/valid adaptation for upper logic
- request FIFO / write data FIFO / read data FIFO
- transfer length counters
- monitoring of busy/init_done
- self-refresh / power-down entry/exit control
- testbenches / assertions / coverage

## 13.2 Responsibilities Not Allowed
An AI agent shall not reimplement the following inside user wrapper RTL:

- SDRAM command sequencing
- detailed SDRAM row state optimization
- refresh timing engine
- direct management of tRCD / CL / tRP / tRFC / tWR
- direct mode-register programming logic

---

## 14. Recommended Wrapper Interface

A ready/valid style upper interface is recommended, for example:

```text
req_valid
req_ready
req_write        // 1: write, 0: read
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

### 14.1 Recommended `req_ready` Condition
```text
req_ready = init_done
         && busy_n
         && !selfrefresh_mode
         && !powerdown_mode
         && (for write: enough data already available in FIFO)
```

### 14.2 Write Request Acceptance
When request handshake completes:
- pulse `I_sdrc_wr_n` Low for one cycle
- present `I_sdrc_addr`, `I_sdrc_dqm`, `I_sdrc_data_len`
- immediately start streaming `len+1` beats from the write FIFO

### 14.3 Read Request Acceptance
When request handshake completes:
- pulse `I_sdrc_rd_n` Low for one cycle
- present `I_sdrc_addr`, `I_sdrc_dqm`, `I_sdrc_data_len`
- capture `O_sdrc_data` into a read FIFO whenever `O_sdrc_rd_valid` is asserted

---

## 15. Recommended FSM

## 15.1 Common Wrapper FSM

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

## 16. RTL Rules (Mandatory)

## 16.1 Request Generation
- Never drive `I_sdrc_wr_n` and `I_sdrc_rd_n` Low in the same cycle
- Pulse width shall always be **exactly one cycle**
- No new request is allowed while `busy_n = 0`

## 16.2 Length Handling
- `I_sdrc_data_len` is length minus 1
- Internal counters shall always compute:
  ```text
  total_beats = unsigned(I_sdrc_data_len) + 1
  ```

## 16.3 Read Data Capture
- `O_sdrc_data` shall be sampled only when `O_sdrc_rd_valid == 1`
- Use `rd_valid` pulses directly for beat counting

## 16.4 Write Data Supply
- At the time the request is accepted, the system must already be able to supply all beats
- No bubbles are allowed on `I_sdrc_data`

## 16.5 Low-Power Control
- Change `selfrefresh` / `power_down` only during idle
- Deassert `req_ready` while in low-power mode

---

## 17. Recommended Assertions

## 17.1 Basic Assertions
```systemverilog
assert property (@(posedge I_sdrc_clk) !(~I_sdrc_wr_n && ~I_sdrc_rd_n));
assert property (@(posedge I_sdrc_clk) (~I_sdrc_wr_n) |=> I_sdrc_wr_n);
assert property (@(posedge I_sdrc_clk) (~I_sdrc_rd_n) |=> I_sdrc_rd_n);
```

## 17.2 Access Conditions
```systemverilog
assert property (@(posedge I_sdrc_clk) (~I_sdrc_wr_n || ~I_sdrc_rd_n) |-> O_sdrc_init_done);
assert property (@(posedge I_sdrc_clk) (~I_sdrc_wr_n || ~I_sdrc_rd_n) |-> O_sdrc_busy_n);
```

## 17.3 Read Beat Count
- For each read request, check that exactly `len+1` `rd_valid` beats are observed

## 17.4 Write Beat Count
- For each write request, check that exactly `len+1` beats were supplied on `I_sdrc_data`

---

## 18. Testbench Considerations

## 18.1 Minimum Test Items
1. do not access before `init_done`
2. 1-beat read
3. 1-beat write
4. multi-beat read
5. multi-beat write
6. verify `data_len=0` means 1 beat
7. verify `data_len=19` means 20 beats
8. suppress double issue while busy
9. verify no data corruption when refresh occurs between requests
10. self-refresh entry/exit
11. power-down entry/exit

## 18.2 Waveform Checkpoints
- request to `wrd_ack` = 2 cycles
- request to busy assertion = 3 cycles
- for read, `rd_valid` aligns with `O_sdrc_data`
- effective read/write length = `len+1`

---

## 19. Ambiguities and Adopted Policy

## 19.1 Auto-refresh Flow Terminology
The user guide contains wording that appears to mix auto-refresh and self-refresh in some places.
This specification adopts the following interpretation:

- **auto-refresh**: internal autonomous controller operation
- **self-refresh**: externally requested mode via `I_sdrc_selfrefresh`

## 19.2 Meaning of `O_sdrc_wrd_ack`
The name implies a shared read/write acknowledgment.
This specification treats it as **request accepted indication**.

## 19.3 Input Hold Duration
The datasheet does not explicitly define a strict hold duration for addr / dqm / len in text.
This specification adopts the conservative rule below:

- valid in the request pulse cycle
- **held at least until `ack` is returned**
- for implementation simplicity, holding until busy assertion is also acceptable

## 19.4 Write Data Start Timing
In the waveform, write data appears immediately after request start.
This specification therefore adopts the conservative rule:

- **start continuous write-data driving from the request cycle**

---

## 20. Implementation Checklist

- [ ] added wait for `init_done`
- [ ] issue requests only when `busy_n` is high
- [ ] `wr_n` / `rd_n` are one-cycle active-low pulses
- [ ] never issue `wr_n` and `rd_n` together
- [ ] handled `data_len` as length-1
- [ ] captured read data only on `rd_valid`
- [ ] ensured continuous write-beat supply
- [ ] blocked requests during self-refresh / power-down
- [ ] preserved required port naming for embedded version
- [ ] checked clock ratio for GW1NR-4 embedded 32-bit controller
- [ ] defined an `I_sdram_clk` phase adjustment policy
- [ ] considered IOLOGIC DFF constraints for the external version if needed

---

## 21. Additional Implementation Notes

### 21.1 Embedded SDRAM Controller
- SDRAM-side signals that appear after generation should be routed directly to the **top level**
- The signal names should remain **identical to the generated IP port names**
- This helps Gowin Software perform place-and-route correctly

### 21.2 External SDRAM Controller
- Constraining SDRAM-side I/O DFFs to IOLOGIC DFF may improve I/O transmission performance
- Timing parameters must always be reconfigured according to the target SDRAM part number

---

## 22. Summary

The five essential integration rules for this IP are:

1. **Do nothing until `init_done` is asserted**
2. **Issue requests only when `busy_n` is high**
3. **Generate read/write requests as active-low one-cycle pulses**
4. **The effective transfer length is `data_len + 1`**
5. **Capture reads with `rd_valid`, and provide writes as a continuous stream**

If these five rules are embedded into the wrapper RTL as a fixed protocol contract, upper-level logic can use the controller without modeling detailed SDRAM timing directly.

---

## 23. AI-Agent Implementation Prompt Template

The following can be used directly as an implementation prompt:

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
