#!/usr/bin/env python3
"""
Linux-focused Questa launcher for this repository.

Why this script exists:
  - Existing sim.py was authored for Windows/Lattice OEM usage.
  - On Linux, vlog.f uses backslash paths (..\foo\bar.sv) that fail in vlog -f.
  - In this environment, vsim -c may exit 0 even when startup fails before run.

Behavior:
  - Normalizes vlog.f path separators to '/' into a temporary file.
  - Recompiles common sources when requested.
  - Compiles the selected testbench.
  - Uses -suppress 7061 to align with Windows ModelSim behavior for this codebase.
  - Runs vsim in batch mode and checks sim.log for Fatal/Error patterns.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Optional, Tuple


def print_usage(script_name: str) -> None:
    print(
        f"Usage: {script_name} <TB_PATH> [recompile] [log LEVEL] [+PLUSARGS...]\n"
        "\n"
        "  TB_PATH    - Relative path to testbench top (e.g. 02_uart_log_cli/testbench.sv)\n"
        "  recompile  - Rebuild common libraries from vlog.f before simulation\n"
        "  log LEVEL  - Set tb_log_pkg log level (0-5 or SILENT/ERROR/WARN/INFO/DEBUG/TRACE)\n"
        "  +PLUSARGS  - Passed through to vsim as-is\n"
    )


def run_subprocess(
    args: List[str],
    cwd: Path,
    check: bool = True,
    description: Optional[str] = None,
) -> subprocess.CompletedProcess:
    if description:
        print(f"[sim_questa_linux.py] {description}")

    try:
        result = subprocess.run(args, cwd=str(cwd), text=True)
    except FileNotFoundError as error:
        tool_name = args[0] if args else "command"
        raise RuntimeError(
            f"Required tool '{tool_name}' not found in PATH."
        ) from error

    if check and result.returncode != 0:
        raise RuntimeError(
            f"Command failed with exit code {result.returncode}: {' '.join(args)}"
        )

    return result


def parse_arguments(
    argv: List[str],
) -> Tuple[str, bool, Optional[str], List[str]]:
    if not argv:
        raise ValueError("Missing testbench path argument.")

    tb_path = argv[0]
    tokens = list(argv[1:])

    recompile = False
    log_level: Optional[str] = None
    plusargs: List[str] = []

    index = 0
    while index < len(tokens):
        current = tokens[index]
        lower = current.lower()

        if lower == "recompile":
            recompile = True
            index += 1
            continue

        if lower in ("log", "loglevel"):
            if index + 1 >= len(tokens):
                raise ValueError("Missing LEVEL after 'log' option.")
            log_level = tokens[index + 1]
            index += 2
            continue

        if current.startswith("+"):
            plusargs.append(current)
            index += 1
            continue

        print(
            f"[sim_questa_linux.py] Warning: extra argument '{current}' ignored.",
            file=sys.stderr,
        )
        index += 1

    return tb_path, recompile, log_level, plusargs


def map_log_level(log_level: Optional[str]) -> Optional[int]:
    if log_level is None:
        return None

    level_text = log_level.strip()
    if not level_text:
        return None

    if level_text.isdigit():
        value = int(level_text)
        if 0 <= value <= 5:
            return value
        return None

    upper = level_text.upper()
    mapping = {
        "SILENT": 0,
        "SILNT": 0,
        "ERROR": 1,
        "WARN": 2,
        "WARNING": 2,
        "INFO": 3,
        "DEBUG": 4,
        "TRACE": 5,
    }
    return mapping.get(upper)


def normalize_vlog_file_for_linux(script_dir: Path) -> Path:
    src = script_dir / "vlog.f"
    if not src.exists():
        raise FileNotFoundError(f"vlog.f not found: {src}")

    dst = script_dir / ".vlog_linux.f"
    text = src.read_text(encoding="utf-8")
    dst.write_text(text.replace("\\", "/"), encoding="utf-8")
    return dst


def collect_available_vendor_libraries(script_dir: Path) -> List[str]:
    simlib_root = script_dir.parent / "04_simlib"
    available: List[str] = []

    for library_name in ("gw1n", "gw2a"):
        if (simlib_root / library_name).exists():
            available.append(library_name)

    return available


def prepare_libraries(script_dir: Path) -> List[str]:
    work_lib_dir = script_dir / "work"
    simlib_root = script_dir.parent / "04_simlib"
    available_vendor_libraries = collect_available_vendor_libraries(script_dir)

    if not work_lib_dir.exists():
        run_subprocess(
            ["vlib", str(work_lib_dir)],
            cwd=script_dir,
            description="vlib work",
        )

    run_subprocess(
        ["vmap", "work", str(work_lib_dir)],
        cwd=script_dir,
        description="vmap work",
    )

    for library_name in available_vendor_libraries:
        run_subprocess(
            ["vmap", library_name, str(simlib_root / library_name)],
            cwd=script_dir,
            description=f"vmap {library_name}",
        )

    return available_vendor_libraries


def maybe_recompile_common_sources(script_dir: Path, recompile: bool) -> None:
    if not recompile:
        print("[sim_questa_linux.py] Skip recompile (pass 'recompile' to force).")
        return

    vlog_linux = normalize_vlog_file_for_linux(script_dir)
    try:
        run_subprocess(
            ["vlog", "-sv", "-work", "work", "-f", str(vlog_linux), "-l", "compile.log"],
            cwd=script_dir,
            description="vlog common sources",
        )
    finally:
        try:
            vlog_linux.unlink(missing_ok=True)
        except OSError:
            pass


def compile_testbench(script_dir: Path, tb_path: str) -> str:
    tb_path_norm = tb_path.replace("\\", "/")
    tb_file = (script_dir / tb_path_norm).resolve()

    if not tb_file.exists():
        raise FileNotFoundError(
            f"Testbench file not found: {tb_file.relative_to(script_dir)}"
        )

    tb_top = tb_file.stem
    run_subprocess(
        [
            "vlog",
            "-sv",
            "+define+SIM",
            f"+incdir+{script_dir.parent / '02_tb'}",
            f"+incdir+{tb_file.parent}",
            "-work",
            "work",
            str(tb_file),
        ],
        cwd=script_dir,
        description=f"vlog testbench {tb_file.relative_to(script_dir)}",
    )
    return tb_top


def analyze_sim_log(sim_log: Path) -> Optional[str]:
    if not sim_log.exists():
        return "sim.log was not generated."

    text = sim_log.read_text(encoding="utf-8", errors="replace")

    if "Invalid host." in text:
        return (
            "License host mismatch detected. Regenerate LR license for this Linux host "
            "(MAC/hostname), then retry."
        )

    if "Error loading design" in text:
        return "Design load failed during vsim elaboration."

    if re.search(r"\*\*\s+Fatal:", text):
        return "Simulation hit a fatal error."

    if re.search(r"\*\*\s+Error:", text):
        return "Simulation reported an error."

    return None


def launch_simulation(
    script_dir: Path,
    tb_top: str,
    log_level_value: Optional[int],
    vendor_libraries: List[str],
    plusargs: List[str],
) -> int:
    vsim_plusargs: List[str] = list(plusargs)
    if log_level_value is not None:
        vsim_plusargs.append(f"+TB_LOG_LEVEL={log_level_value}")

    command: List[str] = [
        "vsim",
        "-batch",
        "-suppress",
        "7061",
        f"work.{tb_top}",
        "-voptargs=+acc",
    ]
    for library_name in vendor_libraries:
        command.extend(["-L", library_name])
    command.extend(vsim_plusargs)
    command.extend(["-do", "run -all; quit -code 0", "-l", "sim.log"])

    print("[sim_questa_linux.py] Launching Questa:")
    print("                      " + " ".join(command))
    result = subprocess.run(command, cwd=str(script_dir), text=True)

    sim_issue = analyze_sim_log(script_dir / "sim.log")
    if sim_issue is not None:
        print(f"[sim_questa_linux.py] ERROR: {sim_issue}", file=sys.stderr)
        return 1

    return result.returncode


def main(argv: List[str]) -> int:
    if os.name == "nt":
        print(
            "[sim_questa_linux.py] ERROR: This launcher is Linux-specific. Use sim.py on Windows.",
            file=sys.stderr,
        )
        return 1

    script_path = Path(__file__).resolve()
    script_dir = script_path.parent
    original_cwd = Path.cwd()

    try:
        if not argv or argv[0] in ("help", "-h", "--help", "/?"):
            print_usage(script_path.name)
            return 0 if argv else 1

        tb_path, recompile, log_level_text, plusargs = parse_arguments(argv)

        os.chdir(script_dir)
        missing_tools = [
            tool for tool in ("vlib", "vmap", "vlog", "vsim") if shutil.which(tool) is None
        ]
        if missing_tools:
            raise RuntimeError(
                "Required tools not found in PATH: " + ", ".join(missing_tools)
            )

        vendor_libraries = prepare_libraries(script_dir)
        maybe_recompile_common_sources(script_dir, recompile)
        tb_top = compile_testbench(script_dir, tb_path)
        log_level_value = map_log_level(log_level_text)
        return launch_simulation(
            script_dir,
            tb_top,
            log_level_value,
            vendor_libraries,
            plusargs,
        )

    except (ValueError, FileNotFoundError, RuntimeError) as error:
        print(f"[sim_questa_linux.py] ERROR: {error}", file=sys.stderr)
        return 1
    finally:
        try:
            os.chdir(original_cwd)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
