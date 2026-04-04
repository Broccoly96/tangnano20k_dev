#!/usr/bin/env python3
"""Ethernet UDP register access CLI for the tangmega60k V2 register map."""

from __future__ import annotations

import argparse
import dataclasses
import socket
import time
from pathlib import Path
from typing import Iterable

try:
    import yaml
except ImportError:  # pragma: no cover - exercised via fallback loader
    yaml = None


PROTO_MAGIC = 0x55AA
FPGA_DEFAULT_IP = "192.168.100.2"
UDP_DEFAULT_PORT = 50000

CMD_READ = 0x01
CMD_WRITE = 0x02
CMD_PING = 0x03
CMD_READ_RESP = 0x81
CMD_WRITE_RESP = 0x82
CMD_PING_RESP = 0x83

STS_OK = 0x00
STS_BAD_ADDR = 0x01
STS_BAD_ALIGN = 0x02
STS_BAD_CMD = 0x03
STS_CFG_REJECTED = 0x04

REGISTERS = {
    "DEVICE_ID"                   : 0x0000_0000,
    "VERSION"                     : 0x0000_0004,
    "SCRATCH"                     : 0x0000_0008,
    "CONF_INDEX"                  : 0x0000_000C,
    "CONF_DATA"                   : 0x0000_0010,
    "LED_CONTROL"                 : 0x0000_0014,
    "RX_PACKET_COUNT"             : 0x0000_0018,
    "TX_PACKET_COUNT"             : 0x0000_001C,
    "ARP_COUNT"                   : 0x0000_0020,
    "UDP_COMMAND_COUNT"           : 0x0000_0024,
    "ERROR_COUNT"                 : 0x0000_0028,
    "RX_DROP_COUNT"               : 0x0000_002C,
    "TX_DROP_COUNT"               : 0x0000_0030,
    "LAST_ETHER_TYPE"             : 0x0000_0034,
    "LAST_SRC_MAC_HI"             : 0x0000_0038,
    "LAST_SRC_MAC_LO"             : 0x0000_003C,
    "LAST_SRC_IP"                 : 0x0000_0040,
    "LAST_DST_UDP_PORT"           : 0x0000_0044,
    "LAST_CMD_STATUS"             : 0x0000_0048,
    "PHY_STATUS"                  : 0x0000_004C,
    "NET_CFG_CONTROL"             : 0x0000_0050,
    "NET_STATUS"                  : 0x0000_0054,
    "NET_SHADOW_FPGA_IP_ADDR"     : 0x0000_0058,
    "NET_SHADOW_UDP_CTRL_PORT"    : 0x0000_005C,
    "NET_SHADOW_UDP_LOG_SRC_PORT" : 0x0000_0060,
    "NET_SHADOW_LOG_DST_IP"       : 0x0000_0064,
    "NET_SHADOW_LOG_DST_PORT"     : 0x0000_0068,
    "NET_ACTIVE_FPGA_IP_ADDR"     : 0x0000_006C,
    "NET_ACTIVE_UDP_CTRL_PORT"    : 0x0000_0070,
    "NET_ACTIVE_UDP_LOG_SRC_PORT" : 0x0000_0074,
    "NET_ACTIVE_LOG_DST_IP"       : 0x0000_0078,
    "NET_ACTIVE_LOG_DST_PORT"     : 0x0000_007C,
    "LINK_CONTROL"                : 0x0000_0080,
    "LINK_STATUS_EXT"             : 0x0000_0084,
    "LOG_STREAM_CONTROL"          : 0x0000_0088,
    "LOG_STREAM_STATUS"           : 0x0000_008C,
    "LOG_STREAM_PACKET_COUNT"     : 0x0000_0090,
    "LOG_STREAM_DROP_COUNT"       : 0x0000_0094,
    "LOG_STREAM_LAST_SEQ"         : 0x0000_0098,
}
REGISTER_NAMES = {addr: name for name, addr in REGISTERS.items()}
DEFAULT_REG_MAP_PATH = Path(__file__).resolve().with_name("eth_udp_reg_map.default.yaml")


