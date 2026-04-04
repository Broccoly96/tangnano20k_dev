"""Textual multi-screen TUI for Ethernet UDP register access and log monitoring."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import socket
import time

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import Button, DataTable, Footer, Header, Input, Static

from eth_udp_reg_tool import (
    CMD_READ,
    CMD_WRITE,
    REGISTERS,
    RegisterDef,
    decode_register_value,
    load_register_map,
    status_to_text,
    transact,
)
from uart_log_decoder import UARTLogDecoder
from uart_log_udp import UDPLogClient
from uart_log_udp_protocol import (
    UDP_LOG_STREAM_UART_PRIMARY,
    UDPLogStreamDecoder,
    format_udp_log_flags,
    format_udp_log_stream_id,
)


@dataclass
class SessionState:
    target_ip: str
    target_port: int
    bind_ip: str
    bind_port: int
    last_status: str = "idle"
    last_error: str = "-"
    last_response: str = "-"


@dataclass(frozen=True)
class LogRow:
    time_text: str
    udp_seq: str
    stream: str
    flags: str
    valid: str
    src: str
    evt: str
    text: str


class EthUdpRegApp(App[None]):
    """Terminal UI with log, Ethernet, PCIe, and FPGA screens."""

    CSS = """
    #session_bar {
      height: 2;
      layout: horizontal;
      margin: 0 1;
    }
    #session_bar Input {
      width: 32;
      margin-right: 1;
    }
    #session_bar Static {
      width: auto;
      margin-right: 1;
      content-align: left middle;
    }
    #main_layout {
      layout: horizontal;
      height: 1fr;
      margin: 0 1;
    }
    #nav {
      width: 22;
      border: round;
      padding: 0 1;
      margin-right: 1;
    }
    #nav Button {
      width: 100%;
      margin-bottom: 1;
    }
    #nav Input {
      width: 100%;
      margin-bottom: 1;
    }
    .screen {
      height: 1fr;
      width: 1fr;
    }
    .hidden {
      display: none;
    }
    .toolbar {
      height: 3;
      layout: horizontal;
      margin-bottom: 1;
    }
    .toolbar Input {
      width: 20;
      margin-right: 1;
    }
    .toolbar Button {
      margin-right: 1;
    }
    .summary {
      height: 11;
      border: round;
      padding: 0 1;
      margin-bottom: 1;
    }
    .split {
      layout: horizontal;
      height: 1fr;
    }
    .split DataTable {
      width: 1fr;
      height: 1fr;
      margin-right: 1;
    }
    #log_screen #log_table {
      height: 1fr;
    }
    #eth_table, #pcie_table, #fpga_direct_table, #fpga_conf_table {
      height: 1fr;
    }
    #status_line {
      height: 2;
      margin: 0 1 1 1;
    }
    """

    BINDINGS = [
        ("1", "show_log", "Log"),
        ("2", "show_eth", "Eth"),
        ("3", "show_pcie", "PCIe"),
        ("4", "show_fpga", "FPGA"),
        ("r", "read_selected", "Read"),
        ("w", "write_selected", "Write"),
        ("p", "toggle_watch", "Watch"),
        ("c", "toggle_changed_only", "Changed"),
        ("d", "toggle_log_mode", "Decode/Raw"),
        ("s", "save_log_view", "Save View"),
        ("l", "toggle_session_log", "Session Log"),
        ("m", "reload_map", "Reload Map"),
        ("t", "toggle_pcie_activity_periodic", "PCIe Act Per"),
        ("y", "toggle_pcie_status_periodic", "PCIe Sts Per"),
        ("g", "trigger_pcie_activity_snapshot", "PCIe Act Snap"),
        ("h", "trigger_pcie_status_snapshot", "PCIe Sts Snap"),
        ("q", "quit", "Quit"),
    ]

    def __init__(
        self,
        *,
        target_ip: str,
        target_port: int,
        bind_ip: str,
        bind_port: int,
        reg_map_path: str,
        log_file: str | None,
    ) -> None:
        super().__init__()
        self._session = SessionState(
            target_ip=target_ip,
            target_port=int(target_port),
            bind_ip=bind_ip,
            bind_port=int(bind_port),
        )
        self._reg_map_path = reg_map_path
        self._decoder_path = Path(__file__).resolve().with_name("decode_rules.default.yaml")
        self._regs_by_name: dict[str, RegisterDef] = {}
        self._regs_by_addr: dict[int, RegisterDef] = {}
        self._screen_regs: dict[str, list[RegisterDef]] = {"eth": [], "pcie": [], "fpga_direct": [], "fpga_conf": []}
        self._row_maps: dict[str, list[RegisterDef]] = {}
        self._values: dict[str, int] = {}
        self._active_screen = "log"
        self._watch_enabled = False
        self._changed_only = False
        self._poll_interval_s = 2.0
        self._next_poll_at = 0.0
        self._seq = 1

        self._udp = UDPLogClient()
        self._udp_decoder = UDPLogStreamDecoder()
        self._decoder = UARTLogDecoder()
        self._log_mode = "decode"
        self._udp_log_bind_port = 50001
        self._udp_log_bound_port = 0
        self._udp_last_peer = "-"
        self._udp_last_seq = "-"
        self._udp_last_valid = "-"
        self._udp_last_flags = "-"
        self._udp_last_stream = "-"
        self._udp_last_gap = 0
        self._udp_last_timestamp = "-"
        self._udp_packet_count = 0
        self._udp_packet_lost = 0
        self._log_rows: list[LogRow] = []
        self._log_src_filter = ""
        self._log_evt_filter = ""
        self._log_text_filter = ""
        self._log_file_path = Path(log_file) if log_file else None
        self._log_fp = None
        self._session_log_enabled = bool(log_file)
        self._pending_status_text = "status: idle"

        self._reload_decoder()

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Vertical():
            with Horizontal(id="session_bar"):
                yield Static("Target IP")
                yield Input(self._session.target_ip, id="target_ip")
                yield Static("Bind IP")
                yield Input(self._session.bind_ip, id="bind_ip")
                yield Static("Target Port")
                yield Input(str(self._session.target_port), id="target_port")
                yield Static("Bind Port")
                yield Input(str(self._session.bind_port), id="bind_port")
                yield Static("last: -", id="session_last")
                yield Static("err: -", id="session_error")
            with Horizontal(id="main_layout"):
                with Vertical(id="nav"):
                    yield Button("1 Log", id="nav_log")
                    yield Button("2 Eth", id="nav_eth")
                    yield Button("3 PCIe", id="nav_pcie")
                    yield Button("4 FPGA", id="nav_fpga")
                    yield Input("0x00000000", id="write_value", placeholder="write value")
                    yield Input("2.0", id="poll_interval", placeholder="poll sec")
                    yield Button("Read", id="btn_read")
                    yield Button("Write", id="btn_write")
                    yield Button("Reload Map", id="btn_reload")
                    yield Button("Watch OFF", id="btn_watch")
                    yield Button("Changed ALL", id="btn_changed")
                with Vertical(id="screen_host"):
                    with Vertical(id="log_screen", classes="screen"):
                        with Horizontal(classes="toolbar"):
                            yield Input("", id="log_src_filter", placeholder="SRC all / 0x04")
                            yield Input("", id="log_evt_filter", placeholder="EVT all / 0x61")
                            yield Input("", id="log_text_filter", placeholder="text filter")
                            yield Input(str(self._decoder_path), id="decoder_path")
                            yield Button("Decode", id="btn_log_mode")
                            yield Button("Reload Decoder", id="btn_decoder_reload")
                            yield Button("Save View", id="btn_save_view")
                            yield Button("Session Log ON" if self._session_log_enabled else "Session Log OFF", id="btn_session_log")
                            yield Button("Clear", id="btn_log_clear")
                        yield Static("", id="log_summary", classes="summary")
                        yield DataTable(id="log_table")
                    with Vertical(id="eth_screen", classes="screen hidden"):
                        with Horizontal(classes="toolbar"):
                            yield Static("Eth register map", id="eth_toolbar_title")
                        yield Static("", id="eth_summary", classes="summary")
                        yield DataTable(id="eth_table")
                    with Vertical(id="pcie_screen", classes="screen hidden"):
                        with Horizontal(classes="toolbar"):
                            yield Static("PCIe register map", id="pcie_toolbar_title")
                            yield Button("Act Periodic", id="btn_pcie_toggle_act_periodic")
                            yield Button("Sts Periodic", id="btn_pcie_toggle_sts_periodic")
                            yield Button("Act Snap", id="btn_pcie_trigger_act")
                            yield Button("Sts Snap", id="btn_pcie_trigger_sts")
                        yield Static("", id="pcie_summary", classes="summary")
                        yield DataTable(id="pcie_table")
                    with Vertical(id="fpga_screen", classes="screen hidden"):
                        with Horizontal(classes="toolbar"):
                            yield Static("FPGA register map", id="fpga_toolbar_title")
                        yield Static("", id="fpga_summary", classes="summary")
                        with Horizontal(classes="split"):
                            yield DataTable(id="fpga_direct_table")
                            yield DataTable(id="fpga_conf_table")
            yield Static("status: idle", id="status_line")
        yield Footer()

    def on_mount(self) -> None:
        self._log_table = self.query_one("#log_table", DataTable)
        self._eth_table = self.query_one("#eth_table", DataTable)
        self._pcie_table = self.query_one("#pcie_table", DataTable)
        self._fpga_direct_table = self.query_one("#fpga_direct_table", DataTable)
        self._fpga_conf_table = self.query_one("#fpga_conf_table", DataTable)
        self._status = self.query_one("#status_line", Static)
        self._log_summary = self.query_one("#log_summary", Static)
        self._eth_summary = self.query_one("#eth_summary", Static)
        self._pcie_summary = self.query_one("#pcie_summary", Static)
        self._fpga_summary = self.query_one("#fpga_summary", Static)
        self._session_last = self.query_one("#session_last", Static)
        self._session_error = self.query_one("#session_error", Static)
        self._watch_button = self.query_one("#btn_watch", Button)
        self._changed_button = self.query_one("#btn_changed", Button)
        self._log_mode_button = self.query_one("#btn_log_mode", Button)
        self._session_log_button = self.query_one("#btn_session_log", Button)
        self._ip_input = self.query_one("#target_ip", Input)
        self._bind_ip_input = self.query_one("#bind_ip", Input)
        self._port_input = self.query_one("#target_port", Input)
        self._bind_port_input = self.query_one("#bind_port", Input)
        self._write_input = self.query_one("#write_value", Input)
        self._poll_input = self.query_one("#poll_interval", Input)
        self._decoder_input = self.query_one("#decoder_path", Input)
        self._log_src_input = self.query_one("#log_src_filter", Input)
        self._log_evt_input = self.query_one("#log_evt_filter", Input)
        self._log_text_input = self.query_one("#log_text_filter", Input)

        for table in (
            self._log_table,
            self._eth_table,
            self._pcie_table,
            self._fpga_direct_table,
            self._fpga_conf_table,
        ):
            table.cursor_type = "row"
        self._log_table.cursor_type = "none"
        self._log_table.show_cursor = False

        self._log_table.add_columns("Time", "UDP Seq", "Stream", "Flags", "Valid", "SRC", "EVT", "Text")
        for table in (self._eth_table, self._pcie_table, self._fpga_direct_table, self._fpga_conf_table):
            table.add_column("Name", width=26)
            table.add_column("Loc", width=10)
            table.add_column("Access", width=8)
            table.add_column("Value", width=14)
            table.add_column("Decoded", width=80)
            table.add_column("Group", width=16)

        self._reload_catalog()
        self._ensure_udp_listener(force=True)
        self.set_interval(0.05, self._poll_udp)
        self.set_interval(0.10, self._poll_active_screen)
        self.set_interval(0.25, self._refresh_log_table)
        self._show_screen("log")
        self._refresh_all_summaries()
        self._status.update(self._pending_status_text)

    def on_shutdown(self) -> None:
        self._udp.disconnect()
        if self._log_fp is not None:
            self._log_fp.close()
            self._log_fp = None

    def on_button_pressed(self, event: Button.Pressed) -> None:
        button_id = event.button.id
        if button_id == "nav_log":
            self.action_show_log()
        elif button_id == "nav_eth":
            self.action_show_eth()
        elif button_id == "nav_pcie":
            self.action_show_pcie()
        elif button_id == "nav_fpga":
            self.action_show_fpga()
        elif button_id == "btn_watch":
            self.action_toggle_watch()
        elif button_id == "btn_changed":
            self.action_toggle_changed_only()
        elif button_id == "btn_log_mode":
            self.action_toggle_log_mode()
        elif button_id == "btn_decoder_reload":
            self._reload_decoder()
        elif button_id == "btn_save_view":
            self.action_save_log_view()
        elif button_id == "btn_session_log":
            self.action_toggle_session_log()
        elif button_id == "btn_log_clear":
            self._clear_log_table()
        elif button_id == "btn_read":
            self.action_read_selected()
        elif button_id == "btn_write":
            self.action_write_selected()
        elif button_id == "btn_reload":
            self.action_reload_map()
        elif button_id == "btn_pcie_toggle_act_periodic":
            self.action_toggle_pcie_activity_periodic()
        elif button_id == "btn_pcie_toggle_sts_periodic":
            self.action_toggle_pcie_status_periodic()
        elif button_id == "btn_pcie_trigger_act":
            self.action_trigger_pcie_activity_snapshot()
        elif button_id == "btn_pcie_trigger_sts":
            self.action_trigger_pcie_status_snapshot()

    def action_show_log(self) -> None:
        self._show_screen("log")

    def action_show_eth(self) -> None:
        self._show_screen("eth")

    def action_show_pcie(self) -> None:
        self._show_screen("pcie")

    def action_show_fpga(self) -> None:
        self._show_screen("fpga")

    def action_toggle_watch(self) -> None:
        self._watch_enabled = not self._watch_enabled
        self._watch_button.label = "Watch ON" if self._watch_enabled else "Watch OFF"
        self._set_status("watch enabled" if self._watch_enabled else "watch disabled")

    def action_toggle_changed_only(self) -> None:
        self._changed_only = not self._changed_only
        self._changed_button.label = "Changed Only" if self._changed_only else "Changed ALL"
        self._set_status("changed-only enabled" if self._changed_only else "changed-only disabled")

    def action_toggle_log_mode(self) -> None:
        self._log_mode = "raw" if self._log_mode == "decode" else "decode"
        self._log_mode_button.label = "Raw" if self._log_mode == "raw" else "Decode"
        self._set_status(f"log mode: {self._log_mode}")

    def action_read_selected(self) -> None:
        reg = self._selected_reg()
        if reg is None:
            self._set_status("no register selected")
            return
        try:
            value = self._read_reg(reg)
        except Exception as exc:
            self._session.last_error = str(exc)
            self._set_status(f"read failed: {exc}")
            return
        self._store_value(reg, value)
        self._set_status(f"read {reg.name}: 0x{value:08X}")

    def action_write_selected(self) -> None:
        reg = self._selected_reg()
        if reg is None:
            self._set_status("no register selected")
            return
        if "W" not in reg.access:
            self._set_status(f"register is not writable: {reg.name}")
            return
        try:
            value = int(self._write_input.value.strip(), 0)
        except ValueError:
            self._set_status("invalid write value")
            return
        try:
            self._write_reg(reg, value)
        except Exception as exc:
            self._session.last_error = str(exc)
            self._set_status(f"write failed: {exc}")
            return
        self._store_value(reg, value)
        self._set_status(f"write {reg.name}: 0x{value:08X}")

    def action_save_log_view(self) -> None:
        logs_dir = Path("logs")
        logs_dir.mkdir(parents=True, exist_ok=True)
        path = logs_dir / f"eth_reg_view_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
        rows = self._filtered_log_rows()
        with path.open("w", encoding="utf-8") as fp:
            for row in rows:
                fp.write(
                    f"{row.time_text} {row.udp_seq} {row.stream} {row.flags} "
                    f"{row.valid} {row.src} {row.evt} {row.text}\n"
                )
        self._set_status(f"log view saved: {path}")

    def action_toggle_session_log(self) -> None:
        self._session_log_enabled = not self._session_log_enabled
        self._session_log_button.label = (
            "Session Log ON" if self._session_log_enabled else "Session Log OFF"
        )
        if not self._session_log_enabled and self._log_fp is not None:
            self._log_fp.close()
            self._log_fp = None
        self._set_status("session log enabled" if self._session_log_enabled else "session log disabled")

    def action_reload_map(self) -> None:
        self._reload_catalog()
        self._set_status(f"register map reloaded: {self._reg_map_path}")

    def action_toggle_pcie_activity_periodic(self) -> None:
        self._toggle_pcie_log_control_bit(
            mask=(1 << 0),
            label="PCIe activity periodic",
        )

    def action_toggle_pcie_status_periodic(self) -> None:
        self._toggle_pcie_log_control_bit(
            mask=(1 << 1),
            label="PCIe status periodic",
        )

    def action_trigger_pcie_activity_snapshot(self) -> None:
        self._trigger_pcie_snapshot(mask=(1 << 0), label="PCIe activity snapshot")

    def action_trigger_pcie_status_snapshot(self) -> None:
        self._trigger_pcie_snapshot(mask=(1 << 1), label="PCIe status snapshot")

    def _reload_decoder(self) -> None:
        decoder_path = Path(self._decoder_input.value.strip()) if hasattr(self, "_decoder_input") else self._decoder_path
        if not decoder_path.exists():
            self._set_status(f"decoder not found: {decoder_path}")
            return
        self._decoder = UARTLogDecoder.from_yaml(decoder_path)
        self._decoder_path = decoder_path
        if hasattr(self, "_decoder_input"):
            self._decoder_input.value = str(decoder_path)
        self._set_status(f"decoder reloaded: {decoder_path}")

    def _reg_by_name(self, reg_name: str) -> RegisterDef:
        reg = self._regs_by_name.get(reg_name)
        if reg is None:
            raise KeyError(f"register not found: {reg_name}")
        return reg

    def _read_named_reg(self, reg_name: str) -> int:
        reg = self._reg_by_name(reg_name)
        value = self._read_reg(reg)
        self._store_value(reg, value)
        return value

    def _write_named_reg(self, reg_name: str, value: int, *, cached_value: int | None = None) -> None:
        reg = self._reg_by_name(reg_name)
        self._write_reg(reg, value)
        if cached_value is None:
            cached_value = value
        self._store_value(reg, cached_value)

    def _toggle_pcie_log_control_bit(self, *, mask: int, label: str) -> None:
        try:
            current_value = self._read_named_reg("PCIE_LOG_CONTROL")
            new_value = current_value ^ mask
            self._write_named_reg("PCIE_LOG_CONTROL", new_value)
        except Exception as exc:
            self._session.last_error = str(exc)
            self._set_status(f"{label} toggle failed: {exc}")
            return
        state_text = "enabled" if (new_value & mask) else "disabled"
        self._set_status(f"{label} {state_text}: 0x{new_value:08X}")

    def _trigger_pcie_snapshot(self, *, mask: int, label: str) -> None:
        packet_count_before: int | None = None
        try:
            packet_count_before = self._read_named_reg("LOG_STREAM_PACKET_COUNT")
            self._write_named_reg("PCIE_LOG_TRIGGER", mask, cached_value=0)
        except Exception as exc:
            if packet_count_before is not None:
                try:
                    time.sleep(0.2)
                    packet_count_after = self._read_named_reg("LOG_STREAM_PACKET_COUNT")
                    if packet_count_after > packet_count_before:
                        delta = packet_count_after - packet_count_before
                        self._session.last_error = "-"
                        self._set_status(
                            f"{label} triggered (ack timeout, observed +{delta} log packets)"
                        )
                        return
                except Exception:
                    pass
            self._session.last_error = str(exc)
            self._set_status(f"{label} trigger failed: {exc}")
            return
        self._set_status(f"{label} triggered")

    def _reload_catalog(self) -> None:
        self._regs_by_name, self._regs_by_addr = load_register_map(self._reg_map_path)
        all_defs = sorted(self._regs_by_name.values(), key=lambda reg: (reg.screen, reg.group, reg.space, reg.block, reg.address))
        self._screen_regs["eth"] = [reg for reg in all_defs if reg.screen == "eth" and reg.space == "direct"]
        self._screen_regs["pcie"] = [reg for reg in all_defs if reg.screen == "pcie" and reg.space == "direct"]
        self._screen_regs["fpga_direct"] = [reg for reg in all_defs if reg.screen == "fpga" and reg.space == "direct"]
        self._screen_regs["fpga_conf"] = [reg for reg in all_defs if reg.screen == "fpga" and reg.space == "conf"]
        self._row_maps["eth_table"] = list(self._screen_regs["eth"])
        self._row_maps["pcie_table"] = list(self._screen_regs["pcie"])
        self._row_maps["fpga_direct_table"] = list(self._screen_regs["fpga_direct"])
        self._row_maps["fpga_conf_table"] = list(self._screen_regs["fpga_conf"])
        self._fill_register_table(self._eth_table, self._row_maps["eth_table"])
        self._fill_register_table(self._pcie_table, self._row_maps["pcie_table"])
        self._fill_register_table(self._fpga_direct_table, self._row_maps["fpga_direct_table"])
        self._fill_register_table(self._fpga_conf_table, self._row_maps["fpga_conf_table"])

    def _fill_register_table(self, table: DataTable, regs: list[RegisterDef]) -> None:
        try:
            table.clear(columns=False)
        except TypeError:
            table.clear()
        for reg in regs:
            loc = f"0x{reg.address:04X}" if reg.space == "direct" else f"{reg.block:02X}:{reg.address:02X}"
            table.add_row(reg.name, loc, reg.access, "-", reg.description or "-", reg.group)

    def _show_screen(self, screen_name: str) -> None:
        self._active_screen = screen_name
        for candidate in ("log", "eth", "pcie", "fpga"):
            widget = self.query_one(f"#{candidate}_screen", Vertical)
            widget.set_class(candidate != screen_name, "hidden")
        self._refresh_all_summaries()
        self._set_status(f"screen: {screen_name}")

    def _selected_reg(self) -> RegisterDef | None:
        focus = self.focused
        if isinstance(focus, DataTable):
            return self._selected_from_table(focus)
        if self._active_screen == "eth":
            return self._selected_from_table(self._eth_table)
        if self._active_screen == "pcie":
            return self._selected_from_table(self._pcie_table)
        if self._active_screen == "fpga":
            return self._selected_from_table(self._fpga_direct_table)
        return None

    def _selected_from_table(self, table: DataTable) -> RegisterDef | None:
        regs = self._row_maps.get(table.id or "", [])
        if not regs:
            return None
        try:
            row_index = int(table.cursor_row)
        except Exception:
            row_index = 0
        if row_index < 0 or row_index >= len(regs):
            return None
        return regs[row_index]

    def _transact(self, cmd: int, addr: int, data: int):
        self._session.target_ip = self._ip_input.value.strip()
        self._session.bind_ip = self._bind_ip_input.value.strip()
        self._session.target_port = int(self._port_input.value.strip())
        self._session.bind_port = int(self._bind_port_input.value.strip())
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            if self._session.bind_ip or self._session.bind_port:
                sock.bind((self._session.bind_ip, self._session.bind_port))
            resp = transact(
                sock=sock,
                target_ip=self._session.target_ip,
                target_port=self._session.target_port,
                cmd=cmd,
                addr=addr,
                data=data,
                seq=self._seq,
                timeout_s=0.5,
            )
        self._seq = (self._seq + 1) & 0xFFFF
        self._session.last_status = status_to_text(resp.status)
        self._session.last_response = f"{resp.cmd:02X}@0x{resp.addr:04X}=0x{resp.data:08X}"
        self._session.last_error = "-"
        return resp

    def _read_reg(self, reg: RegisterDef) -> int:
        if reg.space == "direct":
            return self._transact(CMD_READ, reg.address, 0).data
        self._transact(CMD_WRITE, REGISTERS["CONF_INDEX"], reg.conf_index)
        return self._transact(CMD_READ, REGISTERS["CONF_DATA"], 0).data

    def _write_reg(self, reg: RegisterDef, value: int) -> None:
        if reg.space == "direct":
            self._transact(CMD_WRITE, reg.address, value)
        else:
            self._transact(CMD_WRITE, REGISTERS["CONF_INDEX"], reg.conf_index)
            self._transact(CMD_WRITE, REGISTERS["CONF_DATA"], value)

    def _store_value(self, reg: RegisterDef, value: int) -> None:
        old_value = self._values.get(reg.name)
        self._values[reg.name] = value & 0xFFFF_FFFF
        if self._changed_only and old_value == value:
            return
        self._update_table_cell(reg, value)
        if reg.name == "NET_ACTIVE_LOG_DST_PORT":
            bind_port = value & 0xFFFF
            if bind_port != 0:
                self._udp_log_bind_port = bind_port
                self._ensure_udp_listener(force=True)
        self._refresh_all_summaries()
        self._log_session_line(f"{reg.name}=0x{value:08X}")

    def _update_table_cell(self, reg: RegisterDef, value: int) -> None:
        target_id = "eth_table"
        if reg.screen == "pcie":
            target_id = "pcie_table"
        elif reg.screen == "fpga" and reg.space == "conf":
            target_id = "fpga_conf_table"
        elif reg.screen == "fpga":
            target_id = "fpga_direct_table"
        table = {
            "eth_table": self._eth_table,
            "pcie_table": self._pcie_table,
            "fpga_direct_table": self._fpga_direct_table,
            "fpga_conf_table": self._fpga_conf_table,
        }[target_id]
        regs = self._row_maps[target_id]
        try:
            row_index = regs.index(reg)
        except ValueError:
            return
        decoded = (
            " ".join(
                decode_register_value(
                    reg.address,
                    value,
                    reg_def=reg,
                    regs_by_addr=self._regs_by_addr,
                )
            )
            if reg.space == "direct" else "-"
        )
        table.update_cell_at((row_index, 3), f"0x{value:08X}")
        table.update_cell_at((row_index, 4), decoded if decoded else "-")

    def _poll_active_screen(self) -> None:
        if not self._watch_enabled or self._active_screen == "log":
            return
        try:
            self._poll_interval_s = max(float(self._poll_input.value.strip()), 0.05)
        except ValueError:
            self._poll_interval_s = 0.5
        now = datetime.now().timestamp()
        if now < self._next_poll_at:
            return
        self._next_poll_at = now + self._poll_interval_s
        regs = []
        if self._active_screen == "eth":
            regs = [reg for reg in self._screen_regs["eth"] if reg.poll_default]
        elif self._active_screen == "pcie":
            regs = [reg for reg in self._screen_regs["pcie"] if reg.poll_default]
        elif self._active_screen == "fpga":
            regs = [reg for reg in self._screen_regs["fpga_direct"] + self._screen_regs["fpga_conf"] if reg.poll_default or reg.space == "conf"]
        changed = 0
        for reg in regs:
            try:
                value = self._read_reg(reg)
            except Exception as exc:
                self._session.last_error = str(exc)
                self._set_status(f"poll failed: {exc}")
                return
            if self._values.get(reg.name) != value:
                changed += 1
            self._store_value(reg, value)
        self._set_status(f"poll complete: {len(regs)} regs, {changed} changed")

    def _udp_bind_ip_value(self) -> str:
        bind_ip = self._bind_ip_input.value.strip()
        return bind_ip if bind_ip else "0.0.0.0"

    def _ensure_udp_listener(self, *, force: bool) -> None:
        bind_ip = self._udp_bind_ip_value()
        bind_port = int(self._udp_log_bind_port)
        if not force and self._udp.is_connected and self._udp.bind_ip == bind_ip and self._udp.bind_port == bind_port:
            return
        self._udp.disconnect()
        try:
            self._udp.connect(bind_ip, bind_port)
        except OSError:
            self._udp.connect(bind_ip, 0)
        self._udp_log_bound_port = self._udp.bind_port
        self._udp_decoder.reset()
        self._udp_packet_count = 0
        self._udp_packet_lost = 0
        self._udp_last_peer = "-"
        self._udp_last_seq = "-"
        self._udp_last_valid = "-"
        self._udp_last_flags = "-"
        self._udp_last_stream = "-"
        self._udp_last_gap = 0
        self._udp_last_timestamp = "-"

    def _poll_udp(self) -> None:
        if not self._udp.is_connected:
            try:
                self._ensure_udp_listener(force=False)
            except Exception:
                return
        packets = self._udp.recv_packets()
        if not packets:
            return
        for payload, peer in packets:
            try:
                result = self._udp_decoder.feed_packet(payload)
            except Exception as exc:
                self._session.last_error = str(exc)
                self._set_status(f"udp decode failed: {exc}")
                continue
            self._udp_packet_count = self._udp_decoder.packet_count
            self._udp_packet_lost = self._udp_decoder.packet_lost_count
            self._udp_last_peer = f"{peer[0]}:{peer[1]}"
            self._udp_last_seq = f"0x{result.packet.seq:04X}"
            self._udp_last_valid = str(result.packet.valid_bytes)
            self._udp_last_flags = format_udp_log_flags(result.packet.flags)
            self._udp_last_stream = format_udp_log_stream_id(result.packet.stream_id)
            self._udp_last_gap = result.packet_lost_count
            self._udp_last_timestamp = f"0x{result.packet.timestamp:08X}"
            for frame in result.uart_frames:
                text = self._decoder.decode(frame.event).message if self._log_mode == "decode" else (
                    f"src={frame.event.src_id} evt={frame.event.event_id} "
                    f"ts={frame.event.timestamp} arg0=0x{frame.event.arg0:08X} "
                    f"arg1=0x{frame.event.arg1:08X} arg2=0x{frame.event.arg2:08X}"
                )
                self._append_log_row(
                    LogRow(
                        time_text=datetime.now().strftime("%H:%M:%S.%f")[:-3],
                        udp_seq=self._udp_last_seq,
                        stream=self._udp_last_stream,
                        flags=self._udp_last_flags,
                        valid=str(result.packet.valid_bytes),
                        src=f"0x{frame.event.src_id:02X}",
                        evt=f"0x{frame.event.event_id:02X}",
                        text=text,
                    )
                )
            if not result.uart_frames and result.packet.stream_id == UDP_LOG_STREAM_UART_PRIMARY:
                self._append_log_row(
                    LogRow(
                        time_text=datetime.now().strftime("%H:%M:%S.%f")[:-3],
                        udp_seq=self._udp_last_seq,
                        stream=self._udp_last_stream,
                        flags=self._udp_last_flags,
                        valid=str(result.packet.valid_bytes),
                        src="-",
                        evt="-",
                        text=f"udp packet peer={self._udp_last_peer}",
                    )
                )
        self._refresh_log_table()
        self._refresh_all_summaries()

    def _append_log_row(self, row: LogRow) -> None:
        self._log_rows.append(row)
        self._log_session_line(
            f"LOG {row.udp_seq} {row.src} {row.evt} {row.text}"
        )

    def _clear_log_table(self) -> None:
        self._log_rows.clear()
        try:
            self._log_table.clear(columns=False)
        except TypeError:
            self._log_table.clear()
        self._set_status("log table cleared")

    def _filtered_log_rows(self) -> list[LogRow]:
        self._log_src_filter = self._log_src_input.value.strip()
        self._log_evt_filter = self._log_evt_input.value.strip()
        self._log_text_filter = self._log_text_input.value.strip().lower()
        rows = []
        for row in self._log_rows:
            if self._log_src_filter and self._log_src_filter.lower() not in {"all", "*"}:
                if row.src.lower() != self._log_src_filter.lower():
                    continue
            if self._log_evt_filter and self._log_evt_filter.lower() not in {"all", "*"}:
                if row.evt.lower() != self._log_evt_filter.lower():
                    continue
            if self._log_text_filter and self._log_text_filter not in row.text.lower():
                continue
            rows.append(row)
        return rows

    def _refresh_log_table(self) -> None:
        rows = self._filtered_log_rows()
        previous_scroll_y = self._log_table.scroll_y
        follow_tail = len(self._log_table.rows) == 0 or self._log_table.is_vertical_scroll_end
        try:
            self._log_table.clear(columns=False)
        except TypeError:
            self._log_table.clear()
        for row in rows:
            self._log_table.add_row(
                row.time_text,
                row.udp_seq,
                row.stream,
                row.flags,
                row.valid,
                row.src,
                row.evt,
                row.text,
            )
        if not rows:
            return
        try:
            if follow_tail:
                self._log_table.scroll_end(animate=False)
            else:
                self._log_table.scroll_to(y=previous_scroll_y, animate=False)
        except Exception:
            pass

    def _format_value(self, name: str) -> str:
        if name not in self._values:
            return "-"
        return f"0x{self._values[name]:08X}"

    def _refresh_all_summaries(self) -> None:
        self._session_last.update(f"last: {self._session.last_response}")
        self._session_error.update(f"err: {self._session.last_error}")
        self._log_summary.update(
            "\n".join(
                [
                    "[UDP Log]",
                    f"bind       : {self._udp_bind_ip_value()}:{self._udp_log_bound_port}",
                    f"mode       : {self._log_mode}",
                    f"udp_pkts   : {self._udp_packet_count}",
                    f"udp_lost   : {self._udp_packet_lost}",
                    f"udp_peer   : {self._udp_last_peer}",
                    f"udp_seq    : {self._udp_last_seq}",
                    f"udp_stream : {self._udp_last_stream}",
                    f"udp_valid  : {self._udp_last_valid}",
                    f"udp_flags  : {self._udp_last_flags}",
                    f"udp_ts     : {self._udp_last_timestamp}",
                ]
            )
        )
        self._eth_summary.update(
            "\n".join(
                [
                    "[Eth Summary]",
                    f"NET_STATUS            {self._format_value('NET_STATUS')}",
                    f"LINK_STATUS_EXT       {self._format_value('LINK_STATUS_EXT')}",
                    f"LOG_STREAM_STATUS     {self._format_value('LOG_STREAM_STATUS')}",
                    f"RX_PACKET_COUNT       {self._format_value('RX_PACKET_COUNT')}",
                    f"TX_PACKET_COUNT       {self._format_value('TX_PACKET_COUNT')}",
                    f"PROTO_ERROR_COUNT     {self._format_value('PROTO_ERROR_COUNT')}",
                    f"IPV4_DROP_COUNT       {self._format_value('IPV4_DROP_COUNT')}",
                    f"UDP_DROP_COUNT        {self._format_value('UDP_DROP_COUNT')}",
                    f"RX_MALFORMED_COUNT    {self._format_value('RX_MALFORMED_COUNT')}",
                    f"NET_ACTIVE_FPGA_IP    {self._format_value('NET_ACTIVE_FPGA_IP_ADDR')}",
                    f"NET_ACTIVE_CTRL_PORT  {self._format_value('NET_ACTIVE_UDP_CTRL_PORT')}",
                    f"NET_ACTIVE_LOG_PORT   {self._format_value('NET_ACTIVE_LOG_DST_PORT')}",
                ]
            )
        )
        pcie_status = self._values.get("PCIE_STATUS", 0)
        present = "yes" if (pcie_status & 0x1) else "no"
        self._pcie_summary.update(
            "\n".join(
                [
                    "[PCIe Summary]",
                    f"present               {present}",
                    f"PCIE_STATUS           {self._format_value('PCIE_STATUS')}",
                    f"PCIE_LINKUP_STATUS    {self._format_value('PCIE_LINKUP_STATUS')}",
                    f"PCIE_LTSSM            {self._format_value('PCIE_LTSSM')}",
                    f"PCIE_LAST_RX_ERROR    {self._format_value('PCIE_LAST_RX_ERROR')}",
                    f"TLP_UNSUPPORTED       {self._format_value('PCIE_TLP_UNSUPPORTED_COUNT')}",
                    f"RX_FRAME_COUNT        {self._format_value('PCIE_RX_FRAME_COUNT')}",
                    f"RX_DROP_COUNT         {self._format_value('PCIE_RX_DROP_COUNT')}",
                    f"TX_FRAME_COUNT        {self._format_value('PCIE_TX_FRAME_COUNT')}",
                    f"TX_DROP_COUNT         {self._format_value('PCIE_TX_DROP_COUNT')}",
                    f"PCIE_LOG_CONTROL      {self._format_value('PCIE_LOG_CONTROL')}",
                    f"PCIE_LOG_TRIGGER      {self._format_value('PCIE_LOG_TRIGGER')}",
                ]
            )
        )
        self._fpga_summary.update(
            "\n".join(
                [
                    "[FPGA Summary]",
                    f"DEVICE_ID             {self._format_value('DEVICE_ID')}",
                    f"VERSION               {self._format_value('VERSION')}",
                    f"FPGA_STATUS           {self._format_value('FPGA_STATUS')}",
                    f"FPGA_UPTIME_LO        {self._format_value('FPGA_UPTIME_LO')}",
                    f"FPGA_UPTIME_HI        {self._format_value('FPGA_UPTIME_HI')}",
                    f"FPGA_SNAPSHOT_COUNT   {self._format_value('FPGA_SNAPSHOT_COUNT')}",
                    f"CONF_INDEX            {self._format_value('CONF_INDEX')}",
                    f"CONF_DATA             {self._format_value('CONF_DATA')}",
                ]
            )
        )

    def _open_log_if_needed(self) -> None:
        if self._log_file_path is None:
            logs_dir = Path("logs")
            logs_dir.mkdir(parents=True, exist_ok=True)
            self._log_file_path = logs_dir / f"eth_reg_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
        else:
            self._log_file_path.parent.mkdir(parents=True, exist_ok=True)
        if self._log_fp is None:
            self._log_fp = self._log_file_path.open("a", encoding="utf-8")

    def _log_session_line(self, text: str) -> None:
        if not self._session_log_enabled:
            return
        self._open_log_if_needed()
        if self._log_fp is None:
            return
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        self._log_fp.write(f"{stamp} {text}\n")
        self._log_fp.flush()

    def _set_status(self, text: str) -> None:
        self._pending_status_text = f"status: {text}"
        if hasattr(self, "_status"):
            self._status.update(self._pending_status_text)
        if hasattr(self, "_session_last"):
            self._session_last.update(f"last: {self._session.last_response}")
        if hasattr(self, "_session_error"):
            self._session_error.update(f"err: {self._session.last_error}")


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", type=str, default="192.168.100.2")
    parser.add_argument("--port", type=int, default=50000)
    parser.add_argument("--bind-ip", type=str, default="")
    parser.add_argument("--bind-port", type=int, default=0)
    parser.add_argument("--reg-map", type=str, default="")
    parser.add_argument("--log-file", type=str, default=None)
    args = parser.parse_args()

    reg_map_path = args.reg_map or str(Path(__file__).resolve().with_name("eth_udp_reg_map.default.yaml"))
    app = EthUdpRegApp(
        target_ip=args.ip,
        target_port=args.port,
        bind_ip=args.bind_ip,
        bind_port=args.bind_port,
        reg_map_path=reg_map_path,
        log_file=args.log_file,
    )
    app.run()


if __name__ == "__main__":
    main()
