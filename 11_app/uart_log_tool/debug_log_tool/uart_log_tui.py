"""Textual TUI for UART log monitor, replay, filtering, and reset control."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import Button, DataTable, Footer, Header, Input, Select, Static

from uart_log_decoder import UARTLogDecoder
from uart_log_protocol import Event, Frame, FrameParser
from uart_log_replay import ReplayRecord, load_replay_records
from uart_log_serial import UARTSerialClient
from uart_log_tcp import UARTTCPClient


@dataclass(frozen=True)
class StoredEvent:
    host_time: str | None
    seq: int
    event: Event
    lost_count: int


@dataclass(frozen=True)
class LogRow:
    host_time: str
    seq_text: str
    src_text: str
    evt_text: str
    timestamp_text: str
    arg0_text: str
    arg1_text: str
    arg2_text: str
    crc_text: str
    mode_text: str
    text: str
    search_text: str


class UARTLogApp(App[None]):
    """Terminal GUI for UART log monitoring over serial or TCP."""

    CSS = """
    #top_bar {
      height: 3;
      layout: horizontal;
      margin: 0 1;
    }
    #main_row {
      layout: horizontal;
      height: 1fr;
      margin: 0 1;
    }
    #port_select {
      width: 32;
      margin-right: 1;
    }
    #baud_input {
      width: 10;
      margin-right: 1;
    }
    #filter_input {
      width: 32;
      margin-right: 1;
    }
    #btn_rescan {
      width: 12;
      margin-right: 1;
    }
    #btn_connect {
      width: 14;
      margin-right: 1;
    }
    #btn_reset {
      width: 12;
      margin-right: 1;
    }
    #status_line {
      width: 1fr;
      content-align: left middle;
    }
    #log_table {
      width: 1fr;
      height: 1fr;
    }
    #stats_panel {
      width: 38;
      padding: 0 1;
      border: round;
    }
    #help_line {
      height: 2;
      margin: 0 1 1 1;
      content-align: left middle;
    }
    """

    BINDINGS = [
        ("p", "rescan", "Rescan Ports"),
        ("c", "toggle_connect", "Connect/Disconnect"),
        ("m", "toggle_mode", "Raw/Decode"),
        ("u", "reload_decoder", "Reload Decoder"),
        ("l", "toggle_log", "Log ON/OFF"),
        ("x", "clear_logs", "Clear Logs"),
        ("r", "send_reset", "Send Ctrl+R"),
        ("f", "focus_filter", "Focus Filter"),
        ("q", "quit", "Quit"),
    ]

    def __init__(
        self,
        *,
        transport: str,
        initial_port: str | None,
        baud: int,
        tcp_host: str,
        tcp_port: int,
        mode: str,
        decoder_path: str,
        log_file: str | None,
        replay_file: str | None,
    ) -> None:
        super().__init__()
        self._transport = transport.lower()
        self._initial_port = initial_port
        self._baud = int(baud)
        self._tcp_host = tcp_host
        self._tcp_port = int(tcp_port)
        self._mode = mode.lower()
        self._filter_text = ""

        self._decoder_path = decoder_path
        self._decoder_path_obj = Path(decoder_path)
        self._decoder = UARTLogDecoder()
        self._decoder_mtime_ns: int | None = None

        self._serial = UARTSerialClient()
        self._tcp = UARTTCPClient()
        self._parser = FrameParser()

        self._rx_frames = 0
        self._crc_seen = 0
        self._lost_seen = 0
        self._tcp_packets = 0
        self._tcp_bytes = 0
        self._tcp_last_frame = "-"

        self._rows: list[StoredEvent] = []

        self._log_enabled = bool(log_file)
        self._log_file_path = Path(log_file) if log_file else None
        self._log_fp = None

        self._replay_file_path = Path(replay_file) if replay_file else None
        self._replay_records: list[ReplayRecord] = []
        self._replay_idx = 0
        self._replay_finished = False
        self._replay_load_error: str | None = None

        if self._replay_file_path is not None:
            try:
                self._replay_records = load_replay_records(self._replay_file_path)
            except Exception as exc:
                self._replay_load_error = str(exc)
                self._replay_records = []

        self._table: DataTable | None = None
        self._stats: Static | None = None
        self._status: Static | None = None
        self._port_select: Select[str] | None = None
        self._baud_input: Input | None = None
        self._filter_input: Input | None = None
        self._connect_button: Button | None = None
        self._rescan_button: Button | None = None
        self._reset_button: Button | None = None

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Vertical():
            with Horizontal(id="top_bar"):
                yield Select[str](options=[], prompt="Port", id="port_select")
                yield Input(value=str(self._baud), id="baud_input")
                yield Input(placeholder="filter src/evt/text", id="filter_input")
                yield Button("Rescan (p)", id="btn_rescan")
                yield Button("Connect (c)", id="btn_connect")
                yield Button("Soft Reset (r)", id="btn_reset")
                yield Static("disconnected", id="status_line")
            with Horizontal(id="main_row"):
                yield DataTable(id="log_table")
                yield Static("", id="stats_panel")
            yield Static(
                "keys: p=rescan c=connect m=mode u=reload l=log x=clear r=reset f=filter q=quit",
                id="help_line",
            )
        yield Footer()

    def on_mount(self) -> None:
        self._table = self.query_one("#log_table", DataTable)
        self._stats = self.query_one("#stats_panel", Static)
        self._status = self.query_one("#status_line", Static)
        self._port_select = self.query_one("#port_select", Select)
        self._baud_input = self.query_one("#baud_input", Input)
        self._filter_input = self.query_one("#filter_input", Input)
        self._connect_button = self.query_one("#btn_connect", Button)
        self._rescan_button = self.query_one("#btn_rescan", Button)
        self._reset_button = self.query_one("#btn_reset", Button)

        self._table.cursor_type = "row"
        self._table.add_columns(
            "Time",
            "SEQ",
            "SRC",
            "EVT",
            "TS",
            "ARG0",
            "ARG1",
            "ARG2",
            "CRC",
            "Mode",
            "Text",
        )

        self._reload_decoder(force=True, manual=False)

        if self._replay_file_path is not None:
            if self._port_select is not None:
                self._port_select.disabled = True
            if self._baud_input is not None:
                self._baud_input.disabled = True
            if self._connect_button is not None:
                self._connect_button.disabled = True
                self._connect_button.label = "Replay"
            if self._rescan_button is not None:
                self._rescan_button.disabled = True
            if self._reset_button is not None:
                self._reset_button.disabled = True
            if self._replay_load_error is None:
                self._set_status(
                    f"replay loaded: {self._replay_file_path} ({len(self._replay_records)} events)"
                )
                self.set_interval(0.05, self._poll_replay)
            else:
                self._set_status(
                    f"replay load failed: {self._replay_file_path} ({self._replay_load_error})"
                )
        else:
            if self._transport == "tcp":
                self._prepare_tcp_mode()
                self._set_status("ready")
                self.set_interval(0.05, self._poll_tcp)
            else:
                self._refresh_ports()
                self._set_status("ready")
                self.set_interval(0.05, self._poll_serial)

        if self._log_enabled:
            self._open_log_if_needed()
            if self._log_fp is not None:
                self._log_meta("logging started")

        self.set_interval(0.5, self._watch_decoder)
        self._update_stats()

    def on_shutdown(self) -> None:
        self._serial.disconnect()
        self._tcp.disconnect()
        if self._log_fp is not None:
            self._log_meta("application shutdown")
            self._log_fp.close()
            self._log_fp = None

    def on_button_pressed(self, event: Button.Pressed) -> None:
        button_id = event.button.id
        if button_id == "btn_rescan":
            self.action_rescan()
        elif button_id == "btn_connect":
            self.action_toggle_connect()
        elif button_id == "btn_reset":
            self.action_send_reset()

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id != "filter_input":
            return
        self._filter_text = event.value.strip().lower()
        self._render_table()
        self._update_stats()

    def action_focus_filter(self) -> None:
        if self._filter_input is not None:
            self.set_focus(self._filter_input)

    def action_rescan(self) -> None:
        if self._replay_file_path is not None:
            self._set_status("replay mode: serial disabled")
            return
        if self._transport != "serial":
            self._set_status(f"{self._transport} mode: rescan disabled")
            return
        self._refresh_ports()
        self._set_status("ports rescanned")

    def action_toggle_connect(self) -> None:
        if self._replay_file_path is not None:
            self._set_status("replay mode: connect disabled")
            return
        if self._active_connected():
            self._disconnect_active()
        else:
            self._connect_active()

    def action_toggle_mode(self) -> None:
        self._mode = "raw" if self._mode == "decode" else "decode"
        self._set_status(f"mode={self._mode}")
        self._render_table()
        self._update_stats()

    def action_reload_decoder(self) -> None:
        self._reload_decoder(force=True, manual=True)

    def action_toggle_log(self) -> None:
        self._log_enabled = not self._log_enabled
        if self._log_enabled:
            self._open_log_if_needed()
            self._log_meta("logging enabled")
            self._set_status("log enabled")
        else:
            self._log_meta("logging disabled")
            self._set_status("log disabled")
            if self._log_fp is not None:
                self._log_fp.close()
                self._log_fp = None
        self._update_stats()

    def action_clear_logs(self) -> None:
        self._rows.clear()
        self._render_table()
        self._set_status("log table cleared")
        self._log_meta("log table cleared")

    def action_send_reset(self) -> None:
        self._send_reset()

    def _watch_decoder(self) -> None:
        self._reload_decoder(force=False, manual=False)

    def _reload_decoder(self, *, force: bool, manual: bool) -> None:
        if not self._decoder_path_obj.exists():
            if manual:
                self._set_status(f"decoder not found: {self._decoder_path_obj}")
            return

        mtime_ns = self._decoder_path_obj.stat().st_mtime_ns
        if not force and self._decoder_mtime_ns == mtime_ns:
            return

        try:
            loaded = UARTLogDecoder.from_yaml(self._decoder_path_obj)
        except Exception as exc:
            if manual:
                self._set_status(f"decoder reload failed: {exc}")
            self._log_meta(f"decoder reload failed: {exc}")
            return

        self._decoder = loaded
        self._decoder_mtime_ns = mtime_ns
        self._render_table()

        if manual:
            self._set_status("decoder reloaded")

    def _refresh_ports(self) -> None:
        if self._port_select is None:
            return

        ports = self._serial.list_ports()
        if ports:
            options = [
                (
                    f"{p.device:<8} | {p.description if p.description else p.hwid}",
                    p.device,
                )
                for p in ports
            ]
            self._port_select.set_options(options)
            if self._initial_port and any(p.device == self._initial_port for p in ports):
                self._port_select.value = self._initial_port
            else:
                self._port_select.value = ports[0].device
        else:
            self._port_select.set_options([("(no serial ports)", "")])
            self._port_select.value = ""

    def _prepare_tcp_mode(self) -> None:
        if self._port_select is not None:
            endpoint = f"{self._tcp_host}:{self._tcp_port}"
            self._port_select.set_options([(f"TCP {endpoint}", endpoint)])
            self._port_select.value = endpoint
            self._port_select.disabled = True
        if self._baud_input is not None:
            self._baud_input.value = "-"
            self._baud_input.disabled = True
        if self._rescan_button is not None:
            self._rescan_button.disabled = True

    def _active_connected(self) -> bool:
        if self._transport == "tcp":
            return self._tcp.is_connected
        return self._serial.is_connected

    def _connect_active(self) -> None:
        if self._transport == "tcp":
            self._connect_tcp()
        else:
            self._connect_serial()

    def _disconnect_active(self) -> None:
        if self._transport == "tcp":
            self._disconnect_tcp()
        else:
            self._disconnect_serial()

    def _selected_port(self) -> str:
        if self._port_select is None:
            return ""
        value = self._port_select.value
        if value is None or value == Select.BLANK:
            return ""
        return str(value)

    def _reset_stream_stats(self) -> None:
        self._parser.reset()
        self._rx_frames = 0
        self._crc_seen = 0
        self._lost_seen = 0
        self._tcp_packets = 0
        self._tcp_bytes = 0
        self._tcp_last_frame = "-"

    def _connect_serial(self) -> None:
        port = self._selected_port()
        if not port:
            self._set_status("no port selected")
            return
        if self._baud_input is None:
            self._set_status("baud input unavailable")
            return

        try:
            baud = int(self._baud_input.value.strip())
        except ValueError:
            self._set_status("invalid baud")
            return

        try:
            self._serial.connect(port, baud)
        except Exception as exc:
            self._set_status(f"connect failed: {exc}")
            self._log_meta(f"connect failed port={port} baud={baud} err={exc}")
            return

        self._reset_stream_stats()
        if self._connect_button is not None:
            self._connect_button.label = "Disconnect (c)"
        self._set_status(f"connected: {port} @ {baud}")
        self._log_meta(f"connected port={port} baud={baud}")
        self._update_stats()

    def _connect_tcp(self) -> None:
        try:
            self._tcp.connect(self._tcp_host, self._tcp_port)
        except Exception as exc:
            self._set_status(f"tcp connect failed: {exc}")
            self._log_meta(
                f"tcp connect failed host={self._tcp_host} port={self._tcp_port} err={exc}"
            )
            return

        self._reset_stream_stats()
        if self._connect_button is not None:
            self._connect_button.label = "Disconnect (c)"
        self._set_status(f"tcp connected: {self._tcp_host}:{self._tcp_port}")
        self._log_meta(f"tcp connected host={self._tcp_host} port={self._tcp_port}")
        self._update_stats()

    def _disconnect_serial(self) -> None:
        if self._serial.is_connected:
            self._serial.disconnect()
            if self._connect_button is not None:
                self._connect_button.label = "Connect (c)"
            self._set_status("disconnected")
            self._log_meta("disconnected")
            self._update_stats()

    def _disconnect_tcp(self) -> None:
        if self._tcp.is_connected:
            self._tcp.disconnect()
            if self._connect_button is not None:
                self._connect_button.label = "Connect (c)"
            self._set_status("tcp disconnected")
            self._log_meta("tcp disconnected")
            self._update_stats()

    def _send_reset(self) -> None:
        if self._replay_file_path is not None:
            self._set_status("replay mode: TX disabled")
            return

        if self._transport == "tcp":
            if not self._tcp.is_connected:
                self._set_status("not connected")
                return
            written = self._tcp.send_cli_command("reset")
        else:
            if not self._serial.is_connected:
                self._set_status("not connected")
                return
            written = self._serial.send_cli_command("reset")

        if written > 0:
            self._set_status("sent reset")
            self._log_meta("tx cmd=reset")
        else:
            self._set_status("send failed (reset)")

    def _poll_serial(self) -> None:
        if not self._serial.is_connected:
            return
        data = self._serial.read_bytes()
        if not data:
            return
        self._handle_stream_data(data, count_tcp=False)

    def _poll_tcp(self) -> None:
        if not self._tcp.is_connected:
            return

        data = self._tcp.read_bytes()
        if not data:
            if not self._tcp.is_connected:
                if self._connect_button is not None:
                    self._connect_button.label = "Connect (c)"
                self._set_status("tcp disconnected")
                self._log_meta("tcp disconnected by peer")
                self._update_stats()
            return

        self._tcp_packets += 1
        self._tcp_bytes += len(data)
        self._handle_stream_data(data, count_tcp=True)

    def _handle_stream_data(self, data: bytes, *, count_tcp: bool) -> None:
        frames = self._parser.feed(data)

        if self._parser.crc_error_count > self._crc_seen:
            delta = self._parser.crc_error_count - self._crc_seen
            self._crc_seen = self._parser.crc_error_count
            self._log_meta(f"crc_error +{delta}")

        for frame in frames:
            self._append_live_frame(frame)

        if count_tcp and frames:
            self._tcp_last_frame = f"0x{frames[-1].seq:02X}"

        self._update_stats()

    def _poll_replay(self) -> None:
        if self._replay_finished:
            return

        if self._replay_idx >= len(self._replay_records):
            self._replay_finished = True
            self._set_status("replay finished")
            self._log_meta("replay finished")
            self._update_stats()
            return

        record = self._replay_records[self._replay_idx]
        self._replay_idx += 1
        self._append_event(record.seq, record.event, record.lost_count, host_time=record.host_time)
        self._update_stats()

    def _append_live_frame(self, frame: Frame) -> None:
        self._append_event(frame.seq, frame.event, frame.lost_count, host_time=None)

    def _build_row_from_stored(self, stored: StoredEvent) -> LogRow:
        ts_host = stored.host_time or datetime.now().strftime("%H:%M:%S.%f")[:-3]

        if self._mode == "decode":
            decoded = self._decoder.decode(stored.event)
            text = f"[{decoded.level}] {decoded.title}: {decoded.message}"
        else:
            text = (
                f"src={stored.event.src_id} evt={stored.event.event_id} ts={stored.event.timestamp} "
                f"arg0={stored.event.arg0} arg1={stored.event.arg1} arg2={stored.event.arg2}"
            )

        search_text = " ".join(
            [
                ts_host,
                f"0x{stored.seq:02X}",
                f"0x{stored.event.src_id:02X}",
                f"0x{stored.event.event_id:02X}",
                str(stored.event.timestamp),
                f"0x{stored.event.arg0:08X}",
                f"0x{stored.event.arg1:08X}",
                f"0x{stored.event.arg2:08X}",
                text,
                f"lost={stored.lost_count}",
            ]
        ).lower()

        return LogRow(
            host_time=ts_host,
            seq_text=f"0x{stored.seq:02X}",
            src_text=f"0x{stored.event.src_id:02X}",
            evt_text=f"0x{stored.event.event_id:02X}",
            timestamp_text=str(stored.event.timestamp),
            arg0_text=f"0x{stored.event.arg0:08X}",
            arg1_text=f"0x{stored.event.arg1:08X}",
            arg2_text=f"0x{stored.event.arg2:08X}",
            crc_text="OK",
            mode_text=self._mode.upper(),
            text=text,
            search_text=search_text,
        )

    def _append_event(
        self,
        seq: int,
        event: Event,
        lost_count: int,
        *,
        host_time: str | None,
    ) -> None:
        stored = StoredEvent(host_time=host_time, seq=seq, event=event, lost_count=lost_count)
        row = self._build_row_from_stored(stored)
        self._rows.append(stored)
        self._rx_frames += 1

        if lost_count > 0:
            self._lost_seen += lost_count
            self._log_meta(f"seq_loss +{lost_count} at seq=0x{seq:02X}")

        if self._row_matches_filter(row):
            self._append_row_to_table(row)

        self._log_event(seq, event, lost_count, row.text)

    def _row_matches_filter(self, row: LogRow) -> bool:
        if not self._filter_text:
            return True
        return self._filter_text in row.search_text

    def _append_row_to_table(self, row: LogRow) -> None:
        if self._table is None:
            return
        self._table.add_row(
            row.host_time,
            row.seq_text,
            row.src_text,
            row.evt_text,
            row.timestamp_text,
            row.arg0_text,
            row.arg1_text,
            row.arg2_text,
            row.crc_text,
            row.mode_text,
            row.text,
        )
        try:
            self._table.scroll_end(animate=False)
        except Exception:
            pass

    def _render_table(self) -> None:
        if self._table is None:
            return
        try:
            self._table.clear(columns=False)
        except TypeError:
            self._table.clear()
        for stored in self._rows:
            row = self._build_row_from_stored(stored)
            if self._row_matches_filter(row):
                self._append_row_to_table(row)

    def _set_status(self, message: str) -> None:
        if self._status is None:
            return

        if self._replay_file_path is not None:
            conn = "replay"
        else:
            conn = "connected" if self._active_connected() else "disconnected"
        self._status.update(f"{conn} | {message}")

    def _update_stats(self) -> None:
        if self._stats is None:
            return

        if self._replay_file_path is not None:
            conn = "replay"
            port = "-"
            replay_state = f"{self._replay_idx}/{len(self._replay_records)}"
            transport = "replay"
        else:
            conn = "connected" if self._active_connected() else "disconnected"
            transport = self._transport
            if self._transport == "tcp":
                port = f"{self._tcp_host}:{self._tcp_port}"
            else:
                port = self._selected_port() or "-"
            replay_state = "-"

        filtered_rows = sum(
            1 for stored in self._rows if self._row_matches_filter(self._build_row_from_stored(stored))
        )
        log_state = "ON" if self._log_enabled else "OFF"

        self._stats.update(
            "\n".join(
                [
                    "[Stats]",
                    f"transport  : {transport}",
                    f"port       : {port}",
                    f"connection : {conn}",
                    f"mode       : {self._mode}",
                    f"filter     : {self._filter_text or '-'}",
                    f"rows       : {filtered_rows}/{len(self._rows)}",
                    f"rx_frames  : {self._rx_frames}",
                    f"tcp_pkts   : {self._tcp_packets}",
                    f"tcp_bytes  : {self._tcp_bytes}",
                    f"seq_lost   : {self._lost_seen}",
                    f"crc_errors : {self._crc_seen}",
                    f"last_seq   : {self._tcp_last_frame}",
                    f"replay     : {replay_state}",
                    f"log_file   : {log_state}",
                    f"decoder    : {self._decoder_path}",
                ]
            )
        )

    def _open_log_if_needed(self) -> None:
        if not self._log_enabled or self._log_fp is not None:
            return

        if self._log_file_path is None:
            logs_dir = Path("logs")
            logs_dir.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            self._log_file_path = logs_dir / f"uart_{timestamp}.log"
        else:
            self._log_file_path.parent.mkdir(parents=True, exist_ok=True)

        self._log_fp = self._log_file_path.open("a", encoding="utf-8")

    def _log_meta(self, message: str) -> None:
        if not self._log_enabled:
            return
        self._open_log_if_needed()
        if self._log_fp is None:
            return

        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        self._log_fp.write(f"{ts} mode=META {message}\n")
        self._log_fp.flush()

    def _log_event(self, seq: int, event: Event, lost_count: int, text: str) -> None:
        if not self._log_enabled:
            return
        self._open_log_if_needed()
        if self._log_fp is None:
            return

        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        self._log_fp.write(
            f"{ts} mode={self._mode.upper()} seq=0x{seq:02X} "
            f"src=0x{event.src_id:02X} evt=0x{event.event_id:02X} ts={event.timestamp} "
            f"arg0=0x{event.arg0:08X} arg1=0x{event.arg1:08X} arg2=0x{event.arg2:08X} "
            f"crc=OK lost={lost_count} msg={text}\n"
        )
        self._log_fp.flush()
