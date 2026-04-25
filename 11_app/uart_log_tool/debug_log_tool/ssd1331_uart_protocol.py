"""Shared SSD1331 UART host protocol helpers."""

from __future__ import annotations


HOST_SRC_INDEX = 3
UART_LOG_NUM_SRC = 4
HOST_SRC_ID = 0x04

EVT_CMD_ACK = 0x30
EVT_CMD_ERR = 0x3E

DISP_OP_INIT = 0
DISP_OP_CLEAR = 1
DISP_OP_FILL = 2
DISP_OP_PATTERN = 3
DISP_OP_ON = 4
DISP_OP_OFF = 5


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


def build_pattern_command() -> bytes:
    return b"P\n"


def build_on_command() -> bytes:
    return b"O\n"


def build_off_command() -> bytes:
    return b"X\n"


def build_fill_command(rgb888: int) -> bytes:
    return f"F {rgb888 & 0xFFFFFF:06X}\n".encode("ascii")