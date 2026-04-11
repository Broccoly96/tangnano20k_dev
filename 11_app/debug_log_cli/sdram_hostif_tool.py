"""Host-side CLI for the SDRAM UART ASCII + raw bulk protocol."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Protocol


SCRIPT_DIR = Path(__file__).resolve().parent
TOOL_DIR = SCRIPT_DIR.parent / "uart_log_tool" / "debug_log_tool"
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from sdram_uart_protocol import (  # noqa: E402
    HOST_EVT_BULK_ABORT,
    HOST_EVT_BULK_DONE,
    HOST_EVT_BULK_ERR,
    HOST_EVT_BULK_OK,
    HOST_EVT_CMD_ERR,
    HOST_EVT_READ_RSP,
    HOST_EVT_WRITE_ACK,
    build_bulk_read_command,
    build_bulk_write_command,
    build_read_command,
    build_write_command,
    iter_bulk_write_blocks,
    parse_u21,
    parse_u32,
    recv_bulk_read_blob,
    drain_frames,
    select_source_index,
    select_host_source,
    wait_for_frame,
    write_exact,
)
from uart_log_protocol import Frame, FrameParser  # noqa: E402
from uart_log_serial import UARTSerialClient  # noqa: E402
from uart_log_tcp import UARTTCPClient  # noqa: E402


class ByteClient(Protocol):
    def read_bytes(self, max_bytes: int = 512) -> bytes: ...
    def write_bytes(self, payload: bytes) -> int: ...
    def disconnect(self) -> None: ...


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


def wait_for_host_event(
    client: ByteClient,
    parser: FrameParser,
    timeout_s: float,
    event_id: int,
    *,
    addr: int | None = None,
) -> Frame:
    return wait_for_frame(
        lambda: client.read_bytes(),
        parser,
        timeout_s,
        lambda frame: frame.event.src_id == 0x03
        and frame.event.event_id == event_id
        and (addr is None or (frame.event.arg0 & 0x1F_FFFF) == addr),
    )


def wait_for_bulk_terminal_event(
    client: ByteClient,
    parser: FrameParser,
    timeout_s: float,
) -> Frame:
    return wait_for_frame(
        lambda: client.read_bytes(),
        parser,
        timeout_s,
        lambda frame: frame.event.src_id == 0x03
        and frame.event.event_id in (HOST_EVT_BULK_DONE, HOST_EVT_BULK_ABORT, HOST_EVT_BULK_ERR),
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Send SDRAM host-interface commands over uart_log_cli."
    )
    parser.add_argument("--transport", choices=["serial", "tcp"], default="tcp")
    parser.add_argument("--tcp-host", default="192.168.10.40")
    parser.add_argument("--tcp-port", type=int, default=2323)
    parser.add_argument("--port", default=None)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--settle-ms", type=int, default=100)
    parser.add_argument("--timeout-s", type=float, default=5.0)

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("select-host")

    parser_write = subparsers.add_parser("write")
    parser_write.add_argument("addr", type=parse_u21)
    parser_write.add_argument("data", type=parse_u32)
    parser_write.add_argument("--select-host", action="store_true")

    parser_read = subparsers.add_parser("read")
    parser_read.add_argument("addr", type=parse_u21)
    parser_read.add_argument("--select-host", action="store_true")

    parser_bulk_write = subparsers.add_parser("bulk-write")
    parser_bulk_write.add_argument("addr", type=parse_u21)
    parser_bulk_write.add_argument("path")
    parser_bulk_write.add_argument("--select-host", action="store_true")

    parser_bulk_read = subparsers.add_parser("bulk-read")
    parser_bulk_read.add_argument("addr", type=parse_u21)
    parser_bulk_read.add_argument("words", type=parse_u21)
    parser_bulk_read.add_argument("path")
    parser_bulk_read.add_argument("--select-host", action="store_true")

    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    client = connect_client(args)
    parser = FrameParser()

    try:
      if args.command == "select-host":
        try:
            select_source_index(
                client.write_bytes,
                lambda: client.read_bytes(),
                parser,
                2,
                settle_ms=args.settle_ms,
                timeout_s=args.timeout_s,
            )
        except TimeoutError:
            print("warning: host-source confirmation timed out; source may already be selected", file=sys.stderr)
        print("sent host-source select sequence")
        return 0

      if getattr(args, "select_host", False):
        try:
            select_source_index(
                client.write_bytes,
                lambda: client.read_bytes(),
                parser,
                2,
                settle_ms=args.settle_ms,
                timeout_s=args.timeout_s,
            )
        except TimeoutError:
            print("warning: host-source confirmation timed out; proceeding anyway", file=sys.stderr)

      drain_frames(lambda: client.read_bytes(), parser, 0.2)

      if args.command == "write":
        write_exact(client.write_bytes, build_write_command(args.addr, args.data))
        frame = wait_for_host_event(
            client,
            parser,
            args.timeout_s,
            HOST_EVT_WRITE_ACK,
            addr=args.addr,
        )
        print(
            f"WRITE_ACK addr=0x{frame.event.arg0:05X} data=0x{frame.event.arg1:08X} "
            f"status=0x{frame.event.arg2:08X}"
        )
        return 0

      if args.command == "read":
        write_exact(client.write_bytes, build_read_command(args.addr))
        frame = wait_for_host_event(
            client,
            parser,
            args.timeout_s,
            HOST_EVT_READ_RSP,
            addr=args.addr,
        )
        print(
            f"READ_RSP addr=0x{frame.event.arg0:05X} data=0x{frame.event.arg1:08X} "
            f"status=0x{frame.event.arg2:08X}"
        )
        return 0

      if args.command == "bulk-write":
        print("INOP: bulk path disabled")
        return 1

      if args.command == "bulk-read":
        print("INOP: bulk path disabled")
        return 1

      raise SystemExit(f"unsupported command: {args.command}")
    finally:
      client.disconnect()


if __name__ == "__main__":
    raise SystemExit(main())
