"""Textual TUI for UART log viewing plus SDRAM map inspection."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import argparse
import os
import time

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import Button, DataTable, Footer, Header, Input, Select, Static

from sdram_uart_protocol import (
    HOST_EVT_BULK_DONE,
    HOST_EVT_BULK_OK,
    HOST_EVT_READ_RSP,
    HOST_EVT_WRITE_ACK,
    build_bulk_read_command,
    build_bulk_write_command,
    build_read_command,
    build_status_read_command,
    build_status_write_command,
    build_write_command,
    iter_bulk_write_blocks,
    recv_bulk_read_blob,
    wait_for_frame,
)
from uart_log_decoder import UARTLogDecoder
from uart_log_protocol import Event, Frame, FrameParser
from uart_log_replay import ReplayRecord, load_replay_records
from uart_log_serial import UARTSerialClient
from uart_log_tcp import UARTTCPClient


HOST_SRC_INDEX = 2
UART_LOG_NUM_SRC = 3
SYS_SRC_ID = 0x00
EV_MODE_CHANGE = 0x01
HOST_SRC_ID = 0x03
HOST_EVT_WRITE_ACK = 0x30
HOST_EVT_READ_RSP = 0x31
HOST_EVT_CMD_ERR = 0x3E
CMD_NEXT_SRC = 0x06
MAP_BYTE_COUNT = 256
MAP_WORD_COUNT = MAP_BYTE_COUNT // 4
MAP_RESPONSE_TIMEOUT_S = 1.0
STATUS_BASE_ADDR = 0x00000
STATUS_BYTE_COUNT = 64
STATUS_WORD_COUNT = STATUS_BYTE_COUNT // 4
STATUS_RESPONSE_TIMEOUT_S = 1.0
STATUS_SELFTEST_ADDR = 0x0003C
STATUS_SELFTEST_DATA = 0x0000_0001


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


def parse_u21(text: str) -> int:
    value = int(text, 0)
    if value < 0 or value > 0x1F_FFFF:
        raise ValueError(f"out of range u21 addr: {text}")
    return value


def make_read_packet(addr: int) -> bytes:
    return build_read_command(addr)


def make_status_read_packet(addr: int) -> bytes:
    return build_status_read_command(addr)


def make_write_packet(addr: int, data: int) -> bytes:
    return build_write_command(addr, data)


def make_status_write_packet(addr: int, data: int) -> bytes:
    return build_status_write_command(addr, data)


def next_src_steps(current_idx: int, target_idx: int, num_src: int = UART_LOG_NUM_SRC) -> int:
    return (target_idx - current_idx) % num_src


def format_sdram_map_text(base_addr: int, map_bytes: bytes) -> str:
    if len(map_bytes) < MAP_BYTE_COUNT:
        padded = bytearray(MAP_BYTE_COUNT)
        padded[: len(map_bytes)] = map_bytes
        map_bytes = bytes(padded)

    lines = [f"Base: 0x{base_addr:05X}  Mode: 4-byte little-endian words"]
    lines.append("      00        04        08        0C")
    for row in range(16):
        row_base = row * 16
        cells = []
        for col in range(0, 16, 4):
            idx = row_base + col
            word = int.from_bytes(map_bytes[idx : idx + 4], "little", signed=False)
            cells.append(f"{word:08X}")
        lines.append(f"{row:01X}0 | " + "  ".join(cells))
    return "\n".join(lines)


def _pad_status_bytes(status_bytes: bytes) -> bytes:
    if len(status_bytes) >= STATUS_BYTE_COUNT:
        return status_bytes[:STATUS_BYTE_COUNT]
    padded = bytearray(STATUS_BYTE_COUNT)
    padded[: len(status_bytes)] = status_bytes
    return bytes(padded)


def _status_word(status_bytes: bytes, offset: int) -> int:
    return int.from_bytes(status_bytes[offset : offset + 4], "little", signed=False)


def _status_state_name(state: int) -> str:
    return {
        0x0: "IDLE",
        0x1: "WRITE_WAIT",
        0x2: "WRITE_REQ",
        0x3: "WRITE_RUN",
        0x4: "READ_WAIT",
        0x5: "READ_REQ",
        0x6: "READ_RUN",
        0x7: "RETRY_WAIT",
        0x8: "RETRY_REQ",
        0x9: "RETRY_RUN",
        0xA: "CLEAR_WAIT",
        0xB: "CLEAR_REQ",
        0xC: "CLEAR_RUN",
        0xD: "PASS",
        0xE: "FAIL",
    }.get(state, f"STATE_{state:02X}")


def _status_fail_reason_name(reason: int) -> str:
    return {
        0x00: "NONE",
        0x01: "TIMEOUT",
        0x03: "MISMATCH",
    }.get(reason, f"REASON_{reason:02X}")


def format_sdram_status_text(status_bytes: bytes) -> str:
    status_bytes = _pad_status_bytes(status_bytes)

    summary = _status_word(status_bytes, 0x00)
    mem_summary = _status_word(status_bytes, 0x04)
    current_addr = _status_word(status_bytes, 0x08)
    expected_word = _status_word(status_bytes, 0x0C)
    last_read = _status_word(status_bytes, 0x10)
    last_status = _status_word(status_bytes, 0x14)
    fail_addr = _status_word(status_bytes, 0x18)
    fail_expected = _status_word(status_bytes, 0x1C)
    fail_actual = _status_word(status_bytes, 0x20)
    retry_summary = _status_word(status_bytes, 0x24)
    retry_data1 = _status_word(status_bytes, 0x28)
    retry_data2 = _status_word(status_bytes, 0x2C)
    ctrl_summary = _status_word(status_bytes, 0x30)
    ctrl_detail = _status_word(status_bytes, 0x34)
    handshake = _status_word(status_bytes, 0x38)
    latest_rd = _status_word(status_bytes, 0x3C)

    summary_version = (summary >> 24) & 0xFF
    summary_state = (summary >> 16) & 0xFF
    summary_reason = (summary >> 8) & 0xFF

    mem_base_idx = (mem_summary >> 24) & 0xFF
    mem_rd_seen = (mem_summary >> 16) & 0xFF
    mem_wr_count = (mem_summary >> 8) & 0xFF
    mem_cycle = mem_summary & 0xFF

    retry_limit = (retry_summary >> 24) & 0xFF
    retry_used = (retry_summary >> 16) & 0xFF
    retry_total = (retry_summary >> 8) & 0xFF

    ctrl_state = (ctrl_summary >> 28) & 0xF
    ctrl_read_count = (ctrl_summary >> 8) & 0xFF
    ctrl_write_count = ctrl_summary & 0xFF

    lines = [
        "Base: 0x00000  Size: 64 bytes  Mode: status + write-only control",
        "Control: SW 0003C 00000001 resets SDRC and reruns selftest",
        "",
        f"0x00 SUMMARY        = 0x{summary:08X}",
        f"  map_version       : 0x{summary_version:02X}",
        f"  memtest_state     : {_status_state_name(summary_state)} (0x{summary_state:02X})",
        f"  fail_reason       : {_status_fail_reason_name(summary_reason)} (0x{summary_reason:02X})",
        f"  host_busy         : {(summary >> 7) & 0x1}",
        f"  test_active       : {(summary >> 6) & 0x1}",
        f"  test_pass         : {(summary >> 5) & 0x1}",
        f"  test_fail         : {(summary >> 4) & 0x1}",
        f"  init_done         : {(summary >> 3) & 0x1}",
        f"  sdrc_reset_active : {(summary >> 2) & 0x1}",
        "",
        f"0x04 MEM_SUMMARY    = 0x{mem_summary:08X}",
        f"  burst_base_idx    : {mem_base_idx} (0x{mem_base_idx:02X})",
        f"  read_words_seen   : {mem_rd_seen}",
        f"  write_word_count  : {mem_wr_count}",
        f"  cycle_count       : {mem_cycle}",
        "",
        f"0x08 CURRENT_ADDR   = 0x{current_addr:08X}",
        f"0x0C EXPECTED_WORD  = 0x{expected_word:08X}",
        f"0x10 LAST_READ      = 0x{last_read:08X}",
        f"0x14 LAST_STATUS    = 0x{last_status:08X}",
        f"  fail_reason       : {_status_fail_reason_name((last_status >> 24) & 0xFF)}",
        f"  rd_seen_words     : {(last_status >> 16) & 0xFF}",
        f"  cycle_count       : {(last_status >> 8) & 0xFF}",
        f"  retry_path        : {(last_status >> 7) & 0x1}",
        f"  busy_n            : {(last_status >> 6) & 0x1}",
        f"  rd_valid          : {(last_status >> 5) & 0x1}",
        f"  wrd_ack           : {(last_status >> 4) & 0x1}",
        f"  init_done         : {(last_status >> 3) & 0x1}",
        f"  retry_count       : {last_status & 0x7}",
        "",
        f"0x18 FAIL_ADDR      = 0x{fail_addr:08X}",
        f"0x1C FAIL_EXPECTED  = 0x{fail_expected:08X}",
        f"0x20 FAIL_ACTUAL    = 0x{fail_actual:08X}",
        "",
        f"0x24 RETRY_SUMMARY  = 0x{retry_summary:08X}",
        f"  retry_limit       : {retry_limit}",
        f"  retries_used      : {retry_used}",
        f"  total_attempts    : {retry_total}",
        f"  recovered         : {(retry_summary >> 7) & 0x1}",
        f"  exhausted         : {(retry_summary >> 6) & 0x1}",
        f"  valid             : {(retry_summary >> 5) & 0x1}",
        f"  fail_reason       : {_status_fail_reason_name(retry_summary & 0x1F)}",
        f"0x28 RETRY_DATA1    = 0x{retry_data1:08X}",
        f"0x2C RETRY_DATA2    = 0x{retry_data2:08X}",
        "",
        f"0x30 CTRL_SUMMARY   = 0x{ctrl_summary:08X}",
        f"  state             : {_status_state_name(ctrl_state)} (0x{ctrl_state:X})",
        f"  wr_launch         : {(ctrl_summary >> 27) & 0x1}",
        f"  rd_launch         : {(ctrl_summary >> 26) & 0x1}",
        f"  busy_n            : {(ctrl_summary >> 25) & 0x1}",
        f"  rd_valid          : {(ctrl_summary >> 24) & 0x1}",
        f"  wrd_ack           : {(ctrl_summary >> 23) & 0x1}",
        f"  init_done         : {(ctrl_summary >> 22) & 0x1}",
        f"  retry_state       : {(ctrl_summary >> 21) & 0x1}",
        f"  retry_valid       : {(ctrl_summary >> 20) & 0x1}",
        f"  retry_recovered   : {(ctrl_summary >> 19) & 0x1}",
        f"  retry_exhausted   : {(ctrl_summary >> 18) & 0x1}",
        f"  retry_count_lsb2  : {(ctrl_summary >> 16) & 0x3}",
        f"  read_word_count   : {ctrl_read_count}",
        f"  write_word_count  : {ctrl_write_count}",
        f"0x34 CTRL_DETAIL    = 0x{ctrl_detail:08X}",
        "",
        f"0x38 HANDSHAKE      = 0x{handshake:08X}",
        f"  magic             : 0x{(handshake >> 24) & 0xFF:02X}",
        f"  busy_n            : {(handshake >> 23) & 0x1}",
        f"  rd_valid          : {(handshake >> 22) & 0x1}",
        f"  wrd_ack           : {(handshake >> 21) & 0x1}",
        f"  init_done         : {(handshake >> 20) & 0x1}",
        f"  test_active       : {(handshake >> 19) & 0x1}",
        f"  test_pass         : {(handshake >> 18) & 0x1}",
        f"  test_fail         : {(handshake >> 17) & 0x1}",
        f"  host_busy         : {(handshake >> 16) & 0x1}",
        f"  sampled_addr      : 0x{handshake & 0xFFFF:04X}",
        "",
        f"0x3C LATEST_RD_DATA = 0x{latest_rd:08X}",
        "",
        "Raw words:",
    ]

    for offset in range(0, STATUS_BYTE_COUNT, 4):
        lines.append(f"  0x{offset:02X}: 0x{_status_word(status_bytes, offset):08X}")

    return "\n".join(lines)


def format_sdram_status_raw_text(status_bytes: bytes) -> str:
    status_bytes = _pad_status_bytes(status_bytes)
    lines = [
        "Base: 0x00000  Size: 64 bytes  Mode: raw 32-bit words",
        "      00        04        08        0C",
    ]
    for row_base in range(0, STATUS_BYTE_COUNT, 16):
        cells = []
        for col in range(0, 16, 4):
            offset = row_base + col
            cells.append(f"{_status_word(status_bytes, offset):08X}")
        lines.append(f"{row_base:02X} | " + "  ".join(cells))
    return "\n".join(lines)


class UARTLogApp(App[None]):
    CSS = """
    #top_bar { height: 3; layout: horizontal; margin: 0 1; }
    #main_layout { layout: horizontal; height: 1fr; margin: 0 1; }
    #nav { width: 18; border: round; padding: 0 1; margin-right: 1; }
    #nav Button { width: 100%; margin-bottom: 1; }
    #screen_host { width: 1fr; height: 1fr; }
    .screen { width: 1fr; height: 1fr; }
    .hidden { display: none; }
    .toolbar { height: 3; layout: horizontal; margin-bottom: 1; }
    .toolbar Input, .toolbar Select, .toolbar Button { margin-right: 1; }
    #port_select { width: 32; margin-right: 1; }
    #baud_input { width: 10; margin-right: 1; }
    #filter_input { width: 32; margin-right: 1; }
    #btn_rescan { width: 12; margin-right: 1; }
    #btn_connect { width: 14; margin-right: 1; }
    #btn_reset { width: 12; margin-right: 1; }
    #status_line { width: 1fr; content-align: left middle; }
    #log_main_row { layout: horizontal; height: 1fr; }
    #log_table { width: 1fr; height: 1fr; }
    #stats_panel { width: 38; padding: 0 1; border: round; }
    #map_summary { height: 5; border: round; padding: 0 1; margin-bottom: 1; }
    #map_view { height: 1fr; border: round; padding: 0 1; overflow: auto; }
    .panel { border: round; padding: 0 1; margin-bottom: 1; }
    .rw_panel { height: auto; }
    #rw_grid { width: 1fr; height: 1fr; }
    #rw_grid .toolbar { margin-bottom: 0; }
    #map_base_input { width: 18; }
    #btn_map_refresh { width: 12; }
    #btn_status_refresh { width: 16; }
    #btn_status_mode { width: 14; }
    #btn_status_selftest { width: 14; }
    #status_summary { height: 5; border: round; padding: 0 1; margin-bottom: 1; }
    #status_scroll { height: 1fr; border: round; padding: 0 1; }
    #status_view { width: 1fr; height: auto; }
    #single_read_addr_input { width: 18; }
    #single_read_result { width: 28; content-align: left middle; }
    #single_write_addr_input { width: 18; }
    #single_write_data_input { width: 18; }
    #file_read_path_input { width: 1fr; }
    #file_write_addr_input { width: 18; }
    #file_write_path_input { width: 1fr; }
    #help_line { height: 2; margin: 0 1 1 1; content-align: left middle; }
    """

    BINDINGS = [
        ("1", "show_log", "Log"),
        ("2", "show_map", "SDRAM Map"),
        ("3", "show_rw", "SDRAM RW"),
        ("4", "show_status", "SDRAM STS"),
        ("p", "rescan", "Rescan Ports"),
        ("c", "toggle_connect", "Connect/Disconnect"),
        ("m", "toggle_mode", "Raw/Decode"),
        ("u", "reload_decoder", "Reload Decoder"),
        ("l", "toggle_log", "Log ON/OFF"),
        ("x", "clear_logs", "Clear Logs"),
        ("r", "send_reset", "Send Ctrl+R"),
        ("f", "focus_filter", "Focus Filter"),
        ("g", "refresh_map", "Refresh Map"),
        ("q", "quit", "Quit"),
    ]

    def __init__(self, *, transport: str, initial_port: str | None, baud: int, tcp_host: str, tcp_port: int, mode: str, decoder_path: str, log_file: str | None, replay_file: str | None) -> None:
        super().__init__()
        self._transport = transport.lower()
        self._initial_port = initial_port
        self._baud = int(baud)
        self._tcp_host = tcp_host
        self._tcp_port = int(tcp_port)
        self._mode = mode.lower()
        self._filter_text = ""
        self._active_screen = "log"
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
        self._selected_src_idx = 0
        self._rows: list[StoredEvent] = []
        self._log_enabled = bool(log_file)
        self._log_file_path = Path(log_file) if log_file else None
        self._log_fp = None
        self._replay_file_path = Path(replay_file) if replay_file else None
        self._replay_records: list[ReplayRecord] = []
        self._replay_idx = 0
        self._replay_finished = False
        self._replay_load_error: str | None = None
        self._map_base_addr = 0
        self._map_bytes = bytearray(MAP_BYTE_COUNT)
        self._map_refresh_active = False
        self._map_restore_src_idx: int | None = None
        self._map_select_deadline = 0.0
        self._map_rsp_deadline = 0.0
        self._map_pending_queue: list[int] = []
        self._map_inflight_addr: int | None = None
        self._map_received_words: dict[int, int] = {}
        self._map_summary_text = "idle"
        self._status_bytes = bytearray(STATUS_BYTE_COUNT)
        self._status_refresh_active = False
        self._status_select_deadline = 0.0
        self._status_rsp_deadline = 0.0
        self._status_pending_queue: list[int] = []
        self._status_inflight_addr: int | None = None
        self._status_summary_text = "idle"
        self._status_mode = "decode"
        self._status_selftest_active = False
        self._status_selftest_inflight = False
        self._status_selftest_select_deadline = 0.0
        self._status_selftest_rsp_deadline = 0.0
        self._rw_summary_text = "idle"
        self._rw_single_read_result = "-"
        self._rw_single_write_result = "-"
        self._rw_file_write_result = "-"
        self._rw_file_read_result = "-"
        self._rw_task_active = False
        self._rw_task_kind = ""
        self._rw_task_restore_src_idx: int | None = None
        self._rw_task_select_deadline = 0.0
        self._rw_task_rsp_deadline = 0.0
        self._rw_task_pending: list[tuple[str, int, int]] = []
        self._rw_task_inflight: tuple[str, int, int] | None = None
        self._rw_task_expected_reads = 0
        self._rw_task_read_results: dict[int, int] = {}
        self._rw_task_output_path: Path | None = None
        self._rw_task_output_len = 0
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
        self._map_summary: Static | None = None
        self._map_view: Static | None = None
        self._map_base_input: Input | None = None
        self._status_summary: Static | None = None
        self._status_view: Static | None = None
        self._status_mode_button: Button | None = None
        self._status_selftest_button: Button | None = None
        self._rw_summary: Static | None = None
        self._single_read_addr_input: Input | None = None
        self._single_read_result: Static | None = None
        self._single_write_addr_input: Input | None = None
        self._single_write_data_input: Input | None = None
        self._single_write_result: Static | None = None
        self._file_write_addr_input: Input | None = None
        self._file_write_path_input: Input | None = None
        self._file_write_result: Static | None = None
        self._file_read_path_input: Input | None = None
        self._file_read_result: Static | None = None

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
            with Horizontal(id="main_layout"):
                with Vertical(id="nav"):
                    yield Button("1 Log", id="nav_log")
                    yield Button("2 SDRAM Map", id="nav_map")
                    yield Button("3 SDRAM RW", id="nav_rw")
                    yield Button("4 SDRAM STS", id="nav_status")
                with Vertical(id="screen_host"):
                    with Vertical(id="log_screen", classes="screen"):
                        with Horizontal(id="log_main_row"):
                            yield DataTable(id="log_table")
                            yield Static("", id="stats_panel")
                    with Vertical(id="map_screen", classes="screen hidden"):
                        with Horizontal(classes="toolbar"):
                            yield Input(value="0x00000", id="map_base_input", placeholder="base addr")
                            yield Button("Refresh", id="btn_map_refresh")
                        yield Static("", id="map_summary")
                        yield Static("", id="map_view")
                    with Vertical(id="status_screen", classes="screen hidden"):
                        with Horizontal(classes="toolbar"):
                            yield Button("Refresh Status", id="btn_status_refresh")
                            yield Button("Mode: Decode", id="btn_status_mode")
                            yield Button("Selftest", id="btn_status_selftest")
                        yield Static("", id="status_summary")
                        with VerticalScroll(id="status_scroll"):
                            yield Static("", id="status_view")
                    with Vertical(id="rw_screen", classes="screen hidden"):
                        yield Static("", id="rw_summary", classes="panel")
                        with Vertical(id="rw_grid"):
                            with Vertical(classes="panel rw_panel"):
                                yield Static("Single Address Read")
                                with Horizontal(classes="toolbar"):
                                    yield Button("Read", id="btn_single_read")
                                    yield Input(value="0x00000", id="single_read_addr_input", placeholder="addr")
                                    yield Static("-", id="single_read_result")
                            with Vertical(classes="panel rw_panel"):
                                yield Static("Single Address Write")
                                with Horizontal(classes="toolbar"):
                                    yield Button("Write", id="btn_single_write")
                                    yield Input(value="0x00000", id="single_write_addr_input", placeholder="addr")
                                    yield Input(value="0x00000000", id="single_write_data_input", placeholder="data")
                                yield Static("-", id="single_write_result")
                            with Vertical(classes="panel rw_panel"):
                                yield Static("File Select Read")
                                with Horizontal(classes="toolbar"):
                                    yield Button("Read", id="btn_file_read_save")
                                    yield Input(value="", id="file_read_path_input", placeholder="output path")
                                yield Static("-", id="file_read_result")
                            with Vertical(classes="panel rw_panel"):
                                yield Static("File Select Write")
                                with Horizontal(classes="toolbar"):
                                    yield Button("Write", id="btn_file_write")
                                    yield Input(value="0x00000", id="file_write_addr_input", placeholder="base addr")
                                    yield Input(value="", id="file_write_path_input", placeholder="file path")
                                yield Static("-", id="file_write_result")
            yield Static("keys: 1=log 2=map 3=rw 4=sts p=rescan c=connect m=mode u=reload l=log x=clear r=reset f=filter g=refresh q=quit", id="help_line")
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
        self._map_summary = self.query_one("#map_summary", Static)
        self._map_view = self.query_one("#map_view", Static)
        self._map_base_input = self.query_one("#map_base_input", Input)
        self._status_summary = self.query_one("#status_summary", Static)
        self._status_view = self.query_one("#status_view", Static)
        self._status_mode_button = self.query_one("#btn_status_mode", Button)
        self._status_selftest_button = self.query_one("#btn_status_selftest", Button)
        self._rw_summary = self.query_one("#rw_summary", Static)
        self._single_read_addr_input = self.query_one("#single_read_addr_input", Input)
        self._single_read_result = self.query_one("#single_read_result", Static)
        self._single_write_addr_input = self.query_one("#single_write_addr_input", Input)
        self._single_write_data_input = self.query_one("#single_write_data_input", Input)
        self._single_write_result = self.query_one("#single_write_result", Static)
        self._file_write_addr_input = self.query_one("#file_write_addr_input", Input)
        self._file_write_path_input = self.query_one("#file_write_path_input", Input)
        self._file_write_result = self.query_one("#file_write_result", Static)
        self._file_read_path_input = self.query_one("#file_read_path_input", Input)
        self._file_read_result = self.query_one("#file_read_result", Static)
        self._table.cursor_type = "row"
        self._table.add_columns("Time", "SEQ", "SRC", "EVT", "TS", "ARG0", "ARG1", "ARG2", "CRC", "Mode", "Text")
        self._reload_decoder(force=True, manual=False)
        self._refresh_map_view()
        self._refresh_status_view()
        self._refresh_rw_view()
        self._show_screen("log")
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
                self._set_status(f"replay loaded: {self._replay_file_path} ({len(self._replay_records)} events)")
                self.set_interval(0.05, self._poll_replay)
            else:
                self._set_status(f"replay load failed: {self._replay_file_path} ({self._replay_load_error})")
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
        self.set_interval(0.05, self._poll_map_refresh)
        self.set_interval(0.05, self._poll_status_refresh)
        self.set_interval(0.05, self._poll_status_selftest)
        self.set_interval(0.05, self._poll_rw_task)
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
        elif button_id == "nav_log":
            self.action_show_log()
        elif button_id == "nav_map":
            self.action_show_map()
        elif button_id == "nav_status":
            self.action_show_status()
        elif button_id == "nav_rw":
            self.action_show_rw()
        elif button_id == "btn_map_refresh":
            self.action_refresh_map()
        elif button_id == "btn_status_refresh":
            self.action_refresh_status()
        elif button_id == "btn_status_mode":
            self.action_toggle_status_mode()
        elif button_id == "btn_status_selftest":
            self.action_status_selftest()
        elif button_id == "btn_single_read":
            self._start_single_read()
        elif button_id == "btn_single_write":
            self._start_single_write()
        elif button_id == "btn_file_write":
            self._start_file_write()
        elif button_id == "btn_file_read_save":
            self._start_file_read_save()

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "filter_input":
            self._filter_text = event.value.strip().lower()
            self._render_table()
            self._update_stats()

    def action_show_log(self) -> None:
        self._show_screen("log")

    def action_show_map(self) -> None:
        self._show_screen("map")

    def action_show_status(self) -> None:
        self._show_screen("status")

    def action_show_rw(self) -> None:
        self._show_screen("rw")

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

    def action_refresh_map(self) -> None:
        if self._active_screen == "status":
            self._start_status_refresh()
        else:
            self._start_map_refresh()

    def action_refresh_status(self) -> None:
        self._start_status_refresh()

    def action_toggle_status_mode(self) -> None:
        self._status_mode = "raw" if self._status_mode == "decode" else "decode"
        self._refresh_status_view()
        self._set_status(f"sdram status mode={self._status_mode}")

    def action_status_selftest(self) -> None:
        self._start_status_selftest()

    def _show_screen(self, screen_name: str) -> None:
        self._active_screen = screen_name
        log_screen = self.query_one("#log_screen", Vertical)
        map_screen = self.query_one("#map_screen", Vertical)
        status_screen = self.query_one("#status_screen", Vertical)
        rw_screen = self.query_one("#rw_screen", Vertical)
        log_screen.set_class(screen_name != "log", "hidden")
        map_screen.set_class(screen_name != "map", "hidden")
        status_screen.set_class(screen_name != "status", "hidden")
        rw_screen.set_class(screen_name != "rw", "hidden")

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
            self._decoder = UARTLogDecoder.from_yaml(self._decoder_path_obj)
        except Exception as exc:
            if manual:
                self._set_status(f"decoder reload failed: {exc}")
            self._log_meta(f"decoder reload failed: {exc}")
            return
        self._decoder_mtime_ns = mtime_ns
        self._render_table()
        if manual:
            self._set_status("decoder reloaded")

    def _refresh_ports(self) -> None:
        if self._port_select is None:
            return
        ports = self._serial.list_ports()
        if ports:
            options = [(f"{p.device:<8} | {p.description if p.description else p.hwid}", p.device) for p in ports]
            self._port_select.set_options(options)
            self._port_select.value = self._initial_port if self._initial_port and any(p.device == self._initial_port for p in ports) else ports[0].device
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
        return self._tcp.is_connected if self._transport == "tcp" else self._serial.is_connected

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
        return "" if value is None or value == Select.BLANK else str(value)

    def _reset_stream_stats(self) -> None:
        self._parser.reset()
        self._rx_frames = 0
        self._crc_seen = 0
        self._lost_seen = 0
        self._tcp_packets = 0
        self._tcp_bytes = 0
        self._tcp_last_frame = "-"
        self._selected_src_idx = 0

    def _connect_serial(self) -> None:
        port = self._selected_port()
        if not port or self._baud_input is None:
            self._set_status("invalid serial setup")
            return
        try:
            baud = int(self._baud_input.value.strip())
            self._serial.connect(port, baud)
        except Exception as exc:
            self._set_status(f"connect failed: {exc}")
            self._log_meta(f"connect failed port={port} err={exc}")
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
            self._log_meta(f"tcp connect failed host={self._tcp_host} port={self._tcp_port} err={exc}")
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

    def _send_bytes(self, payload: bytes) -> int:
        if self._replay_file_path is not None:
            return 0
        if self._transport == "tcp":
            return 0 if not self._tcp.is_connected else self._tcp.write_bytes(payload)
        return 0 if not self._serial.is_connected else self._serial.write_bytes(payload)

    def _read_bytes(self) -> bytes:
        if self._replay_file_path is not None:
            return b""
        if self._transport == "tcp":
            return b"" if not self._tcp.is_connected else self._tcp.read_bytes()
        return b"" if not self._serial.is_connected else self._serial.read_bytes()

    def _wait_for_host_event(self, event_id: int, timeout_s: float) -> Frame:
        return wait_for_frame(
            self._read_bytes,
            self._parser,
            timeout_s,
            lambda frame: frame.event.src_id == HOST_SRC_ID and frame.event.event_id == event_id,
        )

    def _send_next_src_steps(self, steps: int) -> bool:
        for _ in range(steps):
            if self._send_bytes(bytes([CMD_NEXT_SRC])) != 1:
                return False
        return True

    def _host_task_busy(self) -> bool:
        return (
            self._map_refresh_active
            or self._status_refresh_active
            or self._status_selftest_active
            or self._rw_task_active
        )

    def _refresh_status_view(self) -> None:
        mode_label = "Decode" if self._status_mode == "decode" else "Raw"
        if self._status_mode_button is not None:
            self._status_mode_button.label = f"Mode: {mode_label}"
        if self._status_summary is not None:
            self._status_summary.update(
                "\n".join(
                    [
                        "[SDRAM STS]",
                        "base       : 0x00000",
                        "size       : 64 bytes",
                        f"view       : {self._status_mode}",
                        f"state      : {self._status_operation_state()}",
                        f"detail     : {self._status_summary_text}",
                    ]
                )
            )
        if self._status_view is not None:
            if self._status_mode == "raw":
                self._status_view.update(format_sdram_status_raw_text(bytes(self._status_bytes)))
            else:
                self._status_view.update(format_sdram_status_text(bytes(self._status_bytes)))

    def _start_status_refresh(self) -> None:
        if self._replay_file_path is not None:
            self._status_summary_text = "replay mode: SDRAM STS disabled"
            self._refresh_status_view()
            self._set_status(self._status_summary_text)
            return
        if not self._active_connected():
            self._status_summary_text = "not connected"
            self._refresh_status_view()
            self._set_status(self._status_summary_text)
            return
        if self._host_task_busy():
            self._status_summary_text = "host task busy"
            self._refresh_status_view()
            self._set_status(self._status_summary_text)
            return

        self._status_refresh_active = True
        self._status_select_deadline = 0.0
        self._status_rsp_deadline = 0.0
        self._status_inflight_addr = None
        self._status_pending_queue = [STATUS_BASE_ADDR + idx * 4 for idx in range(STATUS_WORD_COUNT)]
        self._status_summary_text = f"queued {STATUS_WORD_COUNT} status reads"
        self._refresh_status_view()
        self._set_status(self._status_summary_text)

    def _finish_status_refresh(self, detail: str) -> None:
        self._status_refresh_active = False
        self._status_inflight_addr = None
        self._status_rsp_deadline = 0.0
        self._status_summary_text = detail
        self._refresh_status_view()
        self._set_status(detail)

    def _status_operation_state(self) -> str:
        if self._status_refresh_active:
            return "refreshing"
        if self._status_selftest_active:
            return "selftest"
        return "idle"

    def _start_status_selftest(self) -> None:
        if self._replay_file_path is not None:
            self._status_summary_text = "replay mode: selftest disabled"
            self._refresh_status_view()
            self._set_status(self._status_summary_text)
            return
        if not self._active_connected():
            self._status_summary_text = "not connected"
            self._refresh_status_view()
            self._set_status(self._status_summary_text)
            return
        if self._host_task_busy():
            self._status_summary_text = "host task busy"
            self._refresh_status_view()
            self._set_status(self._status_summary_text)
            return

        self._status_selftest_active = True
        self._status_selftest_inflight = False
        self._status_selftest_select_deadline = 0.0
        self._status_selftest_rsp_deadline = 0.0
        self._status_summary_text = "queued selftest trigger"
        self._refresh_status_view()
        self._set_status(self._status_summary_text)

    def _finish_status_selftest(self, detail: str, *, refresh_after_ack: bool = False) -> None:
        self._status_selftest_active = False
        self._status_selftest_inflight = False
        self._status_selftest_rsp_deadline = 0.0
        self._status_summary_text = detail
        self._refresh_status_view()
        self._set_status(detail)
        if refresh_after_ack:
            self._start_status_refresh()

    def _refresh_rw_view(self) -> None:
        if self._rw_summary is not None:
            self._rw_summary.update(
                "\n".join(
                    [
                        "[SDRAM RW]",
                        f"state  : {'busy' if self._rw_task_active else 'idle'}",
                        f"task   : {self._rw_task_kind or '-'}",
                        f"detail : {self._rw_summary_text}",
                    ]
                )
            )
        if self._single_read_result is not None:
            self._single_read_result.update(self._rw_single_read_result)
        if self._single_write_result is not None:
            self._single_write_result.update(self._rw_single_write_result)
        if self._file_write_result is not None:
            self._file_write_result.update(self._rw_file_write_result)
        if self._file_read_result is not None:
            self._file_read_result.update(self._rw_file_read_result)

    def _start_rw_task(self, *, kind: str, commands: list[tuple[str, int, int]], expected_reads: int = 0, output_path: Path | None = None, output_len: int = 0) -> bool:
        if self._replay_file_path is not None:
            self._set_status("replay mode: SDRAM RW disabled")
            return False
        if not self._active_connected():
            self._set_status("not connected")
            return False
        if self._host_task_busy():
            self._set_status("host task busy")
            return False
        self._rw_task_active = True
        self._rw_task_kind = kind
        self._rw_task_pending = list(commands)
        self._rw_task_inflight = None
        self._rw_task_expected_reads = expected_reads
        self._rw_task_read_results = {}
        self._rw_task_output_path = output_path
        self._rw_task_output_len = output_len
        self._rw_task_restore_src_idx = None
        self._rw_task_select_deadline = time.monotonic()
        self._rw_task_rsp_deadline = 0.0
        self._rw_summary_text = f"started {kind}"
        self._refresh_rw_view()
        self._set_status(self._rw_summary_text)
        return True

    def _finish_rw_task(self, detail: str) -> None:
        self._rw_task_active = False
        self._rw_summary_text = detail
        self._rw_task_restore_src_idx = None
        self._rw_task_kind = ""
        self._rw_task_pending = []
        self._rw_task_inflight = None
        self._rw_task_expected_reads = 0
        self._rw_task_rsp_deadline = 0.0
        self._refresh_rw_view()
        self._set_status(detail)

    def _start_single_read(self) -> None:
        if self._single_read_addr_input is None:
            return
        try:
            addr = parse_u21(self._single_read_addr_input.value.strip())
        except Exception as exc:
            self._rw_single_read_result = f"invalid addr: {exc}"
            self._refresh_rw_view()
            self._set_status(self._rw_single_read_result)
            return
        if self._start_rw_task(kind="single_read", commands=[("read", addr, 0)], expected_reads=1):
            self._rw_single_read_result = f"reading 0x{addr:05X}..."
            self._refresh_rw_view()

    def _start_single_write(self) -> None:
        if self._single_write_addr_input is None or self._single_write_data_input is None:
            return
        try:
            addr = parse_u21(self._single_write_addr_input.value.strip())
            data = int(self._single_write_data_input.value.strip(), 0) & 0xFFFF_FFFF
        except Exception as exc:
            self._rw_single_write_result = f"invalid input: {exc}"
            self._refresh_rw_view()
            self._set_status(self._rw_single_write_result)
            return
        if self._start_rw_task(kind="single_write", commands=[("write", addr, data)]):
            self._rw_single_write_result = f"writing 0x{data:08X} -> 0x{addr:05X}"
            self._refresh_rw_view()

    def _start_file_write(self) -> None:
        self._rw_file_write_result = "INOP: bulk path disabled"
        self._refresh_rw_view()
        self._set_status(self._rw_file_write_result)

    def _start_file_read_save(self) -> None:
        self._rw_file_read_result = "INOP: bulk path disabled"
        self._refresh_rw_view()
        self._set_status(self._rw_file_read_result)

    def _poll_serial(self) -> None:
        if not self._serial.is_connected:
            return
        data = self._serial.read_bytes()
        if data:
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
            text = f"src={stored.event.src_id} evt={stored.event.event_id} ts={stored.event.timestamp} arg0={stored.event.arg0} arg1={stored.event.arg1} arg2={stored.event.arg2}"
        search_text = " ".join([ts_host, f"0x{stored.seq:02X}", f"0x{stored.event.src_id:02X}", f"0x{stored.event.event_id:02X}", str(stored.event.timestamp), f"0x{stored.event.arg0:08X}", f"0x{stored.event.arg1:08X}", f"0x{stored.event.arg2:08X}", text, f"lost={stored.lost_count}"]).lower()
        return LogRow(ts_host, f"0x{stored.seq:02X}", f"0x{stored.event.src_id:02X}", f"0x{stored.event.event_id:02X}", str(stored.event.timestamp), f"0x{stored.event.arg0:08X}", f"0x{stored.event.arg1:08X}", f"0x{stored.event.arg2:08X}", "OK", self._mode.upper(), text, search_text)

    def _append_event(self, seq: int, event: Event, lost_count: int, *, host_time: str | None) -> None:
        self._handle_special_event(event)
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

    def _handle_special_event(self, event: Event) -> None:
        if event.src_id == SYS_SRC_ID and event.event_id == EV_MODE_CHANGE:
            self._selected_src_idx = event.arg1 & 0xFF
        if not self._map_refresh_active or event.src_id != HOST_SRC_ID:
            pass
        else:
            if event.event_id == HOST_EVT_READ_RSP and self._map_inflight_addr is not None and event.arg0 == self._map_inflight_addr:
                self._map_received_words[event.arg0] = event.arg1
                word_index = event.arg0 - self._map_base_addr
                if 0 <= word_index < MAP_WORD_COUNT:
                    offset = word_index * 4
                    self._map_bytes[offset : offset + 4] = event.arg1.to_bytes(4, "little")
                self._map_inflight_addr = None
                self._map_rsp_deadline = 0.0
                self._refresh_map_view()
                if not self._map_pending_queue:
                    self._finish_map_refresh("refresh complete")
            elif event.event_id == HOST_EVT_CMD_ERR and self._map_inflight_addr is not None:
                self._map_refresh_active = False
                self._map_summary_text = f"refresh failed at 0x{self._map_inflight_addr:05X}: cmd_err"
                self._map_inflight_addr = None
                self._refresh_map_view()
                self._set_status(self._map_summary_text)

        if not self._status_refresh_active or event.src_id != HOST_SRC_ID:
            pass
        else:
            if event.event_id == HOST_EVT_READ_RSP and self._status_inflight_addr is not None and event.arg0 == self._status_inflight_addr:
                offset = event.arg0 - STATUS_BASE_ADDR
                if 0 <= offset < STATUS_BYTE_COUNT:
                    self._status_bytes[offset : offset + 4] = event.arg1.to_bytes(4, "little")
                self._status_inflight_addr = None
                self._status_rsp_deadline = 0.0
                self._refresh_status_view()
                if not self._status_pending_queue:
                    self._finish_status_refresh("status refresh complete")
            elif event.event_id == HOST_EVT_CMD_ERR and self._status_inflight_addr is not None:
                self._finish_status_refresh(
                    f"status refresh failed at 0x{self._status_inflight_addr:05X}: cmd_err 0x{event.arg0:08X}"
                )

        if not self._status_selftest_active or event.src_id != HOST_SRC_ID:
            pass
        else:
            if (
                event.event_id == HOST_EVT_WRITE_ACK
                and self._status_selftest_inflight
                and event.arg0 == STATUS_SELFTEST_ADDR
            ):
                self._finish_status_selftest(
                    "selftest trigger acknowledged; refreshing status",
                    refresh_after_ack=True,
                )
            elif event.event_id == HOST_EVT_CMD_ERR and self._status_selftest_inflight:
                self._finish_status_selftest(
                    f"selftest trigger failed: cmd_err 0x{event.arg0:08X}"
                )

        if not self._rw_task_active or event.src_id != HOST_SRC_ID:
            return
        if self._rw_task_inflight is None:
            return
        op_kind, inflight_addr, inflight_data = self._rw_task_inflight
        if event.event_id == HOST_EVT_READ_RSP and op_kind == "read" and event.arg0 == inflight_addr:
            self._rw_task_read_results[inflight_addr] = event.arg1
            self._rw_task_inflight = None
            self._rw_task_rsp_deadline = 0.0
            if self._rw_task_kind == "single_read":
                self._rw_single_read_result = f"0x{inflight_addr:05X} -> 0x{event.arg1:08X}"
            self._refresh_rw_view()
        elif event.event_id == HOST_EVT_WRITE_ACK and op_kind == "write" and event.arg0 == inflight_addr:
            self._rw_task_inflight = None
            self._rw_task_rsp_deadline = 0.0
            if self._rw_task_kind == "single_write":
                self._rw_single_write_result = f"0x{inflight_data:08X} -> 0x{inflight_addr:05X} OK"
            self._refresh_rw_view()
        elif event.event_id == HOST_EVT_CMD_ERR:
            self._rw_task_inflight = None
            self._rw_task_rsp_deadline = 0.0
            if self._rw_task_kind == "single_read":
                self._rw_single_read_result = f"CMD_ERR arg0=0x{event.arg0:08X}"
            elif self._rw_task_kind == "single_write":
                self._rw_single_write_result = f"CMD_ERR arg0=0x{event.arg0:08X}"
            elif self._rw_task_kind == "file_write":
                self._rw_file_write_result = f"CMD_ERR arg0=0x{event.arg0:08X}"
            elif self._rw_task_kind == "file_read_save":
                self._rw_file_read_result = f"CMD_ERR arg0=0x{event.arg0:08X}"
            self._finish_rw_task("rw task failed: cmd_err")

    def _row_matches_filter(self, row: LogRow) -> bool:
        return True if not self._filter_text else self._filter_text in row.search_text

    def _append_row_to_table(self, row: LogRow) -> None:
        if self._table is None:
            return
        self._table.add_row(row.host_time, row.seq_text, row.src_text, row.evt_text, row.timestamp_text, row.arg0_text, row.arg1_text, row.arg2_text, row.crc_text, row.mode_text, row.text)
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

    def _refresh_map_view(self) -> None:
        if self._map_summary is not None:
            self._map_summary.update("\n".join(["[SDRAM Map]", f"base       : 0x{self._map_base_addr:05X}", "mode       : 4-byte words", f"state      : {'refreshing' if self._map_refresh_active else 'idle'}", f"detail     : {self._map_summary_text}"]))
        if self._map_view is not None:
            self._map_view.update(format_sdram_map_text(self._map_base_addr, self._map_bytes))

    def _start_map_refresh(self) -> None:
        if self._map_base_input is not None:
            try:
                self._map_base_addr = parse_u21(self._map_base_input.value.strip())
            except Exception as exc:
                self._map_summary_text = f"invalid base addr: {exc}"
                self._refresh_map_view()
                self._set_status(self._map_summary_text)
                return
        if self._replay_file_path is not None:
            self._map_summary_text = "replay mode: SDRAM Map disabled"
            self._refresh_map_view()
            self._set_status(self._map_summary_text)
            return
        if not self._active_connected():
            self._map_summary_text = "not connected"
            self._refresh_map_view()
            self._set_status(self._map_summary_text)
            return
        if self._host_task_busy():
            self._map_summary_text = "host task busy"
            self._refresh_map_view()
            self._set_status(self._map_summary_text)
            return

        self._map_refresh_active = True
        self._map_restore_src_idx = None
        self._map_select_deadline = 0.0
        self._map_rsp_deadline = 0.0
        self._map_inflight_addr = None
        self._map_received_words = {}
        self._map_bytes = bytearray(MAP_BYTE_COUNT)
        self._map_pending_queue = [self._map_base_addr + idx for idx in range(MAP_WORD_COUNT)]
        self._map_summary_text = f"queued {MAP_WORD_COUNT} SDRAM reads"
        self._refresh_map_view()
        self._set_status(self._map_summary_text)

    def _poll_map_refresh(self) -> None:
        if not self._map_refresh_active:
            return
        now = time.monotonic()
        if self._selected_src_idx != HOST_SRC_INDEX:
            if now >= self._map_select_deadline:
                if self._send_bytes(bytes([CMD_NEXT_SRC])) != 1:
                    self._map_refresh_active = False
                    self._map_summary_text = "failed to select host source"
                    self._refresh_map_view()
                    self._set_status(self._map_summary_text)
                    return
                self._map_summary_text = f"selecting host source (current={self._selected_src_idx})"
                self._map_select_deadline = now + 0.35
                self._refresh_map_view()
            return
        if self._map_inflight_addr is not None and now > self._map_rsp_deadline:
            failed_addr = self._map_inflight_addr
            self._map_refresh_active = False
            self._map_summary_text = f"timeout waiting for 0x{failed_addr:05X}"
            self._map_inflight_addr = None
            self._refresh_map_view()
            self._set_status(self._map_summary_text)
            return
        if self._map_inflight_addr is not None or now < self._map_select_deadline or not self._map_pending_queue:
            return
        next_addr = self._map_pending_queue.pop(0)
        payload = make_read_packet(next_addr)
        if self._send_bytes(payload) != len(payload):
            self._map_refresh_active = False
            self._map_summary_text = f"short write for 0x{next_addr:05X}"
            self._refresh_map_view()
            self._set_status(self._map_summary_text)
            return
        self._map_inflight_addr = next_addr
        self._map_rsp_deadline = now + MAP_RESPONSE_TIMEOUT_S
        self._map_summary_text = f"reading 0x{next_addr:05X} ({len(self._map_received_words)+1}/{MAP_WORD_COUNT})"
        self._refresh_map_view()

    def _poll_status_refresh(self) -> None:
        if not self._status_refresh_active:
            return
        now = time.monotonic()
        if self._selected_src_idx != HOST_SRC_INDEX:
            if now >= self._status_select_deadline:
                if self._send_bytes(bytes([CMD_NEXT_SRC])) != 1:
                    self._finish_status_refresh("failed to select host source")
                    return
                self._status_summary_text = f"selecting host source (current={self._selected_src_idx})"
                self._status_select_deadline = now + 0.35
                self._refresh_status_view()
            return
        if self._status_inflight_addr is not None and now > self._status_rsp_deadline:
            self._finish_status_refresh(f"timeout waiting for 0x{self._status_inflight_addr:05X}")
            return
        if self._status_inflight_addr is not None or now < self._status_select_deadline or not self._status_pending_queue:
            return

        next_addr = self._status_pending_queue.pop(0)
        payload = make_status_read_packet(next_addr)
        if self._send_bytes(payload) != len(payload):
            self._finish_status_refresh(f"short write for 0x{next_addr:05X}")
            return
        self._status_inflight_addr = next_addr
        self._status_rsp_deadline = now + STATUS_RESPONSE_TIMEOUT_S
        completed = STATUS_WORD_COUNT - len(self._status_pending_queue)
        self._status_summary_text = f"reading 0x{next_addr:05X} ({completed}/{STATUS_WORD_COUNT})"
        self._refresh_status_view()

    def _poll_status_selftest(self) -> None:
        if not self._status_selftest_active:
            return
        now = time.monotonic()
        if self._selected_src_idx != HOST_SRC_INDEX:
            if now >= self._status_selftest_select_deadline:
                if self._send_bytes(bytes([CMD_NEXT_SRC])) != 1:
                    self._finish_status_selftest("failed to select host source")
                    return
                self._status_summary_text = f"selecting host source (current={self._selected_src_idx})"
                self._status_selftest_select_deadline = now + 0.35
                self._refresh_status_view()
            return
        if self._status_selftest_inflight and now > self._status_selftest_rsp_deadline:
            self._finish_status_selftest(
                f"timeout waiting for selftest ack at 0x{STATUS_SELFTEST_ADDR:05X}"
            )
            return
        if self._status_selftest_inflight or now < self._status_selftest_select_deadline:
            return

        payload = make_status_write_packet(STATUS_SELFTEST_ADDR, STATUS_SELFTEST_DATA)
        if self._send_bytes(payload) != len(payload):
            self._finish_status_selftest(
                f"short write for selftest trigger at 0x{STATUS_SELFTEST_ADDR:05X}"
            )
            return
        self._status_selftest_inflight = True
        self._status_selftest_rsp_deadline = now + STATUS_RESPONSE_TIMEOUT_S
        self._status_summary_text = (
            f"triggering selftest SW 0x{STATUS_SELFTEST_ADDR:05X} 0x{STATUS_SELFTEST_DATA:08X}"
        )
        self._refresh_status_view()

    def _poll_rw_task(self) -> None:
        if not self._rw_task_active:
            return
        now = time.monotonic()
        if self._selected_src_idx != HOST_SRC_INDEX:
            if now >= self._rw_task_select_deadline:
                if self._send_bytes(bytes([CMD_NEXT_SRC])) != 1:
                    self._finish_rw_task("failed to select host source")
                    return
                self._rw_summary_text = f"selecting host source (current={self._selected_src_idx})"
                self._rw_task_select_deadline = now + 0.35
                self._refresh_rw_view()
            return
        if self._rw_task_inflight is not None and now > self._rw_task_rsp_deadline:
            op_kind, inflight_addr, _ = self._rw_task_inflight
            if self._rw_task_kind == "single_read":
                self._rw_single_read_result = f"timeout at 0x{inflight_addr:05X}"
            elif self._rw_task_kind == "single_write":
                self._rw_single_write_result = f"timeout at 0x{inflight_addr:05X}"
            elif self._rw_task_kind == "file_write":
                self._rw_file_write_result = f"timeout at 0x{inflight_addr:05X}"
            elif self._rw_task_kind == "file_read_save":
                self._rw_file_read_result = f"timeout at 0x{inflight_addr:05X}"
            self._rw_task_inflight = None
            self._finish_rw_task(f"{op_kind} timeout at 0x{inflight_addr:05X}")
            return
        if self._rw_task_inflight is not None or now < self._rw_task_select_deadline:
            return
        if not self._rw_task_pending:
            if self._rw_task_kind == "file_write":
                self._rw_file_write_result = "file write complete"
            elif self._rw_task_kind == "file_read_save":
                self._complete_file_read_save()
            else:
                self._finish_rw_task(f"{self._rw_task_kind} complete")
            self._refresh_rw_view()
            return
        op_kind, addr, data = self._rw_task_pending.pop(0)
        payload = make_read_packet(addr) if op_kind == "read" else make_write_packet(addr, data)
        expected = len(payload)
        if self._send_bytes(payload) != expected:
            self._finish_rw_task(f"{op_kind} short write at 0x{addr:05X}")
            return
        self._rw_task_inflight = (op_kind, addr, data)
        self._rw_task_rsp_deadline = now + MAP_RESPONSE_TIMEOUT_S
        self._rw_summary_text = f"{op_kind} 0x{addr:05X}"
        self._refresh_rw_view()

    def _complete_file_read_save(self) -> None:
        if self._rw_task_output_path is None:
            self._finish_rw_task("file read complete")
            return
        ordered_addrs = sorted(self._rw_task_read_results.keys())
        blob = bytearray()
        for addr in ordered_addrs:
            blob.extend(self._rw_task_read_results[addr].to_bytes(4, "little"))
        try:
            self._rw_task_output_path.parent.mkdir(parents=True, exist_ok=True)
            self._rw_task_output_path.write_bytes(bytes(blob[: self._rw_task_output_len]))
            self._rw_file_read_result = f"saved {self._rw_task_output_len} bytes to {self._rw_task_output_path}"
            self._finish_rw_task("file read save complete")
        except Exception as exc:
            self._rw_file_read_result = f"save failed: {exc}"
            self._finish_rw_task("file read save failed")

    def _finish_map_refresh(self, detail: str) -> None:
        self._map_refresh_active = False
        self._map_summary_text = detail
        self._map_restore_src_idx = None
        self._refresh_map_view()
        self._set_status(detail)

    def _set_status(self, message: str) -> None:
        if self._status is None:
            return
        conn = "replay" if self._replay_file_path is not None else ("connected" if self._active_connected() else "disconnected")
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
            port = f"{self._tcp_host}:{self._tcp_port}" if self._transport == "tcp" else (self._selected_port() or "-")
            replay_state = "-"
        filtered_rows = sum(1 for stored in self._rows if self._row_matches_filter(self._build_row_from_stored(stored)))
        log_state = "ON" if self._log_enabled else "OFF"
        self._stats.update("\n".join(["[Stats]", f"transport  : {transport}", f"port       : {port}", f"connection : {conn}", f"screen     : {self._active_screen}", f"mode       : {self._mode}", f"filter     : {self._filter_text or '-'}", f"src_sel    : {self._selected_src_idx}", f"rows       : {filtered_rows}/{len(self._rows)}", f"rx_frames  : {self._rx_frames}", f"tcp_pkts   : {self._tcp_packets}", f"tcp_bytes  : {self._tcp_bytes}", f"seq_lost   : {self._lost_seen}", f"crc_errors : {self._crc_seen}", f"last_seq   : {self._tcp_last_frame}", f"replay     : {replay_state}", f"log_file   : {log_state}", f"decoder    : {self._decoder_path}"]))

    def _open_log_if_needed(self) -> None:
        if not self._log_enabled or self._log_fp is not None:
            return
        if self._log_file_path is None:
            logs_dir = Path("logs")
            logs_dir.mkdir(parents=True, exist_ok=True)
            self._log_file_path = logs_dir / f"uart_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
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
        self._log_fp.write(f"{ts} mode={self._mode.upper()} seq=0x{seq:02X} src=0x{event.src_id:02X} evt=0x{event.event_id:02X} ts={event.timestamp} arg0=0x{event.arg0:08X} arg1=0x{event.arg1:08X} arg2=0x{event.arg2:08X} crc=OK lost={lost_count} msg={text}\n")
        self._log_fp.flush()


def _build_parser() -> argparse.ArgumentParser:
    script_dir = Path(__file__).resolve().parent
    default_decoder = script_dir / "decode_rules.default.yaml"

    parser = argparse.ArgumentParser(description="UART log monitor for tangnano20k uart_log_cli")
    parser.add_argument("--transport", type=str, choices=["serial", "tcp"], default="tcp")
    parser.add_argument("--port", type=str, default=None)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--tcp-host", type=str, default="192.168.10.40")
    parser.add_argument("--tcp-port", type=int, default=2323)
    parser.add_argument("--mode", type=str, choices=["raw", "decode"], default="decode")
    parser.add_argument("--decoder", type=str, default=str(default_decoder))
    parser.add_argument("--log-file", type=str, default=None)
    parser.add_argument("--replay", type=str, default=None)
    parser.add_argument("--no-color", action="store_true")
    return parser


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()

    if args.no_color:
        os.environ["NO_COLOR"] = "1"
        os.environ["TEXTUAL_NO_COLOR"] = "1"

    app = UARTLogApp(
        transport=args.transport,
        initial_port=args.port,
        baud=args.baud,
        tcp_host=args.tcp_host,
        tcp_port=args.tcp_port,
        mode=args.mode,
        decoder_path=args.decoder,
        log_file=args.log_file,
        replay_file=args.replay,
    )
    app.run()


if __name__ == "__main__":
    main()
