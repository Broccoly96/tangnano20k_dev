"""Monochrome framebuffer helpers for SSD1306 host-side tools."""

from __future__ import annotations

from dataclasses import dataclass

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover - runtime dependency check
    Image = None
    ImageDraw = None
    ImageFont = None


SSD1306_WIDTH = 128
SSD1306_HEIGHT = 32
SSD1306_PAGE_COUNT = SSD1306_HEIGHT // 8
SSD1306_FRAME_BYTES = SSD1306_WIDTH * SSD1306_PAGE_COUNT


def _clip_pixel(x: int, y: int) -> bool:
    return 0 <= x < SSD1306_WIDTH and 0 <= y < SSD1306_HEIGHT


@dataclass
class SSD1306FrameBuffer:
    _bytes: bytearray

    @classmethod
    def blank(cls, *, fill: bool = False) -> "SSD1306FrameBuffer":
        return cls(bytearray([0xFF if fill else 0x00] * SSD1306_FRAME_BYTES))

    @classmethod
    def from_bytes(cls, blob: bytes) -> "SSD1306FrameBuffer":
        if len(blob) != SSD1306_FRAME_BYTES:
            raise ValueError(
                f"frame payload must be exactly {SSD1306_FRAME_BYTES} bytes, got {len(blob)}"
            )
        return cls(bytearray(blob))

    def to_bytes(self) -> bytes:
        return bytes(self._bytes)

    def clear(self, *, fill: bool = False) -> None:
        value = 0xFF if fill else 0x00
        for idx in range(SSD1306_FRAME_BYTES):
            self._bytes[idx] = value

    def invert(self) -> None:
        for idx in range(SSD1306_FRAME_BYTES):
            self._bytes[idx] ^= 0xFF

    def set_pixel(self, x: int, y: int, on: bool = True) -> None:
        if not _clip_pixel(x, y):
            return
        byte_idx = (y >> 3) * SSD1306_WIDTH + x
        bit_mask = 1 << (y & 0x7)
        if on:
            self._bytes[byte_idx] |= bit_mask
        else:
            self._bytes[byte_idx] &= ~bit_mask & 0xFF

    def draw_line(self, x0: int, y0: int, x1: int, y1: int, *, on: bool = True) -> None:
        dx = abs(x1 - x0)
        sx = 1 if x0 < x1 else -1
        dy = -abs(y1 - y0)
        sy = 1 if y0 < y1 else -1
        err = dx + dy

        while True:
            self.set_pixel(x0, y0, on)
            if x0 == x1 and y0 == y1:
                break
            err2 = err * 2
            if err2 >= dy:
                err += dy
                x0 += sx
            if err2 <= dx:
                err += dx
                y0 += sy

    def draw_rect(self, x: int, y: int, width: int, height: int, *, on: bool = True, fill: bool = False) -> None:
        if width <= 0 or height <= 0:
            return
        if fill:
            for row in range(y, y + height):
                for col in range(x, x + width):
                    self.set_pixel(col, row, on)
            return

        self.draw_line(x, y, x + width - 1, y, on=on)
        self.draw_line(x, y + height - 1, x + width - 1, y + height - 1, on=on)
        self.draw_line(x, y, x, y + height - 1, on=on)
        self.draw_line(x + width - 1, y, x + width - 1, y + height - 1, on=on)

    def draw_text(self, x: int, y: int, text: str, *, on: bool = True) -> None:
        if not text:
            return
        if Image is None or ImageDraw is None or ImageFont is None:
            raise RuntimeError(
                "text rendering requires Pillow. Install it in the active venv first."
            )

        image = Image.new("1", (SSD1306_WIDTH, SSD1306_HEIGHT), 0)
        draw = ImageDraw.Draw(image)
        font = ImageFont.load_default()
        draw.text((x, y), text, fill=1 if on else 0, font=font, spacing=0)

        for row in range(SSD1306_HEIGHT):
            for col in range(SSD1306_WIDTH):
                if image.getpixel((col, row)):
                    self.set_pixel(col, row, on)


def build_checker_frame() -> bytes:
    framebuffer = SSD1306FrameBuffer.blank(fill=False)
    for page in range(SSD1306_PAGE_COUNT):
        for column in range(SSD1306_WIDTH):
            framebuffer._bytes[(page * SSD1306_WIDTH) + column] = (
                0xAA if ((page + column) & 1) == 0 else 0x55
            )
    return framebuffer.to_bytes()


def invert_frame(blob: bytes) -> bytes:
    framebuffer = SSD1306FrameBuffer.from_bytes(blob)
    framebuffer.invert()
    return framebuffer.to_bytes()