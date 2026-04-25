import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from textual.containers import VerticalScroll  # noqa: E402
from textual.widgets import Button, Input, Static  # noqa: E402
from sdram_uart_protocol import BULK_ABORT, CMD_LITERAL_NEXT  # noqa: E402
from uart_log_protocol import Event  # noqa: E402

from uart_log_tui import (  # noqa: E402
    UARTLogApp,
    format_sdram_map_text,
    format_sdram_status_raw_text,
    format_sdram_status_text,
    next_src_steps,
)


class DummySock:
    def __init__(self) -> None:
        self.sent: list[bytes] = []

    def send(self, payload: bytes) -> int:
        self.sent.append(payload)
        return len(payload)

    def recv(self, max_bytes: int) -> bytes:
        raise BlockingIOError

    def close(self) -> None:
        pass


def _unstuff_cli_literal_bytes(data: bytes) -> bytes:
    unstuffed = bytearray()
    literal_pending = False
    for byte_value in data:
        if literal_pending:
            unstuffed.append(byte_value)
            literal_pending = False
        elif byte_value == CMD_LITERAL_NEXT:
            literal_pending = True
        else:
            unstuffed.append(byte_value)
    return bytes(unstuffed)


class UARTLogTuiTests(unittest.TestCase):
    def test_next_src_steps_wraps_forward(self) -> None:
        self.assertEqual(next_src_steps(0, 2), 2)
        self.assertEqual(next_src_steps(2, 0), 1)
        self.assertEqual(next_src_steps(1, 1), 0)

    def test_format_sdram_map_text_word_mode(self) -> None:
        blob = bytes(range(256))
        text = format_sdram_map_text(0x10000, blob)
        self.assertIn("Base: 0x10000  Mode: 4-byte little-endian words", text)
        self.assertIn("      00        01        02        03", text)
        self.assertIn(
            "00 | 03020100  07060504  0B0A0908  0F0E0D0C  "
            "13121110  17161514  1B1A1918  1F1E1D1C  "
            "23222120  27262524  2B2A2928  2F2E2D2C  "
            "33323130  37363534  3B3A3938  3F3E3D3C",
            text,
        )

    def test_format_sdram_status_text_decodes_pass_state(self) -> None:
        blob = bytearray(80)
        words = {
            0x00: 0x030D00A8,
            0x04: 0xB61A1A21,
            0x08: 0x001002BB,
            0x0C: 0x000000D0,
            0x10: 0x000000CF,
            0x24: 0x03000000,
            0x30: 0xD2401A1A,
            0x38: 0x47950038,
        }
        for offset, value in words.items():
            blob[offset : offset + 4] = value.to_bytes(4, "little")

        text = format_sdram_status_text(bytes(blob))
        self.assertIn("map_version       : 0x03", text)
        self.assertIn("memtest_state     : PASS (0x0D)", text)
        self.assertIn("fail_reason       : NONE (0x00)", text)
        self.assertIn("retry_limit       : 3", text)
        self.assertIn("sampled_addr      : 0x0038", text)

    def test_format_sdram_status_text_decodes_hs_v05_fields(self) -> None:
        blob = bytearray(80)
        words = {
            0x00: 0x051600A8,
            0x14: 0x0035FD12,
            0x30: 0xB4FE0304,
            0x38: 0x48BF4123,
            0x48: 0x5204004D,
        }
        for offset, value in words.items():
            blob[offset : offset + 4] = value.to_bytes(4, "little")

        text = format_sdram_status_text(bytes(blob))
        self.assertIn("map_version       : 0x05", text)
        self.assertIn("memtest_state     : PASS (0x16)", text)
        self.assertIn("cmd               : READ (0b101)", text)
        self.assertIn("ack_count         : 18", text)
        self.assertIn("cmd               : AUTO_REFRESH", text)
        self.assertIn("pair_active       : 1", text)
        self.assertIn("0x38 HS_HANDSHAKE  = 0x48BF4123", text)
        self.assertIn("cmd               : ACTIVE (0b011)", text)
        self.assertIn("0x48 HS_REFRESH     = 0x5204004D", text)
        self.assertIn("interval_count_lsb: 77", text)

    def test_format_sdram_status_raw_text_formats_words(self) -> None:
        blob = bytearray(64)
        blob[0x00:0x04] = (0x030D00A8).to_bytes(4, "little")
        blob[0x04:0x08] = (0xB61A1A21).to_bytes(4, "little")
        text = format_sdram_status_raw_text(bytes(blob))
        self.assertIn("Base: 0x00000  Size: 80 bytes  Mode: raw 32-bit words", text)
        self.assertIn("00 | 030D00A8  B61A1A21  00000000  00000000", text)