@dataclasses.dataclass(frozen=True)
class RegisterDef:
    address: int
    name: str
    access: str
    reset_value: int
    description: str


@dataclasses.dataclass(frozen=True)
class UdpRegResponse:
    magic: int
    cmd: int
    status: int
    addr: int
    data: int
    seq: int
    reserved: int


def build_request(cmd: int, addr: int, data: int, seq: int, flags: int = 0) -> bytes:
    return (
        int(PROTO_MAGIC).to_bytes(2, "big")
        + bytes([cmd & 0xFF, flags & 0xFF])
        + int(addr & 0xFFFFFFFF).to_bytes(4, "big")
        + int(data & 0xFFFFFFFF).to_bytes(4, "big")
        + int(seq & 0xFFFF).to_bytes(2, "big")
        + (0).to_bytes(2, "big")
    )


def parse_response(packet: bytes) -> UdpRegResponse:
    if len(packet) != 16:
        raise ValueError(f"response must be 16 bytes, got {len(packet)}")
    return UdpRegResponse(
        magic=int.from_bytes(packet[0:2], "big"),
        cmd=packet[2],
        status=packet[3],
        addr=int.from_bytes(packet[4:8], "big"),
        data=int.from_bytes(packet[8:12], "big"),
        seq=int.from_bytes(packet[12:14], "big"),
        reserved=int.from_bytes(packet[14:16], "big"),
    )


def status_to_text(status: int) -> str:
    mapping = {
        STS_OK: "OK",
        STS_BAD_ADDR: "BAD_ADDR",
        STS_BAD_ALIGN: "BAD_ALIGN",
        STS_BAD_CMD: "BAD_CMD",
        STS_CFG_REJECTED: "CFG_REJECTED",
    }
    return mapping.get(status, f"UNKNOWN_{status:#04x}")


def load_register_map(path: str | Path | None = None) -> tuple[dict[str, RegisterDef], dict[int, RegisterDef]]:
    reg_path = Path(path) if path is not None else DEFAULT_REG_MAP_PATH
    loaded = _load_yaml_mapping(reg_path)

    registers_raw = loaded.get("registers", loaded)
    if not isinstance(registers_raw, list):
        raise ValueError("register map YAML must contain a 'registers' list")

    by_name: dict[str, RegisterDef] = {}
    by_addr: dict[int, RegisterDef] = {}
    for entry in registers_raw:
        if not isinstance(entry, dict):
            raise ValueError("register map entry must be a mapping")
        name = str(entry["name"]).strip().upper()
        address = int(entry["address"], 0) if isinstance(entry["address"], str) else int(entry["address"])
        access = str(entry.get("access", "RO")).strip().upper()
        reset_value_raw = entry.get("reset_value", 0)
        reset_value = (
            int(reset_value_raw, 0) if isinstance(reset_value_raw, str) else int(reset_value_raw)
        )
        description = str(entry.get("description", ""))
        reg_def = RegisterDef(
            address=address & 0xFFFF_FFFF,
            name=name,
            access=access,
            reset_value=reset_value & 0xFFFF_FFFF,
            description=description,
        )
        by_name[reg_def.name] = reg_def
        by_addr[reg_def.address] = reg_def
    return by_name, by_addr


def _load_yaml_mapping(path: Path) -> dict:
    if yaml is not None:
        with path.open("r", encoding="utf-8") as fp:
            return yaml.safe_load(fp) or {}
    return _load_yaml_mapping_fallback(path)


