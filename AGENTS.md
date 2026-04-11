#

## 0 Design Specification Writing Rule

When drafting design specifications, write at **Detail Level +1**.
This means increasing **information content** (not word count) so a reviewer can implement and verify the design without guessing.

#### Constraints
- Do **not** inflate text by rephrasing the same point. Add only **new, decision-relevant information** (conditions, states, rules, examples, numbers).
- Avoid ambiguous terms ("as needed", "preferably", "sufficient"). Use explicit, testable conditions.
- Add a line break for every 70-80 characters, or after a period.
- Use bullet lists when needed (enumeration, specification lineup, etc.). But do **not** overuse them.


## 1 Directory Layout & Roles
- `00_ip`      : Third-party/vendor IP sources (read-only). **Do not modify.**
- `01_src`    : User RTL sources (design).
- `02_tb`     : Common testbench utilities: packages, interfaces, BFMs, helpers, assertions, tasks/functions.
- `03_sim`    : Simulation projects. Each testbench has its own subfolder containing TB top, testcases, and sim scripts.
- `04_simlib` : Precompiled simulation libraries (Questa/ModelSim, Xilinx/Intel libs, etc.).


## 2 Source Code Categorization Rules
- RTL code **shall** be stored in `01_src/`.
- Testbench common code **shall** be stored in `02_tb/`.
- Testbench tops (wrappers) **shall** reside under `03_sim/<tb_name>/`.
- Testcase code **shall** be stored under `03_sim/<tb_name>/` alongside the testbench top.
- Testcase files **shall** contain a **single `initial` block** describing scenarios.
  - Helper tasks/functions **shall be excluded** from testcase files and placed in separate files under `02_tb/`.

**Recommended file naming:**
- TB top: `testbench.sv`
- Testcase: `testcase_<scenario>.svh`

**Compile order:**
1. Packages → 2. Interfaces/typedefs → 3. Common TB utils → 4. DUT RTL → 5. TB top → 6. Testcases


## 3 Commenting & Naming Rules

### Source file naming
- Add suffix `_pkg` for `package` type modules.
- Add suffix `_if` for `interface` type modules.
- Add protocol prefix: `uart_`, `wishbone_`, `axi4st_`, etc.
- Add suffix `_driver`/`_monitor`/`_receiver` for testbench protocol components.

### Module Ports
- All Upper case.

### Signal types
- All Lower case.

### Buffer Flip-flop
- Incoming signal buffer: `signal` → `signal_q` → `signal_qq`.

### State Machine
- Prefix: `st_` (e.g., `st_state`, `st_nextstate`).
- State names: all upper case (e.g., `IDLE`, `BOOT`, `END_SEQ`).

### FSM
- Always add a comment at the top of the FSM block explaining each state's purpose and
  describing the transition flow between states with a diagram.

### Others
- Header comment: purpose, behavior, usage (+ minimal example).
- Every major `always`/`function`/`task` block needs verbose description.
- FSM: document state purposes, actions, transition flow, **transition conditions**.


## 4 Coding Rules (SystemVerilog)

### 4.1 Always-block structure
- **Do not** implement functionality as a single monolithic block.
- **Decompose** into multiple small blocks, each with **single responsibility**.
- Keep sensitivity type correct (`always_ff` vs `always_comb`).
- Add brief comment at top describing purpose, behavior, and key invariants.
- When an `always_ff` block grows to hold multiple register categories
  (ex. state, counters, CDC synchronizers, debug/trace, handshake outputs),
  split it into separate `always_ff` blocks by responsibility.
- A register shall be assigned in exactly one `always_ff` block.
- Group registers together only when they share the same update event and the
  same verification intent.
- Prefer separate blocks for:
  - FSM/state-holding registers
  - Handshake/request-valid registers
  - Counters/statistics
  - CDC synchronizers
  - Debug/trace capture registers
- Also split blocks when:
  - Reset values or reset release conditions differ between register groups
  - Update enable conditions differ significantly between register groups
  - One-cycle pulse generation is mixed with sticky/state-holding registers
  - External interface boundary registers are mixed with internal control state
  - Nested conditional depth grows enough that side effects are hard to trace
  - The block requires long comments to explain independent behaviors

### 4.2 When to split into multiple files/modules
Split when:
- Distinct interface or protocol (AXI, SPI, I2C, UART, etc.)
- Independent FSM that can be verified on its own
- Algorithmic datapath (pipeline, CRC/ECC, filtering)
- Register/CSR handling grows large → dedicated `*_regs.sv`

