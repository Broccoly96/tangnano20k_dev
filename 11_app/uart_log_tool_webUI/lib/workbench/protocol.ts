import { readFile, writeFile, mkdir } from "node:fs/promises";
import { extname } from "node:path";

import type {
  DecodedEvent,
  DisplayMode,
  LogRow,
  ReplayRecord,
  StoredEvent,
  UartEvent,
  UartFrame,
} from "@/lib/workbench/types";

export const UART_SYNC_BYTE = 0x7e;
export const FRAME_PAYLOAD_BYTES = 16;
export const FRAME_TOTAL_BYTES = 19;

export const HOST_SRC_INDEX = 2;
export const UART_LOG_NUM_SRC = 4;
export const SYS_SRC_ID = 0x00;
export const SYS_EVT_MODE_CHANGE = 0x01;
export const SDRAM_HOST_SRC_ID = 0x03;
export const EEPROM_HOST_SRC_ID = 0x01;
export const DISPLAY_HOST_SRC_ID = 0x04;
export const DISPLAY_SRC_INDEX = 3;

export const HOST_EVT_WRITE_ACK = 0x30;
export const HOST_EVT_READ_RSP = 0x31;
export const HOST_EVT_BULK_OK = 0x32;
export const HOST_EVT_BULK_ERR = 0x33;
export const HOST_EVT_BULK_PROGRESS = 0x34;
export const HOST_EVT_BULK_DONE = 0x35;
export const HOST_EVT_BULK_ABORT = 0x36;
export const HOST_EVT_CMD_ERR = 0x3e;
export const HOST_EVT_BURST_ERR = HOST_EVT_BULK_ERR;
export const HOST_EVT_BURST_DATA = HOST_EVT_BULK_PROGRESS;
export const HOST_EVT_BURST_DONE = HOST_EVT_BULK_DONE;

export const EVT_CMD_ACK = 0x30;
export const EVT_CMD_ERR = 0x3e;

export const DISP_OP_INIT = 0;
export const DISP_OP_CLEAR = 1;
export const DISP_OP_FRAME_WRITE = 2;
export const DISP_OP_ON = 3;
export const DISP_OP_OFF = 4;
export const DISP_OP_REFRESH = 5;
export const DISP_OP_AUTO_ON = 6;
export const DISP_OP_AUTO_OFF = 7;
export const DISP_OP_SET_FPS = 8;
export const SSD1306_FRAME_BYTES = 512;
export const DISPLAY_FRAMEBUFFER_BASE_ADDR = 0x10000;

export const CMD_NEXT_SRC = 0x06;
export const CMD_LITERAL_NEXT = 0x10;
export const CMD_SOFT_RESET = 0x12;

export const MAP_ROWS = 16;
export const MAP_WORDS_PER_ROW = 16;
export const MAP_WORD_COUNT = MAP_ROWS * MAP_WORDS_PER_ROW;
export const MAP_BYTE_COUNT = MAP_WORD_COUNT * 4;
export const STATUS_BYTE_COUNT = 80;
export const EEPROM_MAP_ROWS = 16;
export const EEPROM_MAP_BYTES_PER_ROW = 16;
export const EEPROM_MAP_BYTE_COUNT = EEPROM_MAP_ROWS * EEPROM_MAP_BYTES_PER_ROW;
export const SDRAM_MAX_WORD_ADDR = 0x1f_ffff;
export const EEPROM_MAX_ADDR = 0x1ffff;
export const MAX_BULK_WORD_COUNT = 0x0f_ffff;
export const BURST_MAX_WORDS = 256;

const BULK_SOF0 = 0x55;
const BULK_SOF1 = 0xaa;
const BULK_WR_DATA = 0x01;
const BULK_WR_END = 0x02;
const BULK_ABORT = 0xe0;
const MAX_BULK_PAYLOAD_BYTES = 104;
const MAX_BULK_WRITE_CHUNK_BYTES = 64;
const CLI_LITERAL_BYTES = new Set<number>([0x04, 0x06, CMD_LITERAL_NEXT, CMD_SOFT_RESET, 0x14, 0x3f]);

export class FrameParser {
  private buffer = new Uint8Array(0);
  private lastSeq: number | null = null;
  validFrameCount = 0;
  crcErrorCount = 0;
  lostEventCount = 0;

  reset() {
    this.buffer = new Uint8Array(0);
    this.lastSeq = null;
    this.validFrameCount = 0;
    this.crcErrorCount = 0;
    this.lostEventCount = 0;
  }

  feed(data: Uint8Array): UartFrame[] {
    if (!data.length) {
      return [];
    }

    const merged = new Uint8Array(this.buffer.length + data.length);
    merged.set(this.buffer, 0);
    merged.set(data, this.buffer.length);
    this.buffer = merged;

    const frames: UartFrame[] = [];
    while (true) {
      const syncIndex = this.buffer.indexOf(UART_SYNC_BYTE);
      if (syncIndex < 0) {
        this.buffer = new Uint8Array(0);
        break;
      }
      if (syncIndex > 0) {
        this.buffer = this.buffer.slice(syncIndex);
      }
      if (this.buffer.length < FRAME_TOTAL_BYTES) {
        break;
      }

      const candidate = this.buffer.slice(0, FRAME_TOTAL_BYTES);
      const seq = candidate[1];
      const payload = candidate.slice(2, 18);
      const crcRx = candidate[18];
      const crcCalc = crc8Atm(new Uint8Array([seq, ...payload]));

      if (crcRx !== crcCalc) {
        this.crcErrorCount += 1;
        this.buffer = this.buffer.slice(1);
        continue;
      }

      let lostCount = 0;
      if (this.lastSeq !== null) {
        const expected = (this.lastSeq + 1) & 0xff;
        if (seq !== expected) {
          lostCount = (seq - expected) & 0xff;
          this.lostEventCount += lostCount;
        }
      }
      this.lastSeq = seq;

      frames.push({
        sync: UART_SYNC_BYTE,
        seq,
        payloadBytes: payload,
        crc: crcRx,
        crcOk: true,
        lostCount,
        rawHex: Array.from(candidate).map((value) => value.toString(16).toUpperCase().padStart(2, "0")).join(" "),
        event: decodeEventPayload(payload),
      });
      this.validFrameCount += 1;
      this.buffer = this.buffer.slice(FRAME_TOTAL_BYTES);
    }

    return frames;
  }
}

export interface BurstDataPacket {
  packetId: number;
  packetCount: number;
  firstWordIndex: number;
  validWordCount: number;
  words: number[];
}

