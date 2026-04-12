"""Shared SDRAM UART host protocol helpers."""

from __future__ import annotations

from dataclasses import dataclass
import time
from typing import Callable

from uart_log_protocol import Frame, FrameParser


HOST_SRC_INDEX = 2
UART_LOG_NUM_SRC = 3
HOST_SRC_ID = 0x03
SYS_SRC_ID = 0x00
SYS_EVT_MODE_CHANGE = 0x01

HOST_EVT_WRITE_ACK = 0x30
HOST_EVT_READ_RSP = 0x31
HOST_EVT_BULK_OK = 0x32
HOST_EVT_BULK_ERR = 0x33
HOST_EVT_BULK_PROGRESS = 0x34
HOST_EVT_BULK_DONE = 0x35
HOST_EVT_BULK_ABORT = 0x36
HOST_EVT_CMD_ERR = 0x3E

CMD_NEXT_SRC = 0x06
CMD_READ = "R"
CMD_WRITE = "W"
CMD_BULK_READ = "BR"
CMD_BULK_WRITE = "BW"

BULK_SOF0 = 0x55
BULK_SOF1 = 0xAA
BULK_WR_DATA = 0x01
BULK_WR_END = 0x02
BULK_RD_DATA = 0x81
BULK_RD_END = 0x82
BULK_ABORT = 0xE0
MAX_BULK_PAYLOAD_BYTES = 104


def parse_u21(text: str) -> int:
    value = int(text, 0)
    if value < 0 or value > 0x1F_FFFF:
        raise ValueError(f"out of range u21 addr: {text}")
    return value


def parse_u32(text: str) -> int:
    value = int(text, 0)
    if value < 0 or value > 0xFFFF_FFFF:
        raise ValueError(f"out of range u32: {text}")
    return value


def next_src_steps(current_idx: int, target_idx: int, num_src: int = UART_LOG_NUM_SRC) -> int:
    return (target_idx - current_idx) % num_src


def build_ascii_command(command: str, *fields: int) -> bytes:
    parts = [command]
    for field in fields:
      if command in (CMD_BULK_READ, CMD_BULK_WRITE) and len(parts) == 2:
        parts.append(f"{field:05X}")
      elif command in (CMD_BULK_READ, CMD_BULK_WRITE) and len(parts) == 3:
        parts.append(f"{field:05X}")
      elif command == CMD_WRITE and len(parts) == 3:
        parts.append(f"{field:08X}")
      else:
        parts.append(f"{field:05X}")
    return (" ".join(parts) + "\n").encode("ascii")


def build_read_command(addr: int) -> bytes:
    return build_ascii_command(CMD_READ, addr)


def build_write_command(addr: int, data: int) -> bytes:
    return build_ascii_command(CMD_WRITE, addr, data & 0xFFFF_FFFF)


def build_bulk_read_command(addr: int, words: int) -> bytes:
    return build_ascii_command(CMD_BULK_READ, addr, words)


def build_bulk_write_command(addr: int, words: int) -> bytes:
    return build_ascii_command(CMD_BULK_WRITE, addr, words)


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte_value in data:
        crc ^= (byte_value & 0xFF) << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def build_bulk_block(block_type: int, seq: int, payload: bytes = b"") -> bytes:
    payload_len = len(payload)
    if payload_len > MAX_BULK_PAYLOAD_BYTES:
        raise ValueError(f"payload too large: {payload_len}")
    header = bytes(
        [
            BULK_SOF0,
            BULK_SOF1,
            block_type & 0xFF,
            seq & 0xFF,
            payload_len & 0xFF,
            (payload_len >> 8) & 0xFF,
        ]
    )
    crc = crc16_ccitt_false(header[2:] + payload)
    return header + payload + bytes([crc & 0xFF, (crc >> 8) & 0xFF])


def iter_bulk_write_blocks(blob: bytes) -> list[bytes]:
    blocks: list[bytes] = []
    seq = 0
    for offset in range(0, len(blob), MAX_BULK_PAYLOAD_BYTES):
        payload = blob[offset : offset + MAX_BULK_PAYLOAD_BYTES]
        if len(payload) % 4 != 0:
            payload = payload + bytes(4 - (len(payload) % 4))
        blocks.append(build_bulk_block(BULK_WR_DATA, seq, payload))
        seq = (seq + 1) & 0xFF
    blocks.append(build_bulk_block(BULK_WR_END, seq, b""))
    return blocks


@dataclass(frozen=True)
class RawBulkBlock:
    block_type: int
    seq: int
    payload: bytes
    crc_ok: bool


