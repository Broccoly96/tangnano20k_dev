"""UART log frame protocol parsing utilities.

This module implements fixed-length frame parsing for the UART log CLI stream:
  SYNC(0x7E) + SEQ(1B) + PAYLOAD(16B) + CRC8(1B)

CRC uses CRC-8/ATM over SEQ + PAYLOAD (SYNC excluded).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

UART_SYNC_BYTE = 0x7E
FRAME_PAYLOAD_BYTES = 16
FRAME_TOTAL_BYTES = 19


@dataclass(frozen=True)
class Event:
    """Decoded 16-byte payload event fields."""

    src_id: int
    event_id: int
    timestamp: int
    arg0: int
    arg1: int
    arg2: int


@dataclass(frozen=True)
class Frame:
    """One validated UART frame with decoded payload."""

    sync: int
    seq: int
    payload_bytes: bytes
    crc: int
    crc_ok: bool
    lost_count: int
    raw_hex: str
    event: Event


def crc8_atm_update(crc_in: int, data_byte: int) -> int:
    """Update CRC-8/ATM state for one byte (poly=0x07, non-reflected)."""

    crc = (crc_in ^ data_byte) & 0xFF
    for _ in range(8):
        if crc & 0x80:
            crc = ((crc << 1) ^ 0x07) & 0xFF
        else:
            crc = (crc << 1) & 0xFF
    return crc


def crc8_atm(data: bytes) -> int:
    """Compute CRC-8/ATM over a bytes object."""

    crc = 0x00
    for byte in data:
        crc = crc8_atm_update(crc, byte)
    return crc


def decode_event_payload(payload: bytes) -> Event:
    """Decode a 16-byte payload into Event fields.

    Payload layout (little-endian word stream):
      word0 = {src_id, event_id, timestamp[15:0]}
      word1 = arg0
      word2 = arg1
      word3 = arg2
    """

    if len(payload) != FRAME_PAYLOAD_BYTES:
        raise ValueError(f"payload length must be {FRAME_PAYLOAD_BYTES}")

    timestamp = int.from_bytes(payload[0:2], byteorder="little", signed=False)
    event_id = payload[2]
    src_id = payload[3]

    arg0 = int.from_bytes(payload[4:8], byteorder="little", signed=False)
    arg1 = int.from_bytes(payload[8:12], byteorder="little", signed=False)
    arg2 = int.from_bytes(payload[12:16], byteorder="little", signed=False)

    return Event(
        src_id=src_id,
        event_id=event_id,
        timestamp=timestamp,
        arg0=arg0,
        arg1=arg1,
        arg2=arg2,
    )


def build_frame(seq: int, payload: bytes) -> bytes:
    """Build a valid 19-byte frame (helper for tests/tools)."""

    if len(payload) != FRAME_PAYLOAD_BYTES:
        raise ValueError(f"payload length must be {FRAME_PAYLOAD_BYTES}")

    seq_u8 = seq & 0xFF
    crc = crc8_atm(bytes([seq_u8]) + payload)
    return bytes([UART_SYNC_BYTE, seq_u8]) + payload + bytes([crc])


class FrameParser:
    """Streaming parser for fixed 19-byte UART log frames.

    Behavior:
    - Scans for SYNC(0x7E) and attempts fixed-length frame decode.
    - Rejects CRC mismatch frames and continues re-synchronization.
    - Reports SEQ discontinuities as lost_count on validated frames.
    """

    def __init__(self) -> None:
        self._buffer = bytearray()
        self._last_seq: Optional[int] = None
        self.valid_frame_count = 0
        self.crc_error_count = 0
        self.lost_event_count = 0

    def reset(self) -> None:
        """Reset parser state and statistics."""

        self._buffer.clear()
        self._last_seq = None
        self.valid_frame_count = 0
        self.crc_error_count = 0
        self.lost_event_count = 0

    def feed(self, data: bytes) -> list[Frame]:
        """Feed raw UART bytes and return validated frames."""

        if not data:
            return []

        self._buffer.extend(data)
        frames: list[Frame] = []

        while True:
            try:
                sync_idx = self._buffer.index(UART_SYNC_BYTE)
            except ValueError:
                self._buffer.clear()
                break

            if sync_idx > 0:
                del self._buffer[:sync_idx]

            if len(self._buffer) < FRAME_TOTAL_BYTES:
                break

            candidate = bytes(self._buffer[:FRAME_TOTAL_BYTES])
            seq = candidate[1]
            payload = candidate[2:18]
            crc_rx = candidate[18]
            crc_calc = crc8_atm(bytes([seq]) + payload)

            if crc_calc != crc_rx:
                # SYNC false-positive or corrupted frame; drop one byte and rescan.
                self.crc_error_count += 1
                del self._buffer[0]
                continue

            lost_count = 0
            if self._last_seq is not None:
                expected = (self._last_seq + 1) & 0xFF
                if seq != expected:
                    lost_count = (seq - expected) & 0xFF
                    self.lost_event_count += lost_count
            self._last_seq = seq

            event = decode_event_payload(payload)
            frame = Frame(
                sync=UART_SYNC_BYTE,
                seq=seq,
                payload_bytes=payload,
                crc=crc_rx,
                crc_ok=True,
                lost_count=lost_count,
                raw_hex=" ".join(f"{b:02X}" for b in candidate),
                event=event,
            )
            frames.append(frame)
            self.valid_frame_count += 1
            del self._buffer[:FRAME_TOTAL_BYTES]

        return frames
