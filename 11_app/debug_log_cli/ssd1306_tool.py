"""Host-side CLI for the SSD1306 UART ASCII + raw bulk protocol."""

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
    drain_frames,
    select_source_index,
    wait_for_frame,
    write_exact,
)
from ssd1306_uart_protocol import (  # noqa: E402
    DISP_OP_CLEAR,
    DISP_OP_FRAME_WRITE,
    DISP_OP_INIT,
    DISP_OP_OFF,
    DISP_OP_ON,
    EVT_CMD_ACK,
    EVT_CMD_ERR,
    EVT_FRAME_ABORT,
    EVT_FRAME_DONE,
    EVT_FRAME_ERR,
    EVT_FRAME_OK,
    EVT_FRAME_PROG,
    HOST_SRC_ID,
    HOST_SRC_INDEX,
    build_clear_command,
    build_frame_write_command,
    build_init_command,
    build_off_command,
    build_on_command,
    decode_frame_progress_arg0,
    iter_frame_write_blocks,
    load_frame_file,
)
from uart_log_protocol import Frame, FrameParser  # noqa: E402
from uart_log_serial import UARTSerialClient  # noqa: E402
from uart_log_tcp import UARTTCPClient  # noqa: E402


class ByteClient(Protocol):
    def read_bytes(self, max_bytes: int = 512) -> bytes: ...
    def write_bytes(self, payload: bytes) -> int: ...
    def disconnect(self) -> None: ...


def build_checker_frame() -> bytes:
    frame = bytearray(512)
    for page in range(4):
        for column in range(128):
            frame[(page * 128) + column] = 0xAA if ((page + column) & 1) == 0 else 0x55
    return bytes(frame)


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


def wait_for_display_result(
    client: ByteClient,
    parser: FrameParser,
    timeout_s: float,
    ok_event_id: int,
    *,
    expected_arg0_low3: int | None = None,
) -> Frame:
    return wait_for_frame(
        lambda: client.read_bytes(),
        parser,
        timeout_s,
        lambda frame: frame.event.src_id == HOST_SRC_ID
        and (
            (
                frame.event.event_id == ok_event_id
                and (
                    expected_arg0_low3 is None
                    or (frame.event.arg0 & 0x7) == expected_arg0_low3
                )
            )
            or frame.event.event_id in (EVT_CMD_ERR, EVT_FRAME_ERR, EVT_FRAME_ABORT)
        ),
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Send SSD1306 display commands over uart_log_cli."
    )
    parser.add_argument("--transport", choices=["serial", "tcp"], default="tcp")
    parser.add_argument("--tcp-host", default="192.168.10.40")
    parser.add_argument("--tcp-port", type=int, default=2323)
    parser.add_argument("--port", default=None)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--settle-ms", type=int, default=100)
    parser.add_argument("--timeout-s", type=float, default=5.0)

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("select-display")

    parser_init = subparsers.add_parser("init")
    parser_init.add_argument("--select-display", action="store_true")

    parser_on = subparsers.add_parser("on")
    parser_on.add_argument("--select-display", action="store_true")

    parser_off = subparsers.add_parser("off")
    parser_off.add_argument("--select-display", action="store_true")

    parser_clear = subparsers.add_parser("clear")
    parser_clear.add_argument("--select-display", action="store_true")

    parser_pattern = subparsers.add_parser("pattern")
    parser_pattern.add_argument("--select-display", action="store_true")

    parser_frame = subparsers.add_parser("frame-write")
    parser_frame.add_argument("path")
    parser_frame.add_argument("--select-display", action="store_true")

    return parser


def maybe_select_display(
    client: ByteClient,
    parser: FrameParser,
    args: argparse.Namespace,
) -> None:
    if not getattr(args, "select_display", False):
        return
    try:
        select_source_index(
            client.write_bytes,
            lambda: client.read_bytes(),
            parser,
            HOST_SRC_INDEX,
            settle_ms=args.settle_ms,
            timeout_s=args.timeout_s,
        )
    except TimeoutError:
        print("warning: display-source confirmation timed out; proceeding anyway", file=sys.stderr)


