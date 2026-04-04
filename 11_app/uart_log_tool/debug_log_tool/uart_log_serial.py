"""Serial port utilities for UART log CLI host tool."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import serial
from serial.tools import list_ports


CLI_COMMAND_BYTES = {
    "help": b"?",
    "reset": bytes([0x12]),  # Ctrl+R
    "next": bytes([0x06]),   # Ctrl+F
    "prev": bytes([0x04]),   # Ctrl+D
    "status": bytes([0x14]), # Ctrl+T
}


@dataclass(frozen=True)
class PortInfo:
    """Display-friendly serial port descriptor."""

    device: str
    description: str
    hwid: str


class UARTSerialClient:
    """Thin wrapper around pyserial with non-blocking read behavior."""

    def __init__(self) -> None:
        self._ser: Optional[serial.Serial] = None

    @staticmethod
    def list_ports() -> list[PortInfo]:
        """Enumerate available COM/TTY ports."""

        ports: list[PortInfo] = []
        for item in list_ports.comports():
            ports.append(
                PortInfo(
                    device=item.device,
                    description=item.description or "",
                    hwid=item.hwid or "",
                )
            )
        ports.sort(key=lambda p: p.device)
        return ports

    @property
    def is_connected(self) -> bool:
        return self._ser is not None and self._ser.is_open

    def connect(self, port: str, baud: int) -> None:
        """Open serial connection in non-blocking mode."""

        self.disconnect()
        self._ser = serial.Serial(
            port=port,
            baudrate=baud,
            timeout=0,
            write_timeout=0.2,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
        )

    def disconnect(self) -> None:
        """Close serial connection if open."""

        if self._ser is not None:
            try:
                self._ser.close()
            finally:
                self._ser = None

    def read_bytes(self, max_bytes: int = 512) -> bytes:
        """Read currently buffered bytes, non-blocking."""

        if not self.is_connected or self._ser is None:
            return b""

        waiting = self._ser.in_waiting
        if waiting <= 0:
            return b""

        read_len = waiting if waiting < max_bytes else max_bytes
        return self._ser.read(read_len)

    def write_bytes(self, payload: bytes) -> int:
        """Write raw bytes to serial TX. Returns number of bytes written."""

        if not self.is_connected or self._ser is None:
            return 0
        return int(self._ser.write(payload))

    def send_cli_command(self, name: str) -> int:
        """Send one predefined CLI command by symbolic name."""

        if name not in CLI_COMMAND_BYTES:
            raise ValueError(f"unknown command: {name}")
        return self.write_bytes(CLI_COMMAND_BYTES[name])
