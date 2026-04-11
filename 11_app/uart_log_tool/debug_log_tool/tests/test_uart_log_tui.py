import sys
import unittest
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from textual.widgets import Button, Input  # noqa: E402

from uart_log_tui import UARTLogApp, format_sdram_map_text, next_src_steps  # noqa: E402


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
            self.assertEqual(app.query_one("#nav_rw", Button).label.plain, "3 SDRAM RW")
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