**Size triggers (heuristics):**
- Module: ~300-500 lines → consider split
- File: ~800-1200 lines → prefer split
- Port list: ~40-60 signals → consider split (or group via `interface`/`struct`)

### 4.3 FSM coding rules

**4.3.1 State enum**
```systemverilog
typedef enum logic [2:0] {IDLE, START, DATA, STOP} state_t;
state_t st_state, st_nextstate;
```

**4.3.2 State register** - dedicated `always_ff` block, reset to default state.

**4.3.3 Next-state logic** - dedicated `always_comb` block with safe default:
```systemverilog
st_nextstate = st_state;  // hold unless condition met
case (st_state) ... endcase
```

**4.3.4 Separate FSM from datapath** - move counters, edge generators, output registers to separate blocks.

**4.3.5 Reset helper logic** - explicitly reset in default/idle state.

**4.3.6 Comment every FSM block** - include default state and transition conditions.


## 5. Logging Requirements for SystemVerilog Testbenches

### 5.1 Purpose

The testbench shall use structured logging with multiple verbosity levels so
that:

* normal regressions remain readable,
* failures can be debugged efficiently by increasing verbosity,
* log usage stays consistent across all testbench components.

The default behavior shall avoid excessive output while still preserving
enough information to localize failures.

### 5.2 Supported Log Levels

The testbench shall support:

* `LOG_ERROR`
* `LOG_WARN`
* `LOG_INFO`
* `LOG_DEBUG`
* `LOG_TRACE`

All components shall use these levels consistently.

### 5.3 Log Level Definitions

#### ERROR

Use for definite testcase failures or specification violations.

Typical cases:

* expected vs actual mismatch
* protocol violation
* invalid DUT response
* failing timeout
* scoreboard mismatch

#### WARN

Use for suspicious or degraded behavior that does not immediately fail the
testcase.

Typical cases:

* unusually slow response
* retry or recovery path taken
* fallback configuration used
* transient `X` / `Z` observed but recovered
* queue buildup or repeated backpressure
* rare but legal behavior worth reviewing

Rule:

* Use `WARN` for "not failed, but suspicious".

#### INFO

Use for normal high-level progress messages.

Typical cases:

* testcase start/end
* reset asserted/deasserted
* environment initialized
* sequence start/end
* transaction summary
* final pass/fail summary

Rule:

* Use `INFO` for "what is happening".

#### DEBUG

Use for detailed diagnostic information needed during failure analysis.

Typical cases:

* transaction field details
* internal state transitions
* expected value calculation details
* queue depth
* retry count, polling count, wait count
* local decision context in driver, monitor, or scoreboard

Rule:

* Use `DEBUG` for "why it happened".

#### TRACE

Use only for very high-frequency step-by-step tracing.

Typical cases:

* per-cycle signal logging
* per-beat bus activity
* loop iteration tracing
* task/function entry and exit
* repeated polling output

Rule:

* Use `TRACE` for "show every step".

### 5.4 Usage Rules

* `INFO` shall be the default regression level.
* `WARN` shall not be used for normal control flow.
* `DEBUG` shall not be used for per-cycle logging.
* `TRACE` shall normally be disabled in standard regression runs.
* The same kind of event shall use the same log level across all components.

### 5.5 Component Guidance

#### Driver

* `INFO`
  : transaction start/end summary
* `DEBUG`
  : request details, local decisions
* `TRACE`
  : handshake waiting, low-level bus activity
* `WARN`
  : retries, delayed acceptance, fallback behavior

#### Monitor

* `INFO`
  : captured transaction summary
* `DEBUG`
  : decoded fields and interpretation
* `TRACE`
  : per-beat / per-cycle observation
* `WARN`
  : suspicious but recoverable observations

#### Scoreboard / Checker

* `INFO`
  : compare summary and aggregate progress
* `DEBUG`
  : expected / actual details and compare context
* `ERROR`
  : mismatch or violation
* `WARN`
  : delayed compare, queue backlog,
  suspicious non-fatal condition

#### Testcase / Sequence Control

* `INFO`
  : testcase / phase / scenario milestones
* `DEBUG`
  : parameter choices and control decisions
* `WARN`
  : degraded but recoverable execution

### 5.6 Practical Decision Guide

* Definite failure            -> `ERROR`
* Suspicious but not failing  -> `WARN`
* Normal progress             -> `INFO`
* Diagnostic detail           -> `DEBUG`
* Per-step tracing            -> `TRACE`

---

## 6. RTL Simulation Policy

### 6.1 Purpose
RTL simulation shall be performed in two stages:
1. unit-level testing for each module,
2. integration-level testing for the top RTL.

The objective is to verify all functional behavior, including edge cases,
before proceeding to full-system integration.