def _load_yaml_mapping_fallback(path: Path) -> dict:
    loaded: dict[str, list[dict[str, str]]] = {"registers": []}
    current: dict[str, str] | None = None
    in_registers = False

    with path.open("r", encoding="utf-8") as fp:
        for raw_line in fp:
            line = raw_line.split("#", 1)[0].rstrip()
            if not line.strip():
                continue
            stripped = line.strip()
            if stripped == "registers:":
                in_registers = True
                continue
            if not in_registers:
                continue
            if stripped.startswith("- "):
                if current is not None:
                    loaded["registers"].append(current)
                current = {}
                stripped = stripped[2:].strip()
                if stripped:
                    key, value = stripped.split(":", 1)
                    current[key.strip()] = value.strip()
                continue
            if current is None:
                raise ValueError(f"invalid register map YAML near line: {raw_line.rstrip()}")
            key, value = stripped.split(":", 1)
            current[key.strip()] = value.strip()

    if current is not None:
        loaded["registers"].append(current)
    return loaded


def reg_name_for_addr(addr: int, regs_by_addr: dict[int, RegisterDef] | None = None) -> str | None:
    addr_u32 = addr & 0xFFFF_FFFF
    if regs_by_addr is not None and addr_u32 in regs_by_addr:
        return regs_by_addr[addr_u32].name
    return REGISTER_NAMES.get(addr_u32)


def parse_register_arg(text: str) -> int:
    token = text.strip().upper()
    if token in REGISTERS:
        return REGISTERS[token]
    if token.startswith("REG_") and token[4:] in REGISTERS:
        return REGISTERS[token[4:]]
    return int(text, 0)


def resolve_register_arg(text: str, regs_by_name: dict[str, RegisterDef] | None = None) -> int:
    token = text.strip().upper()
    if regs_by_name is not None:
        if token in regs_by_name:
            return regs_by_name[token].address
        if token.startswith("REG_") and token[4:] in regs_by_name:
            return regs_by_name[token[4:]].address
    return parse_register_arg(text)


def validate_register_addr(addr: int) -> int:
    addr_u32 = addr & 0xFFFF_FFFF
    if addr_u32 > 0xFFFF:
        raise ValueError(f"register address out of 16-bit range: 0x{addr_u32:08X}")
    return addr_u32


def u32_to_ipv4(value: int) -> str:
    return ".".join(str((value >> shift) & 0xFF) for shift in (24, 16, 8, 0))


def _speed_code_to_text(code: int) -> str:
    mapping = {
        0b00: "10M",
        0b01: "100M",
        0b10: "1000M",
        0b11: "RESERVED",
    }
    return mapping.get(code & 0x3, "UNKNOWN")


