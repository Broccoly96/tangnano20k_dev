"""Shared SDRAM UART host protocol helpers."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import time
from typing import Callable

from uart_log_protocol import Frame, FrameParser


HOST_SRC_INDEX = 2
UART_LOG_NUM_SRC = 4
HOST_SRC_ID = 0x03
SYS_SRC_ID = 0x00
SYS_EVT_MODE_CHANGE = 0x01

HOST_EVT_WRITE_ACK = 0x30
HOST_EVT_READ_RSP = 0x31
HOST_EVT_BULK_OK = 0x32
HOST_EVT_BULK_ERR = 0x33
HOST_EVT_BULK_PROGRESS = 0x34
HOST_EVT_BURST_ERR = HOST_EVT_BULK_ERR
HOST_EVT_BURST_DATA = HOST_EVT_BULK_PROGRESS
HOST_EVT_BULK_DONE = 0x35
HOST_EVT_BURST_DONE = HOST_EVT_BULK_DONE
HOST_EVT_BULK_ABORT = 0x36
HOST_EVT_CMD_ERR = 0x3E

CMD_PREV_SRC = 0x04
CMD_NEXT_SRC = 0x06
CMD_LITERAL_NEXT = 0x10
CMD_SOFT_RESET = 0x12
CMD_STATUS_REQ = 0x14
CMD_HELP = 0x3F
CMD_READ = "R"
CMD_STATUS_READ = "SR"
CMD_WRITE = "W"
CMD_STATUS_WRITE = "SW"
CMD_BULK_READ = "BR"
CMD_BULK_WRITE = "BW"
CMD_BURST_TEST_READ = "BRT"
CMD_BURST_TEST_WRITE = "BWT"

BULK_SOF0 = 0x55
BULK_SOF1 = 0xAA
BULK_WR_DATA = 0x01
BULK_WR_END = 0x02
BULK_RD_DATA = 0x81
BULK_RD_END = 0x82
BULK_ABORT = 0xE0
MAX_BULK_PAYLOAD_BYTES = 104
MAX_BULK_WRITE_CHUNK_BYTES = 64
SDRAM_MAX_WORD_ADDR = 0x1F_FFFF
MAX_BULK_WORD_COUNT = 0x0F_FFFF

CLI_LITERAL_BYTES = frozenset(
    {
        CMD_PREV_SRC,
        CMD_NEXT_SRC,
        CMD_LITERAL_NEXT,
        CMD_SOFT_RESET,
        CMD_STATUS_REQ,
        CMD_HELP,
    }
)


_PARSER_PENDING_FRAMES: dict[int, list[Frame]] = {}


@dataclass(frozen=True)
class BurstDataPacket:
    packet_id: int
    packet_count: int
    first_word_index: int
    valid_word_count: int
    words: tuple[int, ...]


@dataclass(frozen=True)
class BulkReadProgress:
    base_addr: int
    valid_word_count: int
    words: tuple[int, ...]


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


def validate_bulk_range(addr: int, words: int) -> None:
    if addr < 0 or addr > SDRAM_MAX_WORD_ADDR:
        raise ValueError(f"bulk addr out of range: 0x{addr:X}")
    if words < 1 or words > MAX_BULK_WORD_COUNT:
        raise ValueError(f"bulk words out of range 1..{MAX_BULK_WORD_COUNT}: {words}")
    if addr + words - 1 > SDRAM_MAX_WORD_ADDR:
        raise ValueError("bulk range exceeds SDRAM address space")


def padded_word_count(byte_len: int) -> int:
    if byte_len < 0:
        raise ValueError(f"negative byte length: {byte_len}")
    return (byte_len + 3) // 4


def build_pattern_blob(pattern: int, words: int) -> bytes:
    validate_bulk_range(0, words)
    return (pattern & 0xFFFF_FFFF).to_bytes(4, "little") * words


def next_src_steps(current_idx: int, target_idx: int, num_src: int = UART_LOG_NUM_SRC) -> int:
    return (target_idx - current_idx) % num_src


def build_ascii_command(command: str, *fields: int) -> bytes:
    parts = [command]
    for field in fields:
      if command in (
          CMD_BULK_READ,
          CMD_BULK_WRITE,
          CMD_BURST_TEST_READ,
          CMD_BURST_TEST_WRITE,
      ) and len(parts) == 2:
        parts.append(f"{field:05X}")
      elif command in (
          CMD_BULK_READ,
          CMD_BULK_WRITE,
          CMD_BURST_TEST_READ,
          CMD_BURST_TEST_WRITE,
      ) and len(parts) == 3:
        parts.append(f"{field:05X}")
      elif command in (CMD_WRITE, CMD_STATUS_WRITE) and len(parts) == 2:
        parts.append(f"{field:08X}")
      else:
        parts.append(f"{field:05X}")
    return (" ".join(parts) + "\n").encode("ascii")


def build_read_command(addr: int) -> bytes:
    return build_ascii_command(CMD_READ, addr)


def build_status_read_command(addr: int) -> bytes:
    return build_ascii_command(CMD_STATUS_READ, addr)


def build_write_command(addr: int, data: int) -> bytes:
    return build_ascii_command(CMD_WRITE, addr, data & 0xFFFF_FFFF)


def build_status_write_command(addr: int, data: int) -> bytes:
    return build_ascii_command(CMD_STATUS_WRITE, addr, data & 0xFFFF_FFFF)


def build_bulk_read_command(addr: int, words: int) -> bytes:
    return build_ascii_command(CMD_BULK_READ, addr, words)


def build_bulk_write_command(addr: int, words: int) -> bytes:
    return build_ascii_command(CMD_BULK_WRITE, addr, words)


def build_bulk_abort_block(seq: int) -> bytes:
    return stuff_cli_literal_bytes(build_bulk_block(BULK_ABORT, seq, b""))


def build_burst_test_read_command(addr: int, words: int) -> bytes:
    return build_ascii_command(CMD_BURST_TEST_READ, addr, words)


def build_burst_test_write_command(addr: int, words: int) -> bytes:
    return build_ascii_command(CMD_BURST_TEST_WRITE, addr, words)


def decode_burst_data_packet(arg0: int, arg1: int, arg2: int) -> BurstDataPacket:
    packet_id = (arg0 >> 24) & 0xFF
    packet_count = (arg0 >> 16) & 0xFF
    first_word_index = (arg0 >> 8) & 0xFF
    valid_word_count = arg0 & 0xFF
    if valid_word_count == 1:
        payload_words = (arg1 & 0xFFFF_FFFF,)
    elif valid_word_count == 2:
        payload_words = (arg1 & 0xFFFF_FFFF, arg2 & 0xFFFF_FFFF)
    else:
        payload_words = tuple()
    return BurstDataPacket(
        packet_id=packet_id,
        packet_count=packet_count,
        first_word_index=first_word_index,
        valid_word_count=valid_word_count,
        words=payload_words,
    )


def decode_bulk_read_progress(arg0: int, arg1: int, arg2: int) -> BulkReadProgress:
    valid_word_count = (arg0 >> 21) & 0x3
    base_addr = arg0 & SDRAM_MAX_WORD_ADDR
    if valid_word_count not in (1, 2):
        raise ValueError(f"invalid bulk read word count in arg0: 0x{arg0:08X}")
    words = [arg1 & 0xFFFF_FFFF]
    if valid_word_count == 2:
        words.append(arg2 & 0xFFFF_FFFF)
    return BulkReadProgress(
        base_addr=base_addr,
        valid_word_count=valid_word_count,
        words=tuple(words),
    )


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


def stuff_cli_literal_bytes(data: bytes) -> bytes:
    stuffed = bytearray()
    for byte_value in data:
        if byte_value in CLI_LITERAL_BYTES:
            stuffed.append(CMD_LITERAL_NEXT)
        stuffed.append(byte_value)
    return bytes(stuffed)


def iter_bulk_write_blocks(blob: bytes, *, chunk_bytes: int = MAX_BULK_WRITE_CHUNK_BYTES) -> list[bytes]:
    blocks: list[bytes] = []
    seq = 0
    if chunk_bytes < 1 or chunk_bytes > MAX_BULK_PAYLOAD_BYTES:
        raise ValueError(
            f"chunk_bytes must be in range 1..{MAX_BULK_PAYLOAD_BYTES}, got {chunk_bytes}"
        )
    # Keep host BW chunks below the protocol maximum so DLE stuffing for
    # reserved CLI bytes does not create overly long on-wire bursts that have
    # shown CRC failures through the TCP/UART bridge on hardware.
    for offset in range(0, len(blob), chunk_bytes):
        payload = blob[offset : offset + chunk_bytes]
        if len(payload) % 4 != 0:
            payload = payload + bytes(4 - (len(payload) % 4))
        blocks.append(stuff_cli_literal_bytes(build_bulk_block(BULK_WR_DATA, seq, payload)))
        seq = (seq + 1) & 0xFF
    blocks.append(stuff_cli_literal_bytes(build_bulk_block(BULK_WR_END, seq, b"")))
    return blocks


def load_bulk_file(path: str | Path) -> bytes:
    file_path = Path(path)
    suffix = file_path.suffix.lower()
    if suffix not in {".bin", ".hex"}:
        raise ValueError(f"unsupported file format: {file_path.suffix}")
    if suffix == ".bin":
        return file_path.read_bytes()

    raw_text = file_path.read_text(encoding="ascii")
    hex_digits = []
    for char in raw_text:
        if char.isspace():
            continue
        if char not in "0123456789abcdefABCDEF":
            raise ValueError(f"invalid hex character: {char!r}")
        hex_digits.append(char)
    if len(hex_digits) % 2 != 0:
        raise ValueError("hex file contains an odd number of digits")
    return bytes.fromhex("".join(hex_digits))


def save_bulk_file(path: str | Path, blob: bytes) -> None:
    file_path = Path(path)
    suffix = file_path.suffix.lower()
    if suffix not in {".bin", ".hex"}:
        raise ValueError(f"unsupported file format: {file_path.suffix}")
    file_path.parent.mkdir(parents=True, exist_ok=True)
    if suffix == ".bin":
        file_path.write_bytes(blob)
        return

    line_width = 32
    hex_lines = [blob[idx : idx + line_width].hex().upper() for idx in range(0, len(blob), line_width)]
    file_path.write_text("\n".join(hex_lines) + ("\n" if hex_lines else ""), encoding="ascii")


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


def _get_pending_frames(parser: FrameParser) -> list[Frame]:
    return _PARSER_PENDING_FRAMES.setdefault(id(parser), [])


def _queue_pending_frames(parser: FrameParser, frames: list[Frame]) -> None:
    if not frames:
        return
    _get_pending_frames(parser).extend(frames)


def _take_pending_frames(parser: FrameParser) -> list[Frame]:
    pending = _get_pending_frames(parser)
    frames = list(pending)
    pending.clear()
    return frames


def _take_matching_frame(parser: FrameParser, match_fn: Callable[[Frame], bool]) -> Frame | None:
    pending = _get_pending_frames(parser)
    for idx, frame in enumerate(pending):
        if match_fn(frame):
            return pending.pop(idx)
    return None


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
    frames: list[Frame] = _take_pending_frames(parser)
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
        pending_match = _take_matching_frame(parser, match_fn)
        if pending_match is not None:
            return pending_match
        data = read_fn()
        if data:
            frames = parser.feed(data)
            _queue_pending_frames(parser, frames)
            pending_match = _take_matching_frame(parser, match_fn)
            if pending_match is not None:
                return pending_match
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


def recv_bulk_read_words(
    read_fn: Callable[[], bytes],
    parser: FrameParser,
    timeout_s: float,
    *,
    addr: int,
    words: int,
) -> bytes:
    validate_bulk_range(addr, words)
    deadline = time.monotonic() + timeout_s
    received_words: dict[int, int] = {}

    while time.monotonic() < deadline:
        pending_frames = _take_pending_frames(parser)
        if pending_frames:
            frame_batch = pending_frames
        else:
            frame_batch = []
        data = read_fn()
        if data:
            frame_batch.extend(parser.feed(data))
        if frame_batch:
            for frame in frame_batch:
                if frame.event.src_id != HOST_SRC_ID:
                    continue
                if frame.event.event_id == HOST_EVT_BULK_PROGRESS:
                    progress = decode_bulk_read_progress(
                        frame.event.arg0,
                        frame.event.arg1,
                        frame.event.arg2,
                    )
                    for word_offset, value in enumerate(progress.words):
                        word_addr = progress.base_addr + word_offset
                        if word_addr < addr or word_addr >= addr + words:
                            raise RuntimeError(
                                f"bulk read returned out-of-range word addr=0x{word_addr:05X}"
                            )
                        received_words[word_addr] = value
                elif frame.event.event_id == HOST_EVT_BULK_DONE:
                    done_addr = frame.event.arg0 & SDRAM_MAX_WORD_ADDR
                    done_words = frame.event.arg1 & SDRAM_MAX_WORD_ADDR
                    if done_addr != addr or done_words != words:
                        raise RuntimeError(
                            f"bulk read done mismatch addr=0x{done_addr:05X} words={done_words}"
                        )
                    blob = bytearray()
                    for word_addr in range(addr, addr + words):
                        if word_addr not in received_words:
                            raise RuntimeError(
                                f"bulk read incomplete at addr=0x{word_addr:05X}"
                            )
                        blob.extend(received_words[word_addr].to_bytes(4, "little"))
                    return bytes(blob)
                elif frame.event.event_id == HOST_EVT_BULK_ABORT:
                    raise RuntimeError(
                        f"bulk read aborted reason=0x{frame.event.arg0:08X} detail=0x{frame.event.arg1:08X}"
                    )
                elif frame.event.event_id == HOST_EVT_BULK_ERR:
                    raise RuntimeError(
                        f"bulk read error reason=0x{frame.event.arg0:08X} detail=0x{frame.event.arg1:08X}"
                    )
                elif frame.event.event_id == HOST_EVT_CMD_ERR:
                    raise RuntimeError(
                        f"bulk read cmd_err reason=0x{frame.event.arg0:08X} detail=0x{frame.event.arg1:08X}"
                    )
        time.sleep(0.01)

    raise TimeoutError("timed out waiting for bulk read completion")
