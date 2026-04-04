import sys
import unittest
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from eth_udp_reg_tool import (
    CMD_READ,
    CMD_READ_RESP,
    REGISTERS,
    UdpRegResponse,
    decode_register_value,
    load_register_map,
    log_stream_write_verified,
    pcie_trigger_verified,
    response_matches_request,
)


class EthUdpRegToolTests(unittest.TestCase):
    def test_response_matching_requires_cmd_addr_and_seq(self) -> None:
        resp = UdpRegResponse(
            magic=0x55AA,
            cmd=CMD_READ_RESP,
            status=0,
            addr=REGISTERS["DEVICE_ID"],
            data=0,
            seq=0x1234,
            reserved=0,
        )

        self.assertTrue(
            response_matches_request(
                resp,
                cmd=CMD_READ,
                addr=REGISTERS["DEVICE_ID"],
                seq=0x1234,
            )
        )
        self.assertFalse(
            response_matches_request(
                resp,
                cmd=CMD_READ,
                addr=REGISTERS["VERSION"],
                seq=0x1234,
            )
        )
        self.assertFalse(
            response_matches_request(
                resp,
                cmd=CMD_READ,
                addr=REGISTERS["DEVICE_ID"],
                seq=0x1235,
            )
        )

    def test_write_fallback_helpers(self) -> None:
        self.assertTrue(log_stream_write_verified(0x1, 0x1, 0x1))
        self.assertTrue(log_stream_write_verified(0x0, 0x0, 0x0))
        self.assertFalse(log_stream_write_verified(0x1, 0x1, 0x0))

        self.assertTrue(pcie_trigger_verified(0x2, 10, 12))
        self.assertFalse(pcie_trigger_verified(0x2, 10, 10))
        self.assertTrue(pcie_trigger_verified(0x0, None, 10))

    def test_load_register_map_v3_groups_direct_and_conf(self) -> None:
        regs_by_name, regs_by_addr = load_register_map(TOOL_DIR / "eth_udp_reg_map.default.yaml")

        self.assertIn("NET_STATUS", regs_by_name)
        self.assertIn("PCIE_STATUS", regs_by_name)
        self.assertIn("PCIE_LINKUP_STATUS", regs_by_name)
        self.assertIn("PCIE_LTSSM", regs_by_name)
        self.assertIn("PCIE_LAST_RX_ERROR", regs_by_name)
        self.assertIn("PCIE_LOG_CONTROL", regs_by_name)
        self.assertIn("PCIE_LOG_TRIGGER", regs_by_name)
        self.assertIn("TOP_STATUS", regs_by_name)
        self.assertNotIn("PCIE_SIGNATURE", regs_by_name)

        self.assertEqual(regs_by_name["NET_STATUS"].space, "direct")
        self.assertEqual(regs_by_name["PCIE_STATUS"].space, "direct")
        self.assertEqual(regs_by_name["PCIE_LTSSM"].space, "direct")
        self.assertEqual(regs_by_name["PCIE_LOG_CONTROL"].access, "RW")
        self.assertEqual(regs_by_name["PCIE_LOG_TRIGGER"].screen, "pcie")
        self.assertEqual(regs_by_name["PCIE_LTSSM"].decoder["kind"], "enum")
        self.assertEqual(regs_by_name["PCIE_LAST_RX_ERROR"].decoder["kind"], "bitset")
        self.assertEqual(regs_by_name["TOP_STATUS"].block, 0x00)
        self.assertEqual(regs_by_name["TOP_STATUS"].space, "conf")
        self.assertEqual(regs_by_name["PCIE_STATUS"].screen, "pcie")
        self.assertEqual(regs_by_addr[REGISTERS["PCIE_STATUS"]].name, "PCIE_STATUS")

    def test_decode_register_value_for_fpga_and_pcie(self) -> None:
        fpga_bits = decode_register_value(REGISTERS["FPGA_STATUS"], 0b1_1111)
        pcie_bits = decode_register_value(REGISTERS["PCIE_STATUS"], (1 << 0) | (1 << 2) | (0x12 << 18))
        pcie_link_bits = decode_register_value(REGISTERS["PCIE_LINKUP_STATUS"], 0x1)
        pcie_ltssm_bits = decode_register_value(REGISTERS["PCIE_LTSSM"], 0x10)
        pcie_last_rx_error_bits = decode_register_value(REGISTERS["PCIE_LAST_RX_ERROR"], 0x12)
        pcie_ctrl_bits = decode_register_value(REGISTERS["PCIE_LOG_CONTROL"], 0b11)

        self.assertIn("pll_locked=1", fpga_bits)
        self.assertIn("snapshot_seen=1", fpga_bits)
        self.assertIn("present=1", pcie_bits)
        self.assertIn("bridge_enable=1", pcie_bits)
        self.assertIn("intr_mask=0x12", pcie_bits)
        self.assertNotIn("link_up=1", pcie_bits)
        self.assertIn("link_up=1", pcie_link_bits)
        self.assertIn("ltssm=0x10", pcie_ltssm_bits)
        self.assertIn("name=L0", pcie_ltssm_bits)
        self.assertIn("invalid_tlp=1", pcie_last_rx_error_bits)
        self.assertIn("unsupported_tlp_format=1", pcie_last_rx_error_bits)
        self.assertIn("activity_periodic_enable=1", pcie_ctrl_bits)
        self.assertIn("status_periodic_enable=1", pcie_ctrl_bits)


if __name__ == "__main__":
    unittest.main()
