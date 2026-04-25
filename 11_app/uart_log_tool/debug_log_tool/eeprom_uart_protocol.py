"""Shared EEPROM UART host protocol helpers."""

from __future__ import annotations

from dataclasses import dataclass

from sdram_uart_protocol import (
    build_bulk_abort_block,
    drain_frames,
    iter_bulk_write_blocks,
    load_bulk_file,
    save_bulk_file,
    select_source_index,
    write_exact,
)


HOST_SRC_INDEX = 0
UART_LOG_NUM_SRC = 4
HOST_SRC_ID = 0x01

HOST_EVT_WRITE_ACK = 0x30
HOST_EVT_READ_RSP = 0x31
HOST_EVT_BULK_OK = 0x32
HOST_EVT_BULK_ERR = 0x33
HOST_EVT_BULK_PROGRESS = 0x34
HOST_EVT_BULK_DONE = 0x35
HOST_EVT_BULK_ABORT = 0x36
HOST_EVT_CMD_ERR = 0x3E

CMD_READ = "R"
CMD_WRITE = "W"
CMD_BULK_READ = "BR"
CMD_BULK_WRITE = "BW"

EEPROM_MAX_ADDR = 0x1FFFF
MAX_BULK_BYTE_COUNT = EEPROM_MAX_ADDR


@dataclass(frozen=True)
class BulkReadProgress:
    base_addr: int
    valid_byte_count: int
    data: bytes


def parse_addr(text: str) -> int:
    value = int(text, 0)
    if value < 0 or value > EEPROM_MAX_ADDR:
        raise ValueError(f"out of range EEPROM addr: {text}")
    return value


def parse_data_byte(text: str) -> int:
    value = int(text, 0)
    if value < 0 or value > 0xFF:
        raise ValueError(f"out of range EEPROM data byte: {text}")
    return value


def validate_bulk_range(addr: int, byte_count: int) -> None:
    if addr < 0 or addr > EEPROM_MAX_ADDR:
        raise ValueError(f"bulk addr out of range: 0x{addr:X}")
    if byte_count < 1 or byte_count > MAX_BULK_BYTE_COUNT:
        raise ValueError(
            f"bulk byte count out of range 1..{MAX_BULK_BYTE_COUNT}: {byte_count}"
        )
    if addr + byte_count - 1 > EEPROM_MAX_ADDR:
        raise ValueError("bulk range exceeds EEPROM address space")


def build_ascii_command(command: str, *fields: int) -> bytes:
    parts = [command]
    for index, field in enumerate(fields):
        if index == 0:
            parts.append(f"{field:05X}")
        elif command in (CMD_BULK_READ, CMD_BULK_WRITE):
            parts.append(f"{field:05X}")
        else:
            parts.append(f"{field & 0xFF:02X}")
    return (" ".join(parts) + "\n").encode("ascii")


def build_read_command(addr: int) -> bytes:
    return build_ascii_command(CMD_READ, addr)


def build_write_command(addr: int, data: int) -> bytes:
    return build_ascii_command(CMD_WRITE, addr, data & 0xFF)


def build_bulk_read_command(addr: int, byte_count: int) -> bytes:
    return build_ascii_command(CMD_BULK_READ, addr, byte_count)


def build_bulk_write_command(addr: int, byte_count: int) -> bytes:
    return build_ascii_command(CMD_BULK_WRITE, addr, byte_count)


def decode_bulk_read_progress(arg0: int, arg1: int, arg2: int) -> BulkReadProgress:
    valid_byte_count = (arg0 >> 17) & 0xFF
    base_addr = arg0 & EEPROM_MAX_ADDR
    if valid_byte_count < 1 or valid_byte_count > 8:
        raise ValueError(f"invalid bulk read byte count in arg0: 0x{arg0:08X}")

    payload = (
        (arg1 & 0xFFFF_FFFF).to_bytes(4, "little")
        + (arg2 & 0xFFFF_FFFF).to_bytes(4, "little")
    )
    return BulkReadProgress(
        base_addr=base_addr,
        valid_byte_count=valid_byte_count,
        data=payload[:valid_byte_count],
    )