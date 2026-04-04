"""TCP socket utilities for UART log CLI host tool."""

from __future__ import annotations

import socket
from typing import Optional

from uart_log_serial import CLI_COMMAND_BYTES


class UARTTCPClient:
    """Thin wrapper around a non-blocking TCP socket for UART byte streams."""

    def __init__(self) -> None:
        self._sock: Optional[socket.socket] = None
        self._host = ""
        self._port = 0

    @property
    def host(self) -> str:
        return self._host

    @property
    def port(self) -> int:
        return self._port

    @property
    def is_connected(self) -> bool:
        return self._sock is not None

    def connect(self, host: str, port: int) -> None:
        """Open a TCP connection in low-latency non-blocking style."""

        self.disconnect()
        sock = socket.create_connection((host, int(port)), timeout=1.0)
        sock.settimeout(0.0)
        self._sock = sock
        self._host = str(host)
        self._port = int(port)

    def disconnect(self) -> None:
        """Close the TCP connection if open."""

        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None
                self._host = ""
                self._port = 0

    def read_bytes(self, max_bytes: int = 512) -> bytes:
        """Read currently buffered bytes, non-blocking."""

        if self._sock is None:
            return b""

        try:
            data = self._sock.recv(max_bytes)
        except BlockingIOError:
            return b""
        except TimeoutError:
            return b""
        except OSError:
            self.disconnect()
            return b""

        if data == b"":
            self.disconnect()
            return b""

        return data

    def write_bytes(self, payload: bytes) -> int:
        """Write raw bytes to the TCP stream. Returns bytes accepted."""

        if self._sock is None:
            return 0

        try:
            return int(self._sock.send(payload))
        except (BlockingIOError, TimeoutError):
            return 0
        except OSError:
            self.disconnect()
            return 0

    def send_cli_command(self, name: str) -> int:
        """Send one predefined CLI command by symbolic name."""

        if name not in CLI_COMMAND_BYTES:
            raise ValueError(f"unknown command: {name}")
        return self.write_bytes(CLI_COMMAND_BYTES[name])
