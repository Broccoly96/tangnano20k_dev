"""OCR hardware smoke test.

Connects to the FPGA via TCP (ESP UART bridge), navigates the uart_log_cli to
source 4 (OCR), triggers inference with 'Z', and decodes the response frames.

Frame format (19 bytes each):
  [0]     SYNC = 0x7E
  [1]     SEQ (8-bit counter)
  [2..3]  timestamp_ms (little-endian)
  [4]     event_id
  [5]     src_id  (0x00 = system, 0x01..0x05 = sources 0..4)
  [6..9]  arg0 (little-endian u32)
  [10..13] arg1 (little-endian u32)
  [14..17] arg2 (little-endian u32)
  [18]    CRC-8/ATM

Known event IDs:
  System (src_id=0x00):
    0x01 = EV_MODE_CHANGE  arg0=old_src, arg1=new_src
    0x03 = EV_RESET_ACK
  OCR (src_id=0x05, i.e. SRC_IF[4]+1):
    0x30 = EVT_OCR_ACK
    0x31 = EVT_OCR_BUSY
    0x40 = EVT_OCR_RESULT  arg0={class[5:0],char[7:0],0x00,0x00}
    0x41 = EVT_OCR_CYCLES  arg0=total, arg1=L0, arg2=L1
"""

from __future__ import annotations

import socket
import struct
import time

# --- config ---
HOST = "192.168.10.40"
PORT = 2323
TIMEOUT = 5.0          # overall socket timeout
NAV_WAIT = 1.0         # seconds to wait after source navigation before 'Z'
CMD_NEXT_SRC = 0x06    # Ctrl+F
CMD_PREV_SRC = 0x04    # Ctrl+D  (from source 0 → source 4 in one step)
CMD_RUN_OCR  = 0x5A    # 'Z'
SYNC_BYTE    = 0x7E
FRAME_LEN    = 19
OCR_SRC_ID   = 0x05    # SRC_IF[4] → src_id = 4+1 = 5
SYS_SRC_ID   = 0x00

