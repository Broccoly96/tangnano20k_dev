"""Minimal host-side sender for the embedded SDRAM UART host interface.

Usage examples:

  python 11_app/debug_log_cli/sdram_hostif_tool.py --transport tcp select-host
  python 11_app/debug_log_cli/sdram_hostif_tool.py --transport tcp write 0x100308 0x89ABCDEF
  python 11_app/debug_log_cli/sdram_hostif_tool.py --transport tcp read 0x100308
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path
from typing import Protocol


SCRIPT_DIR = Path(__file__).resolve().parent
TOOL_DIR = SCRIPT_DIR.parent / "uart_log_tool" / "debug_log_tool"
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from uart_log_serial import UARTSerialClient  # noqa: E402
from uart_log_tcp import UARTTCPClient  # noqa: E402


CMD_NEXT_SRC = bytes([0x06])
CMD_LITERAL_NEXT = 0x10
CMD_WRITE = 0x57
CMD_READ = 0x52
HOST_SOURCE_NEXT_COUNT = 2


class ByteClient(Protocol):
    def write_bytes(self, payload: bytes) -> int: ...
    def disconnect(self) -> None: ...


def parse_u32(text: str) -> int:
    value = int(text, 0)
    if value < 0 or value > 0xFFFF_FFFF:
        raise argparse.ArgumentTypeError(f"out of range u32: {text}")
    return value


def parse_u21(text: str) -> int:
    value = int(text, 0)
    if value < 0 or value > 0x1F_FFFF:
        raise argparse.ArgumentTypeError(f"out of range u21 addr: {text}")
    return value


def connect_client(args: argparse.Namespace) -> ByteClient:
    if args.transport == "tcp":
        client = UARTTCPClient()
        client.connect(args.tcp_host, args.tcp_port)
        return client

    client = UARTSerialClient()
    if not args.port:
        raise SystemExit("--port is required for serial transport")
    client.connect(args.port, args.baud)
    return client


def write_exact(client: ByteClient, payload: bytes) -> None:
    written = client.write_bytes(payload)
    if written != len(payload):
        raise SystemExit(f"short write: expected {len(payload)} bytes, got {written}")


def escape_cli_payload(payload: bytes) -> bytes:
    reserved = {0x04, 0x06, 0x10, 0x12, 0x14, 0x3F}
    escaped = bytearray()
    for byte_value in payload:
        if byte_value in reserved:
            escaped.append(CMD_LITERAL_NEXT)
        escaped.append(byte_value)
    return bytes(escaped)


def make_write_packet(addr: int, data: int) -> bytes:
    return escape_cli_payload(
        bytes(
            [
                CMD_WRITE,
                (addr >> 16) & 0x1F,
                (addr >> 8) & 0xFF,
                addr & 0xFF,
                (data >> 24) & 0xFF,
                (data >> 16) & 0xFF,
                (data >> 8) & 0xFF,
                data & 0xFF,
            ]
        )
    )


def make_read_packet(addr: int) -> bytes:
    return escape_cli_payload(
        bytes(
            [
                CMD_READ,
                (addr >> 16) & 0x1F,
                (addr >> 8) & 0xFF,
                addr & 0xFF,
            ]
        )
    )


def select_host_source(client: ByteClient, settle_ms: int) -> None:
    for _ in range(HOST_SOURCE_NEXT_COUNT):
        write_exact(client, CMD_NEXT_SRC)
        time.sleep(settle_ms / 1000.0)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Send embedded SDRAM host-interface commands over UART log transport."
    )
    parser.add_argument(
        "--transport",
        choices=["serial", "tcp"],
        default="tcp",
        help="transport used to reach uart_log_cli",
    )
    parser.add_argument("--tcp-host", default="192.168.10.40")
    parser.add_argument("--tcp-port", type=int, default=2323)
    parser.add_argument("--port", default=None, help="serial port such as COM5")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument(
        "--settle-ms",
        type=int,
        default=100,
        help="wait time between source-select bytes",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("select-host", help="send Ctrl+F twice to select SDRAM host source")

    parser_write = subparsers.add_parser("write", help="send one SDRAM host write command")
    parser_write.add_argument("addr", type=parse_u21)
    parser_write.add_argument("data", type=parse_u32)
    parser_write.add_argument(
        "--select-host",
        action="store_true",
        help="select SDRAM host source before sending the command",
    )

    parser_read = subparsers.add_parser("read", help="send one SDRAM host read command")
    parser_read.add_argument("addr", type=parse_u21)
    parser_read.add_argument(
        "--select-host",
        action="store_true",
        help="select SDRAM host source before sending the command",
    )

    return parser


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()

    client = connect_client(args)
    try:
        if args.command == "select-host":
            select_host_source(client, args.settle_ms)
            print("sent host-source select sequence")
            return 0

        if getattr(args, "select_host", False):
            select_host_source(client, args.settle_ms)

        if args.command == "write":
            payload = make_write_packet(args.addr, args.data)
            write_exact(client, payload)
            print(f"sent WRITE addr=0x{args.addr:05X} data=0x{args.data:08X}")
            return 0

        if args.command == "read":
            payload = make_read_packet(args.addr)
            write_exact(client, payload)
            print(f"sent READ addr=0x{args.addr:05X}")
            return 0

        raise SystemExit(f"unsupported command: {args.command}")
    finally:
        client.disconnect()


if __name__ == "__main__":
    raise SystemExit(main())