### 6.2 Test Order Rule
- The agent shall first create and execute unit tests for each module.
- The agent shall not skip directly to integration testing.
- Integration testing shall begin only after all target unit tests are
  completed.

### 6.3 Unit Test Requirements
- A dedicated simulation folder shall be created under `03_sim/`
  for each module.
- Each unit test folder shall contain:
  - a testbench top,
  - one or more testcase files,
  - required simulation scripts.
- Unit tests shall be executed for every module.
- Unit tests shall cover:
  - all intended functional behavior,
  - boundary conditions,
  - abnormal and corner cases,
  - interface timing edge cases,
  - reset and initialization behavior.
- Unit testing shall pursue thorough verification rather than minimal
  testcase count.

### 6.4 Integration Test Requirements
- A dedicated integration test environment shall be created for the top RTL.
- The integration test shall include:
  - the top-level RTL,
  - a top-level testbench,
  - testcases that activate all subordinate units under the top RTL.
- Integration tests shall exercise all major system functions and
  inter-module interactions.
- Integration tests shall confirm that the full design behavior matches the
  expected top-level functionality.

### 6.5 Logging Requirements for Simulation
- All testbenches and testcases shall actively use `tb_log_pkg.sv`
  and/or `eth_log_pkg`, where applicable.
- Logging shall be used not only for failure reporting, but also for:
  - testcase progress visibility,
  - transaction tracing,
  - internal state observation,
  - efficient debug during failure analysis.
- Logging usage shall follow the logging policy defined in this document.

### 6.6 Simulation Folder Naming Rules
- The integration test folder shall be named:

  `01_[top_rtl_name]`

- Unit test folders shall be named:

  `[NN]_[module_name]`

  where:
  - `NN` is a two-digit decimal number,
  - unit test numbering shall start after `01`,
  - `01_...` shall be reserved exclusively for the integration test.

### 6.7 Examples
- Integration test:
  - `03_sim/01_top_system`
- Unit tests:
  - `03_sim/02_uart_rx`
  - `03_sim/03_uart_tx`
  - `03_sim/04_csr_regs`

### 6.8 Execution Rule
- Test creation shall prioritize thoroughness over minimality.
- Simulation plans shall explicitly identify and verify edge cases.
- Each unit test shall be completed before relying on the same behavior only
  from integration-level coverage.

---


## 7 Simulation

### Linux (Questa) - highest priority
```bash
cd /home/kenji/git/tangmega60k_dev
source /home/kenji/tools/questa_fse/use_questa_fse.sh
cd 03_sim
python3 sim_questa_linux.py 01_uart/testbench.sv recompile
```
- Use `/` in TB path arguments.
- Log: `03_sim/sim.log`, `03_sim/compile.log`

### Windows (ModelSim)
```bash
cd 03_sim
python sim.py 01_uart\testbench.sv recompile
```
Options: `recompile`, `openwave`, `log LEVEL`, `vsimpath PATH`, `+PLUSARGS`


## 7 Synthesis with GOWIN EDA

### 7.1 gowin_syn.sh wrapper (recommended) (Linux only)
```bash
cd /home/kenji/git/tangmega60k_dev
./11_app/gowin_syn.sh syn       # synthesis only
./11_app/gowin_syn.sh pnr       # place & route (requires prior syn)
./11_app/gowin_syn.sh all       # synthesis + PnR
./11_app/gowin_syn.sh -v all     # with verbose output
```
- Success: `GowinSynthesis finish`, `Placement and routing completed`

### 7.2 Direct gw_sh invocation (manual only) (Linux only)
```bash
export GOWIN_EDA_HOME=/home/kenji/tools/gowin/eda-current/IDE
export QT_QPA_PLATFORM=offscreen
export LD_PRELOAD=/lib/x86_64-linux-gnu/libfreetype.so.6
${GOWIN_EDA_HOME}/bin/gw_sh /tmp/gw_run_syn_only.tcl
```

### 7.3 Common issues
- **Linux License**: check `IDE/bin/gwlicense.ini`, verify network to
  `gowinlic.sipeed.com:10559`
- **Linux Qt errors**: use `QT_QPA_PLATFORM=offscreen`
- **Linux font symbols**: use
  `LD_PRELOAD=/lib/x86_64-linux-gnu/libfreetype.so.6`
