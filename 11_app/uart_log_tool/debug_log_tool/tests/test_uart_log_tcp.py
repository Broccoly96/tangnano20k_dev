import socket
import sys
import threading
import time
import unittest
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from uart_log_tcp import UARTTCPClient  # noqa: E402


class _TCPServerThread(threading.Thread):
    def __init__(self, payloads: list[bytes]) -> None:
        super().__init__(daemon=True)
        self._payloads = payloads
        self.received = bytearray()
        self.ready = threading.Event()
        self.port = 0

    def run(self) -> None:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.bind(("127.0.0.1", 0))
            server.listen(1)
            self.port = int(server.getsockname()[1])
            self.ready.set()
            conn, _ = server.accept()
            with conn:
                for payload in self._payloads:
                    if payload:
                        conn.sendall(payload)
                        time.sleep(0.02)
                while True:
                    data = conn.recv(64)
                    if not data:
                        break
                    self.received.extend(data)


class UARTTCPClientTests(unittest.TestCase):
    def test_connect_read_write_and_remote_close(self) -> None:
        server = _TCPServerThread([b"\x7E\x01", b"\x02\x03"])
        server.start()
        self.assertTrue(server.ready.wait(timeout=2.0))

        client = UARTTCPClient()
        client.connect("127.0.0.1", server.port)

        deadline = time.time() + 2.0
        chunks = bytearray()
        while time.time() < deadline and len(chunks) < 4:
            chunks.extend(client.read_bytes())
            time.sleep(0.01)

        self.assertEqual(bytes(chunks), b"\x7E\x01\x02\x03")
        self.assertEqual(client.write_bytes(b"ABC"), 3)

        deadline = time.time() + 2.0
        while time.time() < deadline and server.received != b"ABC":
            time.sleep(0.01)

        client.disconnect()
        server.join(timeout=2.0)
        self.assertEqual(bytes(server.received), b"ABC")
        self.assertFalse(client.is_connected)

    def test_send_cli_command_uses_uart_command_bytes(self) -> None:
        server = _TCPServerThread([])
        server.start()
        self.assertTrue(server.ready.wait(timeout=2.0))

        client = UARTTCPClient()
        client.connect("127.0.0.1", server.port)
        self.assertEqual(client.send_cli_command("help"), 1)
        client.disconnect()
        server.join(timeout=2.0)

        self.assertEqual(bytes(server.received), b"?")


if __name__ == "__main__":
    unittest.main()
