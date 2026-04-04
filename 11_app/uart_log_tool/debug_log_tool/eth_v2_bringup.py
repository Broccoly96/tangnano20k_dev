#!/usr/bin/env python3
"""
Ethernet V2 bring-up helper for the tangmega60k board.

This tool uses the UART debug path as the primary observation channel.
It can:
  - switch uart_log_cli to the Ethernet debug source
  - request one Ethernet status snapshot
  - force the host NIC to 1000M / 100M / 10M and verify link-up
  - stimulate ARP traffic and compare counter deltas
  - send one raw UDP register packet with broadcast/unicast destination MAC

Expected usage:
  sudo python3 11_app/eth_v2_bringup.py --iface enp6s0 --serial-port /dev/ttyUSB0
"""

from __future__ import annotations

import argparse
import os
import re
import socket
import struct
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import serial

from eth_udp_reg_tool import CMD_PING, build_request
from uart_log_decoder import UARTLogDecoder
from uart_log_protocol import FrameParser
from uart_log_serial import CLI_COMMAND_BYTES


@dataclass(frozen=True)
class LinkInfo:
    speed: str
    duplex: str
    link_detected: str


class BringupError(RuntimeError):
    """Raised when the bring-up helper cannot complete one required step."""


def run_checked(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


def get_link_info(iface: str) -> LinkInfo:
    out = run_checked(["ethtool", iface]).stdout
    speed = re.search(r"Speed:\s*([^\n]+)", out)
    duplex = re.search(r"Duplex:\s*([^\n]+)", out)
    link = re.search(r"Link detected:\s*([^\n]+)", out)
    return LinkInfo(
        speed=speed.group(1).strip() if speed else "?",
        duplex=duplex.group(1).strip() if duplex else "?",
        link_detected=link.group(1).strip() if link else "?",
    )


def wait_link(iface: str, expect_speed: str, timeout_s: float) -> LinkInfo:
    end_at = time.time() + timeout_s
    last = get_link_info(iface)
    while time.time() < end_at:
        last = get_link_info(iface)
        if last.link_detected.lower() == "yes" and last.speed == expect_speed:
            return last
        time.sleep(0.5)
    return last


class EthernetStatusProbe:
    """UART-side Ethernet debug source driver."""

    def __init__(self, serial_port: str, decoder_path: str) -> None:
        self._ser = serial.Serial(serial_port, 115200, timeout=0, write_timeout=0.5)
        self._parser = FrameParser()
        self._decoder = UARTLogDecoder.from_yaml(decoder_path)

    def close(self) -> None:
        self._ser.close()

    def _drain(self, sec: float = 0.2) -> None:
        end_at = time.time() + sec
        while time.time() < end_at:
            self._ser.read(512)

    def _collect_frames(self, sec: float = 1.5):
        frames = []
        end_at = time.time() + sec
        while time.time() < end_at:
            data = self._ser.read(512)
            if not data:
                time.sleep(0.02)
                continue
            frames.extend(self._parser.feed(data))
        return frames

    def request_status(self) -> dict[str, str]:
        self._drain(0.2)
        self._ser.write(CLI_COMMAND_BYTES["status"])
        decoded: dict[str, str] = {}
        for frame in self._collect_frames():
            event = self._decoder.decode(frame.event)
            decoded[event.title] = event.message
        return decoded

    def ensure_eth_source(self) -> dict[str, str]:
        for _ in range(5):
            snapshot = self.request_status()
            if "ETH_STATUS" in snapshot:
                return snapshot
            self._ser.write(CLI_COMMAND_BYTES["next"])
            time.sleep(0.3)
        raise BringupError("failed to switch uart_log_cli to Ethernet source")


def build_raw_udp_frame(
    *,
    dst_mac: bytes,
    src_mac: bytes,
    src_ip: bytes,
    dst_ip: bytes,
    src_port: int,
    dst_port: int,
    payload: bytes,
) -> bytes:
    udp_len = 8 + len(payload)
    ipv4_total_len = 20 + udp_len

    ipv4_header = bytearray(20)
    ipv4_header[0] = 0x45
    ipv4_header[1] = 0x00
    ipv4_header[2:4] = ipv4_total_len.to_bytes(2, "big")
    ipv4_header[4:6] = (0).to_bytes(2, "big")
    ipv4_header[6:8] = (0).to_bytes(2, "big")
    ipv4_header[8] = 64
    ipv4_header[9] = 17
    ipv4_header[12:16] = src_ip
    ipv4_header[16:20] = dst_ip
    ipv4_header[10:12] = ipv4_checksum(bytes(ipv4_header)).to_bytes(2, "big")

    udp_header = struct.pack("!HHHH", src_port, dst_port, udp_len, 0)
    return dst_mac + src_mac + b"\x08\x00" + bytes(ipv4_header) + udp_header + payload


def ipv4_checksum(data: bytes) -> int:
    if len(data) & 1:
        data += b"\x00"
    checksum = 0
    for idx in range(0, len(data), 2):
        checksum += (data[idx] << 8) | data[idx + 1]
        checksum = (checksum & 0xFFFF) + (checksum >> 16)
    return (~checksum) & 0xFFFF


def parse_counter_triplet(message: str) -> dict[str, int]:
    parsed: dict[str, int] = {}
    for part in message.split():
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        try:
            parsed[key] = int(value, 0)
        except ValueError:
            continue
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iface", type=str, default="enp6s0")
    parser.add_argument("--serial-port", type=str, default="/dev/ttyUSB0")
    parser.add_argument("--decoder", type=str, default="11_app/decode_rules.default.yaml")
    parser.add_argument("--host-ip", type=str, default="192.168.100.1")
    parser.add_argument("--target-ip", type=str, default="192.168.100.2")
    parser.add_argument("--target-mac", type=str, default="02:00:00:00:00:01")
    parser.add_argument("--ctrl-port", type=int, default=50000)
    parser.add_argument("--wait-link-timeout", type=float, default=10.0)
    args = parser.parse_args()

    if hasattr(os, "geteuid") and os.geteuid() != 0:
        print("warning: raw socket / ethtool operations usually require sudo", file=sys.stderr)

    probe = EthernetStatusProbe(args.serial_port, args.decoder)
    try:
        initial = probe.ensure_eth_source()
        print(f"eth_source_ready ETH_STATUS={initial.get('ETH_STATUS', '-')}")

        for label, cmd, expect_speed in (
            ("AUTO_1000", ["ethtool", "-s", args.iface, "autoneg", "on"], "1000Mb/s"),
            ("FORCE_100", ["ethtool", "-s", args.iface, "autoneg", "off", "speed", "100", "duplex", "full"], "100Mb/s"),
            ("FORCE_10", ["ethtool", "-s", args.iface, "autoneg", "off", "speed", "10", "duplex", "full"], "10Mb/s"),
        ):
            run_checked(cmd)
            link = wait_link(args.iface, expect_speed, args.wait_link_timeout)
            before = probe.request_status()
            run_checked(["arping", "-I", args.iface, "-c", "2", "-w", "2", args.target_ip], check=False)
            after = probe.request_status()
            print(f"[{label}] link={link.speed} duplex={link.duplex} up={link.link_detected}")
            print(f"[{label}] before_eth_status={before.get('ETH_STATUS', '-')}")
            print(f"[{label}] after_eth_status={after.get('ETH_STATUS', '-')}")
            print(f"[{label}] before_counters0={before.get('ETH_COUNTERS0', '-')}")
            print(f"[{label}] after_counters0={after.get('ETH_COUNTERS0', '-')}")

        run_checked(["ethtool", "-s", args.iface, "autoneg", "on"])
        link = wait_link(args.iface, "1000Mb/s", args.wait_link_timeout)
        print(f"[RESTORE] link={link.speed} duplex={link.duplex} up={link.link_detected}")

        src_mac = bytes.fromhex(run_checked(["cat", f"/sys/class/net/{args.iface}/address"]).stdout.strip().replace(":", ""))
        dst_mac = bytes.fromhex(args.target_mac.replace(":", ""))
        src_ip = bytes(int(part) for part in args.host_ip.split("."))
        dst_ip = bytes(int(part) for part in args.target_ip.split("."))
        udp_payload = build_request(cmd=CMD_PING, addr=0, data=0x12345678, seq=0x0033)

        raw_sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
        raw_sock.bind((args.iface, 0))
        try:
            before = probe.request_status()
            raw_sock.send(
                build_raw_udp_frame(
                    dst_mac=b"\xFF\xFF\xFF\xFF\xFF\xFF",
                    src_mac=src_mac,
                    src_ip=src_ip,
                    dst_ip=dst_ip,
                    src_port=40000,
                    dst_port=args.ctrl_port,
                    payload=udp_payload,
                )
            )
            time.sleep(0.2)
            after_bcast = probe.request_status()

            raw_sock.send(
                build_raw_udp_frame(
                    dst_mac=dst_mac,
                    src_mac=src_mac,
                    src_ip=src_ip,
                    dst_ip=dst_ip,
                    src_port=40000,
                    dst_port=args.ctrl_port,
                    payload=udp_payload,
                )
            )
            time.sleep(0.2)
            after_unicast = probe.request_status()
        finally:
            raw_sock.close()

        print(f"[RAW_UDP] before_counters1={before.get('ETH_COUNTERS1', '-')}")
        print(f"[RAW_UDP] after_bcast_counters1={after_bcast.get('ETH_COUNTERS1', '-')}")
        print(f"[RAW_UDP] after_unicast_counters1={after_unicast.get('ETH_COUNTERS1', '-')}")
        print(f"[RAW_UDP] after_unicast_last_pkt={after_unicast.get('ETH_LAST_PKT', '-')}")
        return 0
    finally:
        probe.close()


if __name__ == "__main__":
    raise SystemExit(main())
