import sys
import unittest
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from sdram_uart_protocol import (  # noqa: E402
    BULK_RD_DATA,
    BULK_RD_END,
    BULK_WR_DATA,
    HOST_EVT_BURST_DATA,
    build_bulk_block,
    build_bulk_read_command,
    build_bulk_write_command,
    build_burst_test_read_command,
    build_burst_test_write_command,
    build_read_command,
    build_status_read_command,
    build_status_write_command,
    build_write_command,
    crc16_ccitt_false,
    decode_burst_data_packet,
    iter_bulk_write_blocks,
    RawBulkParser,
)


class SDRAMUARTProtocolTests(unittest.TestCase):
    def test_ascii_commands_are_line_oriented(self) -> None:
        self.assertEqual(build_read_command(0x40), b"R 00040\n")
        self.assertEqual(build_write_command(0x40, 0x12345678), b"W 00040 12345678\n")
        self.assertEqual(build_status_read_command(0x3C), b"SR 0003C\n")
        self.assertEqual(build_status_write_command(0x3C, 0x1), b"SW 0003C 00000001\n")
        self.assertEqual(build_bulk_read_command(0x100, 0x40), b"BR 00100 00040\n")
        self.assertEqual(build_bulk_write_command(0x100, 0x40), b"BW 00100 00040\n")
        self.assertEqual(build_burst_test_read_command(0x100, 0x40), b"BRT 00100 00040\n")
        self.assertEqual(build_burst_test_write_command(0x100, 0x40), b"BWT 00100 00040\n")

    def test_burst_data_packet_decode(self) -> None:
        self.assertEqual(HOST_EVT_BURST_DATA, 0x34)
        packet = decode_burst_data_packet(0x03100402, 0x11111111, 0x22222222)
        self.assertEqual(packet.packet_id, 3)
        self.assertEqual(packet.packet_count, 16)
        self.assertEqual(packet.first_word_index, 4)
        self.assertEqual(packet.valid_word_count, 2)
        self.assertEqual(packet.words, (0x11111111, 0x22222222))

        packet = decode_burst_data_packet(0x04100601, 0x33333333, 0x44444444)
        self.assertEqual(packet.valid_word_count, 1)
        self.assertEqual(packet.words, (0x33333333,))

    def test_bulk_block_crc_round_trip(self) -> None:
        payload = bytes(range(16))
        block = build_bulk_block(BULK_WR_DATA, 3, payload)
        self.assertEqual(
            crc16_ccitt_false(block[2:-2]),
            block[-2] | (block[-1] << 8),
        )

    def test_bulk_write_blocks_split_and_terminate(self) -> None:
        blob = bytes(range(108))
        blocks = iter_bulk_write_blocks(blob)
        self.assertEqual(len(blocks), 3)
        self.assertEqual(blocks[0][2], BULK_WR_DATA)
        self.assertEqual(blocks[1][2], BULK_WR_DATA)
        self.assertEqual(blocks[2][2], 0x02)

    def test_raw_bulk_parser_decodes_multiple_blocks(self) -> None:
        parser = RawBulkParser()
        stream = (
            build_bulk_block(BULK_RD_DATA, 0, b"\x01\x02\x03\x04")
            + build_bulk_block(BULK_RD_END, 1, b"")
        )
        blocks = parser.feed(stream)
        self.assertEqual([block.block_type for block in blocks], [BULK_RD_DATA, BULK_RD_END])
        self.assertTrue(all(block.crc_ok for block in blocks))
        self.assertEqual(blocks[0].payload, b"\x01\x02\x03\x04")


if __name__ == "__main__":
    unittest.main()
