"""Retry-aware SDRAM host stress runner for uart_log_cli over serial or TCP."""

from __future__ import annotations

import argparse
import csv
import random
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
TOOL_DIR = SCRIPT_DIR.parent / "uart_log_tool" / "debug_log_tool"
REPO_ROOT = SCRIPT_DIR.parents[1]
if str(TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(TOOL_DIR))

from sdram_hostif_tool import (  # noqa: E402
    ByteClient,
    connect_client,
    wait_for_bulk_accept,
    wait_for_bulk_terminal_event,
    wait_for_host_result,
)
from sdram_uart_protocol import (  # noqa: E402
    HOST_EVT_BULK_DONE,
    HOST_EVT_BULK_ERR,
    HOST_EVT_BULK_OK,
    HOST_EVT_BULK_PROGRESS,
    HOST_EVT_CMD_ERR,
    HOST_EVT_READ_RSP,
    HOST_EVT_WRITE_ACK,
    HOST_SRC_INDEX,
    SDRAM_MAX_WORD_ADDR,
    build_bulk_read_command,
    build_bulk_write_command,
    build_read_command,
    build_status_read_command,
    build_write_command,
    drain_frames,
    iter_bulk_write_blocks,
    padded_word_count,
    recv_bulk_read_words,
    select_source_index,
    validate_bulk_range,
    wait_for_frame,
    write_exact,
)
from uart_log_protocol import Frame, FrameParser  # noqa: E402


DEFAULT_LENGTHS = [1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 31, 32]
DEFAULT_SEED = 0x5344_5241


@dataclass
class StressResult:
    index: int
    op: str
    addr: int
    words: int
    byte_len: int
    attempt: int
    outcome: str
    detail: str


def parse_length_list(text: str) -> list[int]:
    values: list[int] = []
    for chunk in text.split(","):
        item = chunk.strip()
        if not item:
            continue
        value = int(item, 0)
        if value < 1:
            raise argparse.ArgumentTypeError(f"length must be >= 1: {item}")
        values.append(value)
    if not values:
        raise argparse.ArgumentTypeError("at least one length is required")
    return values


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run retry-aware SDRAM host stress patterns over uart_log_cli."
    )
    parser.add_argument("--transport", choices=["serial", "tcp"], default="tcp")
    parser.add_argument("--tcp-host", default="192.168.10.40")
    parser.add_argument("--tcp-port", type=int, default=2323)
    parser.add_argument("--port", default=None)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--settle-ms", type=int, default=100)
    parser.add_argument("--timeout-s", type=float, default=5.0)
    parser.add_argument("--iterations", type=int, default=32)
    parser.add_argument("--status-every", type=int, default=4)
    parser.add_argument("--retry-count", type=int, default=3)
    parser.add_argument("--seed", type=lambda text: int(text, 0), default=DEFAULT_SEED)
    parser.add_argument("--addr-base", type=lambda text: int(text, 0), default=0x00000)
    parser.add_argument(
        "--span-words",
        type=lambda text: int(text, 0),
        default=SDRAM_MAX_WORD_ADDR + 1,
    )
    parser.add_argument(
        "--lengths",
        type=parse_length_list,
        default=list(DEFAULT_LENGTHS),
        help="comma-separated bulk payload byte lengths",
    )
    parser.add_argument(
        "--csv",
        default=str(REPO_ROOT / "tmp" / "sdram_hostif_stress.csv"),
        help="CSV output path",
    )
    return parser


def choose_word_addr(rng: random.Random, base_addr: int, span_words: int, words: int) -> int:
    if base_addr < 0 or base_addr > SDRAM_MAX_WORD_ADDR:
        raise ValueError(f"base address out of range: 0x{base_addr:X}")
    if span_words < 1:
        raise ValueError("span_words must be >= 1")
    if words < 1:
        raise ValueError("words must be >= 1")

    window_last = min(SDRAM_MAX_WORD_ADDR, base_addr + span_words - 1)
    max_addr = min(window_last - words + 1, SDRAM_MAX_WORD_ADDR - words + 1)
    if max_addr < base_addr:
        raise ValueError(
            f"requested span too small: base=0x{base_addr:05X} span={span_words} words={words}"
        )
    return rng.randint(base_addr, max_addr)


def make_bulk_blob(byte_len: int, rng: random.Random) -> bytes:
    blob = bytearray(rng.getrandbits(8) for _ in range(byte_len))
    hot_bytes = [0x10, 0x04, 0x06, 0x12, 0x14, 0x3F]
    for idx, value in enumerate(hot_bytes):
        if idx >= byte_len:
            break
        blob[idx] = value
    if byte_len >= 2:
        blob[-2] = 0x10
        blob[-1] = 0x3F
    return bytes(blob)


