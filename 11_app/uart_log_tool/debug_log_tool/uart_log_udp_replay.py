#!/usr/bin/env python3
"""Minimal UDP log packet injector for local uart_log_tool verification."""

from __future__ import annotations

import argparse
import socket
import time
from pathlib import Path

from uart_log_protocol import Event, build_frame
from uart_log_replay import ReplayRecord, load_replay_records
from uart_log_udp_protocol import (
    UDP_LOG_FLAG_PARTIAL_CHUNK,
    UDP_LOG_FLAG_SOURCE_RESET,
    build_udp_log_packet,
    feed_uart_frame_bytes,
)


def build_event_payload(event: Event) -> bytes:
    """Encode one Event into the 16-byte UART payload layout."""

    return (
        int(event.timestamp & 0xFFFF).to_bytes(2, "little")
        + bytes([event.event_id & 0xFF, event.src_id & 0xFF])
        + int(event.arg0 & 0xFFFF_FFFF).to_bytes(4, "little")
        + int(event.arg1 & 0xFFFF_FFFF).to_bytes(4, "little")
        + int(event.arg2 & 0xFFFF_FFFF).to_bytes(4, "little")
    )


def replay_records_to_udp_packets(
    records: list[ReplayRecord],
    *,
    packet_seq_start: int = 0,
    packet_timestamp_start: int = 0,
    packet_timestamp_step: int = 1,
) -> list[bytes]:
    """Convert replay records into UDP log packets."""

    packets: list[bytes] = []
    packet_seq = packet_seq_start & 0xFFFF
    packet_ts = packet_timestamp_start & 0xFFFF_FFFF

    for record in records:
        frame_bytes = build_frame(record.seq, build_event_payload(record.event))
        for chunk in feed_uart_frame_bytes(frame_bytes):
            flags = 0
            if len(chunk) < 16:
                flags |= UDP_LOG_FLAG_PARTIAL_CHUNK
            packets.append(
                build_udp_log_packet(
                    seq=packet_seq,
                    flags=flags,
                    timestamp=packet_ts,
                    chunk=chunk,
                )
            )
            packet_seq = (packet_seq + 1) & 0xFFFF
            packet_ts = (packet_ts + packet_timestamp_step) & 0xFFFF_FFFF

    return packets


def build_demo_packets() -> list[bytes]:
    """Build a tiny scenario with normal, gap, and flagged packets."""

    demo_event = Event(
        src_id=0x21,
        event_id=0x42,
        timestamp=0x1234,
        arg0=0x00000001,
        arg1=0x00000002,
        arg2=0x00000003,
    )
    frame_bytes = build_frame(0x10, build_event_payload(demo_event))
    chunks = feed_uart_frame_bytes(frame_bytes)
    return [
        build_udp_log_packet(seq=0x0000, timestamp=0x00000010, chunk=chunks[0]),
        build_udp_log_packet(
            seq=0x0002,
            timestamp=0x00000011,
            flags=UDP_LOG_FLAG_SOURCE_RESET | UDP_LOG_FLAG_PARTIAL_CHUNK,
            chunk=b"RST",
        ),
        build_udp_log_packet(seq=0x0003, timestamp=0x00000012, chunk=chunks[1]),
    ]


def send_packets(
    packets: list[bytes],
    *,
    target_ip: str,
    target_port: int,
    interval_s: float,
) -> None:
    """Send UDP packets at a fixed interval."""

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        for index, payload in enumerate(packets):
            sock.sendto(payload, (target_ip, target_port))
            print(f"sent[{index:02d}] bytes={len(payload)}")
            if index + 1 < len(packets) and interval_s > 0.0:
                time.sleep(interval_s)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", default="127.0.0.1", help="target IPv4 address")
    parser.add_argument("--port", type=int, default=50001, help="target UDP port")
    parser.add_argument(
        "--interval",
        type=float,
        default=0.05,
        help="delay between packets in seconds",
    )
    parser.add_argument(
        "--replay-log",
        type=str,
        default=None,
        help="existing uart_log_tool .log file to replay as UDP log packets",
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="send a built-in demo sequence with seq gap and source_reset flag",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    if bool(args.replay_log) == bool(args.demo):
        parser.error("select exactly one of --replay-log or --demo")

    if args.replay_log:
        replay_path = Path(args.replay_log)
        records = load_replay_records(replay_path)
        packets = replay_records_to_udp_packets(records)
        print(f"replay records={len(records)} packets={len(packets)} file={replay_path}")
    else:
        packets = build_demo_packets()
        print(f"demo packets={len(packets)}")

    send_packets(
        packets,
        target_ip=args.ip,
        target_port=args.port,
        interval_s=args.interval,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
