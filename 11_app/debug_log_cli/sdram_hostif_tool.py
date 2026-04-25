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
    HOST_EVT_BULK_PROGRESS,
    HOST_EVT_CMD_ERR,
    HOST_EVT_READ_RSP,
    HOST_EVT_WRITE_ACK,
    build_bulk_read_command,
    build_bulk_write_command,
    build_read_command,
    build_status_read_command,
    build_status_write_command,
    build_write_command,
    decode_bulk_read_progress,
    iter_bulk_write_blocks,
    load_bulk_file,
    padded_word_count,
    parse_u21,
    parse_u32,
    recv_bulk_read_words,
    save_bulk_file,
    drain_frames,
    select_source_index,
    select_host_source,
    validate_bulk_range,
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


def wait_for_host_result(
    client: ByteClient,
    parser: FrameParser,
    timeout_s: float,
    ok_event_id: int,
    *,
    addr: int | None = None,
) -> Frame:
    """Wait for a command result, accepting either success or CMD_ERR."""
    return wait_for_frame(
        lambda: client.read_bytes(),
        parser,
        timeout_s,
        lambda frame: frame.event.src_id == 0x03
        and (
            (
                frame.event.event_id == ok_event_id
                and (addr is None or (frame.event.arg0 & 0x1F_FFFF) == addr)
            )
            or (
                frame.event.event_id == HOST_EVT_CMD_ERR
                and (addr is None or (frame.event.arg1 & 0x1F_FFFF) == addr)
            )
        ),
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


def wait_for_bulk_accept(
    client: ByteClient,
    parser: FrameParser,
    timeout_s: float,
    *,
    addr: int,
) -> Frame:
    return wait_for_frame(
        lambda: client.read_bytes(),
        parser,
        timeout_s,
        lambda frame: frame.event.src_id == 0x03
        and (
            (frame.event.event_id == HOST_EVT_BULK_OK and (frame.event.arg0 & 0x1F_FFFF) == addr)
            or frame.event.event_id in (HOST_EVT_BULK_ERR, HOST_EVT_CMD_ERR)
        ),
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

    parser_status_write = subparsers.add_parser("status-write")
    parser_status_write.add_argument("addr", type=parse_u21)
    parser_status_write.add_argument("data", type=parse_u32)
    parser_status_write.add_argument("--select-host", action="store_true")

    parser_status_read = subparsers.add_parser("status-read")
    parser_status_read.add_argument("addr", type=parse_u21)
    parser_status_read.add_argument("--select-host", action="store_true")

    parser_selftest = subparsers.add_parser("selftest")
    parser_selftest.add_argument("--select-host", action="store_true")

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
        frame = wait_for_host_result(
            client,
            parser,
            args.timeout_s,
            HOST_EVT_WRITE_ACK,
            addr=args.addr,
        )
        if frame.event.event_id == HOST_EVT_CMD_ERR:
            print(
                f"CMD_ERR reason=0x{frame.event.arg0:08X} addr=0x{frame.event.arg1:05X} "
                f"detail=0x{frame.event.arg2:08X}"
            )
            return 1
        print(
            f"WRITE_ACK addr=0x{frame.event.arg0:05X} data=0x{frame.event.arg1:08X} "
            f"status=0x{frame.event.arg2:08X}"
        )
        return 0

      if args.command == "read":
        write_exact(client.write_bytes, build_read_command(args.addr))
        frame = wait_for_host_result(
            client,
            parser,
            args.timeout_s,
            HOST_EVT_READ_RSP,
            addr=args.addr,
        )
        if frame.event.event_id == HOST_EVT_CMD_ERR:
            print(
                f"CMD_ERR reason=0x{frame.event.arg0:08X} addr=0x{frame.event.arg1:05X} "
                f"detail=0x{frame.event.arg2:08X}"
            )
            return 1
        print(
            f"READ_RSP addr=0x{frame.event.arg0:05X} data=0x{frame.event.arg1:08X} "
            f"status=0x{frame.event.arg2:08X}"
        )
        return 0

      if args.command == "status-write":
        write_exact(client.write_bytes, build_status_write_command(args.addr, args.data))
        frame = wait_for_host_result(
            client,
            parser,
            args.timeout_s,
            HOST_EVT_WRITE_ACK,
            addr=args.addr,
        )
        if frame.event.event_id == HOST_EVT_CMD_ERR:
            print(
                f"CMD_ERR reason=0x{frame.event.arg0:08X} addr=0x{frame.event.arg1:05X} "
                f"detail=0x{frame.event.arg2:08X}"
            )
            return 1
        print(
            f"STATUS_WRITE_ACK addr=0x{frame.event.arg0:05X} data=0x{frame.event.arg1:08X} "
            f"status=0x{frame.event.arg2:08X}"
        )
        return 0

      if args.command == "status-read":
        write_exact(client.write_bytes, build_status_read_command(args.addr))
        frame = wait_for_host_result(
            client,
            parser,
            args.timeout_s,
            HOST_EVT_READ_RSP,
            addr=args.addr,
        )
        if frame.event.event_id == HOST_EVT_CMD_ERR:
            print(
                f"CMD_ERR reason=0x{frame.event.arg0:08X} addr=0x{frame.event.arg1:05X} "
                f"detail=0x{frame.event.arg2:08X}"
            )
            return 1
        print(
            f"STATUS_READ_RSP addr=0x{frame.event.arg0:05X} data=0x{frame.event.arg1:08X} "
            f"status=0x{frame.event.arg2:08X}"
        )
        return 0

      if args.command == "selftest":
        write_exact(client.write_bytes, build_status_write_command(0x0003C, 0x0000_0001))
        frame = wait_for_host_result(
            client,
            parser,
            args.timeout_s,
            HOST_EVT_WRITE_ACK,
            addr=0x0003C,
        )
        if frame.event.event_id == HOST_EVT_CMD_ERR:
            print(
                f"CMD_ERR reason=0x{frame.event.arg0:08X} addr=0x{frame.event.arg1:05X} "
                f"detail=0x{frame.event.arg2:08X}"
            )
            return 1
        print(
            f"SELFTEST_ACK addr=0x{frame.event.arg0:05X} data=0x{frame.event.arg1:08X} "
            f"status=0x{frame.event.arg2:08X}"
        )
        return 0

      if args.command == "bulk-write":
        blob = load_bulk_file(args.path)
        if not blob:
            print("bulk-write rejected: input file is empty", file=sys.stderr)
            return 1

        words = padded_word_count(len(blob))
        validate_bulk_range(args.addr, words)
        pad_bytes = words * 4 - len(blob)
        blocks = iter_bulk_write_blocks(blob)

        write_exact(client.write_bytes, build_bulk_write_command(args.addr, words))
        accept = wait_for_bulk_accept(
            client,
            parser,
            args.timeout_s,
            addr=args.addr,
        )
        if accept.event.event_id != HOST_EVT_BULK_OK:
            print(
                f"BULK_WRITE_REJECT evt=0x{accept.event.event_id:02X} "
                f"reason=0x{accept.event.arg0:08X} arg1=0x{accept.event.arg1:08X} "
                f"arg2=0x{accept.event.arg2:08X}",
                file=sys.stderr,
            )
            return 1

        data_block_count = max(0, len(blocks) - 1)
        for block_index, block in enumerate(blocks):
            write_exact(client.write_bytes, block)
            is_end_block = block_index == len(blocks) - 1
            if is_end_block:
                break
            progress = wait_for_frame(
                lambda: client.read_bytes(),
                parser,
                args.timeout_s,
                lambda frame: frame.event.src_id == 0x03
                and frame.event.event_id in (HOST_EVT_BULK_PROGRESS, HOST_EVT_BULK_ABORT, HOST_EVT_BULK_ERR),
            )
            if progress.event.event_id != HOST_EVT_BULK_PROGRESS:
                print(
                    f"BULK_WRITE_FAIL evt=0x{progress.event.event_id:02X} "
                    f"reason=0x{progress.event.arg0:08X} arg1=0x{progress.event.arg1:08X} "
                    f"arg2=0x{progress.event.arg2:08X}",
                    file=sys.stderr,
                )
                return 1
            print(
                f"BULK_WRITE_PROGRESS chunk={block_index + 1}/{data_block_count} "
                f"addr=0x{progress.event.arg0 & 0x1F_FFFF:05X} "
                f"completed={progress.event.arg1} remaining={progress.event.arg2}"
            )

        terminal = wait_for_bulk_terminal_event(client, parser, args.timeout_s)
        if terminal.event.event_id != HOST_EVT_BULK_DONE:
            print(
                f"BULK_WRITE_FAIL evt=0x{terminal.event.event_id:02X} "
                f"reason=0x{terminal.event.arg0:08X} arg1=0x{terminal.event.arg1:08X} "
                f"arg2=0x{terminal.event.arg2:08X}",
                file=sys.stderr,
            )
            return 1
        print(
            f"BULK_WRITE_DONE addr=0x{args.addr:05X} words={words} bytes={len(blob)} pad={pad_bytes}"
        )
        return 0

      if args.command == "bulk-read":
        validate_bulk_range(args.addr, args.words)
        output_path = Path(args.path)
        if output_path.suffix.lower() not in {".bin", ".hex"}:
            print("bulk-read rejected: output path must end with .bin or .hex", file=sys.stderr)
            return 1

        write_exact(client.write_bytes, build_bulk_read_command(args.addr, args.words))
        accept = wait_for_bulk_accept(
            client,
            parser,
            args.timeout_s,
            addr=args.addr,
        )
        if accept.event.event_id != HOST_EVT_BULK_OK:
            print(
                f"BULK_READ_REJECT evt=0x{accept.event.event_id:02X} "
                f"reason=0x{accept.event.arg0:08X} arg1=0x{accept.event.arg1:08X} "
                f"arg2=0x{accept.event.arg2:08X}",
                file=sys.stderr,
            )
            return 1

        blob = recv_bulk_read_words(
            lambda: client.read_bytes(),
            parser,
            args.timeout_s,
            addr=args.addr,
            words=args.words,
        )
        save_bulk_file(output_path, blob)
        preview = decode_bulk_read_progress(
            ((min(args.words, 2) & 0x3) << 21) | (args.addr & 0x1F_FFFF),
            int.from_bytes(blob[0:4].ljust(4, b"\x00"), "little"),
            int.from_bytes(blob[4:8].ljust(4, b"\x00"), "little"),
        )
        print(
            f"BULK_READ_DONE addr=0x{args.addr:05X} words={args.words} bytes={len(blob)} "
            f"saved={output_path} first_addr=0x{preview.base_addr:05X}"
        )
        return 0

      raise SystemExit(f"unsupported command: {args.command}")
    finally:
      client.disconnect()


if __name__ == "__main__":
    raise SystemExit(main())