# ---------------------------------------------------------------------------
# CRC-8/ATM  (poly=0x07, init=0x00, refin=false, refout=false)
# ---------------------------------------------------------------------------
def crc8_atm(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc


# ---------------------------------------------------------------------------
# Frame decoder
# ---------------------------------------------------------------------------
def decode_frame(raw: bytes) -> dict | None:
    """Decode one 19-byte raw frame. Returns None on CRC mismatch."""
    if len(raw) != FRAME_LEN or raw[0] != SYNC_BYTE:
        return None
    payload = raw[2:18]
    crc_rx  = raw[18]
    crc_calc = crc8_atm(raw[1:18])   # SEQ + PAYLOAD
    if crc_rx != crc_calc:
        return None

    ts_ms    = struct.unpack_from("<H", payload, 0)[0]
    evt_id   = payload[2]
    src_id   = payload[3]
    arg0     = struct.unpack_from("<I", payload, 4)[0]
    arg1     = struct.unpack_from("<I", payload, 8)[0]
    arg2     = struct.unpack_from("<I", payload, 12)[0]
    return dict(seq=raw[1], ts_ms=ts_ms, evt_id=evt_id, src_id=src_id,
                arg0=arg0, arg1=arg1, arg2=arg2)


# ---------------------------------------------------------------------------
# Stream reader: accumulate bytes and yield complete frames
# ---------------------------------------------------------------------------
class FrameReader:
    def __init__(self):
        self._buf = bytearray()

    def feed(self, data: bytes):
        self._buf.extend(data)

    def frames(self) -> list[dict]:
        out = []
        buf = self._buf
        i = 0
        while i < len(buf):
            # Scan for SYNC byte
            if buf[i] != SYNC_BYTE:
                i += 1
                continue
            if i + FRAME_LEN > len(buf):
                break  # wait for more bytes
            raw = bytes(buf[i:i + FRAME_LEN])
            frame = decode_frame(raw)
            if frame is not None:
                out.append(frame)
                i += FRAME_LEN
            else:
                i += 1  # skip this byte and resync
        self._buf = buf[i:]
        return out


# ---------------------------------------------------------------------------
# Pretty-printer
# ---------------------------------------------------------------------------
def describe_frame(f: dict) -> str:
    src  = f["src_id"]
    evt  = f["evt_id"]
    arg0 = f["arg0"]
    arg1 = f["arg1"]
    arg2 = f["arg2"]

    label = f"src=0x{src:02X} evt=0x{evt:02X}"

    if src == SYS_SRC_ID:
        if evt == 0x01:
            return f"[SYS] MODE_CHANGE  src={arg0} → {arg1}"
        if evt == 0x03:
            return "[SYS] RESET_ACK"
        return f"[SYS] {label} arg0=0x{arg0:08X}"

    if src == OCR_SRC_ID:
        if evt == 0x30:
            return "[OCR] EVT_OCR_ACK  (inference started)"
        if evt == 0x31:
            return "[OCR] EVT_OCR_BUSY (engine busy, request dropped)"
        if evt == 0x40:
            ocr_class = (arg0 >> 16) & 0x3F
            ocr_char  = (arg0 >>  8) & 0xFF
            return (f"[OCR] EVT_OCR_RESULT  class={ocr_class}  "
                    f"char='{chr(ocr_char) if 0x20 <= ocr_char < 0x7F else f'0x{ocr_char:02X}'}'  "
                    f"score0={f['arg1']}  score1={f['arg2']}")
        if evt == 0x41:
            return (f"[OCR] EVT_OCR_CYCLES  total={arg0}  L0={arg1}  L1={arg2}")
        return f"[OCR] {label} arg0=0x{arg0:08X}"

    return f"[raw] seq={f['seq']} ts={f['ts_ms']}ms {label} arg0=0x{arg0:08X} arg1=0x{arg1:08X} arg2=0x{arg2:08X}"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    print(f"Connecting to {HOST}:{PORT} ...")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    s.connect((HOST, PORT))
    print("Connected.")

    reader = FrameReader()

    def recv_frames(duration: float) -> list[dict]:
        """Receive for `duration` seconds and return decoded frames."""
        deadline = time.monotonic() + duration
        frames: list[dict] = []
        while time.monotonic() < deadline:
            try:
                chunk = s.recv(256)
                if not chunk:
                    break
                reader.feed(chunk)
                frames.extend(reader.frames())
            except socket.timeout:
                break
        return frames

    # 1. Drain any buffered bytes / pre-existing frames
    print("\n--- Draining buffer (0.5 s) ---")
    pre = recv_frames(0.5)
    for f in pre:
        print(" ", describe_frame(f))

    # 2. Navigate to source 4 using CMD_PREV_SRC (0→4 in one step)
    #    sel_prev_local(0) = NUM_SRC-1 = 4
    print("\n--- Sending CMD_PREV_SRC (0x04) to navigate from src 0 → 4 ---")
    s.sendall(bytes([CMD_PREV_SRC]))

    # Wait for MODE_CHANGE event confirming we reached source 4
    print("Waiting for MODE_CHANGE to src 4 ...")
    deadline = time.monotonic() + 3.0
    reached_src4 = False
    while time.monotonic() < deadline:
        frames = recv_frames(0.2)
        for f in frames:
            print(" ", describe_frame(f))
            if f["src_id"] == SYS_SRC_ID and f["evt_id"] == 0x01 and f["arg1"] == 4:
                reached_src4 = True
        if reached_src4:
            break

    if not reached_src4:
        print("WARNING: did not see MODE_CHANGE to src 4; proceeding anyway.")
        # Try an alternative: navigate via CMD_NEXT_SRC x4
        print("  Trying 4 × CMD_NEXT_SRC (0x06) ...")
        for _ in range(4):
            s.sendall(bytes([CMD_NEXT_SRC]))
            time.sleep(0.3)
            frames = recv_frames(0.3)
            for f in frames:
                print("  ", describe_frame(f))
                if f["src_id"] == SYS_SRC_ID and f["evt_id"] == 0x01 and f["arg1"] == 4:
                    reached_src4 = True

    if not reached_src4:
        print("ERROR: Could not navigate to source 4. Aborting.")
        s.close()
        return

    print("Source 4 active.")

    # 3. Send 'Z' to trigger OCR inference
    time.sleep(0.2)
    print(f"\n--- Sending 'Z' (0x5A) to trigger OCR ---")
    s.sendall(bytes([CMD_RUN_OCR]))

    # 4. Wait and collect response frames
    print(f"Waiting {NAV_WAIT + 1.0:.1f} s for OCR response ...")
    ocr_frames = recv_frames(NAV_WAIT + 1.0)
    print(f"\n--- Received {len(ocr_frames)} frames ---")
    for f in ocr_frames:
        print(" ", describe_frame(f))

    # Summary
    ack_seen    = any(f["src_id"] == OCR_SRC_ID and f["evt_id"] == 0x30 for f in ocr_frames)
    result_seen = any(f["src_id"] == OCR_SRC_ID and f["evt_id"] == 0x40 for f in ocr_frames)
    cycles_seen = any(f["src_id"] == OCR_SRC_ID and f["evt_id"] == 0x41 for f in ocr_frames)

    print("\n--- Summary ---")
    print(f"  ACK seen    : {'YES' if ack_seen    else 'NO'}")
    print(f"  RESULT seen : {'YES' if result_seen else 'NO'}")
    print(f"  CYCLES seen : {'YES' if cycles_seen else 'NO'}")

    if result_seen:
        for f in ocr_frames:
            if f["src_id"] == OCR_SRC_ID and f["evt_id"] == 0x40:
                ocr_class = (f["arg0"] >> 16) & 0x3F
                ocr_char  = (f["arg0"] >>  8) & 0xFF
                print(f"\n  Best class  : {ocr_class}")
                print(f"  Best char   : '{chr(ocr_char) if 0x20 <= ocr_char < 0x7F else f'0x{ocr_char:02X}'}'")
                print(f"  score0      : {f['arg1']}")
                print(f"  score1      : {f['arg2']}")
        print("\nPASS: OCR inference responded correctly.")
    else:
        print("\nFAIL: No OCR result received.")

    s.close()


if __name__ == "__main__":
    main()
