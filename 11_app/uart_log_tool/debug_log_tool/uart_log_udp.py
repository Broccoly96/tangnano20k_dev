"""UDP socket utilities for Ethernet log stream reception."""

from __future__ import annotations

import socket
from typing import Optional


class UDPLogClient:
    """Thin wrapper around a non-blocking UDP socket for log reception."""

    def __init__(self) -> None:
        self._sock: Optional[socket.socket] = None
        self._bind_ip = ""
        self._bind_port = 0

    @property
    def is_connected(self) -> bool:
        return self._sock is not None

    @property
    def bind_ip(self) -> str:
        return self._bind_ip

    @property
    def bind_port(self) -> int:
        return self._bind_port

    def connect(self, bind_ip: str, bind_port: int) -> None:
        """Bind a non-blocking UDP socket."""

        self.disconnect()
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setblocking(False)
        try:
            sock.bind((bind_ip, bind_port))
        except Exception:
            sock.close()
            raise
        bound_ip, bound_port = sock.getsockname()
        self._sock = sock
        self._bind_ip = str(bound_ip)
        self._bind_port = int(bound_port)

    def disconnect(self) -> None:
        """Close the UDP socket if open."""

        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None
                self._bind_ip = ""
                self._bind_port = 0

    def recv_packets(self, max_packets: int = 32) -> list[tuple[bytes, tuple[str, int]]]:
        """Drain currently buffered UDP packets without blocking."""

        if self._sock is None:
            return []

        packets: list[tuple[bytes, tuple[str, int]]] = []
        for _ in range(max_packets):
            try:
                payload, peer = self._sock.recvfrom(65535)
            except BlockingIOError:
                break
            packets.append((payload, (str(peer[0]), int(peer[1]))))
        return packets