export interface BulkReadProgress {
  baseAddr: number;
  validWordCount: number;
  words: number[];
}

export interface EepromBulkReadProgress {
  baseAddr: number;
  validByteCount: number;
  data: Uint8Array;
}

interface DecoderRule {
  level: DecodedEvent["level"];
  title: string;
  message: string;
  tags: string[];
  decode: string;
}

const PLACEHOLDER_PATTERN = /\{([a-zA-Z0-9_]+)(?::([^}]+))?\}/g;

export class RuleDecoder {
  private exact = new Map<string, DecoderRule>();
  private srcAny = new Map<number, DecoderRule>();
  private anyEvt = new Map<number, DecoderRule>();
  private defaultRule: DecoderRule | null = null;

  static fromMapping(rulesRaw: Record<string, unknown>) {
    const decoder = new RuleDecoder();
    decoder.loadMapping(rulesRaw);
    return decoder;
  }

  loadMapping(rulesRaw: Record<string, unknown>) {
    this.exact.clear();
    this.srcAny.clear();
    this.anyEvt.clear();
    this.defaultRule = null;

    Object.entries(rulesRaw).forEach(([key, value]) => {
      if (key === "version") {
        return;
      }
      const normalized = normalizeRule(value);
      this.registerRule(key, normalized);
    });
  }

  decode(event: UartEvent): DecodedEvent {
    const rule = this.selectRule(event);
    if (!rule) {
      return {
        level: "INFO",
        title: "UNMAPPED",
        message: fallbackMessage(event),
        tags: ["fallback"],
      };
    }

    const context = buildDecodeContext(event);
    applyDecodeMode(rule.decode, event, context);
    const template = rule.decode.toLowerCase() === "help_ascii" ? rule.message || "{help_ascii}" : rule.message;
    const message = safeFormat(template, context) || fallbackMessage(event);

    return {
      level: rule.level,
      title: rule.title || "EVENT",
      message,
      tags: [...rule.tags],
    };
  }

  private registerRule(key: string, rule: DecoderRule) {
    if (key === "default") {
      this.defaultRule = rule;
      return;
    }

    const [srcToken, evtToken] = key.split(":").map((part) => part.trim());
    if (!srcToken || !evtToken) {
      throw new Error(`invalid rule key: ${key}`);
    }

    const srcId = parseRuleToken(srcToken);
    const evtId = parseRuleToken(evtToken);
    if (srcId === null && evtId === null) {
      this.defaultRule = rule;
    } else if (srcId === null) {
      this.anyEvt.set(evtId!, rule);
    } else if (evtId === null) {
      this.srcAny.set(srcId, rule);
    } else {
      this.exact.set(`${srcId}:${evtId}`, rule);
    }
  }

  private selectRule(event: UartEvent) {
    return (
      this.exact.get(`${event.srcId}:${event.eventId}`) ??
      this.srcAny.get(event.srcId) ??
      this.anyEvt.get(event.eventId) ??
      this.defaultRule
    );
  }
}

export async function loadDecoderFromYaml(path: string) {
  const fileText = await readFile(path, "utf8");
  const yaml = await import("js-yaml");
  const loaded = (yaml.load(fileText) ?? {}) as Record<string, unknown>;
  const rules = (typeof loaded.rules === "object" && loaded.rules ? loaded.rules : loaded) as Record<string, unknown>;
  return RuleDecoder.fromMapping(rules);
}

export function formatHostTime(date = new Date()) {
  const hh = `${date.getHours()}`.padStart(2, "0");
  const mm = `${date.getMinutes()}`.padStart(2, "0");
  const ss = `${date.getSeconds()}`.padStart(2, "0");
  const ms = `${date.getMilliseconds()}`.padStart(3, "0");
  return `${hh}:${mm}:${ss}.${ms}`;
}

export function buildLogRow(stored: StoredEvent, mode: DisplayMode, decoder: RuleDecoder): LogRow {
  const decoded = decoder.decode(stored.event);
  const rawMessage = fallbackMessage(stored.event);
  const text = mode === "decode" ? `${decoded.title}: ${decoded.message}` : rawMessage;
  const modeText = mode === "decode" ? decoded.level : "RAW";
  const hostTime = stored.hostTime ?? formatHostTime();
  const lostSuffix = stored.lostCount > 0 ? ` lost=${stored.lostCount}` : "";

  return {
    hostTime,
    seqText: `0x${stored.seq.toString(16).toUpperCase().padStart(2, "0")}`,
    srcText: `0x${stored.event.srcId.toString(16).toUpperCase().padStart(2, "0")}`,
    evtText: `0x${stored.event.eventId.toString(16).toUpperCase().padStart(2, "0")}`,
    timestampText: `${stored.event.timestamp}`,
    arg0Text: `0x${u32(stored.event.arg0).toString(16).toUpperCase().padStart(8, "0")}`,
    arg1Text: `0x${u32(stored.event.arg1).toString(16).toUpperCase().padStart(8, "0")}`,
    arg2Text: `0x${u32(stored.event.arg2).toString(16).toUpperCase().padStart(8, "0")}`,
    crcText: "OK",
    modeText,
    text,
    searchText: `${hostTime} ${stored.seq} ${stored.event.srcId} ${stored.event.eventId} ${stored.event.timestamp} ${stored.event.arg0} ${stored.event.arg1} ${stored.event.arg2} ${modeText} ${text}${lostSuffix}`.toLowerCase(),
  };
}

export function formatMapText(baseAddr: number, mapBytes: Uint8Array) {
  const normalized = mapBytes.length >= MAP_BYTE_COUNT ? mapBytes.slice(0, MAP_BYTE_COUNT) : padBytes(mapBytes, MAP_BYTE_COUNT);
  const lines = [`Base: 0x${baseAddr.toString(16).toUpperCase().padStart(5, "0")}  Mode: 4-byte little-endian words`];
  lines.push(`   | ${Array.from({ length: MAP_WORDS_PER_ROW }, (_, idx) => idx.toString(16).toUpperCase().padStart(2, "0").padStart(8, " ")).join("  ")}`);
  lines.push("―".repeat(163));
  for (let row = 0; row < MAP_ROWS; row += 1) {
    const rowBase = row * MAP_WORDS_PER_ROW;
    const cells: string[] = [];
    for (let col = 0; col < MAP_WORDS_PER_ROW; col += 1) {
      const offset = (rowBase + col) * 4;
      const word = bytesToU32(normalized.slice(offset, offset + 4));
      cells.push(word.toString(16).toUpperCase().padStart(8, "0"));
    }
    lines.push(`${rowBase.toString(16).toUpperCase().padStart(2, "0")} | ${cells.join("  ")}`);
  }
  return lines.join("\n");
}