class UARTLogTuiLayoutTests(unittest.IsolatedAsyncioTestCase):
    async def test_layout_contains_requested_sdram_widgets(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            self.assertEqual(app.query_one("#btn_map_refresh", Button).label.plain, "Refresh")
            self.assertEqual(app.query_one("#btn_status_refresh", Button).label.plain, "Refresh Status")
            self.assertEqual(app.query_one("#btn_status_mode", Button).label.plain, "Mode: Decode")
            self.assertEqual(app.query_one("#btn_status_selftest", Button).label.plain, "Selftest")
            self.assertEqual(app.query_one("#nav_rw", Button).label.plain, "3 SDRAM RW")
            self.assertEqual(app.query_one("#nav_status", Button).label.plain, "4 SDRAM STS")
            self.assertEqual(app.query_one("#nav_burst", Button).label.plain, "5 SDRAM Bulk")
            self.assertIsNotNone(app.query_one("#status_scroll", VerticalScroll))
            self.assertEqual(app.query_one("#btn_file_read_save", Button).label.plain, "Read To File")
            self.assertEqual(app.query_one("#btn_file_write", Button).label.plain, "Write File")
            self.assertEqual(app.query_one("#file_write_addr_input", Input).value, "0x00000")

    async def test_map_refresh_queues_bulk_read_when_connected(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app._tcp._sock = DummySock()
            app._start_map_refresh()
            self.assertEqual(app._map_summary_text, "queued bulk read 256 SDRAM words")
            self.assertTrue(app._map_refresh_active)
            self.assertFalse(app._map_command_sent)

    async def test_map_refresh_sends_bulk_read_packet(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            sock = DummySock()
            app._tcp._sock = sock
            app._selected_src_idx = 2
            app._start_map_refresh()
            app._poll_map_refresh()
            self.assertEqual(sock.sent[-1], b"BR 00000 00100\n")
            self.assertTrue(app._map_command_sent)

    async def test_map_refresh_retries_timed_out_bulk_read(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            sock = DummySock()
            app._tcp._sock = sock
            app._selected_src_idx = 2
            app._start_map_refresh()
            app._poll_map_refresh()

            app._map_rsp_deadline = 0.0
            app._poll_map_refresh()
            app._poll_map_refresh()

            self.assertEqual(sock.sent[-2:], [b"BR 00000 00100\n", b"BR 00000 00100\n"])
            self.assertTrue(app._map_refresh_active)
            self.assertTrue(app._map_command_sent)
            self.assertEqual(app._map_inflight_retries, 1)
            self.assertEqual(app._map_retry_count, 1)
            self.assertIn("sent BR 0x00000 words=256", app._map_summary_text)

    async def test_map_refresh_fails_after_retry_limit(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app._tcp._sock = DummySock()
            app._selected_src_idx = 2
            app._start_map_refresh()
            app._poll_map_refresh()

            app._map_inflight_retries = 3
            app._map_rsp_deadline = 0.0
            app._poll_map_refresh()

            self.assertFalse(app._map_refresh_active)
            self.assertIsNone(app._map_inflight_addr)
            self.assertEqual(app._map_inflight_retries, 0)
            self.assertIn("timeout waiting for BR 0x00000", app._map_summary_text)

    async def test_map_refresh_updates_from_bulk_progress_and_done(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app._tcp._sock = DummySock()
            app._selected_src_idx = 2
            app._start_map_refresh()
            app._poll_map_refresh()

            app._handle_special_event(Event(0x03, 0x32, 0, 0x00000000, 0x00000100, 0))
            self.assertIn("bulk read accepted", app._map_summary_text)

            for word_index in range(256):
                arg0 = (1 << 21) | word_index
                app._handle_special_event(
                    Event(0x03, 0x34, 0, arg0, 0xA5000000 | word_index, 0)
                )

            app._handle_special_event(Event(0x03, 0x35, 0, 0x00000000, 0x00000100, 0))

            self.assertFalse(app._map_refresh_active)
            self.assertEqual(app._map_summary_text, "refresh complete")
            self.assertEqual(
                app._map_bytes[0:4],
                (0xA5000000).to_bytes(4, "little"),
            )
            self.assertEqual(
                app._map_bytes[-4:],
                (0xA50000FF).to_bytes(4, "little"),
            )

    async def test_map_refresh_rejects_range_past_sdram_limit(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app._tcp._sock = DummySock()
            app.query_one("#map_base_input", Input).value = "0x1FFFFF"
            app._start_map_refresh()
            self.assertFalse(app._map_refresh_active)
            self.assertIn("map range exceeds SDRAM limit", app._map_summary_text)

    async def test_single_rw_accepts_unaligned_addresses(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app._tcp._sock = DummySock()
            app._selected_src_idx = 2

            app.query_one("#single_read_addr_input", Input).value = "0x00003"
            app._start_single_read()
            self.assertTrue(app._rw_task_active)
            self.assertEqual(app._rw_task_pending, [("read", 0x00003, 0)])
            app._finish_rw_task("test cleanup")

            app.query_one("#single_write_addr_input", Input).value = "0x00005"
            app.query_one("#single_write_data_input", Input).value = "0x12345678"
            app._start_single_write()
            self.assertTrue(app._rw_task_active)
            self.assertEqual(app._rw_task_pending, [("write", 0x00005, 0x12345678)])

    async def test_burst_write_test_sends_bwt_command(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            sock = DummySock()
            app._tcp._sock = sock
            app._selected_src_idx = 2
            app.query_one("#burst_base_input", Input).value = "0x00100"
            app.query_one("#burst_words_input", Input).value = "0x00040"
            app._start_burst_test(is_read=False)
            app._poll_burst_task()

            self.assertEqual(sock.sent[-1], b"BWT 00100 00040\n")
            self.assertTrue(app._burst_task_active)
            self.assertEqual(app._burst_task_kind, "burst_write_test")

    async def test_burst_read_test_collects_packets_and_passes(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app._tcp._sock = DummySock()
            app._selected_src_idx = 2
            app.query_one("#burst_base_input", Input).value = "0x00020"
            app.query_one("#burst_words_input", Input).value = "0x00003"
            app._start_burst_test(is_read=True)
            app._poll_burst_task()

            app._handle_special_event(Event(0x03, 0x34, 0, 0x00020002, 0, 1))
            app._handle_special_event(Event(0x03, 0x34, 0, 0x01020201, 2, 0))
            app._handle_special_event(Event(0x03, 0x35, 0, 0x00000020, 3, 0x80000002))

            self.assertFalse(app._burst_task_active)
            self.assertIn("PASS read words=3", app._burst_result_text)

    async def test_burst_read_reports_mismatch(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app._tcp._sock = DummySock()
            app._selected_src_idx = 2
            app.query_one("#burst_base_input", Input).value = "0x00020"
            app.query_one("#burst_words_input", Input).value = "0x00002"
            app._start_burst_test(is_read=True)
            app._poll_burst_task()

            app._handle_special_event(Event(0x03, 0x34, 0, 0x00010002, 0, 0x12345678))
            app._handle_special_event(Event(0x03, 0x35, 0, 0x00000020, 2, 0x80000001))

            self.assertFalse(app._burst_task_active)
            self.assertIn("FAIL mismatches=1", app._burst_result_text)

    async def test_single_read_timeout_retries_three_times(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            sock = DummySock()
            app._tcp._sock = sock
            app._selected_src_idx = 2
            app.query_one("#single_read_addr_input", Input).value = "0x00003"
            app._start_single_read()
            app._poll_rw_task()

            self.assertTrue(app._rw_task_active)
            self.assertEqual(len(sock.sent), 1)

            for expected_retry in range(1, 4):
                app._rw_task_rsp_deadline = -1.0
                app._poll_rw_task()
                self.assertTrue(app._rw_task_active)
                self.assertEqual(app._rw_task_inflight_retries, expected_retry)
                self.assertEqual(len(sock.sent), expected_retry + 1)

            app._rw_task_rsp_deadline = -1.0
            app._poll_rw_task()

            self.assertFalse(app._rw_task_active)
            self.assertIn("timeout at 0x00003", app._rw_single_read_result)
            self.assertEqual(len(sock.sent), 4)

    async def test_bulk_range_timeout_retries_three_times(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            sock = DummySock()
            app._tcp._sock = sock
            app._selected_src_idx = 2
            with mock.patch("uart_log_tui.select_source_index", return_value=2):
                started = app._start_bulk_task(
                    kind="bulk_range_read",
                    base_addr=0x00020,
                    words=2,
                    result_text="waiting for bulk read data...",
                )

            self.assertTrue(started)
            app._poll_burst_task()
            self.assertEqual(sock.sent[-1], b"BR 00020 00002\n")

            for expected_retry in range(1, 4):
                app._burst_rsp_deadline = -1.0
                with mock.patch("uart_log_tui.select_source_index", return_value=2):
                    app._poll_burst_task()
                self.assertTrue(app._burst_task_active)
                self.assertEqual(app._burst_retry_count, expected_retry)
                self.assertFalse(app._burst_command_sent)
                app._poll_burst_task()
                self.assertTrue(app._burst_command_sent)

            app._burst_rsp_deadline = -1.0
            with mock.patch("uart_log_tui.select_source_index", return_value=2):
                app._poll_burst_task()

            self.assertFalse(app._burst_task_active)
            self.assertEqual(app._burst_result_text, "timeout")

    async def test_bulk_file_write_timeout_sends_abort_before_retry(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            sock = DummySock()
            app._tcp._sock = sock
            app._selected_src_idx = 2
            with mock.patch("uart_log_tui.select_source_index", return_value=2):
                started = app._start_bulk_task(
                    kind="bulk_file_write",
                    base_addr=0x01000,
                    words=2,
                    result_text="waiting for bulk write ack...",
                    write_blob=b"\x01\x02\x03\x04\x05\x06\x07\x08",
                    output_len=8,
                )

            self.assertTrue(started)
            app._poll_burst_task()
            self.assertEqual(sock.sent[-1], b"BW 01000 00002\n")

            app._handle_special_event(Event(0x03, 0x32, 0, 0x00001000, 0x00000002, 0))
            app._poll_burst_task()
            self.assertEqual(app._burst_phase, "wait_write_progress")

            app._burst_rsp_deadline = -1.0
            app._poll_burst_task()

            abort_block = _unstuff_cli_literal_bytes(sock.sent[-1])
            self.assertEqual(abort_block[2], BULK_ABORT)
            self.assertEqual(app._burst_phase, "abort_wait")
            self.assertIn("abort recovery", app._burst_summary_text)

            app._handle_special_event(Event(0x03, 0x36, 0, 0x0000000C, 0x00001000, 0))

            self.assertTrue(app._burst_task_active)
            self.assertFalse(app._burst_command_sent)
            self.assertEqual(app._burst_retry_count, 1)
            self.assertEqual(app._burst_next_block_index, 0)

    async def test_burst_rejects_page_crossing_input(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app._tcp._sock = DummySock()
            app.query_one("#burst_base_input", Input).value = "0x000F8"
            app.query_one("#burst_words_input", Input).value = "0x00010"
            app._start_burst_test(is_read=True)

            self.assertFalse(app._burst_task_active)
            self.assertIn("burst crosses 8-bit column page", app._burst_result_text)

    async def test_status_refresh_requires_connection(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app._start_status_refresh()
            self.assertEqual(app._status_summary_text, "not connected")
            self.assertFalse(app._status_refresh_active)

    async def test_status_selftest_requires_connection(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app._start_status_selftest()
            self.assertEqual(app._status_summary_text, "not connected")
            self.assertFalse(app._status_selftest_active)

    async def test_status_mode_toggle_switches_raw_and_back(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            self.assertEqual(app._status_mode, "decode")
            app.action_toggle_status_mode()
            self.assertEqual(app._status_mode, "raw")
            self.assertEqual(app.query_one("#btn_status_mode", Button).label.plain, "Mode: Raw")
            app.action_toggle_status_mode()
            self.assertEqual(app._status_mode, "decode")

    async def test_status_screen_renders_decode_and_raw_views(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app._status_bytes[0x00:0x04] = (0x030D00A8).to_bytes(4, "little")
            app._status_bytes[0x04:0x08] = (0xB61A1A21).to_bytes(4, "little")
            app._status_bytes[0x38:0x3C] = (0x47950038).to_bytes(4, "little")
            app.action_show_status()
            app._refresh_status_view()

            status_view = app.query_one("#status_view", Static)
            self.assertIn("memtest_state     : PASS (0x0D)", str(status_view.visual))
            self.assertIn("sampled_addr      : 0x0038", str(status_view.visual))

            app.action_toggle_status_mode()
            self.assertIn("Mode: raw 32-bit words", str(status_view.visual))
            self.assertIn("00 | 030D00A8  B61A1A21", str(status_view.visual))

    async def test_file_buttons_use_enabled_bulk_path(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            with tempfile.TemporaryDirectory() as temp_dir:
                input_path = Path(temp_dir) / "input.bin"
                output_path = Path(temp_dir) / "output.bin"
                input_path.write_bytes(b"\x78\x56\x34\x12")

                app.query_one("#file_write_addr_input", Input).value = "0x00040"
                app.query_one("#file_write_path_input", Input).value = str(input_path)
                app.query_one("#file_read_addr_input", Input).value = "0x00040"
                app.query_one("#file_read_words_input", Input).value = "0x00001"
                app.query_one("#file_read_path_input", Input).value = str(output_path)

                app._start_file_write()
                self.assertEqual(app._rw_file_write_result, "-")
                self.assertEqual(
                    str(app.query_one("#status_line", Static).visual),
                    "disconnected | not connected",
                )

                app._start_file_read_save()
                self.assertEqual(app._rw_file_read_result, "-")
                self.assertEqual(
                    str(app.query_one("#status_line", Static).visual),
                    "disconnected | not connected",
                )

    async def test_file_read_accepts_byte_length_spec(self) -> None:
        app = UARTLogApp(
            transport="tcp",
            initial_port=None,
            baud=115200,
            tcp_host="127.0.0.1",
            tcp_port=2323,
            mode="decode",
            decoder_path=str(TOOL_DIR / "decode_rules.default.yaml"),
            log_file=None,
            replay_file=None,
        )

        async with app.run_test():
            app.query_one("#file_read_addr_input", Input).value = "0x00040"
            app.query_one("#file_read_words_input", Input).value = "5b"
            app.query_one("#file_read_path_input", Input).value = "capture.bin"

            with mock.patch.object(app, "_start_bulk_task", return_value=True) as start_bulk:
                app._start_file_read_save()

            start_bulk.assert_called_once()
            self.assertEqual(start_bulk.call_args.kwargs["base_addr"], 0x00040)
            self.assertEqual(start_bulk.call_args.kwargs["words"], 2)
            self.assertEqual(start_bulk.call_args.kwargs["output_len"], 5)
            self.assertIn("bytes=5 words=2", app._rw_file_read_result)


if __name__ == "__main__":
    unittest.main()
