"""Shared SSD1306 UART host protocol helpers."""

from __future__ import annotations

from pathlib import Path

from sdram_uart_protocol import iter_bulk_write_blocks, load_bulk_file
from ssd1306_framebuffer import build_checker_frame as _build_checker_frame
from ssd1306_framebuffer import SSD1306FrameBuffer


HOST_SRC_INDEX = 3
UART_LOG_NUM_SRC = 4
HOST_SRC_ID = 0x04

EVT_CMD_ACK = 0x30
EVT_FRAME_OK = 0x32
EVT_FRAME_ERR = 0x33
EVT_FRAME_PROG = 0x34
EVT_FRAME_DONE = 0x35
EVT_FRAME_ABORT = 0x36
EVT_CMD_ERR = 0x3E

DISP_OP_INIT = 0
DISP_OP_CLEAR = 1
DISP_OP_FRAME_WRITE = 2
DISP_OP_ON = 3
DISP_OP_OFF = 4
DISP_OP_REFRESH = 5
DISP_OP_AUTO_ON = 6
DISP_OP_AUTO_OFF = 7
DISP_OP_SET_FPS = 8

SSD1306_FRAME_BYTES = 512
SSD1306_FRAME_BLOCKS = 8
DISPLAY_FRAMEBUFFER_BASE_ADDR = 0x10000


def parse_rgb888(text: str) -> int:
    value_text = text.strip()
    if value_text.lower().startswith("0x"):
        value_text = value_text[2:]
    if len(value_text) != 6:
        raise ValueError("expected exactly 6 hex digits")
    try:
        value = int(value_text, 16)
    except ValueError as exc:
        raise ValueError("invalid RGB888 hex") from exc
    if value < 0 or value > 0xFFFFFF:
        raise ValueError("RGB888 out of range")
    return value


def build_init_command() -> bytes:
    return b"I\n"


def build_clear_command() -> bytes:
    return b"C\n"


def build_on_command() -> bytes:
    return b"O\n"


def build_off_command() -> bytes:
    return b"X\n"


def build_frame_write_command() -> bytes:
    return b"W\n"


def build_refresh_command() -> bytes:
    return b"R\n"


def build_auto_refresh_on_command() -> bytes:
    return b"E\n"


def build_auto_refresh_off_command() -> bytes:
    return b"D\n"


def build_set_fps_command(fps: int) -> bytes:
    if fps < 1 or fps > 60:
        raise ValueError(f"fps must be in range 1..60, got {fps}")
    return f"F{fps:d}\n".encode("ascii")


def build_checker_frame() -> bytes:
    return _build_checker_frame()


def build_mono_fill_frame(on: bool) -> bytes:
    return SSD1306FrameBuffer.blank(fill=on).to_bytes()


def load_frame_file(path: str | Path) -> bytes:
    blob = load_bulk_file(path)
    if Path(path).suffix.lower() != ".bin":
      raise ValueError("frame-write input must be a .bin file")
    validate_frame_blob(blob)
    return blob


def validate_frame_blob(blob: bytes) -> None:
    if len(blob) != SSD1306_FRAME_BYTES:
        raise ValueError(
            f"frame payload must be exactly {SSD1306_FRAME_BYTES} bytes, got {len(blob)}"
        )


def iter_frame_write_blocks(blob: bytes, *, chunk_bytes: int = 64) -> list[bytes]:
    validate_frame_blob(blob)
    return iter_bulk_write_blocks(blob, chunk_bytes=chunk_bytes)


def decode_frame_progress_arg0(arg0: int) -> tuple[int, int, int]:
    chunk_index = (arg0 >> 24) & 0xFF
    chunk_bytes = (arg0 >> 16) & 0xFF
    total_bytes = arg0 & 0xFFFF
    return chunk_index, chunk_bytes, total_bytes