def prepare_client(args: argparse.Namespace) -> tuple[ByteClient, FrameParser]:
    client = connect_client(args)
    parser = FrameParser()
    try:
        try:
            select_source_index(
                client.write_bytes,
                lambda: client.read_bytes(),
                parser,
                HOST_SRC_INDEX,
                settle_ms=args.settle_ms,
                timeout_s=args.timeout_s,
            )
        except TimeoutError:
            pass
        drain_frames(lambda: client.read_bytes(), parser, 0.2)
        return client, parser
    except Exception:
        client.disconnect()
        raise


def with_prepared_client(args: argparse.Namespace, fn):
    client, parser = prepare_client(args)
    try:
        return fn(client, parser)
    finally:
        client.disconnect()


def cmd_err_detail(frame: Frame) -> str:
    return (
        f"CMD_ERR reason=0x{frame.event.arg0:08X} "
        f"addr=0x{frame.event.arg1 & SDRAM_MAX_WORD_ADDR:05X} "
        f"detail=0x{frame.event.arg2:08X}"
    )


def run_status_read(client: ByteClient, parser: FrameParser, timeout_s: float) -> str:
    write_exact(client.write_bytes, build_status_read_command(0x00000))
    frame = wait_for_host_result(client, parser, timeout_s, HOST_EVT_READ_RSP, addr=0x00000)
    if frame.event.event_id == HOST_EVT_CMD_ERR:
        raise RuntimeError(cmd_err_detail(frame))
    return f"status=0x{frame.event.arg1:08X}"


def run_single_verify(
    client: ByteClient,
    parser: FrameParser,
    timeout_s: float,
    *,
    addr: int,
    data: int,
) -> str:
    write_exact(client.write_bytes, build_write_command(addr, data))
    frame = wait_for_host_result(client, parser, timeout_s, HOST_EVT_WRITE_ACK, addr=addr)
    if frame.event.event_id == HOST_EVT_CMD_ERR:
        raise RuntimeError(cmd_err_detail(frame))

    write_exact(client.write_bytes, build_read_command(addr))
    frame = wait_for_host_result(client, parser, timeout_s, HOST_EVT_READ_RSP, addr=addr)
    if frame.event.event_id == HOST_EVT_CMD_ERR:
        raise RuntimeError(cmd_err_detail(frame))
    if frame.event.arg1 != data:
        raise RuntimeError(
            f"readback mismatch addr=0x{addr:05X} expected=0x{data:08X} got=0x{frame.event.arg1:08X}"
        )
    return f"readback ok data=0x{data:08X}"


def run_bulk_verify(
    args: argparse.Namespace,
    timeout_s: float,
    *,
    addr: int,
    blob: bytes,
) -> str:
    words = padded_word_count(len(blob))
    validate_bulk_range(addr, words)

    def _bulk_write_phase(client: ByteClient, parser: FrameParser) -> None:
        write_exact(client.write_bytes, build_bulk_write_command(addr, words))
        try:
            accept = wait_for_bulk_accept(client, parser, timeout_s, addr=addr)
        except TimeoutError as exc:
            raise TimeoutError(f"bulk write accept timeout addr=0x{addr:05X}") from exc
        if accept.event.event_id != HOST_EVT_BULK_OK:
            raise RuntimeError(
                f"bulk write rejected evt=0x{accept.event.event_id:02X} arg0=0x{accept.event.arg0:08X}"
            )

        blocks = iter_bulk_write_blocks(blob)
        for block_index, block in enumerate(blocks):
            write_exact(client.write_bytes, block)
            if block_index == len(blocks) - 1:
                continue
            try:
                progress = wait_for_frame(
                    lambda: client.read_bytes(),
                    parser,
                    timeout_s,
                    lambda frame: frame.event.src_id == 0x03
                    and frame.event.event_id in (HOST_EVT_BULK_PROGRESS, HOST_EVT_BULK_ERR, HOST_EVT_CMD_ERR),
                )
            except TimeoutError as exc:
                raise TimeoutError(
                    f"bulk write progress timeout addr=0x{addr:05X} block={block_index}"
                ) from exc
            if progress.event.event_id != HOST_EVT_BULK_PROGRESS:
                raise RuntimeError(
                    f"bulk write failed evt=0x{progress.event.event_id:02X} arg0=0x{progress.event.arg0:08X}"
                )

        try:
            terminal = wait_for_bulk_terminal_event(client, parser, timeout_s)
        except TimeoutError as exc:
            raise TimeoutError(f"bulk write done timeout addr=0x{addr:05X}") from exc
        if terminal.event.event_id != HOST_EVT_BULK_DONE:
            raise RuntimeError(
                f"bulk write terminal evt=0x{terminal.event.event_id:02X} arg0=0x{terminal.event.arg0:08X}"
            )

    def _bulk_read_phase(client: ByteClient, parser: FrameParser) -> bytes:
        write_exact(client.write_bytes, build_bulk_read_command(addr, words))
        try:
            accept = wait_for_bulk_accept(client, parser, timeout_s, addr=addr)
        except TimeoutError as exc:
            raise TimeoutError(f"bulk read accept timeout addr=0x{addr:05X}") from exc
        if accept.event.event_id != HOST_EVT_BULK_OK:
            raise RuntimeError(
                f"bulk read rejected evt=0x{accept.event.event_id:02X} arg0=0x{accept.event.arg0:08X}"
            )

        try:
            return recv_bulk_read_words(
                lambda: client.read_bytes(),
                parser,
                timeout_s,
                addr=addr,
                words=words,
            )
        except TimeoutError as exc:
            raise TimeoutError(f"bulk read data timeout addr=0x{addr:05X}") from exc

    with_prepared_client(args, _bulk_write_phase)
    readback = with_prepared_client(args, _bulk_read_phase)

    expected = blob + bytes(words * 4 - len(blob))
    if readback != expected:
        mismatch_index = next(
            idx for idx, (lhs, rhs) in enumerate(zip(expected, readback)) if lhs != rhs
        )
        raise RuntimeError(
            f"bulk mismatch addr=0x{addr:05X} byte={mismatch_index} "
            f"expected=0x{expected[mismatch_index]:02X} got=0x{readback[mismatch_index]:02X}"
        )
    return f"bulk ok bytes={len(blob)} words={words}"


