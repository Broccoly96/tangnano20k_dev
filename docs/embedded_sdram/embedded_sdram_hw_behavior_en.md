# Embedded SDRAM Hardware Behavior Specification

## 1. Purpose

This document records the SDRAM behavior that was verified on real
hardware in this repository.
It is a project-specific hardware behavior note for the current
Tang Nano 20K design using the Gowin embedded SDRAM controller IP.

The main purpose of this document is to preserve the practical rules that
were learned during bring-up.
It focuses on:

- what access pattern is currently safe
- what access pattern shall be treated with caution
- how packed SDRAM access was constructed during characterization
- how the current self-test can be rerun from the status map

This document is based on measurements taken up to 2026-04-19.

---

## 2. Scope

This document covers:

- the active Gowin embedded SDRAM controller integration in this
  repository
- self-test behavior observed on real hardware
- the packed SDRAM access pattern that was confirmed to work
- the project rules that shall be followed until a broader packed
  full-range walker is implemented

This document does not define:

- the internals of the Gowin IP
- a general SDRAM tutorial
- a complete final bank/row/column map for all addresses

---

## 3. Test Environment

The results in this document were obtained with:

- Gowin embedded SDRAM controller IP in `00_ip/embedded_sdram`
- user RTL in `01_src/embedded_sdram`
- top-level integration in `01_src/tangnano20k_top.sv`
- host path configured as status-map-only
- self-test as the only SDRAM traffic source
- linear self-test mode with `BURST_WORDS = 1` as the default
  power-on and manual regression mode

Hardware status was observed through the SDRAM status register map.
The main sweep artifacts are:

- `tmp/sdram_memtest_hw_sweep_test.csv`
- `tmp/sdram_memtest_hw_sweep_legacy_burst.csv`

---

## 4. Validation Signature

The key pass indicator is status register `0x00`.

The observed pass value is:

- `0x040D00A8`

This indicates:

- status-map version = `0x04`
- memtest state = `PASS`
- fail reason = `0x00`
- `init_done = 1`
- `test_pass = 1`
- `test_fail = 0`
- `sdrc_reset_active = 0`

The observed pass retry summary is:

- `0x03000000`

This indicates:

- retry limit = `3`
- retries used = `0`
- retry data valid = `0`

---

## 5. Main Hardware Conclusion

The most important hardware conclusion is:

- the stable default access mode is linear addressing with
  `BURST_WORDS = 1`
- burst mode shall be treated as a characterization/debug feature until
  a complete packed bank/row/column walker is implemented and verified

Earlier hardware results showed that burst access larger than `1` can pass
on the board.
That result was reproduced when the self-test used the older packed access
pattern at a narrow known-good bank/row window.

Later selected bank/row checks did not generalize that result.
For example, `bank=0,row=2`, `bank=2,row=0`, `bank=2,row=1024`,
and `bank=3,row=2` failed under the same `BURST_WORDS = 26` packed
window style.

Therefore, the current design rule is:

- use linear addressing with `BURST_WORDS = 1` for normal full-range
  SDRAM self-test
- do not use burst mode as a default access path
- use packed mode only when reproducing or extending burst
  characterization experiments

---

## 6. Linear Mode Note

Linear mode is the current default access mode.
It treats the Gowin SDRC user address as a flat word index and advances
one word per request.

Project caution:

- if the self-test uses the current linear SDRC address generation, keep
  `BURST_WORDS = 1`
- do not use the linear mode as evidence that burst access is unsupported
- do not increase `BURST_WORDS` in linear mode without a dedicated
  hardware revalidation run

In short:

- linear mode with `BURST_WORDS = 1` is the safe full-range validation path
- packed mode is retained only as a burst characterization reference

The current top-level defaults are:

- `USE_FIXED_WINDOW_ADDR = 0`
- `BURST_WORDS = 1`
- `TEST_WORDS = 2,097,152`

---

## 7. Packed Mode Access Rule

### 7.1 Definition

Packed mode means the SDRC user address is constructed explicitly from
bank, row, and column fields.
In the hardware-proven debug mode, the address is formed as:

```text
O_SDRC_ADDR = {bank[1:0], row[10:0], col[7:0]}
```

with:

- `bank = 2`
- `row = 2`
- `col = 5 + word_offset`

In the current RTL, this corresponds to:

- `USE_FIXED_WINDOW_ADDR = 1`
- `FIXED_BANK_ADDR = 2`
- `FIXED_ROW_ADDR = 2`
- `FIXED_COL_START = 5`

The test-word offset is applied only to the packed column field during the
test read/write phase.

### 7.2 Meaning

This mode keeps bank and row constant and advances only the column field.
It reproduces the same practical access style that produced the earlier
passing `26 x 8` self-test result.

This is the currently known-good reference pattern for burst validation on
hardware.

---

## 8. Packed Mode Access Procedure

The packed mode used in the verified hardware sweep shall be interpreted as
follows.

### 8.1 Test Phase Address Generation

For each test burst:

1. keep `bank` fixed at `2`
2. keep `row` fixed at `2`
3. compute `col = FIXED_COL_START + test_word_idx`
4. pack the address as `{bank, row, col}`
5. issue the SDRC request with the desired burst length

The effective word range touched by a burst starting at `test_word_idx` is:

```text
column_start = FIXED_COL_START + test_word_idx
column_end   = column_start + BURST_WORDS - 1
```

The next burst base is advanced by the number of tested words in the
previous burst.

### 8.2 Write/Read Sequence

The verified packed-mode self-test uses this sequence:

