"""UART log event decoder using YAML rule definitions."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - exercised via from_yaml guard
    yaml = None

from uart_log_protocol import Event

_PLACEHOLDER_PATTERN = re.compile(r"\{([a-zA-Z0-9_]+)(?::([^}]+))?\}")


@dataclass(frozen=True)
class DecodedEvent:
    """Human-readable decode result for one event."""

    level: str
    title: str
    message: str
    tags: list[str]


@dataclass(frozen=True)
class _Rule:
    """Internal normalized decode rule."""

    level: str
    title: str
    message: str
    tags: list[str]
    decode: str


class UARTLogDecoder:
    """Decodes Event objects using key-based YAML rules.

    Priority order:
      1) src:event exact match
      2) src:*
      3) *:event
      4) default
    """

    def __init__(self) -> None:
        self._exact: dict[tuple[int, int], _Rule] = {}
        self._src_any: dict[int, _Rule] = {}
        self._any_evt: dict[int, _Rule] = {}
        self._default: _Rule | None = None

    @staticmethod
    def _pcie_ltssm_name(value: int) -> str:
        names = {
            0x00: "detect.quiet",
            0x01: "detect.active",
            0x02: "polling.active",
            0x03: "polling.compliance",
            0x04: "polling.configuration",
            0x05: "config.linkwidthstart",
            0x06: "config.linkwidthaccept",
            0x07: "config.lanenumwait",
            0x08: "config.lanenumaccept",
            0x09: "config.complete",
            0x0A: "config.idle",
            0x0B: "recovery.receiverlock",
            0x0C: "recovery.equalization",
            0x0D: "recovery.speed",
            0x0E: "recovery.receiverconfig",
            0x0F: "recovery.idle",
            0x10: "L0",
            0x11: "L0s",
            0x12: "L1.entry",
            0x13: "L1.idle",
            0x14: "L2.idle/L2.transmitwake",
            0x15: "reserved",
            0x16: "disable",
            0x17: "loopback.entry",
            0x18: "loopback.active",
            0x19: "loopback.exit",
            0x1A: "hotreset",
        }
        return names.get(value, f"unknown(0x{value:02X})")

    @classmethod
    def from_yaml(cls, path: str | Path) -> "UARTLogDecoder":
        """Load decode rules from a YAML file."""

        if yaml is None:
            raise RuntimeError(
                "PyYAML is required for from_yaml(); install 'PyYAML' or use from_mapping()."
            )

        decoder = cls()
        rule_path = Path(path)
        with rule_path.open("r", encoding="utf-8") as fp:
            loaded = yaml.safe_load(fp) or {}

        if not isinstance(loaded, dict):
            raise ValueError("decoder YAML top-level must be a mapping")

        rules_raw = loaded.get("rules", loaded)
        if not isinstance(rules_raw, dict):
            raise ValueError("decoder rules must be a mapping")

        decoder._load_mapping(rules_raw)
        return decoder

    @classmethod
    def from_mapping(cls, rules: dict[str, Any]) -> "UARTLogDecoder":
        """Construct decoder from in-memory rule mapping (tests/helper)."""

        decoder = cls()
        decoder._load_mapping(rules)
        return decoder

    def _load_mapping(self, rules_raw: dict[str, Any]) -> None:
        for key, value in rules_raw.items():
            if key == "version":
                continue
            rule = self._normalize_rule(value)
            self._register_rule(str(key), rule)

    def _normalize_rule(self, raw: Any) -> _Rule:
        if not isinstance(raw, dict):
            raise ValueError("rule body must be a mapping")

        level = str(raw.get("level", "INFO"))
        title = str(raw.get("title", ""))
        message = str(raw.get("message", ""))
        decode = str(raw.get("decode", "")).strip()

        tags_raw = raw.get("tags", [])
        if isinstance(tags_raw, list):
            tags = [str(t) for t in tags_raw]
        else:
            tags = [str(tags_raw)]

        return _Rule(level=level, title=title, message=message, tags=tags, decode=decode)

    def _register_rule(self, key: str, rule: _Rule) -> None:
        if key == "default":
            self._default = rule
            return

        parts = key.split(":")
        if len(parts) != 2:
            raise ValueError(f"invalid rule key: {key}")

        src_tok, evt_tok = parts[0].strip(), parts[1].strip()
        src_id = self._parse_token(src_tok)
        evt_id = self._parse_token(evt_tok)

        if src_id is None and evt_id is None:
            self._default = rule
        elif src_id is None:
            self._any_evt[evt_id] = rule
        elif evt_id is None:
            self._src_any[src_id] = rule
        else:
            self._exact[(src_id, evt_id)] = rule

    @staticmethod
    def _parse_token(token: str) -> int | None:
        if token == "*":
            return None

        value = int(token, 0)
        if value < 0 or value > 0xFF:
            raise ValueError(f"token out of 8-bit range: {token}")
        return value

    @staticmethod
    def _extract_help_ascii(event: Event) -> str:
        raw = (
            event.arg0.to_bytes(4, byteorder="little")
            + event.arg1.to_bytes(4, byteorder="little")
            + event.arg2.to_bytes(4, byteorder="little")
        )
        stripped = raw.split(b"\x00", 1)[0]
        return "".join(chr(b) if 32 <= b < 127 else "." for b in stripped)

    @staticmethod
    def _context(event: Event) -> dict[str, Any]:
        return {
            "src_id": event.src_id,
            "event_id": event.event_id,
            "timestamp": event.timestamp,
            "arg0": event.arg0,
            "arg1": event.arg1,
            "arg2": event.arg2,
            "arg0_u32": event.arg0 & 0xFFFF_FFFF,
            "arg1_u32": event.arg1 & 0xFFFF_FFFF,
            "arg2_u32": event.arg2 & 0xFFFF_FFFF,
            "arg0_u8": event.arg0 & 0xFF,
            "arg1_u8": event.arg1 & 0xFF,
            "arg2_u8": event.arg2 & 0xFF,
            "arg0_hex": f"{event.arg0:08X}",
            "arg1_hex": f"{event.arg1:08X}",
            "arg2_hex": f"{event.arg2:08X}",
        }

    @staticmethod
    def _apply_decode_mode(decode_mode: str, event: Event, context: dict[str, Any]) -> None:
        mode = decode_mode.lower()
        if mode == "help_ascii":
            context["help_ascii"] = UARTLogDecoder._extract_help_ascii(event)
            return

        if mode == "pcie_edge":
            context["edge_prev"] = (event.arg0 >> 1) & 0x1
            context["edge_curr"] = event.arg0 & 0x1
            return

        if mode == "pcie_ltssm":
            context["ltssm_prev"] = (event.arg0 >> 5) & 0x1F
            context["ltssm_curr"] = event.arg0 & 0x1F
            context["ltssm_prev_hex"] = f"{context['ltssm_prev']:02X}"
            context["ltssm_curr_hex"] = f"{context['ltssm_curr']:02X}"
            context["ltssm_prev_name"] = UARTLogDecoder._pcie_ltssm_name(context["ltssm_prev"])
            context["ltssm_curr_name"] = UARTLogDecoder._pcie_ltssm_name(context["ltssm_curr"])
            return

        if mode == "pcie_rx_err":
            context["rx_err"] = event.arg0 & 0xFF
            context["rx_valid"] = event.arg1 & 0xFF
            context["rx_sop"] = (event.arg2 >> 1) & 0x1
            context["rx_eop"] = event.arg2 & 0x1
            context["rx_bardec"] = (event.arg2 >> 2) & 0x3F
            context["rx_err_hex"] = f"{context['rx_err']:02X}"
            context["rx_valid_hex"] = f"{context['rx_valid']:02X}"
            context["rx_bardec_hex"] = f"{context['rx_bardec']:02X}"
            return

        if mode == "pcie_tlp_chunk":
            context["chunk_idx"] = (event.arg0 >> 28) & 0xF
            context["beat_seq"] = (event.arg0 >> 16) & 0xFFF
            context["rx_valid"] = (event.arg0 >> 8) & 0xFF
            context["rx_sop"] = (event.arg0 >> 7) & 0x1
            context["rx_eop"] = (event.arg0 >> 6) & 0x1
            context["rx_valid_hex"] = f"{context['rx_valid']:02X}"
            return

        if mode == "pcie_ep_status":
            context["ltssm_curr"] = event.arg0 & 0x1F
            context["ltssm_curr_hex"] = f"{context['ltssm_curr']:02X}"
            context["linkup_curr"] = (event.arg0 >> 5) & 0x1
            context["rst_pcie_100m_n_curr"] = (event.arg0 >> 6) & 0x1
            context["rst_pcie_100m_asserted_curr"] = (event.arg0 >> 7) & 0x1
            context["rx_err_curr"] = (event.arg0 >> 8) & 0xFF
            context["rx_err_sticky"] = (event.arg0 >> 16) & 0xFF
            context["req_key"] = (event.arg0 >> 24) & 0xFF
            context["req_count"] = event.arg1 & 0xFFFF
            context["tx_wait_curr"] = (event.arg1 >> 16) & 0x1
            context["rx_err_curr_hex"] = f"{context['rx_err_curr']:02X}"
            context["rx_err_sticky_hex"] = f"{context['rx_err_sticky']:02X}"
            context["req_key_hex"] = f"{context['req_key']:02X}"
            return

    @staticmethod
    def _safe_format(template: str, context: dict[str, Any]) -> str:
        def resolve_value(key: str) -> Any:
            if key in context:
                return context[key]

            byte_match = re.fullmatch(r"(arg[0-2])_b([0-3])", key)
            if byte_match:
                word_name = byte_match.group(1)
                byte_idx = int(byte_match.group(2))
                word_value = int(context.get(word_name, 0)) & 0xFFFF_FFFF
                return (word_value >> (byte_idx * 8)) & 0xFF

            bit_match = re.fullmatch(r"(arg[0-2])_b([0-3])_bit([0-7])", key)
            if bit_match:
                word_name = bit_match.group(1)
                byte_idx = int(bit_match.group(2))
                bit_idx = int(bit_match.group(3))
                word_value = int(context.get(word_name, 0)) & 0xFFFF_FFFF
                byte_value = (word_value >> (byte_idx * 8)) & 0xFF
                return (byte_value >> bit_idx) & 0x1

            word_bit_match = re.fullmatch(r"(arg[0-2])_bit([0-9]|[12][0-9]|3[01])", key)
            if word_bit_match:
                word_name = word_bit_match.group(1)
                bit_idx = int(word_bit_match.group(2))
                word_value = int(context.get(word_name, 0)) & 0xFFFF_FFFF
                return (word_value >> bit_idx) & 0x1

            raise KeyError(key)

        def repl(match: re.Match[str]) -> str:
            key = match.group(1)
            fmt = match.group(2)
            try:
                value = resolve_value(key)
            except KeyError:
                return match.group(0)
            if fmt:
                try:
                    return format(value, fmt)
                except (TypeError, ValueError):
                    return str(value)
            if key in context:
                return str(value)
            if isinstance(value, int):
                return str(value)
            return match.group(0)

        return _PLACEHOLDER_PATTERN.sub(repl, template)

    def _select_rule(self, event: Event) -> _Rule | None:
        if (event.src_id, event.event_id) in self._exact:
            return self._exact[(event.src_id, event.event_id)]
        if event.src_id in self._src_any:
            return self._src_any[event.src_id]
        if event.event_id in self._any_evt:
            return self._any_evt[event.event_id]
        return self._default

    def decode(self, event: Event) -> DecodedEvent:
        """Decode one event according to configured rules."""

        rule = self._select_rule(event)

        if rule is None:
            return DecodedEvent(
                level="INFO",
                title="UNMAPPED",
                message=(
                    f"src={event.src_id} evt={event.event_id} ts={event.timestamp} "
                    f"arg0={event.arg0} arg1={event.arg1} arg2={event.arg2}"
                ),
                tags=["fallback"],
            )

        context = self._context(event)

        self._apply_decode_mode(rule.decode, event, context)
        if rule.decode.lower() == "help_ascii":
            message = rule.message or "{help_ascii}"
        else:
            message = rule.message

        decoded_message = self._safe_format(message, context)

        if not decoded_message:
            decoded_message = (
                f"src={event.src_id} evt={event.event_id} ts={event.timestamp} "
                f"arg0={event.arg0} arg1={event.arg1} arg2={event.arg2}"
            )

        return DecodedEvent(
            level=rule.level,
            title=rule.title or "EVENT",
            message=decoded_message,
            tags=list(rule.tags),
        )