export function formatEepromMapText(baseAddr: number, mapBytes: Uint8Array) {
  const normalized = mapBytes.length >= EEPROM_MAP_BYTE_COUNT ? mapBytes.slice(0, EEPROM_MAP_BYTE_COUNT) : padBytes(mapBytes, EEPROM_MAP_BYTE_COUNT);
  const lines = [`Base: 0x${baseAddr.toString(16).toUpperCase().padStart(5, "0")}  Mode: byte hex + ASCII`];
  lines.push(`Addr  | ${Array.from({ length: EEPROM_MAP_BYTES_PER_ROW }, (_, idx) => idx.toString(16).toUpperCase().padStart(2, "0")).join(" ")} | ASCII`);
  lines.push("―".repeat(74));
  for (let row = 0; row < EEPROM_MAP_ROWS; row += 1) {
    const rowAddr = baseAddr + row * EEPROM_MAP_BYTES_PER_ROW;
    const chunk = normalized.slice(row * EEPROM_MAP_BYTES_PER_ROW, (row + 1) * EEPROM_MAP_BYTES_PER_ROW);
    const hexText = Array.from(chunk, (value) => value.toString(16).toUpperCase().padStart(2, "0")).join(" ");
    const asciiText = Array.from(chunk, (value) => (value >= 32 && value < 127 ? String.fromCharCode(value) : ".")).join("");
    lines.push(`${rowAddr.toString(16).toUpperCase().padStart(5, "0")} | ${hexText} | ${asciiText}`);
  }
  return lines.join("\n");
}

export function formatStatusRawText(statusBytes: Uint8Array) {
  const normalized = padStatusBytes(statusBytes);
  const lines = [
    `Base: 0x00000  Size: ${STATUS_BYTE_COUNT} bytes  Mode: raw 32-bit words`,
    "      00        04        08        0C",
  ];
  for (let rowBase = 0; rowBase < STATUS_BYTE_COUNT; rowBase += 16) {
    const cells: string[] = [];
    for (let col = 0; col < 16; col += 4) {
      const word = bytesToU32(normalized.slice(rowBase + col, rowBase + col + 4));
      cells.push(word.toString(16).toUpperCase().padStart(8, "0"));
    }
    lines.push(`${rowBase.toString(16).toUpperCase().padStart(2, "0")} | ${cells.join("  ")}`);
  }
  return lines.join("\n");
}