def decode_register_value(addr: int, value: int) -> list[str]:
    addr_u32 = addr & 0xFFFF_FFFF
    value_u32 = value & 0xFFFF_FFFF

    if addr_u32 == REGISTERS["PHY_STATUS"]:
        speed_code = (value_u32 >> 2) & 0x3
        return [
            f"link_up={(value_u32 >> 0) & 0x1}",
            f"mdio_init_done={(value_u32 >> 1) & 0x1}",
            f"negotiated_speed={_speed_code_to_text(speed_code)}",
            f"autoneg_complete={(value_u32 >> 4) & 0x1}",
            f"phy_pll_lock={(value_u32 >> 5) & 0x1}",
        ]

    if addr_u32 == REGISTERS["CONF_INDEX"]:
        return [f"conf_index=0x{value_u32 & 0xFFFF:04X}"]

    if addr_u32 == REGISTERS["CONF_DATA"]:
        return [f"conf_data=0x{value_u32:08X}"]

    if addr_u32 in (
        REGISTERS["NET_SHADOW_FPGA_IP_ADDR"],
        REGISTERS["NET_SHADOW_LOG_DST_IP"],
        REGISTERS["NET_ACTIVE_FPGA_IP_ADDR"],
        REGISTERS["NET_ACTIVE_LOG_DST_IP"],
        REGISTERS["LAST_SRC_IP"],
    ):
        return [f"ipv4={u32_to_ipv4(value_u32)}"]

    if addr_u32 in (
        REGISTERS["NET_SHADOW_UDP_CTRL_PORT"],
        REGISTERS["NET_SHADOW_UDP_LOG_SRC_PORT"],
        REGISTERS["NET_SHADOW_LOG_DST_PORT"],
        REGISTERS["NET_ACTIVE_UDP_CTRL_PORT"],
        REGISTERS["NET_ACTIVE_UDP_LOG_SRC_PORT"],
        REGISTERS["NET_ACTIVE_LOG_DST_PORT"],
        REGISTERS["LAST_DST_UDP_PORT"],
    ):
        return [f"port={value_u32 & 0xFFFF}"]

    if addr_u32 == REGISTERS["NET_CFG_CONTROL"]:
        return [
            f"apply_req={(value_u32 >> 0) & 0x1}",
            f"shadow_valid={(value_u32 >> 2) & 0x1}",
            f"apply_busy={(value_u32 >> 3) & 0x1}",
            f"apply_error={(value_u32 >> 4) & 0x1}",
        ]

    if addr_u32 == REGISTERS["NET_STATUS"]:
        speed_code = (value_u32 >> 4) & 0x3
        return [
            f"active_valid={(value_u32 >> 0) & 0x1}",
            f"unsupported_link_mode={(value_u32 >> 1) & 0x1}",
            f"ctrl_plane_enabled={(value_u32 >> 2) & 0x1}",
            f"log_stream_enabled={(value_u32 >> 3) & 0x1}",
            f"speed={_speed_code_to_text(speed_code)}",
            f"duplex={'full' if ((value_u32 >> 6) & 0x1) else 'half'}",
        ]

    if addr_u32 == REGISTERS["LINK_CONTROL"]:
        mode_code = value_u32 & 0x3
        mode_text = {
            0b00: "AUTO",
            0b01: "10M_FULL",
            0b10: "100M_FULL",
            0b11: "1000M_FULL",
        }[mode_code]
        return [
            f"mode={mode_text}",
            f"autoneg_restart_req={(value_u32 >> 2) & 0x1}",
        ]

    if addr_u32 == REGISTERS["LINK_STATUS_EXT"]:
        speed_code = (value_u32 >> 3) & 0x3
        return [
            f"link_up={(value_u32 >> 0) & 0x1}",
            f"mdio_init_done={(value_u32 >> 1) & 0x1}",
            f"autoneg_complete={(value_u32 >> 2) & 0x1}",
            f"negotiated_speed={_speed_code_to_text(speed_code)}",
            f"negotiated_duplex={'full' if ((value_u32 >> 5) & 0x1) else 'half'}",
            f"phy_pll_lock={(value_u32 >> 6) & 0x1}",
            f"override_active={(value_u32 >> 7) & 0x1}",
        ]

    if addr_u32 == REGISTERS["LOG_STREAM_CONTROL"]:
        return [
            f"enable={(value_u32 >> 0) & 0x1}",
            f"clear_counters={(value_u32 >> 1) & 0x1}",
        ]

    if addr_u32 == REGISTERS["LOG_STREAM_STATUS"]:
        return [
            f"active={(value_u32 >> 0) & 0x1}",
            f"overflow_observed={(value_u32 >> 1) & 0x1}",
            f"framing_error_observed={(value_u32 >> 2) & 0x1}",
            f"source_reset_observed={(value_u32 >> 3) & 0x1}",
        ]

    return []


def exchange_packet(
    sock: socket.socket,
    target_ip: str,
    target_port: int,
    packet: bytes,
    timeout_s: float,
) -> UdpRegResponse:
    sock.settimeout(timeout_s)
    sock.sendto(packet, (target_ip, target_port))
    response, _ = sock.recvfrom(2048)
    parsed = parse_response(response)
    if parsed.magic != PROTO_MAGIC:
        raise ValueError(f"unexpected magic: 0x{parsed.magic:04X}")
    return parsed