def execute_with_retries(
    args: argparse.Namespace,
    *,
    index: int,
    op: str,
    addr: int,
    words: int,
    byte_len: int,
    runner,
) -> StressResult:
    max_attempts = args.retry_count + 1
    last_outcome = "FAIL"
    last_detail = "unknown failure"

    for attempt in range(1, max_attempts + 1):
        try:
            detail = runner()
            return StressResult(index, op, addr, words, byte_len, attempt, "PASS", detail)
        except TimeoutError as exc:
            last_outcome = "TIMEOUT"
            last_detail = str(exc)
        except Exception as exc:
            last_outcome = "FAIL"
            last_detail = str(exc)

    return StressResult(index, op, addr, words, byte_len, max_attempts, last_outcome, last_detail)


def write_csv(path: Path, rows: list[StressResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(StressResult.__annotations__.keys()))
        writer.writeheader()
        for row in rows:
            writer.writerow(asdict(row))


def print_row(row: StressResult) -> None:
    print(
        f"[{row.index:04d}] {row.op:<9} {row.outcome:<7} attempt={row.attempt} "
        f"addr=0x{row.addr:05X} words={row.words:<3} bytes={row.byte_len:<3} {row.detail}"
    )


def main() -> int:
    args = build_arg_parser().parse_args()
    rng = random.Random(args.seed)
    results: list[StressResult] = []
    next_index = 1

    for iteration in range(args.iterations):
        if args.status_every > 0 and (iteration % args.status_every) == 0:
            result = execute_with_retries(
                args,
                index=next_index,
                op="status",
                addr=0x00000,
                words=1,
                byte_len=4,
                runner=lambda: with_prepared_client(
                    args,
                    lambda client, parser: run_status_read(client, parser, args.timeout_s),
                ),
            )
            results.append(result)
            print_row(result)
            next_index += 1

        single_addr = choose_word_addr(rng, args.addr_base, args.span_words, 1)
        single_data = rng.getrandbits(32)
        result = execute_with_retries(
            args,
            index=next_index,
            op="single_rw",
            addr=single_addr,
            words=1,
            byte_len=4,
            runner=lambda addr=single_addr, data=single_data: with_prepared_client(
                args,
                lambda client, parser: run_single_verify(
                    client,
                    parser,
                    args.timeout_s,
                    addr=addr,
                    data=data,
                ),
            ),
        )
        results.append(result)
        print_row(result)
        next_index += 1

        byte_len = args.lengths[iteration % len(args.lengths)]
        words = padded_word_count(byte_len)
        bulk_addr = choose_word_addr(rng, args.addr_base, args.span_words, words)
        bulk_blob = make_bulk_blob(byte_len, rng)
        result = execute_with_retries(
            args,
            index=next_index,
            op="bulk_rw",
            addr=bulk_addr,
            words=words,
            byte_len=byte_len,
            runner=lambda addr=bulk_addr, blob=bulk_blob: run_bulk_verify(
                args,
                args.timeout_s,
                addr=addr,
                blob=blob,
            ),
        )
        results.append(result)
        print_row(result)
        next_index += 1

    csv_path = Path(args.csv)
    write_csv(csv_path, results)

    passed = sum(1 for row in results if row.outcome == "PASS")
    failed = len(results) - passed
    recovered = sum(1 for row in results if row.outcome == "PASS" and row.attempt > 1)
    timeout_failures = sum(1 for row in results if row.outcome == "TIMEOUT")
    print(
        f"SUMMARY total={len(results)} pass={passed} fail={failed} "
        f"recovered={recovered} timeout_failures={timeout_failures} csv={csv_path}"
    )
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())