export function formatStatusText(statusBytes: Uint8Array) {
  const bytes = padStatusBytes(statusBytes);
  const summary = statusWord(bytes, 0x00);
  const memSummary = statusWord(bytes, 0x04);
  const currentAddr = statusWord(bytes, 0x08);
  const expectedWord = statusWord(bytes, 0x0c);
  const lastRead = statusWord(bytes, 0x10);
  const lastStatus = statusWord(bytes, 0x14);
  const failAddr = statusWord(bytes, 0x18);
  const failExpected = statusWord(bytes, 0x1c);
  const failActual = statusWord(bytes, 0x20);
  const retrySummary = statusWord(bytes, 0x24);
  const retryData1 = statusWord(bytes, 0x28);
  const retryData2 = statusWord(bytes, 0x2c);
  const ctrlSummary = statusWord(bytes, 0x30);
  const ctrlDetail = statusWord(bytes, 0x34);
  const handshake = statusWord(bytes, 0x38);
  const latestRd = statusWord(bytes, 0x3c);
  const refreshStatus = statusWord(bytes, 0x48);

  const version = (summary >>> 24) & 0xff;
  const state = (summary >>> 16) & 0xff;
  const reason = (summary >>> 8) & 0xff;
  const ctrlState = version >= 0x05 ? (ctrlSummary >>> 27) & 0x1f : (ctrlSummary >>> 28) & 0x0f;

  const lastStatusLines = version >= 0x05
    ? [
        `  fail_reason       : ${statusFailReasonName((lastStatus >>> 20) & 0xff)}`,
        `  state             : ${statusStateName((lastStatus >>> 15) & 0x1f, version)}`,
        `  cmd_ack           : ${(lastStatus >>> 14) & 0x1}`,
        `  init_done         : ${(lastStatus >>> 13) & 0x1}`,
        `  client_ready      : ${(lastStatus >>> 12) & 0x1}`,
        `  cmd_en            : ${(lastStatus >>> 11) & 0x1}`,
        `  cmd               : ${hsCmdName((lastStatus >>> 8) & 0x7)} (0b${(((lastStatus >>> 8) & 0x7).toString(2).padStart(3, "0"))})`,
        `  ack_count         : ${lastStatus & 0xff}`,
      ]
    : [
        `  fail_reason       : ${statusFailReasonName((lastStatus >>> 24) & 0xff)}`,
        `  rd_seen_words     : ${(lastStatus >>> 16) & 0xff}`,
        `  cycle_count       : ${(lastStatus >>> 8) & 0xff}`,
        `  retry_path        : ${(lastStatus >>> 7) & 0x1}`,
        `  busy_n            : ${(lastStatus >>> 6) & 0x1}`,
        `  rd_valid          : ${(lastStatus >>> 5) & 0x1}`,
        `  wrd_ack           : ${(lastStatus >>> 4) & 0x1}`,
        `  init_done         : ${(lastStatus >>> 3) & 0x1}`,
        `  retry_count       : ${lastStatus & 0x7}`,
      ];

  const ctrlSummaryLines = version >= 0x05
    ? [
        `  cmd_en            : ${(ctrlSummary >>> 26) & 0x1}`,
        `  cmd               : ${hsCmdName((ctrlSummary >>> 23) & 0x7)}`,
        `  cmd_ack           : ${(ctrlSummary >>> 22) & 0x1}`,
        `  init_done         : ${(ctrlSummary >>> 21) & 0x1}`,
        `  client_ready      : ${(ctrlSummary >>> 20) & 0x1}`,
        `  read_sample_valid : ${(ctrlSummary >>> 19) & 0x1}`,
        `  pair_active       : ${(ctrlSummary >>> 18) & 0x1}`,
        `  retry_count_lsb2  : ${(ctrlSummary >>> 16) & 0x3}`,
        `  read_word_count   : ${(ctrlSummary >>> 8) & 0xff}`,
        `  write_word_count  : ${ctrlSummary & 0xff}`,
      ]
    : [
        `  wr_launch         : ${(ctrlSummary >>> 27) & 0x1}`,
        `  rd_launch         : ${(ctrlSummary >>> 26) & 0x1}`,
        `  busy_n            : ${(ctrlSummary >>> 25) & 0x1}`,
        `  rd_valid          : ${(ctrlSummary >>> 24) & 0x1}`,
        `  wrd_ack           : ${(ctrlSummary >>> 23) & 0x1}`,
        `  init_done         : ${(ctrlSummary >>> 22) & 0x1}`,
        `  retry_state       : ${(ctrlSummary >>> 21) & 0x1}`,
        `  retry_valid       : ${(ctrlSummary >>> 20) & 0x1}`,
        `  retry_recovered   : ${(ctrlSummary >>> 19) & 0x1}`,
        `  retry_exhausted   : ${(ctrlSummary >>> 18) & 0x1}`,
        `  retry_count_lsb2  : ${(ctrlSummary >>> 16) & 0x3}`,
        `  read_word_count   : ${(ctrlSummary >>> 8) & 0xff}`,
        `  write_word_count  : ${ctrlSummary & 0xff}`,
      ];

  const handshakeLines = version >= 0x05
    ? [
        `0x38 HS_HANDSHAKE  = 0x${hex8(handshake)}`,
        `  magic             : 0x${((handshake >>> 24) & 0xff).toString(16).toUpperCase().padStart(2, "0")}`,
        `  cmd_en            : ${(handshake >>> 23) & 0x1}`,
        `  cmd               : ${hsCmdName((handshake >>> 20) & 0x7)} (0b${(((handshake >>> 20) & 0x7).toString(2).padStart(3, "0"))})`,
        `  cmd_ack           : ${(handshake >>> 19) & 0x1}`,
        `  read_sample_valid : ${(handshake >>> 18) & 0x1}`,
        `  init_done         : ${(handshake >>> 17) & 0x1}`,
        `  host_busy         : ${(handshake >>> 16) & 0x1}`,
        `  test_active       : ${(handshake >>> 15) & 0x1}`,
        `  test_pass         : ${(handshake >>> 14) & 0x1}`,
        `  test_fail         : ${(handshake >>> 13) & 0x1}`,
        `  sampled_addr_low  : 0x${(handshake & 0x1fff).toString(16).toUpperCase().padStart(4, "0")}`,
      ]
    : [
        `0x38 HANDSHAKE      = 0x${hex8(handshake)}`,
        `  magic             : 0x${((handshake >>> 24) & 0xff).toString(16).toUpperCase().padStart(2, "0")}`,
        `  busy_n            : ${(handshake >>> 23) & 0x1}`,
        `  rd_valid          : ${(handshake >>> 22) & 0x1}`,
        `  wrd_ack           : ${(handshake >>> 21) & 0x1}`,
        `  init_done         : ${(handshake >>> 20) & 0x1}`,
        `  test_active       : ${(handshake >>> 19) & 0x1}`,
        `  test_pass         : ${(handshake >>> 18) & 0x1}`,
        `  test_fail         : ${(handshake >>> 17) & 0x1}`,
        `  host_busy         : ${(handshake >>> 16) & 0x1}`,
        `  sampled_addr      : 0x${(handshake & 0xffff).toString(16).toUpperCase().padStart(4, "0")}`,
      ];

  const lines = [
    `Base: 0x00000  Size: ${STATUS_BYTE_COUNT} bytes  Mode: status + write-only control`,
    "Control: SW 0003C 00000001 resets SDRC and reruns selftest",
    "",
    `0x00 SUMMARY        = 0x${hex8(summary)}`,
    `  map_version       : 0x${version.toString(16).toUpperCase().padStart(2, "0")}`,
    `  memtest_state     : ${statusStateName(state, version)} (0x${state.toString(16).toUpperCase().padStart(2, "0")})`,
    `  fail_reason       : ${statusFailReasonName(reason)} (0x${reason.toString(16).toUpperCase().padStart(2, "0")})`,
    `  host_busy         : ${(summary >>> 7) & 0x1}`,
    `  test_active       : ${(summary >>> 6) & 0x1}`,
    `  test_pass         : ${(summary >>> 5) & 0x1}`,
    `  test_fail         : ${(summary >>> 4) & 0x1}`,
    `  init_done         : ${(summary >>> 3) & 0x1}`,
    `  sdrc_reset_active : ${(summary >>> 2) & 0x1}`,
    "",
    `0x04 MEM_SUMMARY    = 0x${hex8(memSummary)}`,
    `  burst_base_idx    : ${(memSummary >>> 24) & 0xff} (0x${(((memSummary >>> 24) & 0xff).toString(16).toUpperCase().padStart(2, "0"))})`,
    `  read_words_seen   : ${(memSummary >>> 16) & 0xff}`,
    `  write_word_count  : ${(memSummary >>> 8) & 0xff}`,
    `  cycle_count       : ${memSummary & 0xff}`,
    "",
    `0x08 CURRENT_ADDR   = 0x${hex8(currentAddr)}`,
    `0x0C EXPECTED_WORD  = 0x${hex8(expectedWord)}`,
    `0x10 LAST_READ      = 0x${hex8(lastRead)}`,
    `0x14 LAST_STATUS    = 0x${hex8(lastStatus)}`,
    ...lastStatusLines,
    "",
    `0x18 FAIL_ADDR      = 0x${hex8(failAddr)}`,
    `0x1C FAIL_EXPECTED  = 0x${hex8(failExpected)}`,
    `0x20 FAIL_ACTUAL    = 0x${hex8(failActual)}`,
    "",
    `0x24 RETRY_SUMMARY  = 0x${hex8(retrySummary)}`,
    `  retry_limit       : ${(retrySummary >>> 24) & 0xff}`,
    `  retries_used      : ${(retrySummary >>> 16) & 0xff}`,
    `  total_attempts    : ${(retrySummary >>> 8) & 0xff}`,
    `  recovered         : ${(retrySummary >>> 7) & 0x1}`,
    `  exhausted         : ${(retrySummary >>> 6) & 0x1}`,
    `  valid             : ${(retrySummary >>> 5) & 0x1}`,
    `  fail_reason       : ${statusFailReasonName(retrySummary & 0x1f)}`,
    `0x28 RETRY_DATA1    = 0x${hex8(retryData1)}`,
    `0x2C RETRY_DATA2    = 0x${hex8(retryData2)}`,
    "",
    `0x30 CTRL_SUMMARY   = 0x${hex8(ctrlSummary)}`,
    `  state             : ${statusStateName(ctrlState, version)} (0x${ctrlState.toString(16).toUpperCase()})`,
    ...ctrlSummaryLines,
    `0x34 CTRL_DETAIL    = 0x${hex8(ctrlDetail)}`,
    "",
    ...handshakeLines,
    "",
    `0x3C LATEST_RD_DATA = 0x${hex8(latestRd)}`,
    "",
    `0x48 HS_REFRESH     = 0x${hex8(refreshStatus)}`,
    `  magic             : 0x${((refreshStatus >>> 24) & 0xff).toString(16).toUpperCase().padStart(2, "0")}`,
    `  pending           : ${(refreshStatus >>> 23) & 0x1}`,
    `  active            : ${(refreshStatus >>> 22) & 0x1}`,
    `  cmd_sent          : ${(refreshStatus >>> 21) & 0x1}`,
    `  can_start         : ${(refreshStatus >>> 20) & 0x1}`,
    `  pair_active       : ${(refreshStatus >>> 19) & 0x1}`,
    `  client_ready      : ${(refreshStatus >>> 18) & 0x1}`,
    `  defer_count       : ${(refreshStatus >>> 8) & 0xff}`,
    `  interval_count_lsb: ${refreshStatus & 0xff}`,
    "",
    "Raw words:",
  ];

  for (let offset = 0; offset < STATUS_BYTE_COUNT; offset += 4) {
    lines.push(`  0x${offset.toString(16).toUpperCase().padStart(2, "0")}: 0x${hex8(statusWord(bytes, offset))}`);
  }
  return lines.join("\n");
}

