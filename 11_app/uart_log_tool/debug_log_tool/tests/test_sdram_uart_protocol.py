import sys
import unittest
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from sdram_uart_protocol import (  # noqa: E402
    BULK_RD_DATA,
    BULK_RD_END,
    BULK_ABORT,
    BULK_WR_DATA,
    BULK_WR_END,
    CMD_LITERAL_NEXT,
    HOST_EVT_BURST_DATA,
    MAX_BULK_WRITE_CHUNK_BYTES,
    build_bulk_block,
    build_bulk_abort_block,
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


def _unstuff_cli_literal_bytes(data: bytes) -> bytes:
    unstuffed = bytearray()
    literal_pending = False
    for byte_value in data:
        if literal_pending:
            unstuffed.append(byte_value)
            literal_pending = False
            continue
        if byte_value == CMD_LITERAL_NEXT:
            literal_pending = True
            continue
        unstuffed.append(byte_value)
    return bytes(unstuffed)


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

    def test_bulk_abort_block_is_stuffed_and_crc_valid(self) -> None:
        block = build_bulk_abort_block(0x10)
        raw_block = _unstuff_cli_literal_bytes(block)

        self.assertEqual(raw_block[2], BULK_ABORT)
        self.assertEqual(raw_block[3], 0x10)
        self.assertEqual(raw_block[4] | (raw_block[5] << 8), 0)
        self.assertEqual(
            crc16_ccitt_false(raw_block[2:-2]),
            raw_block[-2] | (raw_block[-1] << 8),
        )

    def test_bulk_write_blocks_split_and_terminate(self) -> None:
        blob = bytes(range(108))
        blocks = iter_bulk_write_blocks(blob)
        self.assertEqual(len(blocks), 3)
        self.assertEqual(blocks[0][2], BULK_WR_DATA)
        self.assertEqual(blocks[1][2], BULK_WR_DATA)
        self.assertEqual(blocks[2][2], 0x02)

    def test_bulk_write_blocks_escape_legacy_cli_control_bytes(self) -> None:
        blob = bytes([0x04, 0x06, 0x10, 0x12, 0x14, 0x3F, 0x55, 0xAA])
        blocks = iter_bulk_write_blocks(blob)
        self.assertEqual(len(blocks), 2)

        raw_data_block = build_bulk_block(BULK_WR_DATA, 0, blob)
        raw_end_block = build_bulk_block(BULK_WR_END, 1, b"")

        self.assertGreater(len(blocks[0]), len(raw_data_block))
        self.assertEqual(_unstuff_cli_literal_bytes(blocks[0]), raw_data_block)
        self.assertEqual(_unstuff_cli_literal_bytes(blocks[1]), raw_end_block)

    def test_bulk_write_blocks_limit_raw_chunk_size_for_transport(self) -> None:
        blob = b"".join(
            value.to_bytes(4, "little")
            for value in range(0x2500_0000, 0x2500_0040)
        )
        blocks = iter_bulk_write_blocks(blob)

        self.assertEqual(len(blocks), 5)
        for seq, block in enumerate(blocks[:-1]):
            raw_block = _unstuff_cli_literal_bytes(block)
            self.assertEqual(raw_block[2], BULK_WR_DATA)
            self.assertEqual(raw_block[3], seq)
            payload_len = raw_block[4] | (raw_block[5] << 8)
            self.assertLessEqual(payload_len, MAX_BULK_WRITE_CHUNK_BYTES)

        raw_end_block = _unstuff_cli_literal_bytes(blocks[-1])
        self.assertEqual(raw_end_block[2], BULK_WR_END)
        self.assertEqual(raw_end_block[4] | (raw_end_block[5] << 8), 0)

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
