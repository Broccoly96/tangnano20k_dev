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
    "PROTO_ERROR_COUNT"           : 0x0000_0028,
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
    "FPGA_STATUS"                 : 0x0000_009C,
    "FPGA_UPTIME_LO"              : 0x0000_00A0,
    "FPGA_UPTIME_HI"              : 0x0000_00A4,
    "FPGA_SNAPSHOT_COUNT"         : 0x0000_00A8,
    "PCIE_STATUS"                 : 0x0000_00AC,
    "PCIE_TLP_UNSUPPORTED_COUNT"  : 0x0000_00B0,
    "PCIE_RX_FRAME_COUNT"         : 0x0000_00B4,
    "PCIE_RX_DROP_COUNT"          : 0x0000_00B8,
    "PCIE_TX_FRAME_COUNT"         : 0x0000_00BC,
    "PCIE_TX_DROP_COUNT"          : 0x0000_00C0,
    "PCIE_LOG_CONTROL"            : 0x0000_00C4,
    "PCIE_LOG_TRIGGER"            : 0x0000_00C8,
    "IPV4_DROP_COUNT"             : 0x0000_00CC,
    "UDP_DROP_COUNT"              : 0x0000_00D0,
    "RX_MALFORMED_COUNT"          : 0x0000_00D4,
    "PCIE_LINKUP_STATUS"          : 0x0000_00D8,
    "PCIE_LTSSM"                  : 0x0000_00DC,
    "PCIE_LAST_RX_ERROR"          : 0x0000_00E0,
    "PCIE_MMIO_STATUS"            : 0x0000_00E4,
    "PCIE_RX_AVAIL_CNT"           : 0x0000_00E8,
    "PCIE_RX_CUR_LEN"             : 0x0000_00EC,
    "PCIE_RX_CUR_STATUS"          : 0x0000_00F0,
    "PCIE_TX_STATUS_MIRROR"       : 0x0000_00F4,
    "PCIE_TX_FIFO_LEVEL"          : 0x0000_00F8,
    "PCIE_IRQ_STATUS_MIRROR"      : 0x0000_00FC,
    "PCIE_LAST_BAR0_ADDR"         : 0x0000_0100,
    "PCIE_LAST_BAR0_ACCESS"       : 0x0000_0104,
    "PCIE_TLP_RX_VALID_COUNT"     : 0x0000_0108,
    "PCIE_DRP_RD_VALID_COUNT"     : 0x0000_010C,
    "PCIE_DRP_STATUS"             : 0x0000_0110,
    "PCIE_LAST_RX_RAW_DW0"        : 0x0000_0114,
    "PCIE_LAST_RX_RAW_DW1"        : 0x0000_0118,
    "PCIE_LAST_RX_RAW_DW2"        : 0x0000_011C,
    "PCIE_LAST_RX_RAW_DW3"        : 0x0000_0120,
    "PCIE_LAST_RX_RAW_DW4"        : 0x0000_0124,
    "PCIE_LAST_RX_RAW_DW5"        : 0x0000_0128,
    "PCIE_LAST_RX_RAW_DW6"        : 0x0000_012C,
    "PCIE_LAST_RX_RAW_DW7"        : 0x0000_0130,
    "PCIE_LAST_TX_VALID"          : 0x0000_0134,
    "PCIE_TX_CPL_COUNT"           : 0x0000_0138,
    "PCIE_LAST_TX_RAW_DW4"        : 0x0000_013C,
    "PCIE_LAST_TX_RAW_DW5"        : 0x0000_0140,
    "PCIE_LAST_TX_RAW_DW6"        : 0x0000_0144,
    "PCIE_LAST_TX_RAW_DW7"        : 0x0000_0148,
    "PCIE_REQ_FIFO_RD_COUNT"      : 0x0000_014C,
    "PCIE_RSP_FIFO_WR_COUNT"      : 0x0000_0150,
    "PCIE_LAST_CORE_REQ_ADDR"     : 0x0000_0154,
    "PCIE_LAST_CORE_REQ_META"     : 0x0000_0158,
    "PCIE_LAST_TX_RAW_DW0"        : 0x0000_015C,
    "PCIE_LAST_TX_RAW_DW1"        : 0x0000_0160,
    "PCIE_LAST_TX_RAW_DW2"        : 0x0000_0164,
    "PCIE_LAST_TX_RAW_DW3"        : 0x0000_0168,
    "PCIE_TX_PATH_STATUS"         : 0x0000_016C,
    "PCIE_RSP_FIFO_RD_COUNT"      : 0x0000_0170,
    "PCIE_REQ_TLP_COUNT"          : 0x0000_0174,
    "PCIE_REQ_TLP_BARDEC"         : 0x0000_0178,
    "PCIE_REQ_TLP_DW0"            : 0x0000_017C,
    "PCIE_REQ_TLP_DW1"            : 0x0000_0180,
    "PCIE_REQ_TLP_DW2"            : 0x0000_0184,
    "PCIE_REQ_TLP_DW3"            : 0x0000_0188,
    "PCIE_REQ_TLP_DW4"            : 0x0000_018C,
    "PCIE_REQ_TLP_DW5"            : 0x0000_0190,
    "PCIE_REQ_TLP_DW6"            : 0x0000_0194,
    "PCIE_REQ_TLP_DW7"            : 0x0000_0198,
    "PCIE_RESP_TLP_COUNT"         : 0x0000_019C,
    "PCIE_RESP_TLP_DW0"           : 0x0000_01A0,
    "PCIE_RESP_TLP_DW1"           : 0x0000_01A4,
    "PCIE_RESP_TLP_DW2"           : 0x0000_01A8,
    "PCIE_RESP_TLP_DW3"           : 0x0000_01AC,
    "PCIE_RESP_TLP_DW4"           : 0x0000_01B0,
    "PCIE_RESP_TLP_DW5"           : 0x0000_01B4,
    "PCIE_RESP_TLP_DW6"           : 0x0000_01B8,
    "PCIE_RESP_TLP_DW7"           : 0x0000_01BC,
    "PCIE_RXCDC_FIFO_WR_COUNT"    : 0x0000_01C0,
    "PCIE_RXCDC_FIFO_RD_EN_COUNT" : 0x0000_01C4,
    "PCIE_RXCDC_OUT_VALID_COUNT"  : 0x0000_01C8,
    "PCIE_RXCDC_LAST_Q_AT_RDEN_DW0": 0x0000_01CC,
    "PCIE_RXCDC_LAST_Q_AT_RDEN_META": 0x0000_01D0,
    "PCIE_RXCDC_LAST_Q_AFTER1_DW0": 0x0000_01D4,
    "PCIE_RXCDC_LAST_Q_AFTER1_META": 0x0000_01D8,
    "PCIE_IP_RX_BEAT_COUNT"       : 0x0000_01DC,
    "PCIE_IP_RX_SOP_COUNT"        : 0x0000_01E0,
    "PCIE_IP_RX_EOP_COUNT"        : 0x0000_01E4,
    "PCIE_IP_RX_OBS_STATUS"       : 0x0000_01E8,
    "PCIE_IP_RX_OBS_DW0"          : 0x0000_01EC,
    "PCIE_IP_RX_OBS_META"         : 0x0000_01F0,
    "PCIE_IP_RX_ERR_LAST"         : 0x0000_01F4,
    "PCIE_TXIP_VALID_COUNT"       : 0x0000_01F8,
    "PCIE_TXIP_SOP_COUNT"         : 0x0000_01FC,
    "PCIE_TXIP_WAIT_COUNT"        : 0x0000_0200,
}
REGISTER_NAMES = {addr: name for name, addr in REGISTERS.items()}
DEFAULT_REG_MAP_PATH = Path(__file__).resolve().with_name("eth_udp_reg_map.default.yaml")
_DEFAULT_REG_MAP_CACHE: tuple[dict[str, "RegisterDef"], dict[int, "RegisterDef"]] | None = None