export function parseU21(text: string) {
  const value = Number.parseInt(text, 0);
  if (!Number.isFinite(value) || value < 0 || value > SDRAM_MAX_WORD_ADDR) {
    throw new Error(`out of range u21 addr: ${text}`);
  }
  return value;
}

export function parseU32(text: string) {
  const value = Number.parseInt(text, 0);
  if (!Number.isFinite(value) || value < 0 || value > 0xffff_ffff) {
    throw new Error(`out of range u32: ${text}`);
  }
  return u32(value);
}

export function parseEepromAddr(text: string) {
  const value = Number.parseInt(text, 0);
  if (!Number.isFinite(value) || value < 0 || value > EEPROM_MAX_ADDR) {
    throw new Error(`out of range EEPROM addr: ${text}`);
  }
  return value;
}

export function parseRgb888(text: string) {
  const normalized = text.trim().replace(/^0x/i, "");
  if (!/^[0-9a-fA-F]{6}$/.test(normalized)) {
    throw new Error("expected exactly 6 hex digits");
  }
  return Number.parseInt(normalized, 16);
}

export function parseDataByte(text: string) {
  const value = Number.parseInt(text, 0);
  if (!Number.isFinite(value) || value < 0 || value > 0xff) {
    throw new Error(`out of range EEPROM data byte: ${text}`);
  }
  return value;
}

export function validateSdramBulkRange(addr: number, words: number) {
  if (addr < 0 || addr > SDRAM_MAX_WORD_ADDR) {
    throw new Error(`bulk addr out of range: 0x${addr.toString(16).toUpperCase()}`);
  }
  if (words < 1 || words > MAX_BULK_WORD_COUNT) {
    throw new Error(`bulk words out of range 1..${MAX_BULK_WORD_COUNT}: ${words}`);
  }
  if (addr + words - 1 > SDRAM_MAX_WORD_ADDR) {
    throw new Error("bulk range exceeds SDRAM address space");
  }
}

export function validateEepromBulkRange(addr: number, byteCount: number) {
  if (addr < 0 || addr > EEPROM_MAX_ADDR) {
    throw new Error(`bulk addr out of range: 0x${addr.toString(16).toUpperCase()}`);
  }
  if (byteCount < 1 || byteCount > EEPROM_MAX_ADDR) {
    throw new Error(`bulk byte count out of range 1..${EEPROM_MAX_ADDR}: ${byteCount}`);
  }
  if (addr + byteCount - 1 > EEPROM_MAX_ADDR) {
    throw new Error("bulk range exceeds EEPROM address space");
  }
}

export function paddedWordCount(byteLen: number) {
  if (byteLen < 0) {
    throw new Error(`negative byte length: ${byteLen}`);
  }
  return Math.ceil(byteLen / 4);
}

export function buildReadCommand(addr: number) {
  return asciiCommand("R", addr);
}

export function buildStatusReadCommand(addr: number) {
  return asciiCommand("SR", addr);
}

export function buildWriteCommand(addr: number, data: number) {
  return asciiCommand("W", addr, data);
}

export function buildStatusWriteCommand(addr: number, data: number) {
  return asciiCommand("SW", addr, data);
}

export function buildBulkReadCommand(addr: number, words: number) {
  return asciiCommand("BR", addr, words);
}

export function buildBulkWriteCommand(addr: number, words: number) {
  return asciiCommand("BW", addr, words);
}

export function buildBurstTestReadCommand(addr: number, words: number) {
  return asciiCommand("BRT", addr, words);
}

export function buildBurstTestWriteCommand(addr: number, words: number) {
  return asciiCommand("BWT", addr, words);
}

export function buildEepromReadCommand(addr: number) {
  return eepromAsciiCommand("R", addr);
}

export function buildEepromWriteCommand(addr: number, data: number) {
  return eepromAsciiCommand("W", addr, data);
}

export function buildEepromBulkReadCommand(addr: number, byteCount: number) {
  return eepromAsciiCommand("BR", addr, byteCount);
}

export function buildEepromBulkWriteCommand(addr: number, byteCount: number) {
  return eepromAsciiCommand("BW", addr, byteCount);
}

export function buildDisplayInitCommand() {
  return Buffer.from("I\n", "ascii");
}

export function buildDisplayClearCommand() {
  return Buffer.from("C\n", "ascii");
}

export function buildDisplayPatternCommand() {
  return Buffer.from("R\n", "ascii");
}

export function buildDisplayOnCommand() {
  return Buffer.from("O\n", "ascii");
}

export function buildDisplayOffCommand() {
  return Buffer.from("X\n", "ascii");
}

export function buildDisplayFillCommand(rgb888: number) {
  return Buffer.from(`F${Math.min(60, Math.max(1, rgb888 | 0))}\n`, "ascii");
}

