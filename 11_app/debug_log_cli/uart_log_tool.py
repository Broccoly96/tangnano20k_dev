"""Compatibility launcher for the UART log CLI host tool."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys


def _load_target_main():
    wrapper_dir = Path(__file__).resolve().parent
    tool_dir = wrapper_dir.parent / "uart_log_tool" / "debug_log_tool"
    tool_main = tool_dir / "uart_log_tool.py"

    if str(tool_dir) not in sys.path:
        sys.path.insert(0, str(tool_dir))

    spec = importlib.util.spec_from_file_location("uart_log_tool_entry", tool_main)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load tool entry: {tool_main}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.main


def main() -> None:
    _load_target_main()()


if __name__ == "__main__":
    main()
