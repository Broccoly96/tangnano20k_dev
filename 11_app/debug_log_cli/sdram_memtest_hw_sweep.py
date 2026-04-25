"""Run hardware SDRAM memtest sweeps by rewriting top-level localparams."""

from __future__ import annotations

import csv
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
TOP_PATH = REPO_ROOT / "01_src" / "tangnano20k_top.sv"
RUN_ALL_TCL = REPO_ROOT / "05_impl" / "run_all.tcl"
BITSTREAM_PATH = REPO_ROOT / "05_impl" / "impl" / "pnr" / "tangnano20k.fs"
PROGRAMMER = Path(r"C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe")
GW_SH = Path(r"C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe")
HOSTIF_TOOL = REPO_ROOT / "11_app" / "debug_log_cli" / "sdram_hostif_tool.py"
RESULT_DIR = REPO_ROOT / "tmp"

BURST_PATTERN = re.compile(
    r"(localparam int unsigned SDRAM_MEMTEST_BURST_WORDS\s*=\s*)(\d+)(\s*;)"
)
TEST_PATTERN = re.compile(
    r"(localparam int unsigned SDRAM_MEMTEST_TEST_WORDS\s*=\s*)([\d_]+)(\s*;)"
)
MODE_PATTERN = re.compile(
    r"(localparam bit\s+SDRAM_MEMTEST_USE_FIXED_WINDOW_ADDR\s*=\s*1'b)([01])(\s*;)"
)
BANK_PATTERN = re.compile(
    r"(localparam logic \[1:0\]\s+SDRAM_MEMTEST_FIXED_BANK_ADDR\s*=\s*2'd)(\d+)(\s*;)"
)
ROW_PATTERN = re.compile(
    r"(localparam logic \[10:0\]\s+SDRAM_MEMTEST_FIXED_ROW_ADDR\s*=\s*11'd)(\d+)(\s*;)"
)
COL_PATTERN = re.compile(
    r"(localparam logic \[7:0\]\s+SDRAM_MEMTEST_FIXED_COL_START\s*=\s*8'd)(\d+)(\s*;)"
)

BURST_SWEEP_VALUES = [1, 2, 4, 8, 16, 24, 26, 32, 48, 64, 96, 128, 192, 255, 256]
TEST_SWEEP_VALUES = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 4096, 16384, 65536, 262144, 1048576, 2097152]


@dataclass
class SweepResult:
    phase: str
    burst_words: int
    test_words: int
    outcome: str
    summary: int
    state: int
    fail_reason: int
    mem_summary: int
    last_read: int
    last_status: int
    fail_addr: int
    fail_expected: int
    fail_actual: int
    retry_summary: int
    retry_data1: int
    retry_data2: int
    ctrl_summary: int
    handshake: int
    latest_rd: int


def run_cmd(args: list[str], *, cwd: Path) -> None:
    completed = subprocess.run(args, cwd=cwd, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"command failed rc={completed.returncode}: {' '.join(args)}")


def rewrite_top(
    *,
    burst_words: int,
    test_words: int,
    use_fixed_window_addr: bool | None = None,
    fixed_bank_addr: int | None = None,
    fixed_row_addr: int | None = None,
    fixed_col_start: int | None = None,
) -> None:
    text = TOP_PATH.read_text(encoding="utf-8")
    text, burst_count = BURST_PATTERN.subn(rf"\g<1>{burst_words}\g<3>", text, count=1)
    text, test_count = TEST_PATTERN.subn(rf"\g<1>{test_words}\g<3>", text, count=1)
    mode_count = 1
    bank_count = 1
    row_count = 1
    col_count = 1
    if use_fixed_window_addr is not None:
        mode_digit = "1" if use_fixed_window_addr else "0"
        text, mode_count = MODE_PATTERN.subn(rf"\g<1>{mode_digit}\g<3>", text, count=1)
    if fixed_bank_addr is not None:
        text, bank_count = BANK_PATTERN.subn(rf"\g<1>{fixed_bank_addr}\g<3>", text, count=1)
    if fixed_row_addr is not None:
        text, row_count = ROW_PATTERN.subn(rf"\g<1>{fixed_row_addr}\g<3>", text, count=1)
    if fixed_col_start is not None:
        text, col_count = COL_PATTERN.subn(rf"\g<1>{fixed_col_start}\g<3>", text, count=1)
    if (
        burst_count != 1
        or test_count != 1
        or mode_count != 1
        or bank_count != 1
        or row_count != 1
        or col_count != 1
    ):
        raise RuntimeError("failed to rewrite top-level SDRAM memtest localparams")
    TOP_PATH.write_text(text, encoding="utf-8")