@dataclasses.dataclass(frozen=True)
class RegisterDef:
    address: int
    name: str
    access: str
    reset_value: int
    description: str
    space: str = "direct"
    block: int = 0
    screen: str = "eth"
    group: str = "default"
    fmt: str = "hex"
    poll_default: bool = False
    decoder: dict | None = None

    @property
    def conf_index(self) -> int:
        return ((self.block & 0xFF) << 8) | (self.address & 0xFF)


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


def response_cmd_for_request(cmd: int) -> int:
    if cmd == CMD_READ:
        return CMD_READ_RESP
    if cmd == CMD_WRITE:
        return CMD_WRITE_RESP
    if cmd == CMD_PING:
        return CMD_PING_RESP
    raise ValueError(f"unsupported request cmd: 0x{cmd:02X}")


def response_matches_request(resp: UdpRegResponse, *, cmd: int, addr: int, seq: int) -> bool:
    return (
        resp.cmd == response_cmd_for_request(cmd) and
        (resp.addr & 0xFFFF_FFFF) == (addr & 0xFFFF_FFFF) and
        (resp.seq & 0xFFFF) == (seq & 0xFFFF)
    )


def log_stream_write_verified(write_value: int, control_value: int, status_value: int) -> bool:
    requested_enable = write_value & 0x1
    control_enable = control_value & 0x1
    status_active = status_value & 0x1
    return (control_enable == requested_enable) and (status_active == requested_enable)


