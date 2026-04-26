"""Shared SSD1306 UART host protocol helpers."""

from __future__ import annotations

from pathlib import Path

from sdram_uart_protocol import iter_bulk_write_blocks, load_bulk_file


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

SSD1306_FRAME_BYTES = 512
SSD1306_FRAME_BLOCKS = 8


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


def iter_frame_write_blocks(blob: bytes) -> list[bytes]:
    validate_frame_blob(blob)
    return iter_bulk_write_blocks(blob)


def decode_frame_progress_arg0(arg0: int) -> tuple[int, int, int]:
    chunk_index = (arg0 >> 24) & 0xFF
    chunk_bytes = (arg0 >> 16) & 0xFF
    total_bytes = arg0 & 0xFFFF
    return chunk_index, chunk_bytes, total_bytes