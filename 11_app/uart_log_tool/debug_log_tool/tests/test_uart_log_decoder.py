import sys
import unittest
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from uart_log_decoder import UARTLogDecoder  # noqa: E402
from uart_log_protocol import Event  # noqa: E402


class UARTLogDecoderTests(unittest.TestCase):
    def test_safe_format_supports_format_spec_and_byte_bit_lookup(self) -> None:
        decoder = UARTLogDecoder.from_mapping(
            {
                "default": {
                    "title": "FMT",
                    "message": (
                        "a0=0x{arg0:08X} b1=0x{arg0_b1:02X} "
                        "b1bit0={arg0_b1_bit0} arg1bit12={arg1_bit12}"
                    ),
                }
            }
        )

        event = Event(
            src_id=0x03,
            event_id=0x02,
            timestamp=0x1234,
            arg0=0xA1B2_C3D4,
            arg1=0x0000_1000,
            arg2=0x0000_0000,
        )
        decoded = decoder.decode(event)

        self.assertEqual(decoded.title, "FMT")
        self.assertIn("a0=0xA1B2C3D4", decoded.message)
        self.assertIn("b1=0xC3", decoded.message)
        self.assertIn("b1bit0=1", decoded.message)
        self.assertIn("arg1bit12=1", decoded.message)


if __name__ == "__main__":
    unittest.main()
