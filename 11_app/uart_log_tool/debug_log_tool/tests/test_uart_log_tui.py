import sys
import unittest
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from textual.containers import VerticalScroll  # noqa: E402
from textual.widgets import Button, Input, Static  # noqa: E402

from uart_log_tui import (  # noqa: E402
    UARTLogApp,
    format_sdram_map_text,
    format_sdram_status_raw_text,
    format_sdram_status_text,
    next_src_steps,
)


class UARTLogTuiTests(unittest.TestCase):
    def test_next_src_steps_wraps_forward(self) -> None:
        self.assertEqual(next_src_steps(0, 2), 2)
        self.assertEqual(next_src_steps(2, 0), 1)
        self.assertEqual(next_src_steps(1, 1), 0)

    def test_format_sdram_map_text_word_mode(self) -> None:
        blob = bytes(range(256))
        text = format_sdram_map_text(0x10000, blob)
        self.assertIn("Base: 0x10000  Mode: 4-byte little-endian words", text)
        self.assertIn("00 | 03020100  07060504  0B0A0908  0F0E0D0C", text)

    def test_format_sdram_status_text_decodes_pass_state(self) -> None:
        blob = bytearray(64)
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

    def test_format_sdram_status_raw_text_formats_words(self) -> None:
        blob = bytearray(64)
        blob[0x00:0x04] = (0x030D00A8).to_bytes(4, "little")
        blob[0x04:0x08] = (0xB61A1A21).to_bytes(4, "little")
        text = format_sdram_status_raw_text(bytes(blob))
        self.assertIn("Base: 0x00000  Size: 64 bytes  Mode: raw 32-bit words", text)
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
            self.assertEqual(app.query_one("#nav_status", Button).label.plain, "3 SDRAM Status")
            self.assertEqual(app.query_one("#nav_rw", Button).label.plain, "4 SDRAM RW")
            self.assertIsNotNone(app.query_one("#status_scroll", VerticalScroll))
            self.assertEqual(app.query_one("#btn_file_read_save", Button).label.plain, "Read")
            self.assertEqual(app.query_one("#btn_file_write", Button).label.plain, "Write")
            self.assertEqual(app.query_one("#file_write_addr_input", Input).value, "0x00000")

    async def test_map_refresh_reports_inop(self) -> None:
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
            app._start_map_refresh()
            self.assertEqual(app._map_summary_text, "INOP: bulk path disabled")
            self.assertFalse(app._map_refresh_active)

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

    async def test_file_buttons_report_inop(self) -> None:
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
            app._start_file_write()
            app._start_file_read_save()
            self.assertEqual(app._rw_file_write_result, "INOP: bulk path disabled")
            self.assertEqual(app._rw_file_read_result, "INOP: bulk path disabled")


if __name__ == "__main__":
    unittest.main()
