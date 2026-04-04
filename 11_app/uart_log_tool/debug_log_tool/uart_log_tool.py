"""Entry point for UART Log CLI host tool (Textual TUI)."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from uart_log_tui import UARTLogApp


def _build_parser() -> argparse.ArgumentParser:
    script_dir = Path(__file__).resolve().parent
    default_decoder = script_dir / "decode_rules.default.yaml"

    parser = argparse.ArgumentParser(description="UART log monitor for tangnano20k uart_log_cli")
    parser.add_argument(
        "--transport",
        type=str,
        choices=["serial", "tcp"],
        default="tcp",
        help="Log transport",
    )
    parser.add_argument("--port", type=str, default=None, help="Initial serial port (e.g. COM3)")
    parser.add_argument("--baud", type=int, default=115200, help="UART baud rate")
    parser.add_argument(
        "--tcp-host",
        type=str,
        default="192.168.10.40",
        help="TCP host for ESP UART bridge",
    )
    parser.add_argument(
        "--tcp-port",
        type=int,
        default=2323,
        help="TCP port for ESP UART bridge",
    )
    parser.add_argument(
        "--mode",
        type=str,
        choices=["raw", "decode"],
        default="decode",
        help="Display mode",
    )
    parser.add_argument(
        "--decoder",
        type=str,
        default=str(default_decoder),
        help="Decode rule YAML file",
    )
    parser.add_argument(
        "--log-file",
        type=str,
        default=None,
        help="Optional log output path (disabled if omitted)",
    )
    parser.add_argument(
        "--replay",
        type=str,
        default=None,
        help="Replay mode: load and play events from a saved .log file",
    )
    parser.add_argument("--no-color", action="store_true", help="Disable color output")
    return parser


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()

    if args.no_color:
        os.environ["NO_COLOR"] = "1"
        os.environ["TEXTUAL_NO_COLOR"] = "1"

    app = UARTLogApp(
        transport=args.transport,
        initial_port=args.port,
        baud=args.baud,
        tcp_host=args.tcp_host,
        tcp_port=args.tcp_port,
        mode=args.mode,
        decoder_path=args.decoder,
        log_file=args.log_file,
        replay_file=args.replay,
    )
    app.run()


if __name__ == "__main__":
    main()