def main() -> int:
    args = build_arg_parser().parse_args()
    client = connect_client(args)
    parser = FrameParser()

    try:
        if args.command == "select-display":
            try:
                select_source_index(
                    client.write_bytes,
                    lambda: client.read_bytes(),
                    parser,
                    HOST_SRC_INDEX,
                    settle_ms=args.settle_ms,
                    timeout_s=args.timeout_s,
                )
            except TimeoutError:
                print("warning: display-source confirmation timed out; source may already be selected", file=sys.stderr)
            print("sent display-source select sequence")
            return 0

        maybe_select_display(client, parser, args)
        drain_frames(lambda: client.read_bytes(), parser, 0.2)

        if args.command == "init":
            write_exact(client.write_bytes, build_init_command())
            frame = wait_for_display_result(
                client,
                parser,
                args.timeout_s,
                EVT_CMD_ACK,
                expected_arg0_low3=DISP_OP_INIT,
            )
            if frame.event.event_id != EVT_CMD_ACK:
                print(
                    f"INIT_FAIL evt=0x{frame.event.event_id:02X} "
                    f"reason=0x{frame.event.arg0:08X} detail=0x{frame.event.arg1:08X} "
                    f"op=0x{frame.event.arg2:08X}"
                )
                return 1
            print("INIT_ACK")
            return 0

        if args.command == "on":
            write_exact(client.write_bytes, build_on_command())
            frame = wait_for_display_result(
                client,
                parser,
                args.timeout_s,
                EVT_CMD_ACK,
                expected_arg0_low3=DISP_OP_ON,
            )
            if frame.event.event_id != EVT_CMD_ACK:
                print(
                    f"ON_FAIL evt=0x{frame.event.event_id:02X} "
                    f"reason=0x{frame.event.arg0:08X} detail=0x{frame.event.arg1:08X} "
                    f"op=0x{frame.event.arg2:08X}"
                )
                return 1
            print("DISPLAY_ON_ACK")
            return 0

        if args.command == "off":
            write_exact(client.write_bytes, build_off_command())
            frame = wait_for_display_result(
                client,
                parser,
                args.timeout_s,
                EVT_CMD_ACK,
                expected_arg0_low3=DISP_OP_OFF,
            )
            if frame.event.event_id != EVT_CMD_ACK:
                print(
                    f"OFF_FAIL evt=0x{frame.event.event_id:02X} "
                    f"reason=0x{frame.event.arg0:08X} detail=0x{frame.event.arg1:08X} "
                    f"op=0x{frame.event.arg2:08X}"
                )
                return 1
            print("DISPLAY_OFF_ACK")
            return 0

        if args.command == "clear":
            write_exact(client.write_bytes, build_clear_command())
            frame = wait_for_display_result(
                client,
                parser,
                args.timeout_s,
                EVT_CMD_ACK,
                expected_arg0_low3=DISP_OP_CLEAR,
            )
            if frame.event.event_id != EVT_CMD_ACK:
                print(
                    f"CLEAR_FAIL evt=0x{frame.event.event_id:02X} "
                    f"reason=0x{frame.event.arg0:08X} detail=0x{frame.event.arg1:08X} "
                    f"op=0x{frame.event.arg2:08X}"
                )
                return 1
            print("CLEAR_ACK")
            return 0

        if args.command in ("pattern", "frame-write"):
            blob = build_checker_frame() if args.command == "pattern" else load_frame_file(args.path)
            blocks = iter_frame_write_blocks(blob)

            write_exact(client.write_bytes, build_frame_write_command())
            accept = wait_for_display_result(client, parser, args.timeout_s, EVT_FRAME_OK)
            if accept.event.event_id != EVT_FRAME_OK:
                print(
                    f"FRAME_ACCEPT_FAIL evt=0x{accept.event.event_id:02X} "
                    f"arg0=0x{accept.event.arg0:08X} arg1=0x{accept.event.arg1:08X}"
                )
                return 1

            for block_index, block in enumerate(blocks[:-1]):
                write_exact(client.write_bytes, block)
                progress = wait_for_display_result(client, parser, args.timeout_s, EVT_FRAME_PROG)
                if progress.event.event_id != EVT_FRAME_PROG:
                    print(
                        f"FRAME_WRITE_FAIL evt=0x{progress.event.event_id:02X} "
                        f"arg0=0x{progress.event.arg0:08X}"
                    )
                    return 1
                chunk_index, chunk_bytes, total_bytes = decode_frame_progress_arg0(progress.event.arg0)
                print(
                    f"FRAME_PROGRESS chunk={chunk_index + 1}/{len(blocks) - 1} "
                    f"bytes={chunk_bytes} total={total_bytes}"
                )

            write_exact(client.write_bytes, blocks[-1])
            terminal = wait_for_display_result(client, parser, args.timeout_s, EVT_FRAME_DONE)
            if terminal.event.event_id != EVT_FRAME_DONE:
                print(
                    f"FRAME_DONE_FAIL evt=0x{terminal.event.event_id:02X} "
                    f"arg0=0x{terminal.event.arg0:08X} arg1=0x{terminal.event.arg1:08X}"
                )
                return 1
            if args.command == "pattern":
                print(
                    f"PATTERN_DONE bytes={terminal.event.arg0} blocks={terminal.event.arg1}"
                )
            else:
                print(
                    f"FRAME_WRITE_DONE bytes={terminal.event.arg0} blocks={terminal.event.arg1}"
                )
            return 0

        raise AssertionError(f"unhandled command: {args.command}")
    finally:
        client.disconnect()


if __name__ == "__main__":
    raise SystemExit(main())