def transact(
    sock: socket.socket,
    target_ip: str,
    target_port: int,
    cmd: int,
    addr: int,
    data: int,
    seq: int,
    timeout_s: float,
) -> UdpRegResponse:
    packet = build_request(cmd=cmd, addr=addr, data=data, seq=seq)
    return exchange_packet(sock, target_ip, target_port, packet, timeout_s)


def dump_registers(
    sock: socket.socket,
    target_ip: str,
    target_port: int,
    start_addr: int,
    count: int,
    timeout_s: float,
    seq_start: int,
) -> Iterable[UdpRegResponse]:
    for index in range(count):
        yield transact(
            sock=sock,
            target_ip=target_ip,
            target_port=target_port,
            cmd=CMD_READ,
            addr=start_addr + (index * 4),
            data=0,
            seq=(seq_start + index) & 0xFFFF,
            timeout_s=timeout_s,
        )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--reg-map",
        type=str,
        default=str(DEFAULT_REG_MAP_PATH),
        help="YAML register map path",
    )
    parser.add_argument(
        "--ip",
        default=FPGA_DEFAULT_IP,
        help=f"FPGA IPv4 address (default: {FPGA_DEFAULT_IP})",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=UDP_DEFAULT_PORT,
        help=f"FPGA UDP port (default: {UDP_DEFAULT_PORT})",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=1.0,
        help="socket timeout in seconds",
    )
    parser.add_argument(
        "--bind-ip",
        default="",
        help="local IPv4 address to bind before transmit",
    )
    parser.add_argument(
        "--bind-port",
        type=int,
        default=0,
        help="local UDP port to bind before transmit (default: ephemeral)",
    )
    parser.add_argument(
        "--seq",
        type=lambda text: int(text, 0),
        default=1,
        help="starting sequence number",
    )

    subparsers = parser.add_subparsers(dest="subcmd", required=True)

    ping_parser = subparsers.add_parser("ping", help="send a ping request")
    ping_parser.add_argument(
        "--data",
        type=lambda text: int(text, 0),
        default=0x12345678,
        help="32-bit ping payload to echo",
    )

    read_parser = subparsers.add_parser("read", help="read one 32-bit register")
    read_parser.add_argument("addr", type=str)

    write_parser = subparsers.add_parser("write", help="write one 32-bit register")
    write_parser.add_argument("addr", type=str)
    write_parser.add_argument("data", type=lambda text: int(text, 0))

    dump_parser = subparsers.add_parser("dump", help="dump a register range")
    dump_parser.add_argument("start_addr", type=str)
    dump_parser.add_argument(
        "--count",
        type=int,
        default=8,
        help="number of 32-bit registers to read",
    )

    watch_parser = subparsers.add_parser("watch", help="periodically poll a register range")
    watch_parser.add_argument("start_addr", type=str)
    watch_parser.add_argument(
        "--count",
        type=int,
        default=8,
        help="number of 32-bit registers to read",
    )
    watch_parser.add_argument(
        "--interval",
        type=float,
        default=0.5,
        help="poll interval in seconds",
    )
    watch_parser.add_argument(
        "--iterations",
        type=int,
        default=0,
        help="number of polls to run (0 = forever)",
    )
    watch_parser.add_argument(
        "--changed-only",
        action="store_true",
        help="only print registers whose value changed since the previous poll",
    )

    subparsers.add_parser("map", help="list known register names and addresses")

    return parser