export function buildDisplayRefreshCommand() {
  return Buffer.from("R\n", "ascii");
}

export function buildDisplayAutoOnCommand() {
  return Buffer.from("E\n", "ascii");
}

export function buildDisplayAutoOffCommand() {
  return Buffer.from("D\n", "ascii");
}

export function buildDisplaySetFpsCommand(fps: number) {
  if (fps < 1 || fps > 60) {
    throw new Error(`fps must be in range 1..60, got ${fps}`);
  }
  return Buffer.from(`F${fps}\n`, "ascii");
}

export function buildDisplayCheckerFrame() {
  const frame = Buffer.alloc(SSD1306_FRAME_BYTES, 0x00);
  for (let page = 0; page < 4; page += 1) {
    for (let column = 0; column < 128; column += 1) {
      frame[(page * 128) + column] = ((page + column) & 1) === 0 ? 0xaa : 0x55;
    }
  }
  return frame;
}

export function buildDisplayMonoFillFrame(on: boolean) {
  return Buffer.alloc(SSD1306_FRAME_BYTES, on ? 0xff : 0x00);
}

export function buildPatternBlob(pattern: number, words: number) {
  validateSdramBulkRange(0, words);
  const payload = Buffer.alloc(words * 4);
  for (let idx = 0; idx < words; idx += 1) {
    payload.writeUInt32LE(u32(pattern), idx * 4);
  }
  return payload;
}

export function iterBulkWriteBlocks(blob: Uint8Array) {
  const blocks: Buffer[] = [];
  let seq = 0;
  for (let offset = 0; offset < blob.length; offset += MAX_BULK_WRITE_CHUNK_BYTES) {
    let payload = Buffer.from(blob.slice(offset, offset + MAX_BULK_WRITE_CHUNK_BYTES));
    if (payload.length % 4 !== 0) {
      payload = Buffer.concat([payload, Buffer.alloc(4 - (payload.length % 4))]);
    }
    blocks.push(stuffLiteralBytes(buildBulkBlock(BULK_WR_DATA, seq, payload)));
    seq = (seq + 1) & 0xff;
  }
  blocks.push(stuffLiteralBytes(buildBulkBlock(BULK_WR_END, seq, new Uint8Array(0))));
  return blocks;
}

export function buildBulkAbortBlock(seq: number) {
  return stuffLiteralBytes(buildBulkBlock(BULK_ABORT, seq, new Uint8Array(0)));
}

export function decodeBurstDataPacket(arg0: number, arg1: number, arg2: number): BurstDataPacket {
  const validWordCount = arg0 & 0xff;
  const words: number[] = [];
  if (validWordCount >= 1) {
    words.push(u32(arg1));
  }
  if (validWordCount >= 2) {
    words.push(u32(arg2));
  }
  return {
    packetId: (arg0 >>> 24) & 0xff,
    packetCount: (arg0 >>> 16) & 0xff,
    firstWordIndex: (arg0 >>> 8) & 0xff,
    validWordCount,
    words,
  };
}

export function decodeBulkReadProgress(arg0: number, arg1: number, arg2: number): BulkReadProgress {
  const validWordCount = (arg0 >>> 21) & 0x3;
  if (![1, 2].includes(validWordCount)) {
    throw new Error(`invalid bulk read word count in arg0: 0x${hex8(arg0)}`);
  }
  return {
    baseAddr: arg0 & SDRAM_MAX_WORD_ADDR,
    validWordCount,
    words: validWordCount === 2 ? [u32(arg1), u32(arg2)] : [u32(arg1)],
  };
}

export function decodeEepromBulkReadProgress(arg0: number, arg1: number, arg2: number): EepromBulkReadProgress {
  const validByteCount = (arg0 >>> 17) & 0xff;
  if (validByteCount < 1 || validByteCount > 8) {
    throw new Error(`invalid bulk read byte count in arg0: 0x${hex8(arg0)}`);
  }
  const combined = Buffer.concat([u32ToBytes(arg1), u32ToBytes(arg2)]);
  return {
    baseAddr: arg0 & EEPROM_MAX_ADDR,
    validByteCount,
    data: combined.subarray(0, validByteCount),
  };
}

export async function loadBulkFile(path: string) {
  const suffix = extname(path).toLowerCase();
  if (![".bin", ".hex"].includes(suffix)) {
    throw new Error(`unsupported file format: ${suffix}`);
  }
  if (suffix === ".bin") {
    return new Uint8Array(await readFile(path));
  }
  const rawText = await readFile(path, "utf8");
  const hexDigits = rawText.split("").filter((char) => /[0-9a-fA-F]/.test(char));
  if (hexDigits.length % 2 !== 0) {
    throw new Error("hex file contains an odd number of digits");
  }
  return new Uint8Array(Buffer.from(hexDigits.join(""), "hex"));
}

export async function saveBulkFile(path: string, blob: Uint8Array) {
  const suffix = extname(path).toLowerCase();
  if (![".bin", ".hex"].includes(suffix)) {
    throw new Error(`unsupported file format: ${suffix}`);
  }
  await mkdir(new URL(".", `file://${path.replace(/\\/g, "/")}`), { recursive: true }).catch(() => undefined);
  if (suffix === ".bin") {
    await writeFile(path, blob);
    return;
  }
  const lineWidth = 32;
  const lines: string[] = [];
  for (let idx = 0; idx < blob.length; idx += lineWidth) {
    lines.push(Buffer.from(blob.slice(idx, idx + lineWidth)).toString("hex").toUpperCase());
  }
  await writeFile(path, `${lines.join("\n")}${lines.length ? "\n" : ""}`, "utf8");
}