1. generate a burst write request at the packed address
2. write a sequential data pattern
3. wait the configured post-write gap
4. issue a burst read request at the same packed address
5. compare each returned word against the expected data
6. if a mismatch occurs, retry the exact failing word up to three times

This means the packed-mode burst verification is not a raw write-only or
read-only check.
It is a write-read-compare burst validation at a fixed bank/row window.

### 8.3 Clear Phase Note

In the current implementation, the packed fixed-window rule applies to the
test read/write phase.
The memory clear phase is a separate operation.
Do not assume that "packed mode enabled" means every internal maintenance
operation uses the same fixed bank/row/column window.

If the clear behavior is changed in the future, it shall be verified again
on hardware.

---

## 9. Packed Mode Cautions

The following cautions shall be treated as active project rules.

### 9.1 Debug And Characterization Use

Packed fixed-window mode is currently a debug and characterization mode.
Use it when the goal is:

- reproduce the older known-good burst behavior
- validate burst handling after RTL refactoring
- compare a new address-generation strategy against a known reference

Do not treat the current fixed-window mode as a finished full-range
production address map.

Do not enable packed burst mode for the default power-on self-test.
The packed result is not yet stable across the sampled bank/row points.

### 9.2 Column Range Limit

The currently verified fixed-window mode uses an 8-bit column field.
Therefore:

```text
FIXED_COL_START + TEST_WORDS <= 255
```

shall be satisfied for the current packed-window sweep style.

This is why the verified sweep stopped at:

- `BURST_WORDS = 31`
- `TEST_WORDS = 248`

with:

- `FIXED_COL_START = 5`

The current result proves that burst is verified up to at least `31` under
this packed-window rule.
It does not prove that `31` is the controller's absolute maximum burst
length.

### 9.3 Do Not Mix Conclusions

Do not mix these two statements:

- "linear full-range mode is safe with burst `1`"
- "packed fixed-window mode is verified with burst up to at least `31`"

They describe different access methods.
One shall not be used as proof about the other.

### 9.4 Do Not Generalize The Old `26 x 8` Result Incorrectly

The old passing result:

- `BURST_WORDS = 26`
- `BURST_COUNT = 8`

is valid only as proof that the packed access pattern worked on hardware.

It shall not be reinterpreted as proof that any arbitrary flat linear
address walk also supports `BURST_WORDS = 26`.

---

## 10. Verified Packed Mode Results

The following packed-mode points were verified to pass on hardware:

- `BURST_WORDS = 1`, `TEST_WORDS = 8`
- `BURST_WORDS = 2`, `TEST_WORDS = 16`
- `BURST_WORDS = 4`, `TEST_WORDS = 32`
- `BURST_WORDS = 8`, `TEST_WORDS = 64`
- `BURST_WORDS = 16`, `TEST_WORDS = 128`
- `BURST_WORDS = 24`, `TEST_WORDS = 192`
- `BURST_WORDS = 26`, `TEST_WORDS = 208`
- `BURST_WORDS = 28`, `TEST_WORDS = 224`
- `BURST_WORDS = 30`, `TEST_WORDS = 240`
- `BURST_WORDS = 31`, `TEST_WORDS = 248`

All points above completed with:

- summary `0x030D00A8`
- retry summary `0x03000000`

This is the current board-proven burst-capable access range for the
packed-window mode.

---

## 11. Current Project Rules

Until a proper packed full-range walker is implemented and verified, the
following rules shall be used.

### 11.1 Default Safe Regression Mode

Use:

- `USE_FIXED_WINDOW_ADDR = 0`
- `BURST_WORDS = 1`
- `TEST_WORDS = 2,097,152`

when the goal is:

- full-range smoke test
- stable regression behavior
- safe power-on self-test
- manually rerun the self-test from the status map

### 11.2 Manual Self-Test Rerun

The status map includes a write-only control register overlaid on address
`0x003C`.
The same address still reads back the live `LATEST_RD_DATA` word.

Use this host command to reset the Gowin SDRC and rerun the self-test:

```powershell
python 11_app\debug_log_cli\sdram_hostif_tool.py `
  --transport tcp --tcp-host 192.168.10.40 --tcp-port 2323 `
  write 0x3C 0x00000001 --select-host
```

The write returns `WRITE_ACK` when accepted.
After the write, status bit `SUMMARY[2]` is `sdrc_reset_active`.
Polling `read 0` shall show the sequence:

1. reset active or init not done
2. init done with self-test active
3. final PASS or FAIL state

### 11.3 Burst Debug Mode

Use:

- `USE_FIXED_WINDOW_ADDR = 1`
- `FIXED_BANK_ADDR = 2`
- `FIXED_ROW_ADDR = 2`
- `FIXED_COL_START = 5`

when the goal is:

- burst characterization
- packed-mode hardware comparison
- reproduction of the earlier passing burst behavior at the known-good
  packed window

Do not use this mode as the normal default.

### 11.4 Next Design Step

The next engineering task is to implement and verify a full-range packed
bank/row/column walker.

The immediate goal is not "increase burst in linear mode".
The immediate goal is:

- define the correct packed address mapping for the Gowin SDRC user
  interface
- implement a full-range packed walker
- repeat the burst validation using that packed full-range mapping

---

## 12. Repository State At The Time Of Writing

At the time this document was updated, the repository and programmed
hardware had been returned to the conservative default configuration:

- `USE_FIXED_WINDOW_ADDR = 0`
- `BURST_WORDS = 1`
- `TEST_WORDS = 2,097,152`

That configuration was rebuilt, programmed, and observed to return:

- `0x040D00A8`