def print_response(resp: UdpRegResponse, regs_by_addr: dict[int, RegisterDef] | None = None) -> None:
    reg_name = reg_name_for_addr(resp.addr, regs_by_addr)
    reg_text = f" {reg_name}" if reg_name is not None else ""
    print(
        "cmd=0x{cmd:02X} status={status} addr=0x{addr:04X}{reg_text} "
        "data=0x{data:08X} seq=0x{seq:04X}".format(
            cmd=resp.cmd,
            status=status_to_text(resp.status),
            addr=resp.addr & 0xFFFF,
            reg_text=reg_text,
            data=resp.data,
            seq=resp.seq,
        )
    )
    decoded = decode_register_value(resp.addr, resp.data)
    if decoded:
        print("      " + " ".join(decoded))


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    regs_by_name, regs_by_addr = load_register_map(args.reg_map)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        if args.bind_ip or args.bind_port:
            sock.bind((args.bind_ip, args.bind_port))

        if args.subcmd == "ping":
            resp = transact(
                sock=sock,
                target_ip=args.ip,
                target_port=args.port,
                cmd=CMD_PING,
                addr=0,
                data=args.data,
                seq=args.seq,
                timeout_s=args.timeout,
            )
            print_response(resp, regs_by_addr)
            return 0 if resp.status == STS_OK else 2

        if args.subcmd == "read":
            addr = validate_register_addr(resolve_register_arg(args.addr, regs_by_name))
            resp = transact(
                sock=sock,
                target_ip=args.ip,
                target_port=args.port,
                cmd=CMD_READ,
                addr=addr,
                data=0,
                seq=args.seq,
                timeout_s=args.timeout,
            )
            print_response(resp, regs_by_addr)
            return 0 if resp.status == STS_OK else 2

        if args.subcmd == "write":
            addr = validate_register_addr(resolve_register_arg(args.addr, regs_by_name))
            resp = transact(
                sock=sock,
                target_ip=args.ip,
                target_port=args.port,
                cmd=CMD_WRITE,
                addr=addr,
                data=args.data,
                seq=args.seq,
                timeout_s=args.timeout,
            )
            print_response(resp, regs_by_addr)
            return 0 if resp.status == STS_OK else 2

        if args.subcmd == "dump":
            start_addr = validate_register_addr(resolve_register_arg(args.start_addr, regs_by_name))
            for index, resp in enumerate(
                dump_registers(
                    sock=sock,
                    target_ip=args.ip,
                    target_port=args.port,
                    start_addr=start_addr,
                    count=args.count,
                    timeout_s=args.timeout,
                    seq_start=args.seq,
                )
            ):
                print(f"[{index:02d}] ", end="")
                print_response(resp, regs_by_addr)
            return 0

        if args.subcmd == "watch":
            start_addr = validate_register_addr(resolve_register_arg(args.start_addr, regs_by_name))
            previous_values: dict[int, int] = {}
            poll_index = 0
            seq_base = args.seq
            try:
                while args.iterations == 0 or poll_index < args.iterations:
                    responses = list(
                        dump_registers(
                            sock=sock,
                            target_ip=args.ip,
                            target_port=args.port,
                            start_addr=start_addr,
                            count=args.count,
                            timeout_s=args.timeout,
                            seq_start=seq_base,
                        )
                    )
                    seq_base = (seq_base + args.count) & 0xFFFF
                    print(f"# poll={poll_index} t={time.strftime('%Y-%m-%d %H:%M:%S')}")
                    for index, resp in enumerate(responses):
                        current_value = resp.data & 0xFFFF_FFFF
                        changed = previous_values.get(resp.addr) != current_value
                        previous_values[resp.addr] = current_value
                        if args.changed_only and poll_index > 0 and not changed:
                            continue
                        print(f"[{index:02d}] ", end="")
                        print_response(resp, regs_by_addr)
                    poll_index += 1
                    if args.iterations != 0 and poll_index >= args.iterations:
                        break
                    time.sleep(args.interval)
            except KeyboardInterrupt:
                print("# watch interrupted")
            return 0

        if args.subcmd == "map":
            for addr, reg_def in sorted(regs_by_addr.items(), key=lambda item: item[0]):
                print(
                    "0x{addr:04X} {name} {access} reset=0x{reset:08X} {desc}".format(
                        addr=addr,
                        name=reg_def.name,
                        access=reg_def.access,
                        reset=reg_def.reset_value,
                        desc=reg_def.description,
                    )
                )
            return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