def read_host_word(addr: int) -> int:
    args = [
        sys.executable,
        str(HOSTIF_TOOL),
        "--transport",
        "tcp",
        "--tcp-host",
        "192.168.10.40",
        "--tcp-port",
        "2323",
        "read",
        str(addr),
        "--select-host",
    ]
    for _ in range(3):
        completed = subprocess.run(args, cwd=REPO_ROOT, check=False, capture_output=True, text=True)
        if completed.returncode == 0:
            match = re.search(r"data=0x([0-9A-Fa-f]+)", completed.stdout)
            if match:
                return int(match.group(1), 16)
        time.sleep(1.0)
    raise RuntimeError(f"failed to read status addr=0x{addr:05X}: {completed.stdout} {completed.stderr}")


def wait_for_final_summary(timeout_s: float = 180.0) -> int:
    deadline = time.time() + timeout_s
    last_summary = 0
    while time.time() < deadline:
        last_summary = read_host_word(0)
        test_active = (last_summary >> 6) & 0x1
        test_pass = (last_summary >> 5) & 0x1
        test_fail = (last_summary >> 4) & 0x1
        if test_pass or test_fail or (test_active == 0 and ((last_summary >> 3) & 0x1)):
            return last_summary
        time.sleep(2.0)
    raise RuntimeError(f"timeout waiting for memtest completion; last_summary=0x{last_summary:08X}")


def capture_result(phase: str, burst_words: int, test_words: int) -> SweepResult:
    summary = wait_for_final_summary()
    return SweepResult(
        phase=phase,
        burst_words=burst_words,
        test_words=test_words,
        outcome="PASS" if ((summary >> 5) & 0x1) else "FAIL",
        summary=summary,
        state=(summary >> 16) & 0xFF,
        fail_reason=(summary >> 8) & 0xFF,
        mem_summary=read_host_word(4),
        last_read=read_host_word(16),
        last_status=read_host_word(20),
        fail_addr=read_host_word(24),
        fail_expected=read_host_word(28),
        fail_actual=read_host_word(32),
        retry_summary=read_host_word(36),
        retry_data1=read_host_word(40),
        retry_data2=read_host_word(44),
        ctrl_summary=read_host_word(48),
        handshake=read_host_word(56),
        latest_rd=read_host_word(60),
    )


def run_build_and_program() -> None:
    run_cmd([str(GW_SH), str(RUN_ALL_TCL)], cwd=REPO_ROOT)
    run_cmd(
        [
            str(PROGRAMMER),
            "--device",
            "GW2AR-18C",
            "--run",
            "2",
            "--fsFile",
            str(BITSTREAM_PATH),
        ],
        cwd=REPO_ROOT,
    )


def write_csv(path: Path, rows: list[SweepResult]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(SweepResult.__annotations__.keys()))
        writer.writeheader()
        for row in rows:
            writer.writerow(row.__dict__)


def print_result(row: SweepResult) -> None:
    print(
        f"{row.phase:>5} burst={row.burst_words:>3} test={row.test_words:>8} "
        f"outcome={row.outcome:>4} summary=0x{row.summary:08X} "
        f"fail_addr=0x{row.fail_addr:08X} fail_actual=0x{row.fail_actual:08X} "
        f"retry=0x{row.retry_summary:08X}"
    )


def main() -> int:
    RESULT_DIR.mkdir(parents=True, exist_ok=True)
    results: list[SweepResult] = []

    print("Starting BURST_WORDS sweep")
    for burst_words in BURST_SWEEP_VALUES:
        test_words = burst_words
        print(f"\n[BURST] burst_words={burst_words} test_words={test_words}")
        rewrite_top(burst_words=burst_words, test_words=test_words)
        run_build_and_program()
        row = capture_result("burst", burst_words, test_words)
        results.append(row)
        print_result(row)

    passing_bursts = [row.burst_words for row in results if row.phase == "burst" and row.outcome == "PASS"]
    if passing_bursts:
        test_burst_words = max(passing_bursts)
    else:
        test_burst_words = 1

    print(f"\nSelected burst_words={test_burst_words} for TEST_WORDS sweep")

    seen_test_words: set[int] = set()
    for test_words in TEST_SWEEP_VALUES:
        if test_words in seen_test_words:
            continue
        seen_test_words.add(test_words)
        print(f"\n[TEST] burst_words={test_burst_words} test_words={test_words}")
        rewrite_top(burst_words=test_burst_words, test_words=test_words)
        run_build_and_program()
        row = capture_result("test", test_burst_words, test_words)
        results.append(row)
        print_result(row)

    csv_path = RESULT_DIR / "sdram_memtest_hw_sweep.csv"
    write_csv(csv_path, results)
    print(f"\nResults saved to {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
