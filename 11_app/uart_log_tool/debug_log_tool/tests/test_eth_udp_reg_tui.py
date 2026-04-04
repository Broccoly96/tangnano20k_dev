import sys
import unittest
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from eth_udp_reg_tui import EthUdpRegApp, LogRow


class TestableEthUdpRegApp(EthUdpRegApp):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._fake_values = {
            "PCIE_LOG_CONTROL": 0,
            "PCIE_LOG_TRIGGER": 0,
            "LOG_STREAM_PACKET_COUNT": 0,
        }
        self._writes: list[tuple[str, int]] = []
        self._trigger_write_error: Exception | None = None

    def _ensure_udp_listener(self, *, force: bool) -> None:
        self._udp_log_bound_port = self._udp_log_bind_port

    def _set_status(self, text: str) -> None:
        if hasattr(self, "_status"):
            super()._set_status(text)

    def _read_reg(self, reg):  # type: ignore[override]
        return self._fake_values.get(reg.name, 0)

    def _write_reg(self, reg, value):  # type: ignore[override]
        self._writes.append((reg.name, value))
        if reg.name == "PCIE_LOG_TRIGGER" and self._trigger_write_error is not None:
            self._fake_values["LOG_STREAM_PACKET_COUNT"] += 2
            raise self._trigger_write_error
        if reg.name == "PCIE_LOG_CONTROL":
            self._fake_values[reg.name] = value & 0xFFFF_FFFF


class EthUdpRegTuiTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.app = TestableEthUdpRegApp(
            target_ip="192.168.100.2",
            target_port=50000,
            bind_ip="127.0.0.1",
            bind_port=0,
            reg_map_path=str(TOOL_DIR / "eth_udp_reg_map.default.yaml"),
            log_file=None,
        )

    async def test_screen_switch_and_catalog_split(self) -> None:
        async with self.app.run_test():
            self.assertEqual(self.app._active_screen, "log")
            self.assertGreater(len(self.app._screen_regs["eth"]), 0)
            self.assertGreater(len(self.app._screen_regs["pcie"]), 0)
            self.assertGreater(len(self.app._screen_regs["fpga_direct"]), 0)
            self.assertGreater(len(self.app._screen_regs["fpga_conf"]), 0)
            self.assertTrue(all(reg.space == "direct" for reg in self.app._screen_regs["pcie"]))

            self.app.action_show_pcie()
            self.assertEqual(self.app._active_screen, "pcie")

            self.app.action_show_fpga()
            self.assertEqual(self.app._active_screen, "fpga")

    async def test_log_filtering(self) -> None:
        async with self.app.run_test():
            self.app._log_rows = [
                LogRow("12:00:00.000", "0x0001", "uart", "-", "12", "0x04", "0x61", "alpha event"),
                LogRow("12:00:01.000", "0x0002", "uart", "-", "12", "0x05", "0x62", "beta event"),
            ]
            self.app._log_src_input.value = "0x04"
            self.app._log_evt_input.value = "0x61"
            self.app._log_text_input.value = "alpha"

            rows = self.app._filtered_log_rows()

            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0].text, "alpha event")

    async def test_log_refresh_preserves_scroll_when_not_following_tail(self) -> None:
        async with self.app.run_test():
            self.app._log_rows = [
                LogRow("12:00:00.000", "0x0001", "uart", "-", "12", "0x04", "0x61", "row0"),
                LogRow("12:00:01.000", "0x0002", "uart", "-", "12", "0x04", "0x62", "row1"),
                LogRow("12:00:02.000", "0x0003", "uart", "-", "12", "0x04", "0x63", "row2"),
            ]
            self.app._refresh_log_table()
            self.assertEqual(self.app._log_table.cursor_type, "none")
            self.assertFalse(self.app._log_table.show_cursor)
            self.app._log_table.scroll_home(animate=False)
            previous_scroll_y = self.app._log_table.scroll_y

            self.app._log_rows.append(
                LogRow("12:00:03.000", "0x0004", "uart", "-", "12", "0x04", "0x64", "row3")
            )
            self.app._refresh_log_table()

            self.assertEqual(self.app._log_table.scroll_y, previous_scroll_y)

    async def test_pcie_quick_actions(self) -> None:
        async with self.app.run_test():
            self.app.action_toggle_pcie_activity_periodic()
            self.assertEqual(self.app._fake_values["PCIE_LOG_CONTROL"], 0x1)
            self.assertIn(("PCIE_LOG_CONTROL", 0x1), self.app._writes)

            self.app.action_toggle_pcie_status_periodic()
            self.assertEqual(self.app._fake_values["PCIE_LOG_CONTROL"], 0x3)
            self.assertIn(("PCIE_LOG_CONTROL", 0x3), self.app._writes)

            self.app.action_trigger_pcie_activity_snapshot()
            self.app.action_trigger_pcie_status_snapshot()
            self.assertIn(("PCIE_LOG_TRIGGER", 0x1), self.app._writes)
            self.assertIn(("PCIE_LOG_TRIGGER", 0x2), self.app._writes)

    async def test_pcie_snapshot_timeout_uses_packet_count_fallback(self) -> None:
        async with self.app.run_test():
            self.app._trigger_write_error = TimeoutError("timed out")
            self.app.action_trigger_pcie_status_snapshot()
            self.assertEqual(self.app._session.last_error, "-")
            self.assertEqual(self.app._fake_values["LOG_STREAM_PACKET_COUNT"], 2)


if __name__ == "__main__":
    unittest.main()