class RawBulkParser:
    """Incremental parser for raw BR/BW bulk blocks."""

    def __init__(self) -> None:
        self._buffer = bytearray()

    def reset(self) -> None:
        self._buffer.clear()

    def feed(self, data: bytes) -> list[RawBulkBlock]:
        if data:
            self._buffer.extend(data)
        blocks: list[RawBulkBlock] = []

        while True:
            try:
                sof_index = self._buffer.index(BULK_SOF0)
            except ValueError:
                self._buffer.clear()
                break

            if sof_index > 0:
                del self._buffer[:sof_index]

            if len(self._buffer) < 8:
                break
            if self._buffer[1] != BULK_SOF1:
                del self._buffer[0]
                continue

            payload_len = self._buffer[4] | (self._buffer[5] << 8)
            block_len = 6 + payload_len + 2
            if len(self._buffer) < block_len:
                break

            block = bytes(self._buffer[:block_len])
            payload = block[6:-2]
            crc_rx = block[-2] | (block[-1] << 8)
            crc_calc = crc16_ccitt_false(block[2:-2])
            blocks.append(
                RawBulkBlock(
                    block_type=block[2],
                    seq=block[3],
                    payload=payload,
                    crc_ok=(crc_rx == crc_calc),
                )
            )
            del self._buffer[:block_len]

        return blocks


def write_exact(write_fn: Callable[[bytes], int], payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = write_fn(payload[offset:])
        if written <= 0:
            raise RuntimeError("short write")
        offset += written


def select_host_source(write_fn: Callable[[bytes], int], settle_ms: int = 100) -> None:
    for _ in range(HOST_SRC_INDEX):
        write_exact(write_fn, bytes([CMD_NEXT_SRC]))
        time.sleep(settle_ms / 1000.0)


def drain_frames(
    read_fn: Callable[[], bytes],
    parser: FrameParser,
    drain_s: float,
) -> list[Frame]:
    """Collect any currently buffered frames for a short drain interval."""

    deadline = time.monotonic() + drain_s
    frames: list[Frame] = []
    while time.monotonic() < deadline:
        data = read_fn()
        if data:
            frames.extend(parser.feed(data))
        time.sleep(0.01)
    return frames


def select_source_index(
    write_fn: Callable[[bytes], int],
    read_fn: Callable[[], bytes],
    parser: FrameParser,
    target_idx: int,
    *,
    num_src: int = UART_LOG_NUM_SRC,
    drain_s: float = 0.2,
    settle_ms: int = 100,
    timeout_s: float = 1.0,
) -> int:
    """Advance source selection until the target mode-change event is seen.

    The CLI only supports "next source", so this helper cycles through the
    source ring and confirms progress using system mode-change events.
    This avoids assuming the current source index after reconnects or resets.
    """

    if target_idx < 0 or target_idx >= num_src:
        raise ValueError(f"target source index out of range: {target_idx}")

    frames = drain_frames(read_fn, parser, drain_s)
    current_idx: int | None = None
    for frame in frames:
        if frame.event.src_id == SYS_SRC_ID and frame.event.event_id == SYS_EVT_MODE_CHANGE:
            current_idx = frame.event.arg1 & 0xFF
    if current_idx == target_idx:
        return target_idx

    deadline = time.monotonic() + timeout_s
    step_window_s = max(drain_s, (settle_ms / 1000.0) * 2.5, 0.25)
    while time.monotonic() < deadline:
        write_exact(write_fn, bytes([CMD_NEXT_SRC]))
        step_deadline = min(deadline, time.monotonic() + step_window_s)
        while time.monotonic() < step_deadline:
            data = read_fn()
            if data:
                for frame in parser.feed(data):
                    if frame.event.src_id != SYS_SRC_ID:
                        continue
                    if frame.event.event_id != SYS_EVT_MODE_CHANGE:
                        continue
                    current_idx = frame.event.arg1 & 0xFF
                    if current_idx == target_idx:
                        return current_idx
            time.sleep(0.01)

    raise TimeoutError(f"timed out selecting source index {target_idx}")


def wait_for_frame(
    read_fn: Callable[[], bytes],
    parser: FrameParser,
    timeout_s: float,
    match_fn: Callable[[Frame], bool],
) -> Frame:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        data = read_fn()
        if data:
            for frame in parser.feed(data):
                if match_fn(frame):
                    return frame
        time.sleep(0.01)
    raise TimeoutError("timed out waiting for frame")


def recv_bulk_read_blob(
    read_fn: Callable[[], bytes],
    timeout_s: float,
) -> bytes:
    parser = RawBulkParser()
    blob = bytearray()
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        data = read_fn()
        if data:
            for block in parser.feed(data):
                if not block.crc_ok:
                    raise RuntimeError("bulk CRC mismatch")
                if block.block_type == BULK_RD_DATA:
                    blob.extend(block.payload)
                elif block.block_type == BULK_RD_END:
                    return bytes(blob)
                elif block.block_type == BULK_ABORT:
                    raise RuntimeError("bulk abort block received")
                else:
                    raise RuntimeError(f"unexpected bulk block type: 0x{block.block_type:02X}")
        time.sleep(0.01)
    raise TimeoutError("timed out waiting for bulk data")