export function parseReplayLog(logText: string) {
  const records: ReplayRecord[] = [];
  const lineRe = /^(?<date>\d{4}-\d{2}-\d{2}) (?<time>\d{2}:\d{2}:\d{2}\.\d{3}) mode=(?<mode>[A-Z]+) seq=0x(?<seq>[0-9A-Fa-f]{2}) src=0x(?<src>[0-9A-Fa-f]{2}) evt=0x(?<evt>[0-9A-Fa-f]{2}) ts=(?<ts>\d+) arg0=0x(?<arg0>[0-9A-Fa-f]{8}) arg1=0x(?<arg1>[0-9A-Fa-f]{8}) arg2=0x(?<arg2>[0-9A-Fa-f]{8}) crc=(?<crc>[A-Z]+) lost=(?<lost>\d+) msg=(?<msg>.*)$/;
  for (const line of logText.split(/\r?\n/)) {
    const match = lineRe.exec(line.trim());
    if (!match?.groups) {
      continue;
    }
    records.push({
      hostTime: match.groups.time,
      seq: Number.parseInt(match.groups.seq, 16),
      lostCount: Number.parseInt(match.groups.lost, 10),
      event: {
        srcId: Number.parseInt(match.groups.src, 16),
        eventId: Number.parseInt(match.groups.evt, 16),
        timestamp: Number.parseInt(match.groups.ts, 10),
        arg0: Number.parseInt(match.groups.arg0, 16),
        arg1: Number.parseInt(match.groups.arg1, 16),
        arg2: Number.parseInt(match.groups.arg2, 16),
      },
    });
  }
  return records;
}

export function buildLogLine(stored: StoredEvent, mode: DisplayMode, decoder: RuleDecoder) {
  const decoded = decoder.decode(stored.event);
  const message = mode === "decode" ? `${decoded.title}: ${decoded.message}` : fallbackMessage(stored.event);
  const hostTime = stored.hostTime ?? formatHostTime();
  const now = new Date();
  const dateText = `${now.getFullYear()}-${`${now.getMonth() + 1}`.padStart(2, "0")}-${`${now.getDate()}`.padStart(2, "0")}`;
  return `${dateText} ${hostTime} mode=${mode.toUpperCase()} seq=0x${stored.seq.toString(16).toUpperCase().padStart(2, "0")} src=0x${stored.event.srcId.toString(16).toUpperCase().padStart(2, "0")} evt=0x${stored.event.eventId.toString(16).toUpperCase().padStart(2, "0")} ts=${stored.event.timestamp} arg0=0x${hex8(stored.event.arg0)} arg1=0x${hex8(stored.event.arg1)} arg2=0x${hex8(stored.event.arg2)} crc=OK lost=${stored.lostCount} msg=${message}`;
}

function crc8Atm(data: Uint8Array) {
  let crc = 0;
  for (const byte of data) {
    crc = crc8AtmUpdate(crc, byte);
  }
  return crc;
}

function crc8AtmUpdate(crcIn: number, dataByte: number) {
  let crc = (crcIn ^ dataByte) & 0xff;
  for (let idx = 0; idx < 8; idx += 1) {
    crc = crc & 0x80 ? ((crc << 1) ^ 0x07) & 0xff : (crc << 1) & 0xff;
  }
  return crc;
}

function decodeEventPayload(payload: Uint8Array): UartEvent {
  return {
    timestamp: payload[0] | (payload[1] << 8),
    eventId: payload[2],
    srcId: payload[3],
    arg0: bytesToU32(payload.slice(4, 8)),
    arg1: bytesToU32(payload.slice(8, 12)),
    arg2: bytesToU32(payload.slice(12, 16)),
  };
}

function normalizeRule(raw: unknown): DecoderRule {
  if (!raw || typeof raw !== "object") {
    throw new Error("rule body must be a mapping");
  }
  const value = raw as Record<string, unknown>;
  const tagsRaw = value.tags;
  return {
    level: `${value.level ?? "INFO"}`.toUpperCase() as DecodedEvent["level"],
    title: `${value.title ?? ""}`,
    message: `${value.message ?? ""}`,
    tags: Array.isArray(tagsRaw) ? tagsRaw.map((entry) => `${entry}`) : tagsRaw ? [`${tagsRaw}`] : [],
    decode: `${value.decode ?? ""}`,
  };
}

function parseRuleToken(token: string) {
  if (token === "*") {
    return null;
  }
  const value = Number.parseInt(token, 0);
  if (!Number.isFinite(value) || value < 0 || value > 0xff) {
    throw new Error(`token out of 8-bit range: ${token}`);
  }
  return value;
}

function buildDecodeContext(event: UartEvent) {
  return {
    src_id: event.srcId,
    event_id: event.eventId,
    timestamp: event.timestamp,
    arg0: u32(event.arg0),
    arg1: u32(event.arg1),
    arg2: u32(event.arg2),
    arg0_u32: u32(event.arg0),
    arg1_u32: u32(event.arg1),
    arg2_u32: u32(event.arg2),
    arg0_u8: event.arg0 & 0xff,
    arg1_u8: event.arg1 & 0xff,
    arg2_u8: event.arg2 & 0xff,
    arg0_hex: hex8(event.arg0),
    arg1_hex: hex8(event.arg1),
    arg2_hex: hex8(event.arg2),
  } as Record<string, string | number>;
}

function applyDecodeMode(modeText: string, event: UartEvent, context: Record<string, string | number>) {
  const mode = modeText.toLowerCase();
  if (mode === "help_ascii") {
    const raw = Buffer.concat([u32ToBytes(event.arg0), u32ToBytes(event.arg1), u32ToBytes(event.arg2)]);
    const zeroIdx = raw.indexOf(0x00);
    const sliced = zeroIdx >= 0 ? raw.subarray(0, zeroIdx) : raw;
    context.help_ascii = Array.from(sliced, (value) => (value >= 32 && value < 127 ? String.fromCharCode(value) : ".")).join("");
  }
}

function safeFormat(template: string, context: Record<string, string | number>) {
  return template.replace(PLACEHOLDER_PATTERN, (_full, key: string, formatText?: string) => {
    const value = resolvePlaceholder(key, context);
    if (value === undefined) {
      return `{${key}${formatText ? `:${formatText}` : ""}}`;
    }
    if (!formatText) {
      return `${value}`;
    }
    if (typeof value === "number") {
      try {
        return formatNumber(value, formatText);
      } catch {
        return `${value}`;
      }
    }
    return `${value}`;
  });
}

function resolvePlaceholder(key: string, context: Record<string, string | number>) {
  if (key in context) {
    return context[key];
  }
  const byteMatch = /^(arg[0-2])_b([0-3])$/.exec(key);
  if (byteMatch) {
    const word = Number(context[byteMatch[1]] ?? 0);
    return (word >>> (Number(byteMatch[2]) * 8)) & 0xff;
  }
  const bitMatch = /^(arg[0-2])_bit(\d|[12]\d|3[01])$/.exec(key);
  if (bitMatch) {
    const word = Number(context[bitMatch[1]] ?? 0);
    return (word >>> Number(bitMatch[2])) & 0x1;
  }
  return undefined;
}