def pcie_trigger_verified(write_value: int, packet_count_before: int | None, packet_count_after: int) -> bool:
    if (write_value & 0x3) == 0:
        return True
    if packet_count_before is None:
        return False
    return packet_count_after > packet_count_before


def load_register_map(path: str | Path | None = None) -> tuple[dict[str, RegisterDef], dict[int, RegisterDef]]:
    reg_path = Path(path) if path is not None else DEFAULT_REG_MAP_PATH
    loaded = _load_yaml_mapping(reg_path)

    by_name: dict[str, RegisterDef] = {}
    by_addr: dict[int, RegisterDef] = {}
    registers_raw = loaded.get("registers", loaded)
    if isinstance(registers_raw, list):
        for entry in registers_raw:
            reg_def = _parse_register_entry(entry, space_default="direct", block_default=0)
            by_name[reg_def.name] = reg_def
            if reg_def.space == "direct":
                by_addr[reg_def.address] = reg_def
    else:
        raise ValueError("register map YAML must contain a 'registers' list")

    conf_blocks = loaded.get("conf_blocks", [])
    if isinstance(conf_blocks, list):
        for block_entry in conf_blocks:
            if not isinstance(block_entry, dict):
                raise ValueError("conf_blocks entry must be a mapping")
            block_id_raw = block_entry.get("block", 0)
            block_id = int(block_id_raw, 0) if isinstance(block_id_raw, str) else int(block_id_raw)
            registers = block_entry.get("registers", [])
            if not isinstance(registers, list):
                raise ValueError("conf_blocks.registers must be a list")
            for entry in registers:
                reg_def = _parse_register_entry(
                    entry,
                    space_default="conf",
                    block_default=block_id,
                    screen_default=str(block_entry.get("screen", "fpga")),
                    group_default=str(block_entry.get("group", block_entry.get("name", "conf"))),
                )
                by_name[reg_def.name] = reg_def
    return by_name, by_addr


def _parse_register_entry(
    entry: dict,
    *,
    space_default: str,
    block_default: int,
    screen_default: str = "eth",
    group_default: str = "default",
) -> RegisterDef:
    if not isinstance(entry, dict):
        raise ValueError("register map entry must be a mapping")
    name = str(entry["name"]).strip().upper()
    address = int(entry["address"], 0) if isinstance(entry["address"], str) else int(entry["address"])
    access = str(entry.get("access", "RO")).strip().upper()
    reset_value_raw = entry.get("reset_value", 0)
    reset_value = int(reset_value_raw, 0) if isinstance(reset_value_raw, str) else int(reset_value_raw)
    block_raw = entry.get("block", block_default)
    block = int(block_raw, 0) if isinstance(block_raw, str) else int(block_raw)
    return RegisterDef(
        address=address & 0xFFFF_FFFF,
        name=name,
        access=access,
        reset_value=reset_value & 0xFFFF_FFFF,
        description=str(entry.get("description", "")),
        space=str(entry.get("space", space_default)).strip().lower(),
        block=block & 0xFF,
        screen=str(entry.get("screen", screen_default)).strip().lower(),
        group=str(entry.get("group", group_default)).strip().lower(),
        fmt=str(entry.get("format", "hex")).strip().lower(),
        poll_default=bool(entry.get("poll_default", False)),
        decoder=entry.get("decoder") if isinstance(entry.get("decoder"), dict) else None,
    )


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
        if token in regs_by_name and regs_by_name[token].space == "direct":
            return regs_by_name[token].address
        if token.startswith("REG_") and token[4:] in regs_by_name and regs_by_name[token[4:]].space == "direct":
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


def _default_regs_by_addr() -> dict[int, RegisterDef]:
    global _DEFAULT_REG_MAP_CACHE
    if _DEFAULT_REG_MAP_CACHE is None:
        _DEFAULT_REG_MAP_CACHE = load_register_map(DEFAULT_REG_MAP_PATH)
    return _DEFAULT_REG_MAP_CACHE[1]