- **Windows path separator**: both `/` and `\` are accepted by Gowin Tcl,
  but use `/` in Tcl scripts to avoid backslash escape mistakes.
- **Windows gw_sh help**: `gw_sh.exe -h` opens the interactive Tcl console.
  For repeatable CLI operation, always execute a Tcl script file.
- **Windows PnR prerequisite**: `run pnr` requires
  `impl\gwsynthesis\<project>.vg`.
  On a clean project, run `run syn` first or use `run all`.

### 7.4 Synthesis (Windows)
Use the project file as the single entry point.

- Gowin EDA executable:
  `C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe`
- Project file:
  `C:\Electronics\GitHubProjects\tangnano20k_dev\05_impl\tangnano20k.gprj`

#### Synthesis only: `run syn`
```powershell
$tcl = "C:\Electronics\GitHubProjects\tangnano20k_dev\05_impl\run_syn.tcl"
Set-Content -Path $tcl -Value @(
  "open_project C:/Electronics/GitHubProjects/tangnano20k_dev/05_impl/tangnano20k.gprj"
  "run syn"
  "exit"
)
& "C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" `
  $tcl
```
- Success message: `GowinSynthesis finish`
- Main outputs:
  `05_impl\impl\gwsynthesis\tangnano20k.vg`
  `05_impl\impl\gwsynthesis\tangnano20k_syn.rpt.html`
  `05_impl\impl\gwsynthesis\tangnano20k.log`

### 7.5 Plan & Route (Windows)
Use `run pnr` only after synthesis output already exists.
For a clean rebuild from synthesis through bitstream generation,
prefer `run all`.

#### Place & Route only: `run pnr`
```powershell
$tcl = "C:\Electronics\GitHubProjects\tangnano20k_dev\05_impl\run_pnr.tcl"
Set-Content -Path $tcl -Value @(
  "open_project C:/Electronics/GitHubProjects/tangnano20k_dev/05_impl/tangnano20k.gprj"
  "run pnr"
  "exit"
)
& "C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" `
  $tcl
```
- Prerequisite:
  `05_impl\impl\gwsynthesis\tangnano20k.vg`
- Success messages:
  `Placement and routing completed`
  `Bitstream generation completed`
- Main outputs:
  `05_impl\impl\pnr\tangnano20k.fs`
  `05_impl\impl\pnr\tangnano20k.rpt.txt`
  `05_impl\impl\pnr\tangnano20k.log`

#### Full flow: `run all` (recommended for first run)
```powershell
$tcl = "C:\Electronics\GitHubProjects\tangnano20k_dev\05_impl\run_all.tcl"
Set-Content -Path $tcl -Value @(
  "open_project C:/Electronics/GitHubProjects/tangnano20k_dev/05_impl/tangnano20k.gprj"
  "run all"
  "exit"
)
& "C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" `
  $tcl
```
- `run all` executes synthesis and then Place & Route in one invocation.
- Use this flow when `impl\gwsynthesis` does not exist yet or when a full
  bitstream refresh is required.
- Verified on this repository on `2026-04-04`:
  `run all` completed successfully and generated
  `05_impl\impl\pnr\tangnano20k.fs`.


## 8 Programming

### 8.1 Start sudo session (Linux only)
```bash
cd /home/kenji/git/tangmega60k_dev
./11_app/sudo_session/sudo_session_start.sh
```

### 8.2 Program FPGA (SRAM, temporary)

#### Linux
```bash
cd /home/kenji/git/tangmega60k_dev
./11_app/sudo_session/sudo_run.sh \
  /home/kenji/tools/gowin/programmer-current/bin/programmer_cli \
  --device GW5AT-60B --run 2 \
  --fsFile /home/kenji/git/tangmega60k_dev/impl/pnr/tangmega60k_top.fs \
  --cable-index 1 --channel 0
```
- Success: `Programming...: [#########################] 100%`, `Finished.`, `Status Code is: 0x70026020`

#### Windows (Powershell)
- Optional device scan before programming:
```shell
  C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe `
  --device GW2AR-18C `
  --scan
```
- Expected scan result:
  `1 device(s) found!`
  `Name: GW2A-18C GW2AR-18C GW2ANR-18C`
```shell
  C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe `
  --device GW2AR-18C `
  --run 2 `
  --fsFile C:\Electronics\GitHubProjects\tangnano20k_dev\05_impl\impl\pnr\tangnano20k.fs
```
- Success:
  `Programming...: [#########################] 100%`
  `User Code is: 0x0000C102`
  `Status Code is: 0x00006020`
  `Finished.`

### 8.3 Stop session (Linux only)
```bash
cd /home/kenji/git/tangmega60k_dev
./11_app/sudo_session/sudo_session_stop.sh
```

### 8.4 Notes
- `sudo_run.sh` uses `sudo -n` (non-interactive).
- If session missing/expired: exit code 90, re-run `sudo_session_start.sh`.
