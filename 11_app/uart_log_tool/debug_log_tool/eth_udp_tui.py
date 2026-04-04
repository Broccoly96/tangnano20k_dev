"""Textual TUI for Ethernet UDP register access plus log monitoring."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
import socket

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import Button, DataTable, Footer, Header, Input, Static

from eth_udp_tool import (
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


class EthUdpRegApp(App[None]):
    """Small Ethernet register monitor, editor, and UDP log viewer."""

    CSS = """
    #top_bar {
      height: 15;
      layout: horizontal;
      margin: 0 1;
    }
    .cfg_col {
      width: 26;
      height: 15;
      margin-right: 1;
    }
    .cfg_col Input {
      height: 3;
      min-height: 3;
    }
    .cfg_col Static {
      height: 1;
    }
    .cfg_col Button {
      height: 3;
      min-height: 3;
    }
    #main_row {
      layout: horizontal;
      height: 1fr;
      margin: 0 1;
    }
    #reg_table {
      width: 1fr;
      height: 1fr;
    }
    #right_col {
      width: 162;
      height: 1fr;
    }
    #side_panel {
      height: 18;
      border: round;
      padding: 0 1;
      margin-bottom: 1;
    }
    #log_table {
      height: 1fr;
    }
    #status_line {
      height: 2;
      margin: 0 1 1 1;
    }
    """

    BINDINGS = [
        ("r", "read_selected", "Read"),
        ("w", "write_selected", "Write"),
        ("p", "toggle_watch", "Watch"),
        ("m", "reload_map", "Reload Map"),
        ("d", "toggle_log_mode", "Log Mode"),
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
        self._target_ip = target_ip
        self._target_port = int(target_port)
        self._bind_ip = bind_ip
        self._bind_port = int(bind_port)
        self._reg_map_path = reg_map_path
        self._regs_by_name: dict[str, RegisterDef] = {}
        self._regs_by_addr: dict[int, RegisterDef] = {}
        self._ordered_addrs: list[int] = []
        self._watch_enabled = False
        self._poll_interval_s = 0.5
        self._seq = 1
        self._last_status = "idle"
        self._last_error = "-"
        self._log_file_path = Path(log_file) if log_file else None
        self._log_fp = None

        self._udp = UDPLogClient()
        self._udp_decoder = UDPLogStreamDecoder()
        self._decoder = UARTLogDecoder()
        self._log_mode = "decode"
        self._log_src_filter = ""
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

        self._table: DataTable | None = None
        self._log_table: DataTable | None = None
        self._panel: Static | None = None
        self._status: Static | None = None
        self._ip_input: Input | None = None
        self._port_input: Input | None = None
        self._bind_ip_input: Input | None = None
        self._bind_port_input: Input | None = None
        self._write_input: Input | None = None
        self._poll_input: Input | None = None
        self._log_src_input: Input | None = None
        self._watch_button: Button | None = None
        self._log_mode_button: Button | None = None

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Vertical():
            with Horizontal(id="top_bar"):
                with Vertical(classes="cfg_col"):
                    yield Static("Target IP")
                    yield Input(self._target_ip, id="target_ip")
                    yield Static("Target Port")
                    yield Input(str(self._target_port), id="target_port")
                with Vertical(classes="cfg_col"):
                    yield Static("Bind IP")
                    yield Input(self._bind_ip, id="bind_ip")
                    yield Static("Bind Port")
                    yield Input(str(self._bind_port), id="bind_port")
                with Vertical(classes="cfg_col"):
                    yield Static("Write Value")
                    yield Input("0x00000000", id="write_value")
                    yield Static("Poll Interval [s]")
                    yield Input("0.5", id="poll_interval")
                with Vertical(classes="cfg_col"):
                    yield Static("Log SRC Filter")
                    yield Input("", id="log_src_filter", placeholder="all / 0x11 / 17")
                    yield Static("Log Mode")
                    yield Button("Log Decode (d)", id="btn_log_mode")
                with Vertical(classes="cfg_col"):
                    yield Button("Read (r)", id="btn_read")
                    yield Button("Write (w)", id="btn_write")
                    yield Button("Watch OFF (p)", id="btn_watch")
                    yield Button("Reload Map (m)", id="btn_reload")
            with Horizontal(id="main_row"):
                yield DataTable(id="reg_table")
                with Vertical(id="right_col"):
                    yield Static("", id="side_panel")
                    yield DataTable(id="log_table")
            yield Static("status: idle", id="status_line")
        yield Footer()

    def on_mount(self) -> None:
        self._table = self.query_one("#reg_table", DataTable)
        self._log_table = self.query_one("#log_table", DataTable)
        self._panel = self.query_one("#side_panel", Static)
        self._status = self.query_one("#status_line", Static)
        self._ip_input = self.query_one("#target_ip", Input)
        self._port_input = self.query_one("#target_port", Input)
        self._bind_ip_input = self.query_one("#bind_ip", Input)
        self._bind_port_input = self.query_one("#bind_port", Input)
        self._write_input = self.query_one("#write_value", Input)
        self._poll_input = self.query_one("#poll_interval", Input)
        self._log_src_input = self.query_one("#log_src_filter", Input)
        self._watch_button = self.query_one("#btn_watch", Button)
        self._log_mode_button = self.query_one("#btn_log_mode", Button)

        self._table.cursor_type = "row"
        self._table.add_column("Name", width=24)
        self._table.add_column("Addr", width=10)
        self._table.add_column("Access", width=8)
        self._table.add_column("Value", width=12)
        self._table.add_column("Decoded", width=42)

        self._log_table.cursor_type = "row"
        self._log_table.add_column("Time", width=13)
        self._log_table.add_column("UDP Seq", width=9)
        self._log_table.add_column("Stream", width=14)
        self._log_table.add_column("Flags", width=18)
        self._log_table.add_column("Valid", width=7)
        self._log_table.add_column("SRC", width=6)
        self._log_table.add_column("EVT", width=6)
        self._log_table.add_column("Text", width=110)

        self._reload_reg_map()
        self._ensure_udp_listener(force=True)
        self.set_interval(0.05, self._poll_udp)
        self.set_interval(0.5, self._poll_watch)
        self._update_panel()

    def on_shutdown(self) -> None:
        self._udp.disconnect()
        if self._log_fp is not None:
            self._log_fp.close()
            self._log_fp = None

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn_read":
            self.action_read_selected()
        elif event.button.id == "btn_write":
            self.action_write_selected()
        elif event.button.id == "btn_watch":
            self.action_toggle_watch()
        elif event.button.id == "btn_reload":
            self.action_reload_map()
        elif event.button.id == "btn_log_mode":
            self.action_toggle_log_mode()

    def action_read_selected(self) -> None:
        self._read_selected_register()

    def action_write_selected(self) -> None:
        self._write_selected_register()

    def action_toggle_watch(self) -> None:
        self._watch_enabled = not self._watch_enabled
        if self._watch_button is not None:
            self._watch_button.label = "Watch ON (p)" if self._watch_enabled else "Watch OFF (p)"
        self._set_status("watch enabled" if self._watch_enabled else "watch disabled")
        self._update_panel()

    def action_reload_map(self) -> None:
        self._reload_reg_map()
        self._set_status(f"register map reloaded: {self._reg_map_path}")

    def action_toggle_log_mode(self) -> None:
        self._log_mode = "raw" if self._log_mode == "decode" else "decode"
        if self._log_mode_button is not None:
            label = "Log Raw (d)" if self._log_mode == "raw" else "Log Decode (d)"
            self._log_mode_button.label = label
        self._set_status(f"log mode: {self._log_mode}")
        self._update_panel()

    def _reload_reg_map(self) -> None:
        self._regs_by_name, self._regs_by_addr = load_register_map(self._reg_map_path)
        self._ordered_addrs = sorted(self._regs_by_addr.keys())
        if self._table is None:
            return
        try:
            self._table.clear(columns=False)
        except TypeError:
            self._table.clear()
        for addr in self._ordered_addrs:
            reg = self._regs_by_addr[addr]
            self._table.add_row(reg.name, f"0x{addr:04X}", reg.access, "-", reg.description)

    def _selected_reg(self) -> RegisterDef | None:
        if self._table is None or self._table.row_count == 0:
            return None
        try:
            row_index = int(self._table.cursor_row)
        except Exception:
            row_index = 0
        if row_index < 0 or row_index >= len(self._ordered_addrs):
            return None
        return self._regs_by_addr[self._ordered_addrs[row_index]]

    def _read_selected_register(self) -> None:
        reg = self._selected_reg()
        if reg is None:
            self._set_status("no register selected")
            return
        try:
            resp = self._transact(CMD_READ, reg.address, 0)
        except Exception as exc:
            self._last_error = str(exc)
            self._set_status(f"read failed: {exc}")
            return
        self._update_table_value(reg.address, resp.data)
        self._last_status = status_to_text(resp.status)
        self._log_line(f"READ {reg.name} 0x{resp.data:08X} status={self._last_status}")
        self._set_status(f"read {reg.name}: 0x{resp.data:08X}")

    def _write_selected_register(self) -> None:
        reg = self._selected_reg()
        if reg is None:
            self._set_status("no register selected")
            return
        if "W" not in reg.access:
            self._set_status(f"register is not writable: {reg.name}")
            return
        if self._write_input is None:
            self._set_status("write input unavailable")
            return
        try:
            value = int(self._write_input.value.strip(), 0)
        except ValueError:
            self._set_status("invalid write value")
            return
        try:
            resp = self._transact(CMD_WRITE, reg.address, value)
        except Exception as exc:
            self._last_error = str(exc)
            self._set_status(f"write failed: {exc}")
            return
        self._update_table_value(reg.address, resp.data)
        self._last_status = status_to_text(resp.status)
        self._log_line(f"WRITE {reg.name} 0x{value:08X} status={self._last_status}")
        self._set_status(f"write {reg.name}: 0x{resp.data:08X}")

    def _transact(self, cmd: int, addr: int, data: int):
        target_ip = self._ip_input.value.strip() if self._ip_input is not None else self._target_ip
        target_port = int(self._port_input.value.strip()) if self._port_input is not None else self._target_port
        bind_ip = self._bind_ip_input.value.strip() if self._bind_ip_input is not None else self._bind_ip
        bind_port = int(self._bind_port_input.value.strip()) if self._bind_port_input is not None else self._bind_port
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            if bind_ip or bind_port:
                sock.bind((bind_ip, bind_port))
            resp = transact(
                sock=sock,
                target_ip=target_ip,
                target_port=target_port,
                cmd=cmd,
                addr=addr,
                data=data,
                seq=self._seq,
                timeout_s=0.5,
            )
        self._seq = (self._seq + 1) & 0xFFFF
        return resp

    def _update_table_value(self, addr: int, value: int) -> None:
        if self._table is None:
            return
        try:
            row_index = self._ordered_addrs.index(addr)
        except ValueError:
            return
        decoded = " ".join(decode_register_value(addr, value))
        self._table.update_cell_at((row_index, 3), f"0x{value:08X}")
        self._table.update_cell_at((row_index, 4), decoded if decoded else "-")
        if addr == REGISTERS.get("NET_ACTIVE_LOG_DST_PORT"):
            new_port = value & 0xFFFF
            if new_port != 0:
                self._udp_log_bind_port = new_port
                self._ensure_udp_listener(force=True)
        self._update_panel()

    def _poll_watch(self) -> None:
        if not self._watch_enabled:
            return
        if self._poll_input is not None:
            try:
                self._poll_interval_s = max(float(self._poll_input.value.strip()), 0.05)
            except ValueError:
                self._poll_interval_s = 0.5
        now = datetime.now().timestamp()
        if not hasattr(self, "_next_poll_at"):
            self._next_poll_at = 0.0
        if now < self._next_poll_at:
            return
        self._next_poll_at = now + self._poll_interval_s
        for addr in self._ordered_addrs:
            try:
                resp = self._transact(CMD_READ, addr, 0)
            except Exception as exc:
                self._last_error = str(exc)
                self._set_status(f"watch failed: {exc}")
                return
            self._update_table_value(addr, resp.data)
            self._last_status = status_to_text(resp.status)
        self._set_status("watch poll complete")

    def _udp_bind_ip_value(self) -> str:
        if self._bind_ip_input is None:
            return self._bind_ip or "0.0.0.0"
        bind_ip = self._bind_ip_input.value.strip()
        return bind_ip if bind_ip else "0.0.0.0"

    def _current_log_src_filter(self) -> str:
        if self._log_src_input is None:
            return self._log_src_filter
        self._log_src_filter = self._log_src_input.value.strip()
        return self._log_src_filter

    def _src_filter_matches(self, src_id: int) -> bool:
        token = self._current_log_src_filter()
        if token == "" or token.lower() in {"all", "*"}:
            return True
        try:
            expect = int(token, 0) & 0xFF
        except ValueError:
            return True
        return src_id == expect

    def _ensure_udp_listener(self, *, force: bool = False) -> None:
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
        self._udp_last_peer = "-"
        self._udp_last_seq = "-"
        self._udp_last_valid = "-"
        self._udp_last_flags = "-"
        self._udp_last_stream = "-"
        self._udp_last_gap = 0
        self._udp_last_timestamp = "-"
        self._udp_packet_count = 0
        self._udp_packet_lost = 0

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
                self._last_error = str(exc)
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
                if not self._src_filter_matches(frame.event.src_id):
                    continue
                if self._log_mode == "decode":
                    text = self._decoder.decode(frame.event).message
                else:
                    text = (
                        f"src={frame.event.src_id} evt={frame.event.event_id} "
                        f"ts={frame.event.timestamp} "
                        f"arg0=0x{frame.event.arg0:08X} "
                        f"arg1=0x{frame.event.arg1:08X} "
                        f"arg2=0x{frame.event.arg2:08X}"
                    )
                self._append_log_row(
                    udp_seq=self._udp_last_seq,
                    stream=self._udp_last_stream,
                    flags=self._udp_last_flags,
                    valid=str(result.packet.valid_bytes),
                    src=f"0x{frame.event.src_id:02X}",
                    evt=f"0x{frame.event.event_id:02X}",
                    text=text,
                )

            if not result.uart_frames and result.packet.stream_id == UDP_LOG_STREAM_UART_PRIMARY:
                self._append_log_row(
                    udp_seq=self._udp_last_seq,
                    stream=self._udp_last_stream,
                    flags=self._udp_last_flags,
                    valid=str(result.packet.valid_bytes),
                    src="-",
                    evt="-",
                    text=f"udp packet peer={self._udp_last_peer}",
                )
        self._update_panel()

    def _append_log_row(
        self,
        *,
        udp_seq: str,
        stream: str,
        flags: str,
        valid: str,
        src: str,
        evt: str,
        text: str,
    ) -> None:
        if self._log_table is None:
            return
        self._log_table.add_row(
            datetime.now().strftime("%H:%M:%S.%f")[:-3],
            udp_seq,
            stream,
            flags,
            valid,
            src,
            evt,
            text,
        )
        try:
            self._log_table.scroll_end(animate=False)
        except Exception:
            pass

    def _update_panel(self) -> None:
        if self._panel is None or self._table is None:
            return
        selected = self._selected_reg()
        selected_name = selected.name if selected is not None else "-"
        selected_value = "-"
        if selected is not None:
            try:
                row_index = self._ordered_addrs.index(selected.address)
                selected_value = str(self._table.get_cell_at((row_index, 3)))
            except Exception:
                selected_value = "-"

        counter_lines: list[str] = []
        for name in (
            "RX_PACKET_COUNT",
            "TX_PACKET_COUNT",
            "ARP_COUNT",
            "UDP_COMMAND_COUNT",
            "ERROR_COUNT",
            "LOG_STREAM_PACKET_COUNT",
            "LOG_STREAM_DROP_COUNT",
        ):
            reg = self._regs_by_name.get(name)
            if reg is None:
                continue
            row_index = self._ordered_addrs.index(reg.address)
            counter_lines.append(f"{name:22s} {self._table.get_cell_at((row_index, 3))}")

        status_lines: list[str] = []
        for name in ("NET_STATUS", "LINK_STATUS_EXT", "LOG_STREAM_STATUS"):
            reg = self._regs_by_name.get(name)
            if reg is None:
                continue
            row_index = self._ordered_addrs.index(reg.address)
            status_lines.append(f"{name}: {self._table.get_cell_at((row_index, 4))}")

        self._panel.update(
            "\n".join(
                [
                    "[Selected]",
                    f"name       : {selected_name}",
                    f"value      : {selected_value}",
                    "",
                    "[Session]",
                    f"watch      : {'ON' if self._watch_enabled else 'OFF'}",
                    f"last_status: {self._last_status}",
                    f"last_error : {self._last_error}",
                    "",
                    "[UDP Log]",
                    f"bind       : {self._udp_bind_ip_value()}:{self._udp_log_bound_port}",
                    f"log_mode   : {self._log_mode}",
                    f"src_filter : {self._current_log_src_filter() or 'all'}",
                    f"udp_pkts   : {self._udp_packet_count}",
                    f"udp_lost   : {self._udp_packet_lost}",
                    f"udp_peer   : {self._udp_last_peer}",
                    f"udp_seq    : {self._udp_last_seq}",
                    f"udp_stream : {self._udp_last_stream}",
                    f"udp_valid  : {self._udp_last_valid}",
                    f"udp_flags  : {self._udp_last_flags}",
                    f"udp_gap    : {self._udp_last_gap}",
                    f"udp_ts     : {self._udp_last_timestamp}",
                    "",
                    "[Counters]",
                    *counter_lines,
                    "",
                    "[Status]",
                    *status_lines,
                ]
            )
        )

    def _set_status(self, text: str) -> None:
        if self._status is not None:
            self._status.update(f"status: {text}")
        self._update_panel()

    def _open_log_if_needed(self) -> None:
        if self._log_file_path is None:
            logs_dir = Path("logs")
            logs_dir.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            self._log_file_path = logs_dir / f"eth_reg_{stamp}.log"
        else:
            self._log_file_path.parent.mkdir(parents=True, exist_ok=True)
        if self._log_fp is None:
            self._log_fp = self._log_file_path.open("a", encoding="utf-8")

    def _log_line(self, text: str) -> None:
        self._open_log_if_needed()
        if self._log_fp is None:
            return
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        self._log_fp.write(f"{stamp} {text}\n")
        self._log_fp.flush()


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