function formatNumber(value: number, formatText: string) {
  if (/^[0-9]*[Xx]$/.test(formatText)) {
    const width = Number.parseInt(formatText.slice(0, -1) || "0", 10);
    return value.toString(16).toUpperCase().padStart(width, "0");
  }
  return `${value}`;
}

function fallbackMessage(event: UartEvent) {
  return `src=${event.srcId} evt=${event.eventId} ts=${event.timestamp} arg0=${u32(event.arg0)} arg1=${u32(event.arg1)} arg2=${u32(event.arg2)}`;
}

function asciiCommand(command: string, ...fields: number[]) {
  const parts = [command];
  fields.forEach((field, index) => {
    if (["BR", "BW", "BRT", "BWT"].includes(command) && index < 2) {
      parts.push(field.toString(16).toUpperCase().padStart(5, "0"));
    } else if (["W", "SW"].includes(command) && index === 1) {
      parts.push(hex8(field));
    } else {
      parts.push(field.toString(16).toUpperCase().padStart(5, "0"));
    }
  });
  return Buffer.from(`${parts.join(" ")}\n`, "ascii");
}

function eepromAsciiCommand(command: string, ...fields: number[]) {
  const parts = [command];
  fields.forEach((field, index) => {
    if (index === 0 || ["BR", "BW"].includes(command)) {
      parts.push(field.toString(16).toUpperCase().padStart(5, "0"));
    } else {
      parts.push((field & 0xff).toString(16).toUpperCase().padStart(2, "0"));
    }
  });
  return Buffer.from(`${parts.join(" ")}\n`, "ascii");
}

function buildBulkBlock(blockType: number, seq: number, payload: Uint8Array) {
  if (payload.length > MAX_BULK_PAYLOAD_BYTES) {
    throw new Error(`payload too large: ${payload.length}`);
  }
  const header = Buffer.from([
    BULK_SOF0,
    BULK_SOF1,
    blockType & 0xff,
    seq & 0xff,
    payload.length & 0xff,
    (payload.length >>> 8) & 0xff,
  ]);
  const crc = crc16CcittFalse(Buffer.concat([header.subarray(2), Buffer.from(payload)]));
  return Buffer.concat([header, Buffer.from(payload), Buffer.from([crc & 0xff, (crc >>> 8) & 0xff])]);
}

function stuffLiteralBytes(data: Uint8Array) {
  const stuffed: number[] = [];
  Array.from(data).forEach((value) => {
    if (CLI_LITERAL_BYTES.has(value)) {
      stuffed.push(CMD_LITERAL_NEXT);
    }
    stuffed.push(value);
  });
  return Buffer.from(stuffed);
}

function crc16CcittFalse(data: Uint8Array) {
  let crc = 0xffff;
  for (const value of data) {
    crc ^= (value & 0xff) << 8;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc;
}

function padBytes(bytes: Uint8Array, targetLength: number) {
  const padded = new Uint8Array(targetLength);
  padded.set(bytes.slice(0, targetLength));
  return padded;
}

function padStatusBytes(bytes: Uint8Array) {
  return bytes.length >= STATUS_BYTE_COUNT ? bytes.slice(0, STATUS_BYTE_COUNT) : padBytes(bytes, STATUS_BYTE_COUNT);
}

function statusWord(statusBytes: Uint8Array, offset: number) {
  return bytesToU32(statusBytes.slice(offset, offset + 4));
}

function statusStateName(state: number, version = 0x05) {
  const legacy: Record<number, string> = {
    0x0: "IDLE",
    0x1: "WRITE_WAIT",
    0x2: "WRITE_REQ",
    0x3: "WRITE_RUN",
    0x4: "READ_WAIT",
    0x5: "READ_REQ",
    0x6: "READ_RUN",
    0x7: "RETRY_WAIT",
    0x8: "RETRY_REQ",
    0x9: "RETRY_RUN",
    0xa: "CLEAR_WAIT",
    0xb: "CLEAR_REQ",
    0xc: "CLEAR_RUN",
    0xd: "PASS",
    0xe: "FAIL",
  };
  const modern: Record<number, string> = {
    0x0: "IDLE",
    0x1: "POST_INIT",
    0x2: "WRITE_WAIT",
    0x3: "WRITE_ACTIVE_REQ",
    0x4: "WRITE_ACTIVE_ACK",
    0x5: "WRITE_REQ",
    0x6: "WRITE_ACK",
    0x7: "READ_GAP",
    0x8: "READ_ACTIVE_REQ",
    0x9: "READ_ACTIVE_ACK",
    0xa: "READ_REQ",
    0xb: "READ_SAMPLE",
    0xc: "RETRY_WAIT",
    0xd: "RETRY_ACTIVE_REQ",
    0xe: "RETRY_ACTIVE_ACK",
    0xf: "RETRY_READ_REQ",
    0x10: "RETRY_SAMPLE",
    0x11: "CLEAR_WAIT",
    0x12: "CLEAR_ACTIVE_REQ",
    0x13: "CLEAR_ACTIVE_ACK",
    0x14: "CLEAR_REQ",
    0x15: "CLEAR_ACK",
    0x16: "PASS",
    0x17: "FAIL",
  };
  return (version < 0x05 ? legacy : modern)[state] ?? `STATE_${state.toString(16).toUpperCase().padStart(2, "0")}`;
}

function statusFailReasonName(reason: number) {
  return {
    0x00: "NONE",
    0x01: "TIMEOUT",
    0x02: "PAGE_CROSS",
    0x03: "MISMATCH",
  }[reason] ?? `REASON_${reason.toString(16).toUpperCase().padStart(2, "0")}`;
}

function hsCmdName(cmd: number) {
  return {
    0b000: "LOAD_MODE",
    0b001: "AUTO_REFRESH",
    0b010: "PRECHARGE",
    0b011: "ACTIVE",
    0b100: "WRITE",
    0b101: "READ",
    0b110: "BURST_TERMINATE",
    0b111: "NOP",
  }[cmd & 0x7] ?? `CMD_${(cmd & 0x7).toString(16).toUpperCase()}`;
}

function bytesToU32(bytes: Uint8Array) {
  const view = Buffer.alloc(4);
  view.set(bytes.slice(0, 4));
  return view.readUInt32LE(0);
}

function u32ToBytes(value: number) {
  const out = Buffer.alloc(4);
  out.writeUInt32LE(u32(value), 0);
  return out;
}

function hex8(value: number) {
  return u32(value).toString(16).toUpperCase().padStart(8, "0");
}

function u32(value: number) {
  return value >>> 0;
}