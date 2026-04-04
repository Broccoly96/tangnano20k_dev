"""UDP log stream payload parsing and UART frame reconstruction helpers."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from uart_log_protocol import FRAME_TOTAL_BYTES, Frame, FrameParser, UART_SYNC_BYTE, decode_event_payload

UDP_LOG_MAGIC = 0x55AB
UDP_LOG_VERSION = 0x02
UDP_LOG_PAYLOAD_BYTES = 32
UDP_LOG_CHUNK_BYTES = 16
UDP_LOG_STREAM_UART_PRIMARY = 0x01
UDP_LOG_STREAM_UART_ALL_EVENTS = 0x02
UDP_LOG_FLAG_OVERFLOW = 0x0001
UDP_LOG_FLAG_FRAMING_ERROR = 0x0002
UDP_LOG_FLAG_SOURCE_RESET = 0x0004
UDP_LOG_FLAG_PARTIAL_CHUNK = 0x0008


@dataclass(frozen=True)
class UDPLogPacket:
    """One decoded 32-byte UDP log payload."""

    magic: int
    version: int
    stream_id: int
    seq: int
    flags: int
    timestamp: int
    valid_bytes: int
    payload: bytes
    reserved0: int
    reserved1: int

    @property
    def overflow(self) -> bool:
        return bool(self.flags & UDP_LOG_FLAG_OVERFLOW)

    @property
    def framing_error(self) -> bool:
        return bool(self.flags & UDP_LOG_FLAG_FRAMING_ERROR)

    @property
    def source_reset(self) -> bool:
        return bool(self.flags & UDP_LOG_FLAG_SOURCE_RESET)

    @property
    def partial_chunk(self) -> bool:
        return bool(self.flags & UDP_LOG_FLAG_PARTIAL_CHUNK)

    @property
    def valid_payload(self) -> bytes:
        return self.payload[: self.valid_bytes]


@dataclass(frozen=True)
class UDPLogFeedResult:
    """Decoded UDP packet plus any recovered UART frames."""

    packet: UDPLogPacket
    packet_lost_count: int
    uart_frames: tuple[Frame, ...]


def format_udp_log_flags(flags: int) -> str:
    """Return a compact text form of the UDP log flags."""

    names: list[str] = []
    if flags & UDP_LOG_FLAG_OVERFLOW:
        names.append("overflow")
    if flags & UDP_LOG_FLAG_FRAMING_ERROR:
        names.append("framing_error")
    if flags & UDP_LOG_FLAG_SOURCE_RESET:
        names.append("source_reset")
    if flags & UDP_LOG_FLAG_PARTIAL_CHUNK:
        names.append("partial_chunk")
    if not names:
        return "-"
    return "|".join(names)


def format_udp_log_stream_id(stream_id: int) -> str:
    """Return a compact text label for the UDP log stream id."""

    if stream_id == UDP_LOG_STREAM_UART_PRIMARY:
        return "legacy_mirror"
    if stream_id == UDP_LOG_STREAM_UART_ALL_EVENTS:
        return "direct_event"
    return f"unknown(0x{stream_id:02X})"


def parse_udp_log_packet(payload: bytes) -> UDPLogPacket:
    """Parse one 32-byte UDP log payload."""

    if len(payload) != UDP_LOG_PAYLOAD_BYTES:
        raise ValueError(f"UDP log payload must be {UDP_LOG_PAYLOAD_BYTES} bytes")

    magic = int.from_bytes(payload[0:2], "big")
    if magic != UDP_LOG_MAGIC:
        raise ValueError(f"unexpected UDP log magic: 0x{magic:04X}")

    version = payload[2]
    stream_id = payload[3]
    seq = int.from_bytes(payload[4:6], "big")
    flags = int.from_bytes(payload[6:8], "big")
    timestamp = int.from_bytes(payload[8:12], "big")
    valid_bytes = payload[12]
    reserved0 = payload[13]
    chunk = payload[14:30]
    reserved1 = int.from_bytes(payload[30:32], "big")

    if valid_bytes > UDP_LOG_CHUNK_BYTES:
        raise ValueError(f"valid_bytes out of range: {valid_bytes}")

    return UDPLogPacket(
        magic=magic,
        version=version,
        stream_id=stream_id,
        seq=seq,
        flags=flags,
        timestamp=timestamp,
        valid_bytes=valid_bytes,
        payload=chunk,
        reserved0=reserved0,
        reserved1=reserved1,
    )


class UDPLogStreamDecoder:
    """Tracks UDP packet sequence and rebuilds UART frames from log payload bytes."""

    def __init__(self, *, expected_stream_id: int | None = None) -> None:
        self._expected_stream_id = expected_stream_id
        self._packet_seq_last: Optional[int] = None
        self.packet_count = 0
        self.packet_lost_count = 0
        self.uart_parser = FrameParser()

    def reset(self) -> None:
        """Reset packet and UART decode state."""

        self._packet_seq_last = None
        self.packet_count = 0
        self.packet_lost_count = 0
        self.uart_parser.reset()

    def feed_packet(self, payload: bytes) -> UDPLogFeedResult:
        """Decode one UDP log payload and feed its valid bytes into the UART parser."""

        packet = parse_udp_log_packet(payload)
        if packet.version != UDP_LOG_VERSION:
            raise ValueError(f"unexpected UDP log version: 0x{packet.version:02X}")
        if self._expected_stream_id is not None and packet.stream_id != self._expected_stream_id:
            raise ValueError(f"unexpected UDP log stream_id: 0x{packet.stream_id:02X}")
        if packet.stream_id not in (UDP_LOG_STREAM_UART_PRIMARY, UDP_LOG_STREAM_UART_ALL_EVENTS):
            raise ValueError(f"unexpected UDP log stream_id: 0x{packet.stream_id:02X}")

        lost = 0
        if self._packet_seq_last is not None:
            expected = (self._packet_seq_last + 1) & 0xFFFF
            if packet.seq != expected:
                lost = (packet.seq - expected) & 0xFFFF
                self.packet_lost_count += lost
        self._packet_seq_last = packet.seq
        self.packet_count += 1

        if packet.stream_id == UDP_LOG_STREAM_UART_PRIMARY:
            frames = tuple(self.uart_parser.feed(packet.valid_payload))
        else:
            event = decode_event_payload(packet.valid_payload)
            frames = (
                Frame(
                    sync=UART_SYNC_BYTE,
                    seq=packet.seq & 0xFF,
                    payload_bytes=packet.valid_payload,
                    crc=0,
                    crc_ok=True,
                    lost_count=lost,
                    raw_hex=" ".join(f"{b:02X}" for b in packet.valid_payload),
                    event=event,
                ),
            )
        return UDPLogFeedResult(packet=packet, packet_lost_count=lost, uart_frames=frames)


def build_udp_log_packet(
    *,
    seq: int,
    chunk: bytes,
    flags: int = 0,
    timestamp: int = 0,
    stream_id: int = UDP_LOG_STREAM_UART_PRIMARY,
    version: int = UDP_LOG_VERSION,
) -> bytes:
    """Build a valid UDP log payload for tests and offline tools."""

    if len(chunk) > UDP_LOG_CHUNK_BYTES:
        raise ValueError(f"chunk must be at most {UDP_LOG_CHUNK_BYTES} bytes")

    chunk_padded = chunk.ljust(UDP_LOG_CHUNK_BYTES, b"\x00")
    return (
        UDP_LOG_MAGIC.to_bytes(2, "big")
        + bytes([version & 0xFF, stream_id & 0xFF])
        + int(seq & 0xFFFF).to_bytes(2, "big")
        + int(flags & 0xFFFF).to_bytes(2, "big")
        + int(timestamp & 0xFFFFFFFF).to_bytes(4, "big")
        + bytes([len(chunk) & 0xFF, 0x00])
        + chunk_padded
        + b"\x00\x00"
    )


def feed_uart_frame_bytes(frame_bytes: bytes, chunk_size: int = UDP_LOG_CHUNK_BYTES) -> list[bytes]:
    """Split one UART frame byte stream into UDP log chunks for tests."""

    if chunk_size <= 0 or chunk_size > UDP_LOG_CHUNK_BYTES:
        raise ValueError("chunk_size must be between 1 and 16")
    return [frame_bytes[idx : idx + chunk_size] for idx in range(0, len(frame_bytes), chunk_size)]
