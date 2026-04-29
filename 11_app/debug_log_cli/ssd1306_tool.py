"""Host-side CLI for the SSD1306 UART ASCII + raw bulk protocol."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Protocol

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    Image = None
    ImageDraw = None
    ImageFont = None


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
    HOST_SRC_ID as SDRAM_HOST_SRC_ID,
    HOST_SRC_INDEX as SDRAM_HOST_SRC_INDEX,
    build_bulk_write_command,
    drain_frames,
    iter_bulk_write_blocks,
    padded_word_count,
    select_source_index,
    wait_for_frame,
    write_exact,
)
from ssd1306_uart_protocol import (  # noqa: E402
    DISP_OP_AUTO_OFF,
    DISP_OP_AUTO_ON,
    DISP_OP_CLEAR,
    DISP_OP_INIT,
    DISP_OP_OFF,
    DISP_OP_ON,
    DISP_OP_REFRESH,
    DISP_OP_SET_FPS,
    EVT_CMD_ACK,
    EVT_CMD_ERR,
    HOST_SRC_ID,
    HOST_SRC_INDEX,
    build_auto_refresh_off_command,
    build_auto_refresh_on_command,
    build_clear_command,
    build_init_command,
    build_off_command,
    build_on_command,
    build_refresh_command,
    build_set_fps_command,
    load_frame_file,
)
from ssd1306_framebuffer import invert_frame  # noqa: E402
from uart_log_protocol import Frame, FrameParser  # noqa: E402
from uart_log_serial import UARTSerialClient  # noqa: E402
from uart_log_tcp import UARTTCPClient  # noqa: E402


class ByteClient(Protocol):
    def read_bytes(self, max_bytes: int = 512) -> bytes: ...
    def write_bytes(self, payload: bytes) -> int: ...
    def disconnect(self) -> None: ...


SAFE_FRAME_WRITE_CHUNK_BYTES = 32
DISPLAY_FRAMEBUFFER_BASE_ADDR = 0x10000


def require_pillow() -> None:
    if Image is None or ImageDraw is None or ImageFont is None:
        raise SystemExit(
            "text rendering requires Pillow; install it in the project venv with '.venv\\Scripts\\python.exe -m pip install pillow'"
        )


def blank_frame(fill: int = 0) -> bytearray:
    return bytearray([0xFF if fill else 0x00] * 512)


def set_pixel(frame: bytearray, x: int, y: int, on: bool) -> None:
    if not (0 <= x < 128 and 0 <= y < 32):
        return
    index = (y // 8) * 128 + x
    mask = 1 << (y & 0x7)
    if on:
        frame[index] |= mask
    else:
        frame[index] &= (~mask) & 0xFF


def build_fill_frame(fill: int) -> bytes:
    return bytes(blank_frame(1 if fill else 0))


def build_rect_frame(x: int, y: int, width: int, height: int, filled: bool) -> bytes:
    frame = blank_frame(0)
    if width <= 0 or height <= 0:
        return bytes(frame)
    x1 = x + width - 1
    y1 = y + height - 1
    if filled:
        for row in range(y, y1 + 1):
            for col in range(x, x1 + 1):
                set_pixel(frame, col, row, True)
    else:
        for col in range(x, x1 + 1):
            set_pixel(frame, col, y, True)
            set_pixel(frame, col, y1, True)
        for row in range(y, y1 + 1):
            set_pixel(frame, x, row, True)
            set_pixel(frame, x1, row, True)
    return bytes(frame)


def build_line_frame(x0: int, y0: int, x1: int, y1: int) -> bytes:
    frame = blank_frame(0)
    delta_x = abs(x1 - x0)
    step_x = 1 if x0 < x1 else -1
    delta_y = -abs(y1 - y0)
    step_y = 1 if y0 < y1 else -1
    err = delta_x + delta_y
    while True:
        set_pixel(frame, x0, y0, True)
        if x0 == x1 and y0 == y1:
            break
        err2 = err * 2
        if err2 >= delta_y:
            err += delta_y
            x0 += step_x
        if err2 <= delta_x:
            err += delta_x
            y0 += step_y
    return bytes(frame)


def frame_from_pil_image(image: "Image.Image") -> bytes:
    frame = blank_frame(0)
    mono = image.convert("1")
    for y in range(32):
        for x in range(128):
            if mono.getpixel((x, y)):
                set_pixel(frame, x, y, True)
    return bytes(frame)


def build_text_frame(x: int, y: int, text: str) -> bytes:
    require_pillow()
    image = Image.new("1", (128, 32), 0)
    draw = ImageDraw.Draw(image)
    font = ImageFont.load_default()
    draw.text((x, y), text, fill=1, font=font)
    return frame_from_pil_image(image)


def send_frame_blob(
    client: ByteClient,
    parser: FrameParser,
    timeout_s: float,
    blob: bytes,
    *,
    label: str,
) -> int:
    select_source(client, parser, SDRAM_HOST_SRC_INDEX, timeout_s)
    drain_frames(lambda: client.read_bytes(), parser, 0.1)

    blocks = iter_bulk_write_blocks(blob, chunk_bytes=SAFE_FRAME_WRITE_CHUNK_BYTES)
    word_count = padded_word_count(len(blob))
    write_exact(
        client.write_bytes,
        build_bulk_write_command(DISPLAY_FRAMEBUFFER_BASE_ADDR, word_count),
    )
    accept = wait_for_sdram_result(client, parser, timeout_s, HOST_EVT_BULK_OK)
    if accept.event.event_id != HOST_EVT_BULK_OK:
        print(
            f"{label}_ACCEPT_FAIL evt=0x{accept.event.event_id:02X} "
            f"arg0=0x{accept.event.arg0:08X} arg1=0x{accept.event.arg1:08X}"
        )
        return 1

    for block in blocks[:-1]:
        write_exact(client.write_bytes, block)
        progress = wait_for_sdram_result(client, parser, timeout_s, HOST_EVT_BULK_PROGRESS)
        if progress.event.event_id != HOST_EVT_BULK_PROGRESS:
            print(
                f"{label}_WRITE_FAIL evt=0x{progress.event.event_id:02X} "
                f"arg0=0x{progress.event.arg0:08X} arg1=0x{progress.event.arg1:08X}"
            )
            return 1

    write_exact(client.write_bytes, blocks[-1])
    terminal = wait_for_sdram_result(client, parser, timeout_s, HOST_EVT_BULK_DONE)
    if terminal.event.event_id != HOST_EVT_BULK_DONE:
        print(
            f"{label}_DONE_FAIL evt=0x{terminal.event.event_id:02X} "
            f"arg0=0x{terminal.event.arg0:08X} arg1=0x{terminal.event.arg1:08X}"
        )
        return 1

    select_source(client, parser, HOST_SRC_INDEX, timeout_s)
    drain_frames(lambda: client.read_bytes(), parser, 0.1)
    write_exact(client.write_bytes, build_refresh_command())
    refresh = wait_for_display_result(
        client,
        parser,
        timeout_s,
        EVT_CMD_ACK,
        expected_arg0_low4=DISP_OP_REFRESH,
    )
    if refresh.event.event_id != EVT_CMD_ACK:
        print(
            f"{label}_REFRESH_FAIL evt=0x{refresh.event.event_id:02X} "
            f"reason=0x{refresh.event.arg0:08X} detail=0x{refresh.event.arg1:08X} "
            f"op=0x{refresh.event.arg2:08X}"
        )
        return 1

    print(f"{label}_DONE words={word_count} fps={refresh.event.arg1 & 0xFF}")
    return 0


def select_source(
    client: ByteClient,
    parser: FrameParser,
    source_index: int,
    timeout_s: float,
) -> None:
    try:
        select_source_index(
            client.write_bytes,
            lambda: client.read_bytes(),
            parser,
            source_index,
            settle_ms=100,
            timeout_s=timeout_s,
        )
    except TimeoutError:
        print(
            f"warning: source-select confirmation timed out for index {source_index}; proceeding anyway",
            file=sys.stderr,
        )


def wait_for_sdram_result(
    client: ByteClient,
    parser: FrameParser,
    timeout_s: float,
    ok_event_id: int,
) -> Frame:
    return wait_for_frame(
        lambda: client.read_bytes(),
        parser,
        timeout_s,
        lambda frame: frame.event.src_id == SDRAM_HOST_SRC_ID
        and (frame.event.event_id == ok_event_id or frame.event.event_id in (HOST_EVT_BULK_ERR, HOST_EVT_BULK_ABORT)),
    )


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
    expected_arg0_low4: int | None = None,
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
                    expected_arg0_low4 is None
                    or (frame.event.arg0 & 0xF) == expected_arg0_low4
                )
            )
            or frame.event.event_id == EVT_CMD_ERR
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

    parser_refresh = subparsers.add_parser("refresh")
    parser_refresh.add_argument("--select-display", action="store_true")

    parser_auto_on = subparsers.add_parser("auto-on")
    parser_auto_on.add_argument("--select-display", action="store_true")

    parser_auto_off = subparsers.add_parser("auto-off")
    parser_auto_off.add_argument("--select-display", action="store_true")

    parser_fps = subparsers.add_parser("fps")
    parser_fps.add_argument("value", type=int)
    parser_fps.add_argument("--select-display", action="store_true")

    parser_pattern = subparsers.add_parser("pattern")
    parser_pattern.add_argument("--select-display", action="store_true")

    parser_fill = subparsers.add_parser("fill")
    parser_fill.add_argument("value", type=int, choices=[0, 1])
    parser_fill.add_argument("--select-display", action="store_true")

    parser_line = subparsers.add_parser("line")
    parser_line.add_argument("x0", type=int)
    parser_line.add_argument("y0", type=int)
    parser_line.add_argument("x1", type=int)
    parser_line.add_argument("y1", type=int)
    parser_line.add_argument("--select-display", action="store_true")

    parser_rect = subparsers.add_parser("rect")
    parser_rect.add_argument("x", type=int)
    parser_rect.add_argument("y", type=int)
    parser_rect.add_argument("width", type=int)
    parser_rect.add_argument("height", type=int)
    parser_rect.add_argument("--fill", action="store_true")
    parser_rect.add_argument("--select-display", action="store_true")

    parser_text = subparsers.add_parser("text")
    parser_text.add_argument("x", type=int)
    parser_text.add_argument("y", type=int)
    parser_text.add_argument("text")
    parser_text.add_argument("--select-display", action="store_true")

    parser_invert = subparsers.add_parser("invert-file")
    parser_invert.add_argument("path")
    parser_invert.add_argument("--select-display", action="store_true")

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
                expected_arg0_low4=DISP_OP_INIT,
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
                expected_arg0_low4=DISP_OP_ON,
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
                expected_arg0_low4=DISP_OP_OFF,
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
                expected_arg0_low4=DISP_OP_CLEAR,
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

        if args.command == "refresh":
            write_exact(client.write_bytes, build_refresh_command())
            frame = wait_for_display_result(
                client,
                parser,
                args.timeout_s,
                EVT_CMD_ACK,
                expected_arg0_low4=DISP_OP_REFRESH,
            )
            if frame.event.event_id != EVT_CMD_ACK:
                print(
                    f"REFRESH_FAIL evt=0x{frame.event.event_id:02X} "
                    f"reason=0x{frame.event.arg0:08X} detail=0x{frame.event.arg1:08X} "
                    f"op=0x{frame.event.arg2:08X}"
                )
                return 1
            print(f"REFRESH_ACK fps={frame.event.arg1 & 0xFF}")
            return 0

        if args.command == "auto-on":
            write_exact(client.write_bytes, build_auto_refresh_on_command())
            frame = wait_for_display_result(
                client,
                parser,
                args.timeout_s,
                EVT_CMD_ACK,
                expected_arg0_low4=DISP_OP_AUTO_ON,
            )
            if frame.event.event_id != EVT_CMD_ACK:
                print(
                    f"AUTO_ON_FAIL evt=0x{frame.event.event_id:02X} "
                    f"reason=0x{frame.event.arg0:08X} detail=0x{frame.event.arg1:08X} "
                    f"op=0x{frame.event.arg2:08X}"
                )
                return 1
            print(f"AUTO_ON_ACK fps={frame.event.arg1 & 0xFF}")
            return 0

        if args.command == "auto-off":
            write_exact(client.write_bytes, build_auto_refresh_off_command())
            frame = wait_for_display_result(
                client,
                parser,
                args.timeout_s,
                EVT_CMD_ACK,
                expected_arg0_low4=DISP_OP_AUTO_OFF,
            )
            if frame.event.event_id != EVT_CMD_ACK:
                print(
                    f"AUTO_OFF_FAIL evt=0x{frame.event.event_id:02X} "
                    f"reason=0x{frame.event.arg0:08X} detail=0x{frame.event.arg1:08X} "
                    f"op=0x{frame.event.arg2:08X}"
                )
                return 1
            print(f"AUTO_OFF_ACK fps={frame.event.arg1 & 0xFF}")
            return 0

        if args.command == "fps":
            write_exact(client.write_bytes, build_set_fps_command(args.value))
            frame = wait_for_display_result(
                client,
                parser,
                args.timeout_s,
                EVT_CMD_ACK,
                expected_arg0_low4=DISP_OP_SET_FPS,
            )
            if frame.event.event_id != EVT_CMD_ACK:
                print(
                    f"FPS_FAIL evt=0x{frame.event.event_id:02X} "
                    f"reason=0x{frame.event.arg0:08X} detail=0x{frame.event.arg1:08X} "
                    f"op=0x{frame.event.arg2:08X}"
                )
                return 1
            print(f"FPS_ACK value={frame.event.arg1 & 0xFF} period={frame.event.arg2}")
            return 0

        if args.command in ("pattern", "frame-write", "fill", "line", "rect", "text", "invert-file"):
            if args.command == "pattern":
                blob = build_checker_frame()
                label = "PATTERN"
            elif args.command == "frame-write":
                blob = load_frame_file(args.path)
                label = "FRAME_WRITE"
            elif args.command == "fill":
                blob = build_fill_frame(args.value)
                label = "FILL"
            elif args.command == "line":
                blob = build_line_frame(args.x0, args.y0, args.x1, args.y1)
                label = "LINE"
            elif args.command == "rect":
                blob = build_rect_frame(args.x, args.y, args.width, args.height, args.fill)
                label = "RECT"
            elif args.command == "invert-file":
                blob = invert_frame(load_frame_file(args.path))
                label = "INVERT"
            else:
                blob = build_text_frame(args.x, args.y, args.text)
                label = "TEXT"
            return send_frame_blob(client, parser, args.timeout_s, blob, label=label)

        raise AssertionError(f"unhandled command: {args.command}")
    finally:
        client.disconnect()


if __name__ == "__main__":
    raise SystemExit(main())