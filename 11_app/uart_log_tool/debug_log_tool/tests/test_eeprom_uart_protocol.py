import sys
import unittest
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from eeprom_uart_protocol import (  # noqa: E402
    HOST_SRC_ID,
    build_bulk_read_command,
    build_bulk_write_command,
    build_read_command,
    build_write_command,
    decode_bulk_read_progress,
    parse_addr,
    parse_data_byte,
    validate_bulk_range,
)


class EEPROMUARTProtocolTests(unittest.TestCase):
    def test_ascii_commands_are_line_oriented(self) -> None:
        self.assertEqual(HOST_SRC_ID, 0x01)
        self.assertEqual(build_read_command(0x00123), b"R 00123\n")
        self.assertEqual(build_write_command(0x00123, 0xAB), b"W 00123 AB\n")
        self.assertEqual(build_bulk_read_command(0x10000, 0x00100), b"BR 10000 00100\n")
        self.assertEqual(build_bulk_write_command(0x10000, 0x00080), b"BW 10000 00080\n")

    def test_parse_helpers_enforce_byte_ranges(self) -> None:
        self.assertEqual(parse_addr("0x1FFFF"), 0x1FFFF)
        self.assertEqual(parse_data_byte("0xFF"), 0xFF)
        with self.assertRaises(ValueError):
            parse_addr("0x20000")
        with self.assertRaises(ValueError):
            parse_data_byte("0x100")
        with self.assertRaises(ValueError):
            validate_bulk_range(0x1FFF0, 0x20)

    def test_bulk_progress_decode_returns_byte_payload(self) -> None:
        progress = decode_bulk_read_progress(
            (6 << 17) | 0x01234,
            0x44332211,
            0x88776655,
        )
        self.assertEqual(progress.base_addr, 0x01234)
        self.assertEqual(progress.valid_byte_count, 6)
        self.assertEqual(progress.data, bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))


if __name__ == "__main__":
    unittest.main()