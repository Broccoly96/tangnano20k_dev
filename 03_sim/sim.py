#!/usr/bin/env python3
"""
Python replacement for sim.bat (ModelSim / Lattice OEM launcher).

Purpose:
  - Provide a cross-platform, scriptable front-end for ModelSim-based
    simulations equivalent to 03_sim/sim.bat.
Behavior:
  - Parses testbench path and optional flags (recompile, openwave, log level,
    vsim +PLUSARGS).
  - Finds ModelSim/Questa tools (vmap/vlog/vsim) from PATH or a user-supplied
    vsimpath directory.
  - Creates/maps the work library and optional gw1n/gw2a libraries.
  - Optionally recompiles common sources (compile.bat equivalent) using vlog
    and vlog.f.
  - Compiles the specified testbench top, then launches vsim.
Usage:
  - From the 03_sim directory:
      python sim.py 01_uart\\testbench.sv recompile
      python sim.py 01_uart\\testbench.sv recompile openwave
      python sim.py 01_uart\\testbench.sv log DEBUG +TB_SOME_FLAG=1
      python sim.py 01_uart\\testbench.sv vsimpath C:\\lscc\\diamond\\3.13\\modeltech\\win32loem
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Optional, Tuple


DEFAULT_VSIMPATH = r"C:\lscc\diamond\3.13\modeltech\win32loem"


def print_usage(script_name: str) -> None:
    """
    Print command-line usage information for this script.
    """
    message_lines = [
        f"Usage: {script_name} <TB_PATH> [recompile] [openwave] [log LEVEL] [vsimpath PATH] [+PLUSARGS...]",
        "",
        "  TB_PATH    - Relative path to testbench top (e.g. 01_uart\\testbench.sv)",
        "  recompile  - Rebuild common libraries from vlog.f before simulation",
        "  openwave   - Launch ModelSim GUI and apply wave.do in the TB directory if present",
        "  log LEVEL  - Set tb_log_pkg log level (0-5 or SILENT/ERROR/WARN/INFO/DEBUG/TRACE)",
        f"  vsimpath   - Directory (or vsim executable path) to prepend to PATH for ModelSim tools",
        f"               (default on Windows: {DEFAULT_VSIMPATH})",
        "  +PLUSARGS  - Passed through to vsim as-is (e.g. +TB_LOG_LEVEL=4)",
        "",
        "Examples:",
        f"  {script_name} 01_uart\\testbench.sv recompile",
        f"  {script_name} 01_uart\\testbench.sv recompile openwave",
    ]
    for line in message_lines:
        print(line)


def run_subprocess(
    args: List[str],
    cwd: Path,
    env: Optional[dict] = None,
    check: bool = True,
    description: Optional[str] = None,
) -> subprocess.CompletedProcess:
    """
    Run a subprocess with optional description and error checking.
    """
    if description:
        print(f"[sim.py] {description}")

    try:
        result = subprocess.run(
            args,
            cwd=str(cwd),
            env=env,
            text=True,
        )
    except FileNotFoundError as error:
        tool_name = args[0] if args else "command"
        raise RuntimeError(
            f"Required tool '{tool_name}' not found in PATH. "
            "Ensure ModelSim/Questa executables are installed and accessible."
        ) from error

    if check and result.returncode != 0:
        raise RuntimeError(
            f"Command failed with exit code {result.returncode}: {' '.join(args)}"
        )

    return result


def parse_arguments(
    argv: List[str],
) -> Tuple[str, bool, bool, Optional[str], Optional[str], List[str]]:
    """
    Parse command-line arguments in a way that mirrors sim.bat.

    Returns a tuple:
      - tb_path:   Relative path to the testbench top.
      - recompile: True if 'recompile' flag is present.
      - openwave:  True if 'openwave' flag is present.
      - log_level: Optional log level string (numeric or name).
      - vsimpath:  Optional directory (or vsim path) for ModelSim tools.
      - plusargs:  List of +PLUSARGS to forward to vsim.
    """
    if not argv:
        raise ValueError("Missing testbench path argument.")

    tb_path = argv[0]
    tokens = list(argv[1:])

    recompile = False
    openwave = False
    log_level: Optional[str] = None
    vsimpath: Optional[str] = None
    plusargs: List[str] = []

    index = 0
    while index < len(tokens):
        current = tokens[index]
        lower = current.lower()

        if lower == "recompile":
            recompile = True
            index += 1
            continue

        if lower == "openwave":
            openwave = True
            index += 1
            continue

        if lower in ("log", "loglevel"):
            if index + 1 >= len(tokens):
                raise ValueError("Missing LEVEL after 'log' option.")
            log_level = tokens[index + 1]
            index += 2
            continue

        if lower == "vsimpath":
            if index + 1 >= len(tokens):
                raise ValueError("Missing PATH after 'vsimpath' option.")
            vsimpath = tokens[index + 1]
            index += 2
            continue

        if current.startswith("+"):
            plusargs.append(current)
            index += 1
            continue

        print(f"[sim.py] Warning: extra argument '{current}' ignored.", file=sys.stderr)
        index += 1

    return tb_path, recompile, openwave, log_level, vsimpath, plusargs


def map_log_level(log_level: Optional[str]) -> Optional[int]:
    """
    Map a log level string or number to the tb_log_pkg numeric value.
    """
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


def prepare_libraries(script_dir: Path) -> None:
    """
    Create and map the 'work' library and optional device libraries.
    """
    work_lib_dir = script_dir / "work"
    simlib_root = script_dir.parent / "04_simlib"

    if not work_lib_dir.exists():
        print(f"[sim.py] Creating work library at '{work_lib_dir}'")
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

    for library_name in ("gw1n", "gw2a"):
        lib_path = simlib_root / library_name
        if lib_path.exists():
            run_subprocess(
                ["vmap", library_name, str(lib_path)],
                cwd=script_dir,
                description=f"vmap {library_name}",
            )


def maybe_recompile_common_sources(script_dir: Path, recompile: bool) -> None:
    """
    Optionally recompile common sources (equivalent to compile.bat), if requested.
    """
    if not recompile:
        print("[sim.py] Skip recompile (pass 'recompile' to force).")
        return

    vlog_file = script_dir / "vlog.f"
    if not vlog_file.exists():
        print(
            "[sim.py] WARNING: 'recompile' requested, but vlog.f not found; skipping.",
            file=sys.stderr,
        )
        return

    print("[sim.py] Recompiling common sources from vlog.f")
    run_subprocess(
        ["vlog", "-sv", "-work", "work", "-f", str(vlog_file), "-l", "compile.log"],
        cwd=script_dir,
        description="vlog common sources",
    )


def compile_testbench(script_dir: Path, tb_path: str) -> Tuple[str, Path]:
    """
    Compile the specified testbench top into the 'work' library.

    Returns:
      - tb_top: Name of the testbench top unit (filename stem).
      - tb_dir: Directory containing the testbench file.
    """
    tb_file = (script_dir / tb_path).resolve()

    if not tb_file.exists():
        raise FileNotFoundError(
            f"Testbench file not found: {tb_file.relative_to(script_dir)}"
        )

    tb_top = tb_file.stem
    tb_dir = tb_file.parent

    print(f"[sim.py] Compiling testbench '{tb_file.relative_to(script_dir)}'")
    run_subprocess(
        ["vlog", "-sv", "+define+SIM", "-work", "work", str(tb_file)],
        cwd=script_dir,
        description="vlog testbench",
    )

    return tb_top, tb_dir


def launch_simulation(
    script_dir: Path,
    tb_top: str,
    tb_dir: Path,
    openwave: bool,
    log_level_value: Optional[int],
    plusargs: List[str],
) -> int:
    """
    Launch the ModelSim simulation with appropriate options and plusargs.

    Returns:
      - The vsim process exit code.
    """
    vsim_plusargs: List[str] = list(plusargs)

    if log_level_value is not None:
        vsim_plusargs.append(f"+TB_LOG_LEVEL={log_level_value}")

    vsim_mode: List[str] = []
    do_cmds: str

    if openwave:
        do_cmds = f'do wave.do; run -all'
    else:
        vsim_mode = ["-c"]
        do_cmds = "run -all; quit -code 0"

    command: List[str] = ["vsim"] + vsim_mode + [
        f"work.{tb_top}",
        "-voptargs=+acc",
    ]

    simlib_root = script_dir.parent / "04_simlib"
    for library_name in ("gw1n", "gw2a"):
      if (simlib_root / library_name).exists():
        command.extend(["-L", library_name])
    command.extend(vsim_plusargs)
    command.extend(["-do", do_cmds, "-l", "sim.log"])

    print("[sim.py] Launching ModelSim:")
    print("         " + " ".join(command))

    result = subprocess.run(
        command,
        cwd=str(script_dir),
        text=True,
    )
    return result.returncode


def main(argv: List[str]) -> int:
    """
    Entry point: parse arguments, configure environment, and run the simulation.
    """
    script_path = Path(__file__).resolve()
    script_dir = script_path.parent
    original_cwd = Path.cwd()

    try:
        if not argv or argv[0] in ("help", "-h", "--help", "/?"):
            print_usage(script_path.name)
            return 0 if argv else 1

        (
            tb_path,
            recompile,
            openwave,
            log_level_text,
            vsimpath,
            plusargs,
        ) = parse_arguments(argv)

        os.chdir(script_dir)

        # Configure PATH so that vmap/vlog/vsim are available.
        # If vsimpath is provided, prepend it.
        # Otherwise, on Windows, fall back to DEFAULT_VSIMPATH.
        effective_vsimpath = vsimpath
        if effective_vsimpath is None and os.name == "nt":
            effective_vsimpath = DEFAULT_VSIMPATH

        if effective_vsimpath:
            vsimpath_str = effective_vsimpath.strip('"')
            vsim_path_obj = Path(vsimpath_str)
            if vsim_path_obj.is_file():
                bin_dir = vsim_path_obj.parent
            else:
                bin_dir = vsim_path_obj
            os.environ["PATH"] = str(bin_dir) + os.pathsep + os.environ.get("PATH", "")

        missing_tools = [tool for tool in ("vmap", "vlog", "vsim") if shutil.which(tool) is None]
        if missing_tools:
            raise RuntimeError(
                "Required tools not found in PATH: "
                + ", ".join(missing_tools)
                + ". Set PATH correctly or use 'vsimpath <dir>' option."
            )

        prepare_libraries(script_dir)
        maybe_recompile_common_sources(script_dir, recompile)

        tb_top, tb_dir = compile_testbench(script_dir, tb_path)

        log_level_value = map_log_level(log_level_text)

        exit_code = launch_simulation(
            script_dir=script_dir,
            tb_top=tb_top,
            tb_dir=tb_dir,
            openwave=openwave,
            log_level_value=log_level_value,
            plusargs=plusargs,
        )

        return exit_code

    except (ValueError, FileNotFoundError, RuntimeError) as error:
        print(f"[sim.py] ERROR: {error}", file=sys.stderr)
        return 1
    finally:
        try:
            os.chdir(original_cwd)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