def _decoder_reg_def(
    addr_u32: int,
    reg_def: RegisterDef | None,
    regs_by_addr: dict[int, RegisterDef] | None,
) -> RegisterDef | None:
    if reg_def is not None:
        return reg_def
    if regs_by_addr is not None:
        return regs_by_addr.get(addr_u32)
    return _default_regs_by_addr().get(addr_u32)


def _decode_yaml_bitset(reg_def: RegisterDef, value_u32: int) -> list[str]:
    decoder = reg_def.decoder or {}
    fields = decoder.get("fields", [])
    if not isinstance(fields, list):
        return []
    decoded: list[str] = []
    for field in fields:
        if not isinstance(field, dict):
            continue
        bit = int(field.get("bit", 0))
        name = str(field.get("name", f"bit{bit}")).strip()
        decoded.append(f"{name}={(value_u32 >> bit) & 0x1}")
    return decoded


def _decode_yaml_enum(reg_def: RegisterDef, value_u32: int) -> list[str]:
    decoder = reg_def.decoder or {}
    lsb = int(decoder.get("lsb", 0))
    width = int(decoder.get("width", 32))
    mask = (1 << width) - 1 if width < 32 else 0xFFFF_FFFF
    field_name = str(decoder.get("field_name", reg_def.name.lower())).strip()
    raw_value = (value_u32 >> lsb) & mask
    values = decoder.get("values", {})
    decoded_name = None
    if isinstance(values, dict):
        decoded_name = values.get(raw_value)
        if decoded_name is None:
          decoded_name = values.get(f"0x{raw_value:02X}")
        if decoded_name is None:
          decoded_name = values.get(f"0x{raw_value:X}")
    if decoded_name is None:
        return [f"{field_name}=0x{raw_value:X}"]
    return [f"{field_name}=0x{raw_value:02X}", f"name={decoded_name}"]


def _decode_from_yaml(
    addr_u32: int,
    value_u32: int,
    *,
    reg_def: RegisterDef | None,
    regs_by_addr: dict[int, RegisterDef] | None,
) -> list[str]:
    reg = _decoder_reg_def(addr_u32, reg_def, regs_by_addr)
    if reg is None or not isinstance(reg.decoder, dict):
        return []
    kind = str(reg.decoder.get("kind", "")).strip().lower()
    if kind == "bitset":
        return _decode_yaml_bitset(reg, value_u32)
    if kind == "enum":
        return _decode_yaml_enum(reg, value_u32)
    return []


def decode_register_value(
    addr: int,
    value: int,
    *,
    reg_def: RegisterDef | None = None,
    regs_by_addr: dict[int, RegisterDef] | None = None,
) -> list[str]:
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

    if addr_u32 == REGISTERS["FPGA_STATUS"]:
        return [
            f"pll_locked={(value_u32 >> 0) & 0x1}",
            f"rst_released={(value_u32 >> 1) & 0x1}",
            f"phy_rst_n={(value_u32 >> 2) & 0x1}",
            f"log_source_reset_observed={(value_u32 >> 3) & 0x1}",
            f"snapshot_seen={(value_u32 >> 4) & 0x1}",
        ]

    if addr_u32 == REGISTERS["PCIE_STATUS"]:
        return [
            f"present={(value_u32 >> 0) & 0x1}",
            f"bridge_enable={(value_u32 >> 2) & 0x1}",
            f"monitor_enable={(value_u32 >> 3) & 0x1}",
            f"intr_status=0x{(value_u32 >> 13) & 0x1F:02X}",
            f"intr_mask=0x{(value_u32 >> 18) & 0x1F:02X}",
        ]

    if addr_u32 == REGISTERS["PCIE_LINKUP_STATUS"]:
        return [f"link_up={(value_u32 >> 0) & 0x1}"]

    if addr_u32 == REGISTERS["PCIE_LOG_CONTROL"]:
        return [
            f"activity_periodic_enable={(value_u32 >> 0) & 0x1}",
            f"status_periodic_enable={(value_u32 >> 1) & 0x1}",
        ]

    if addr_u32 == REGISTERS["PCIE_LOG_TRIGGER"]:
        return [
            f"activity_snapshot_req={(value_u32 >> 0) & 0x1}",
            f"status_snapshot_req={(value_u32 >> 1) & 0x1}",
        ]

    return _decode_from_yaml(
        addr_u32,
        value_u32,
        reg_def=reg_def,
        regs_by_addr=regs_by_addr,
    )


def exchange_packet(
    sock: socket.socket,
    target_ip: str,
    target_port: int,
    packet: bytes,
    timeout_s: float,
    *,
    expect_cmd: int,
    expect_addr: int,
    expect_seq: int,
) -> UdpRegResponse:
    deadline = time.monotonic() + timeout_s
    sock.sendto(packet, (target_ip, target_port))
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("timed out")
        sock.settimeout(remaining)
        response, _ = sock.recvfrom(2048)
        parsed = parse_response(response)
        if parsed.magic != PROTO_MAGIC:
            continue
        if response_matches_request(
            parsed,
            cmd=expect_cmd,
            addr=expect_addr,
            seq=expect_seq,
        ):
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
    return exchange_packet(
        sock,
        target_ip,
        target_port,
        packet,
        timeout_s,
        expect_cmd=cmd,
        expect_addr=addr,
        expect_seq=seq,
    )


def read_direct_reg(
    sock: socket.socket,
    *,
    target_ip: str,
    target_port: int,
    addr: int,
    seq: int,
    timeout_s: float,
) -> UdpRegResponse:
    return transact(
        sock=sock,
        target_ip=target_ip,
        target_port=target_port,
        cmd=CMD_READ,
        addr=addr,
        data=0,
        seq=seq,
        timeout_s=timeout_s,
    )


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
    if resp.status != STS_OK:
        return
    reg_def = regs_by_addr.get(resp.addr & 0xFFFF_FFFF) if regs_by_addr is not None else None
    decoded = decode_register_value(
        resp.addr,
        resp.data,
        reg_def=reg_def,
        regs_by_addr=regs_by_addr,
    )
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
            packet_count_before: int | None = None
            if addr == REGISTERS["PCIE_LOG_TRIGGER"]:
                try:
                    packet_count_before = read_direct_reg(
                        sock=sock,
                        target_ip=args.ip,
                        target_port=args.port,
                        addr=REGISTERS["LOG_STREAM_PACKET_COUNT"],
                        seq=(args.seq - 1) & 0xFFFF,
                        timeout_s=args.timeout,
                    ).data
                except Exception:
                    packet_count_before = None
            try:
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
            except TimeoutError:
                if addr == REGISTERS["LOG_STREAM_CONTROL"]:
                    control_resp = read_direct_reg(
                        sock=sock,
                        target_ip=args.ip,
                        target_port=args.port,
                        addr=REGISTERS["LOG_STREAM_CONTROL"],
                        seq=(args.seq + 1) & 0xFFFF,
                        timeout_s=args.timeout,
                    )
                    status_resp = read_direct_reg(
                        sock=sock,
                        target_ip=args.ip,
                        target_port=args.port,
                        addr=REGISTERS["LOG_STREAM_STATUS"],
                        seq=(args.seq + 2) & 0xFFFF,
                        timeout_s=args.timeout,
                    )
                    if log_stream_write_verified(
                        args.data,
                        control_resp.data,
                        status_resp.data,
                    ):
                        resp = UdpRegResponse(
                            magic=PROTO_MAGIC,
                            cmd=CMD_WRITE_RESP,
                            status=STS_OK,
                            addr=addr,
                            data=args.data & 0xFFFF_FFFF,
                            seq=args.seq & 0xFFFF,
                            reserved=0,
                        )
                        print("# write ack timeout; verified LOG_STREAM state by readback")
                    else:
                        raise
                elif addr == REGISTERS["PCIE_LOG_TRIGGER"]:
                    time.sleep(0.2)
                    packet_count_after = read_direct_reg(
                        sock=sock,
                        target_ip=args.ip,
                        target_port=args.port,
                        addr=REGISTERS["LOG_STREAM_PACKET_COUNT"],
                        seq=(args.seq + 1) & 0xFFFF,
                        timeout_s=args.timeout,
                    ).data
                    if pcie_trigger_verified(args.data, packet_count_before, packet_count_after):
                        resp = UdpRegResponse(
                            magic=PROTO_MAGIC,
                            cmd=CMD_WRITE_RESP,
                            status=STS_OK,
                            addr=addr,
                            data=args.data & 0xFFFF_FFFF,
                            seq=args.seq & 0xFFFF,
                            reserved=0,
                        )
                        delta = packet_count_after - (packet_count_before or 0)
                        print(f"# write ack timeout; verified PCIe trigger by log packet delta +{delta}")
                    else:
                        raise
                else:
                    raise
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
