import { appendFile, mkdir, readFile } from "node:fs/promises";
import net from "node:net";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

import { SerialPort } from "serialport";

import {
  buildBulkAbortBlock,
  buildBulkReadCommand,
  buildBulkWriteCommand,
  buildBurstTestReadCommand,
  buildBurstTestWriteCommand,
  buildDisplayAutoOffCommand,
  buildDisplayAutoOnCommand,
  buildDisplayCheckerFrame,
  buildDisplayClearCommand,
  buildDisplayInitCommand,
  buildDisplayOffCommand,
  buildDisplayOnCommand,
  buildDisplayMonoFillFrame,
  buildDisplayRefreshCommand,
  buildDisplaySetFpsCommand,
  buildEepromBulkReadCommand,
  buildEepromBulkWriteCommand,
  buildEepromReadCommand,
  buildEepromWriteCommand,
  buildLogLine,
  buildLogRow,
  buildPatternBlob,
  buildReadCommand,
  buildStatusReadCommand,
  buildStatusWriteCommand,
  buildWriteCommand,
  CMD_NEXT_SRC,
  CMD_SOFT_RESET,
  decodeBulkReadProgress,
  decodeBurstDataPacket,
  decodeEepromBulkReadProgress,
  DISPLAY_FRAMEBUFFER_BASE_ADDR,
  DISPLAY_HOST_SRC_ID,
  DISPLAY_SRC_INDEX,
  DISP_OP_AUTO_OFF,
  DISP_OP_AUTO_ON,
  DISP_OP_CLEAR,
  DISP_OP_INIT,
  DISP_OP_OFF,
  DISP_OP_ON,
  DISP_OP_REFRESH,
  DISP_OP_SET_FPS,
  EEPROM_HOST_SRC_ID,
  EEPROM_MAP_BYTE_COUNT,
  EVT_CMD_ACK,
  EVT_CMD_ERR,
  formatEepromMapText,
  formatHostTime,
  formatMapText,
  formatStatusRawText,
  formatStatusText,
  FrameParser,
  HOST_EVT_BULK_ABORT,
  HOST_EVT_BULK_DONE,
  HOST_EVT_BULK_ERR,
  HOST_EVT_BULK_OK,
  HOST_EVT_BULK_PROGRESS,
  HOST_EVT_BURST_DATA,
  HOST_EVT_BURST_DONE,
  HOST_EVT_BURST_ERR,
  HOST_EVT_CMD_ERR,
  HOST_EVT_READ_RSP,
  HOST_EVT_WRITE_ACK,
  HOST_SRC_INDEX,
  iterBulkWriteBlocks,
  loadBulkFile,
  loadDecoderFromYaml,
  MAP_BYTE_COUNT,
  MAP_WORD_COUNT,
  parseDataByte,
  parseEepromAddr,
  parseReplayLog,
  parseRgb888,
  parseU21,
  parseU32,
  paddedWordCount,
  RuleDecoder,
  SDRAM_HOST_SRC_ID,
  SSD1306_FRAME_BYTES,
  STATUS_BYTE_COUNT,
  SYS_EVT_MODE_CHANGE,
  SYS_SRC_ID,
  UART_LOG_NUM_SRC,
  validateEepromBulkRange,
  validateSdramBulkRange,
} from "@/lib/workbench/protocol";
import type {
  ConnectPayload,
  EepromRwState,
  PortInfo,
  ReplayRecord,
  RwState,
  SessionSnapshot,
  StatusViewMode,
  StoredEvent,
  TransportMode,
  UartFrame,
  WorkbenchSnapshot,
} from "@/lib/workbench/types";

const DEFAULT_DECODER = "c:/Electronics/GitHubProjects/tangnano20k_dev/11_app/uart_log_tool/debug_log_tool/decode_rules.default.yaml";
const DEFAULT_TCP_HOST = "192.168.10.40";
const DEFAULT_TCP_PORT = 2323;
const DEFAULT_BAUD = 115200;
const ROW_LIMIT = 2000;

export class WorkbenchService {
  private transport: TransportMode = "tcp";
  private mode: SessionSnapshot["mode"] = "decode";
  private statusMode: StatusViewMode = "decode";
  private port: string | null = null;
  private baud = DEFAULT_BAUD;
  private tcpHost = DEFAULT_TCP_HOST;
  private tcpPort = DEFAULT_TCP_PORT;
  private replayPath: string | null = null;
  private selectedSrcIdx = 0;
  private statusLine = "idle";
  private decoderPath = DEFAULT_DECODER;
  private decoder = RuleDecoder.fromMapping({ default: { level: "INFO", title: "EVENT", message: "", tags: [] } });
  private decoderLoaded = false;
  private decoderError: string | null = null;
  private decoderMtime = 0;
  private logEnabled = false;
  private logFilePath: string | null = null;
  private replayFinished = false;
  private replayLoadError: string | null = null;
  private busy = false;

  private serial: SerialPort | null = null;
  private socket: net.Socket | null = null;
  private parser = new FrameParser();
  private pendingFrames: UartFrame[] = [];
  private rows: StoredEvent[] = [];
  private replayRecords: ReplayRecord[] = [];
  private replayIndex = 0;
  private replayTimer: NodeJS.Timeout | null = null;

  private mapBaseAddr = 0;
  private mapBytes = new Uint8Array(MAP_BYTE_COUNT);
  private mapSummary = "idle";

  private statusBytes = new Uint8Array(STATUS_BYTE_COUNT);
  private statusSummary = "idle";

  private rwState: RwState = {
    summary: "idle",
    singleReadResult: "-",
    singleWriteResult: "-",
    fileWriteResult: "-",
  };

  private burstSummary = "idle";
  private burstResult = "-";
  private burstPreview = "-";
  private burstBaseAddr = 0;
  private burstWords = 0;
  private burstTask = "-";
  private burstPackets = 0;
  private burstPacketsReceived = 0;

  private eepromMapBaseAddr = 0;
  private eepromMapBytes = new Uint8Array(EEPROM_MAP_BYTE_COUNT);
  private eepromMapSummary = "idle";

  private eepromRwState: EepromRwState = {
    summary: "idle",
    singleReadResult: "-",
    singleWriteResult: "-",
    fileWriteResult: "-",
  };

  private displaySummary = "idle";

  private ssd1306Framebytes = new Uint8Array(SSD1306_FRAME_BYTES);
  private ssd1306Summary = "idle";

  constructor() {
    void this.reloadDecoder(true);
  }

  async listPorts(): Promise<PortInfo[]> {
    const ports = await SerialPort.list();
    return ports
      .map((item) => ({
        device: item.path,
        description: item.friendlyName ?? item.manufacturer ?? "",
        hwid: item.pnpId ?? item.serialNumber ?? "",
      }))
      .sort((left, right) => left.device.localeCompare(right.device));
  }

  async connect(payload: ConnectPayload) {
    await this.disconnect();

    this.transport = payload.transport;
    this.mode = payload.mode ?? this.mode;
    this.decoderPath = payload.decoderPath ?? this.decoderPath;
    this.port = payload.port ?? this.port;
    this.baud = payload.baud ?? this.baud;
    this.tcpHost = payload.tcpHost ?? this.tcpHost;
    this.tcpPort = payload.tcpPort ?? this.tcpPort;
    this.replayPath = payload.replayPath ?? null;
    this.selectedSrcIdx = 0;
    this.parser.reset();
    this.pendingFrames = [];
    this.replayFinished = false;
    this.replayLoadError = null;
    this.statusLine = "connecting...";

    await this.reloadDecoder(true);

    if (payload.logFilePath) {
      await this.enableLogging(payload.logFilePath);
    }

    if (payload.transport === "serial") {
      if (!this.port) {
        throw new Error("serial port is required");
      }
      await this.openSerial();
      this.statusLine = `serial connected: ${this.port} @ ${this.baud}`;
      return;
    }

    if (payload.transport === "tcp") {
      await this.openTcp();
      this.statusLine = `tcp connected: ${this.tcpHost}:${this.tcpPort}`;
      return;
    }

    if (!this.replayPath) {
      throw new Error("replay path is required");
    }
    const replayText = await readFile(this.replayPath, "utf8");
    this.replayRecords = parseReplayLog(replayText);
    this.replayIndex = 0;
    this.startReplay();
    this.statusLine = `replay loaded: ${this.replayRecords.length} events`;
  }

  async disconnect() {
    this.stopReplay();
    if (this.serial) {
      const port = this.serial;
      this.serial = null;
      port.removeAllListeners();
      if (port.isOpen) {
        await new Promise<void>((resolve) => port.close(() => resolve()));
      }
    }
    if (this.socket) {
      const socket = this.socket;
      this.socket = null;
      socket.removeAllListeners();
      socket.destroy();
    }
    this.statusLine = "disconnected";
  }

  getSnapshot(): WorkbenchSnapshot {
    void this.ensureDecoderFresh();
    return {
      session: {
        connected: this.isConnected(),
        transport: this.transport,
        mode: this.mode,
        statusMode: this.statusMode,
        port: this.port,
        baud: this.baud,
        tcpHost: this.tcpHost,
        tcpPort: this.tcpPort,
        replayPath: this.replayPath,
        selectedSrcIdx: this.selectedSrcIdx,
        statusLine: this.statusLine,
        decoderPath: this.decoderPath,
        decoderLoaded: this.decoderLoaded,
        decoderError: this.decoderError,
        logEnabled: this.logEnabled,
        logFilePath: this.logFilePath,
        replayFinished: this.replayFinished,
        replayLoadError: this.replayLoadError,
        busy: this.busy,
      },
      stats: {
        rxFrames: this.parser.validFrameCount,
        crcErrors: this.parser.crcErrorCount,
        lostEvents: this.parser.lostEventCount,
        tcpPackets: this.transport === "tcp" ? this.tcpPacketCount : 0,
        tcpBytes: this.transport === "tcp" ? this.tcpByteCount : 0,
        lastSeq: this.rows.length ? `0x${this.rows[this.rows.length - 1].seq.toString(16).toUpperCase().padStart(2, "0")}` : "-",
        totalRows: this.rows.length,
      },
      rows: this.rows.map((row) => buildLogRow(row, this.mode, this.decoder)),
      sdramMap: {
        baseAddr: this.mapBaseAddr,
        summary: this.mapSummary,
        text: formatMapText(this.mapBaseAddr, this.mapBytes),
      },
      sdramStatus: {
        summary: this.statusSummary,
        text: this.statusMode === "decode" ? formatStatusText(this.statusBytes) : formatStatusRawText(this.statusBytes),
      },
      sdramRw: this.rwState,
      sdramBurst: {
        summary: this.burstSummary,
        result: this.burstResult,
        preview: this.burstPreview,
        baseAddr: this.burstBaseAddr,
        words: this.burstWords,
        packetCount: this.burstPackets,
        packetsReceived: this.burstPacketsReceived,
        task: this.burstTask,
      },
      eepromMap: {
        baseAddr: this.eepromMapBaseAddr,
        summary: this.eepromMapSummary,
        text: formatEepromMapText(this.eepromMapBaseAddr, this.eepromMapBytes),
      },
      eepromRw: this.eepromRwState,
      display: {
        summary: this.displaySummary,
      },
      ssd1306: {
        summary: this.ssd1306Summary,
        framebytes: Array.from(this.ssd1306Framebytes),
      },
    };
  }

  async reloadDecoder(force = false) {
    try {
      const stats = await import("node:fs/promises").then((module) => module.stat(this.decoderPath));
      if (!force && stats.mtimeMs <= this.decoderMtime) {
        return;
      }
      this.decoder = await loadDecoderFromYaml(this.decoderPath);
      this.decoderLoaded = true;
      this.decoderError = null;
      this.decoderMtime = stats.mtimeMs;
      this.statusLine = `decoder loaded: ${this.decoderPath}`;
    } catch (error) {
      this.decoderLoaded = false;
      this.decoderError = error instanceof Error ? error.message : `${error}`;
      if (force) {
        throw error;
      }
    }
  }

  async toggleLog(logFilePath?: string | null) {
    if (this.logEnabled) {
      this.logEnabled = false;
      this.statusLine = "log disabled";
      return;
    }
    await this.enableLogging(logFilePath ?? null);
  }

  clearLogs() {
    this.rows = [];
    this.statusLine = "logs cleared";
  }

  sendReset() {
    this.ensureLiveTransport();
    return this.sendBytes(Buffer.from([CMD_SOFT_RESET]));
  }

  setMode(mode: SessionSnapshot["mode"]) {
    this.mode = mode;
    this.statusLine = `mode: ${mode}`;
  }

  toggleStatusMode() {
    this.statusMode = this.statusMode === "decode" ? "raw" : "decode";
    this.statusLine = `status mode: ${this.statusMode}`;
  }

  async refreshMap(baseAddr: number) {
    return this.runExclusive(async () => {
      validateSdramBulkRange(baseAddr, MAP_WORD_COUNT);
      this.mapBaseAddr = baseAddr;
      this.mapSummary = `refreshing 0x${baseAddr.toString(16).toUpperCase().padStart(5, "0")}`;
      this.statusLine = this.mapSummary;
      this.mapBytes.fill(0);
      const words = await this.executeSdramBulkRead(baseAddr, MAP_WORD_COUNT, (receivedCount) => {
        this.mapSummary = `bulk read words ${receivedCount}/${MAP_WORD_COUNT}`;
        this.statusLine = this.mapSummary;
      });

      for (let offset = 0; offset < MAP_WORD_COUNT; offset += 1) {
        const value = words.get(baseAddr + offset) ?? 0;
        const wordOffset = offset * 4;
        this.mapBytes[wordOffset + 0] = value & 0xff;
        this.mapBytes[wordOffset + 1] = (value >>> 8) & 0xff;
        this.mapBytes[wordOffset + 2] = (value >>> 16) & 0xff;
        this.mapBytes[wordOffset + 3] = (value >>> 24) & 0xff;
      }
      this.ensureBulkWordsComplete(words, baseAddr, MAP_WORD_COUNT, "SDRAM map refresh");

      this.mapSummary = `loaded 256 words from 0x${baseAddr.toString(16).toUpperCase().padStart(5, "0")}`;
      this.statusLine = this.mapSummary;
    });
  }

  async refreshStatus() {
    return this.runExclusive(async () => {
      await this.refreshStatusUnlocked();
    });
  }

  async runStatusSelftest() {
    return this.runExclusive(async () => {
      await this.selectSource(HOST_SRC_INDEX);
      this.dropPendingFrames(
        (frame) => frame.event.srcId === SDRAM_HOST_SRC_ID &&
          [HOST_EVT_WRITE_ACK, HOST_EVT_CMD_ERR, HOST_EVT_READ_RSP].includes(frame.event.eventId),
      );
      await this.sendBytes(buildStatusWriteCommand(0x0003c, 0x0000_0001));
      const frame = await this.waitForFrame(
        (candidate) => candidate.event.srcId === SDRAM_HOST_SRC_ID &&
          [HOST_EVT_WRITE_ACK, HOST_EVT_CMD_ERR].includes(candidate.event.eventId) &&
          (candidate.event.eventId !== HOST_EVT_WRITE_ACK || candidate.event.arg0 === 0x0003c),
        1000,
      );
      if (frame.event.eventId === HOST_EVT_CMD_ERR) {
        throw new Error(`selftest trigger failed: cmd_err 0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()}`);
      }
      this.assertAccessStatusOk(frame, "selftest trigger");
      this.statusLine = "selftest trigger acknowledged";
      await this.refreshStatusUnlocked();
    });
  }

  async singleRead(addr: number) {
    return this.runExclusive(async () => {
      await this.selectSource(HOST_SRC_INDEX);
      this.dropPendingFrames(
        (frame) => frame.event.srcId === SDRAM_HOST_SRC_ID &&
          [HOST_EVT_READ_RSP, HOST_EVT_CMD_ERR].includes(frame.event.eventId),
      );
      await this.sendBytes(buildReadCommand(addr));
      const frame = await this.waitForFrame(
        (candidate) => candidate.event.srcId === SDRAM_HOST_SRC_ID &&
          (
            (candidate.event.eventId === HOST_EVT_READ_RSP && candidate.event.arg0 === addr) ||
            candidate.event.eventId === HOST_EVT_CMD_ERR
          ),
        1000,
      );
      if (frame.event.eventId === HOST_EVT_CMD_ERR) {
        throw new Error(`single read failed: cmd_err 0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()}`);
      }
      this.assertAccessStatusOk(frame, `single read 0x${addr.toString(16).toUpperCase().padStart(5, "0")}`);
      this.rwState.singleReadResult = `0x${(frame.event.arg1 >>> 0).toString(16).toUpperCase().padStart(8, "0")}`;
      this.rwState.summary = `read 0x${addr.toString(16).toUpperCase().padStart(5, "0")}`;
      this.statusLine = this.rwState.summary;
    });
  }

  async singleWrite(addr: number, data: number) {
    return this.runExclusive(async () => {
      await this.selectSource(HOST_SRC_INDEX);
      this.dropPendingFrames(
        (frame) => frame.event.srcId === SDRAM_HOST_SRC_ID &&
          [HOST_EVT_WRITE_ACK, HOST_EVT_CMD_ERR].includes(frame.event.eventId),
      );
      await this.sendBytes(buildWriteCommand(addr, data));
      const frame = await this.waitForFrame(
        (candidate) => candidate.event.srcId === SDRAM_HOST_SRC_ID &&
          (
            (candidate.event.eventId === HOST_EVT_WRITE_ACK && candidate.event.arg0 === addr) ||
            candidate.event.eventId === HOST_EVT_CMD_ERR
          ),
        1000,
      );
      if (frame.event.eventId === HOST_EVT_CMD_ERR) {
        throw new Error(`single write failed: cmd_err 0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()}`);
      }
      this.assertAccessStatusOk(frame, `single write 0x${addr.toString(16).toUpperCase().padStart(5, "0")}`);
      this.rwState.singleWriteResult = `wrote 0x${(data >>> 0).toString(16).toUpperCase().padStart(8, "0")}`;
      this.rwState.summary = `write ack 0x${addr.toString(16).toUpperCase().padStart(5, "0")}`;
      this.statusLine = this.rwState.summary;
    });
  }

  async fileWrite(baseAddr: number, filePath: string) {
    return this.runExclusive(async () => {
      const blob = await loadBulkFile(filePath);
      if (!blob.length) {
        throw new Error("input file is empty");
      }
      const words = paddedWordCount(blob.length);
      validateSdramBulkRange(baseAddr, words);
      await this.executeBulkWrite(baseAddr, words, blob, "bulk_file_write");
      this.rwState.fileWriteResult = `validated ${filePath} bytes=${blob.length} words=${words}`;
      this.rwState.summary = "bulk file write complete";
      this.statusLine = this.rwState.summary;
    });
  }

  async bulkRangeRead(baseAddr: number, words: number) {
    return this.runExclusive(async () => {
      validateSdramBulkRange(baseAddr, words);
      this.burstTask = "bulk_range_read";
      this.burstBaseAddr = baseAddr;
      this.burstWords = words;
      this.burstPackets = Math.ceil(words / 2);
      this.burstPacketsReceived = 0;
      const values = await this.executeSdramBulkRead(baseAddr, words, (_receivedCount, packetCount) => {
        this.burstPacketsReceived = packetCount;
        this.burstSummary = `bulk read words ${_receivedCount}/${words}`;
        this.statusLine = this.burstSummary;
      });
      this.ensureBulkWordsComplete(values, baseAddr, words, "bulk range read");
      this.burstSummary = `bulk read complete: ${values.size}/${words} words`;
      this.burstResult = `received ${values.size}/${words} words`;
      this.burstPreview = this.buildBurstPreview(values, words, baseAddr);
      this.statusLine = this.burstSummary;
    });
  }

  async bulkPatternWrite(baseAddr: number, words: number, pattern: number) {
    return this.runExclusive(async () => {
      validateSdramBulkRange(baseAddr, words);
      await this.executeBulkWrite(baseAddr, words, buildPatternBlob(pattern, words), "bulk_pattern_write");
      this.burstSummary = `pattern write complete: 0x${(pattern >>> 0).toString(16).toUpperCase().padStart(8, "0")}`;
      this.burstResult = `pattern=0x${(pattern >>> 0).toString(16).toUpperCase().padStart(8, "0")}`;
      this.burstPreview = "-";
      this.statusLine = this.burstSummary;
    });
  }

  async burstTest(baseAddr: number, words: number, isRead: boolean) {
    return this.runExclusive(async () => {
      if (words < 1 || words > 256) {
        throw new Error("words out of range 1..256");
      }
      if (baseAddr + words - 1 > 0x1f_ffff) {
        throw new Error("burst exceeds SDRAM address range");
      }
      if ((baseAddr & 0xff) + words - 1 > 0xff) {
        throw new Error("burst crosses 8-bit column page");
      }
      this.burstTask = isRead ? "burst_read_test" : "burst_write_test";
      this.burstBaseAddr = baseAddr;
      this.burstWords = words;
      this.burstPackets = Math.ceil(words / 2);
      this.burstPacketsReceived = 0;
      await this.selectSource(HOST_SRC_INDEX);
      await this.sendBytes(isRead ? buildBurstTestReadCommand(baseAddr, words) : buildBurstTestWriteCommand(baseAddr, words));
      const values = new Map<number, number>();
      await this.collectHostFrames(SDRAM_HOST_SRC_ID, [HOST_EVT_BURST_DATA, HOST_EVT_BURST_DONE, HOST_EVT_BURST_ERR], 3000, (frame) => {
        if (frame.event.eventId === HOST_EVT_BURST_DATA) {
          const packet = decodeBurstDataPacket(frame.event.arg0, frame.event.arg1, frame.event.arg2);
          packet.words.forEach((value, index) => values.set(packet.firstWordIndex + index, value));
          this.burstPacketsReceived += 1;
        }
        if (frame.event.eventId === HOST_EVT_BURST_ERR) {
          throw new Error("burst test failed");
        }
        return frame.event.eventId === HOST_EVT_BURST_DONE;
      });
      if (isRead) {
        for (let index = 0; index < words; index += 1) {
          if ((values.get(index) ?? -1) !== index) {
            throw new Error(`burst mismatch at index ${index}`);
          }
        }
      }
      this.burstSummary = `${this.burstTask} complete`;
      this.burstResult = isRead ? "read pattern verified" : "write burst acknowledged";
      this.burstPreview = this.buildBurstPreview(values, words);
      this.statusLine = this.burstSummary;
    });
  }

  async refreshEepromMap(baseAddr: number) {
    return this.runExclusive(async () => {
      validateEepromBulkRange(baseAddr, EEPROM_MAP_BYTE_COUNT);
      this.eepromMapBaseAddr = baseAddr;
      this.eepromMapBytes.fill(0);
      await this.selectSource(0);
      await this.sendBytes(buildEepromBulkReadCommand(baseAddr, EEPROM_MAP_BYTE_COUNT));
      await this.collectHostFrames(EEPROM_HOST_SRC_ID, [HOST_EVT_BULK_OK, HOST_EVT_BULK_PROGRESS, HOST_EVT_BULK_DONE, HOST_EVT_BULK_ERR], 5000, (frame) => {
        if (frame.event.eventId === HOST_EVT_BULK_PROGRESS) {
          const progress = decodeEepromBulkReadProgress(frame.event.arg0, frame.event.arg1, frame.event.arg2);
          this.eepromMapBytes.set(progress.data, progress.baseAddr - baseAddr);
        }
        if (frame.event.eventId === HOST_EVT_BULK_ERR) {
          throw new Error("EEPROM map refresh failed");
        }
        return frame.event.eventId === HOST_EVT_BULK_DONE;
      });
      this.eepromMapSummary = `loaded 256 bytes from 0x${baseAddr.toString(16).toUpperCase().padStart(5, "0")}`;
      this.statusLine = this.eepromMapSummary;
    });
  }

  async eepromSingleRead(addr: number) {
    return this.runExclusive(async () => {
      await this.selectSource(0);
      await this.sendBytes(buildEepromReadCommand(addr));
      const frame = await this.waitForFrame((candidate) => candidate.event.srcId === EEPROM_HOST_SRC_ID && candidate.event.eventId === HOST_EVT_READ_RSP && candidate.event.arg0 === addr, 1000);
      this.eepromRwState.singleReadResult = `0x${(frame.event.arg1 & 0xff).toString(16).toUpperCase().padStart(2, "0")}`;
      this.eepromRwState.summary = `read EEPROM 0x${addr.toString(16).toUpperCase().padStart(5, "0")}`;
      this.statusLine = this.eepromRwState.summary;
    });
  }

  async eepromSingleWrite(addr: number, data: number) {
    return this.runExclusive(async () => {
      await this.selectSource(0);
      await this.sendBytes(buildEepromWriteCommand(addr, data));
      await this.waitForFrame((candidate) => candidate.event.srcId === EEPROM_HOST_SRC_ID && candidate.event.eventId === HOST_EVT_WRITE_ACK && candidate.event.arg0 === addr, 1000);
      this.eepromRwState.singleWriteResult = `wrote 0x${(data & 0xff).toString(16).toUpperCase().padStart(2, "0")}`;
      this.eepromRwState.summary = `write ack EEPROM 0x${addr.toString(16).toUpperCase().padStart(5, "0")}`;
      this.statusLine = this.eepromRwState.summary;
    });
  }

  async eepromFileWrite(baseAddr: number, filePath: string) {
    return this.runExclusive(async () => {
      const blob = await loadBulkFile(filePath);
      if (!blob.length) {
        throw new Error("input file is empty");
      }
      validateEepromBulkRange(baseAddr, blob.length);
      await this.executeEepromBulkWrite(baseAddr, blob);
      this.eepromRwState.fileWriteResult = `validated ${filePath} bytes=${blob.length}`;
      this.eepromRwState.summary = "EEPROM bulk write complete";
      this.statusLine = this.eepromRwState.summary;
    });
  }

  async displayCommand(kind: "init" | "clear" | "pattern" | "on" | "off" | "fill" | "refresh" | "auto-on" | "auto-off", colorText?: string) {
    return this.runExclusive(async () => {
      if (kind === "pattern" || kind === "fill") {
        const blob = kind === "pattern"
          ? buildDisplayCheckerFrame()
          : buildDisplayMonoFillFrame((parseRgb888(colorText ?? "000000") & 0x00ff_ffff) !== 0);
        await this.executeBulkWrite(
          DISPLAY_FRAMEBUFFER_BASE_ADDR,
          paddedWordCount(blob.length),
          blob,
          kind === "pattern" ? "ssd1306_checker" : "ssd1306_fill",
        );
        await this.selectSource(DISPLAY_SRC_INDEX);
        this.dropPendingFrames(
          (frame) => frame.event.srcId === DISPLAY_HOST_SRC_ID &&
            [EVT_CMD_ACK, EVT_CMD_ERR].includes(frame.event.eventId),
        );
        await this.sendBytes(buildDisplayRefreshCommand());
        await this.waitForDisplayAck(DISP_OP_REFRESH);
        this.displaySummary = `${kind} framebuffer refreshed`;
        this.statusLine = this.displaySummary;
        return;
      }

      await this.selectSource(DISPLAY_SRC_INDEX);
      let payload = buildDisplayInitCommand();
      let expected = DISP_OP_INIT;
      if (kind === "clear") {
        payload = buildDisplayClearCommand();
        expected = DISP_OP_CLEAR;
      } else if (kind === "on") {
        payload = buildDisplayOnCommand();
        expected = DISP_OP_ON;
      } else if (kind === "off") {
        payload = buildDisplayOffCommand();
        expected = DISP_OP_OFF;
      } else if (kind === "refresh") {
        payload = buildDisplayRefreshCommand();
        expected = DISP_OP_REFRESH;
      } else if (kind === "auto-on") {
        payload = buildDisplayAutoOnCommand();
        expected = DISP_OP_AUTO_ON;
      } else if (kind === "auto-off") {
        payload = buildDisplayAutoOffCommand();
        expected = DISP_OP_AUTO_OFF;
      }
      this.dropPendingFrames(
        (frame) => frame.event.srcId === DISPLAY_HOST_SRC_ID &&
          [EVT_CMD_ACK, EVT_CMD_ERR].includes(frame.event.eventId),
      );
      await this.sendBytes(payload);
      await this.waitForDisplayAck(expected);
      this.displaySummary = `${kind} acknowledged`;
      this.statusLine = this.displaySummary;
    });
  }

  async ssd1306ReadFrame() {
    return this.runExclusive(async () => {
      const wordCount = SSD1306_FRAME_BYTES / 4; // 128 words
      this.ssd1306Summary = "reading GDDRAM...";
      this.statusLine = this.ssd1306Summary;
      const words = await this.executeSdramBulkRead(
        DISPLAY_FRAMEBUFFER_BASE_ADDR,
        wordCount,
        (receivedCount) => {
          this.ssd1306Summary = `reading ${receivedCount}/${wordCount} words`;
          this.statusLine = this.ssd1306Summary;
        },
      );
      this.ensureBulkWordsComplete(words, DISPLAY_FRAMEBUFFER_BASE_ADDR, wordCount, "SSD1306 GDDRAM read");
      for (let i = 0; i < wordCount; i++) {
        const value = words.get(DISPLAY_FRAMEBUFFER_BASE_ADDR + i) ?? 0;
        this.ssd1306Framebytes[i * 4 + 0] = value & 0xff;
        this.ssd1306Framebytes[i * 4 + 1] = (value >>> 8) & 0xff;
        this.ssd1306Framebytes[i * 4 + 2] = (value >>> 16) & 0xff;
        this.ssd1306Framebytes[i * 4 + 3] = (value >>> 24) & 0xff;
      }
      this.ssd1306Summary = `GDDRAM read complete (${wordCount} words)`;
      this.statusLine = this.ssd1306Summary;
    });
  }

  async ssd1306WriteFrame(framebytes: number[]) {
    return this.runExclusive(async () => {
      if (framebytes.length !== SSD1306_FRAME_BYTES) {
        throw new Error(`framebytes length must be ${SSD1306_FRAME_BYTES}, got ${framebytes.length}`);
      }
      const blob = Buffer.from(framebytes);
      this.ssd1306Framebytes = new Uint8Array(blob);
      const wordCount = paddedWordCount(SSD1306_FRAME_BYTES);
      await this.executeBulkWrite(
        DISPLAY_FRAMEBUFFER_BASE_ADDR,
        wordCount,
        blob,
        "ssd1306_gddram_write",
      );
      await this.selectSource(DISPLAY_SRC_INDEX);
      this.dropPendingFrames(
        (frame) => frame.event.srcId === DISPLAY_HOST_SRC_ID &&
          [EVT_CMD_ACK, EVT_CMD_ERR].includes(frame.event.eventId),
      );
      await this.sendBytes(buildDisplayRefreshCommand());
      await this.waitForDisplayAck(DISP_OP_REFRESH);
      this.ssd1306Summary = "GDDRAM written & display refreshed";
      this.statusLine = this.ssd1306Summary;
    });
  }

  async displaySetFps(fps: number) {
    return this.runExclusive(async () => {
      await this.selectSource(DISPLAY_SRC_INDEX);
      await this.sendBytes(buildDisplaySetFpsCommand(fps));
      await this.waitForDisplayAck(DISP_OP_SET_FPS);
      this.displaySummary = `fps set to ${fps}`;
      this.statusLine = this.displaySummary;
    });
  }

  async dispatchAction(action: string, payload: Record<string, unknown> = {}) {
    switch (action) {
      case "disconnect":
        return this.disconnect();
      case "reloadDecoder":
        return this.reloadDecoder(true);
      case "toggleLog":
        return this.toggleLog((payload.logFilePath as string | undefined) ?? null);
      case "clearLogs":
        return this.clearLogs();
      case "sendReset":
        return this.sendReset();
      case "setMode":
        return this.setMode(payload.mode as SessionSnapshot["mode"]);
      case "toggleStatusMode":
        return this.toggleStatusMode();
      case "refreshMap":
        return this.refreshMap(parseU21(`${payload.baseAddr}`));
      case "refreshStatus":
        return this.refreshStatus();
      case "runStatusSelftest":
        return this.runStatusSelftest();
      case "singleRead":
        return this.singleRead(parseU21(`${payload.addr}`));
      case "singleWrite":
        return this.singleWrite(parseU21(`${payload.addr}`), parseU32(`${payload.data}`));
      case "fileWrite":
        return this.fileWrite(parseU21(`${payload.baseAddr}`), `${payload.filePath}`);
      case "bulkRangeRead":
        return this.bulkRangeRead(parseU21(`${payload.baseAddr}`), Number.parseInt(`${payload.words}`, 0));
      case "bulkPatternWrite":
        return this.bulkPatternWrite(parseU21(`${payload.baseAddr}`), Number.parseInt(`${payload.words}`, 0), parseU32(`${payload.pattern}`));
      case "burstReadTest":
        return this.burstTest(parseU21(`${payload.baseAddr}`), Number.parseInt(`${payload.words}`, 0), true);
      case "burstWriteTest":
        return this.burstTest(parseU21(`${payload.baseAddr}`), Number.parseInt(`${payload.words}`, 0), false);
      case "refreshEepromMap":
        return this.refreshEepromMap(parseEepromAddr(`${payload.baseAddr}`));
      case "eepromSingleRead":
        return this.eepromSingleRead(parseEepromAddr(`${payload.addr}`));
      case "eepromSingleWrite":
        return this.eepromSingleWrite(parseEepromAddr(`${payload.addr}`), parseDataByte(`${payload.data}`));
      case "eepromFileWrite":
        return this.eepromFileWrite(parseEepromAddr(`${payload.baseAddr}`), `${payload.filePath}`);
      case "displayInit":
        return this.displayCommand("init");
      case "displayClear":
        return this.displayCommand("clear");
      case "displayPattern":
        return this.displayCommand("pattern");
      case "displayOn":
        return this.displayCommand("on");
      case "displayOff":
        return this.displayCommand("off");
      case "displayFill":
        return this.displayCommand("fill", `${payload.color}`);
      case "displayRefresh":
        return this.displayCommand("refresh");
      case "displayAutoOn":
        return this.displayCommand("auto-on");
      case "displayAutoOff":
        return this.displayCommand("auto-off");
      case "displaySetFps":
        return this.displaySetFps(Number.parseInt(`${payload.fps}`, 10));
      case "ssd1306ReadFrame":
        return this.ssd1306ReadFrame();
      case "ssd1306WriteFrame":
        return this.ssd1306WriteFrame(payload.framebytes as number[]);
      default:
        throw new Error(`unsupported action: ${action}`);
    }
  }

  private tcpPacketCount = 0;
  private tcpByteCount = 0;

  private isConnected() {
    return Boolean(this.serial?.isOpen || this.socket || this.replayTimer);
  }

  private async ensureDecoderFresh() {
    try {
      await this.reloadDecoder(false);
    } catch {
      // Keep the previously loaded decoder.
    }
  }

  private ensureLiveTransport() {
    if (this.transport === "replay") {
      throw new Error("replay mode: command disabled");
    }
    if (!this.isConnected()) {
      throw new Error("not connected");
    }
  }

  private async openSerial() {
    this.serial = await new Promise<SerialPort>((resolve, reject) => {
      const port = new SerialPort({ path: this.port!, baudRate: this.baud, autoOpen: false });
      port.open((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(port);
      });
    });
    this.serial.on("data", (chunk: Buffer) => this.handleIncomingBytes(chunk));
    this.serial.on("error", (error) => {
      this.statusLine = `serial error: ${error.message}`;
    });
    this.serial.on("close", () => {
      this.statusLine = "serial disconnected";
      this.serial = null;
    });
  }

  private async openTcp() {
    this.socket = await new Promise<net.Socket>((resolve, reject) => {
      const socket = net.createConnection({ host: this.tcpHost, port: this.tcpPort }, () => resolve(socket));
      socket.once("error", reject);
    });
    this.socket.on("data", (chunk: Buffer) => {
      this.tcpPacketCount += 1;
      this.tcpByteCount += chunk.length;
      this.handleIncomingBytes(chunk);
    });
    this.socket.on("error", (error) => {
      this.statusLine = `tcp error: ${error.message}`;
    });
    this.socket.on("close", () => {
      this.statusLine = "tcp disconnected";
      this.socket = null;
    });
  }

  private handleIncomingBytes(chunk: Uint8Array) {
    const frames = this.parser.feed(chunk);
    frames.forEach((frame) => this.handleFrame(frame));
  }

  private handleFrame(frame: UartFrame) {
    this.pendingFrames.push(frame);
    if (this.pendingFrames.length > 1024) {
      this.pendingFrames.splice(0, this.pendingFrames.length - 1024);
    }
    if (frame.event.srcId === SYS_SRC_ID && frame.event.eventId === SYS_EVT_MODE_CHANGE) {
      this.selectedSrcIdx = frame.event.arg1 & 0xff;
    }
    this.appendRow({
      hostTime: formatHostTime(),
      seq: frame.seq,
      event: frame.event,
      lostCount: frame.lostCount,
    });
  }

  private appendRow(row: StoredEvent) {
    this.rows.push(row);
    if (this.rows.length > ROW_LIMIT) {
      this.rows.splice(0, this.rows.length - ROW_LIMIT);
    }
    if (this.logEnabled && this.logFilePath) {
      void appendFile(this.logFilePath, `${buildLogLine(row, this.mode, this.decoder)}\n`, "utf8");
    }
  }

  private startReplay() {
    this.stopReplay();
    this.replayTimer = setInterval(() => {
      if (this.replayIndex >= this.replayRecords.length) {
        this.stopReplay();
        this.replayFinished = true;
        this.statusLine = "replay finished";
        return;
      }
      const record = this.replayRecords[this.replayIndex++];
      this.pendingFrames.push({
        sync: 0x7e,
        seq: record.seq,
        payloadBytes: new Uint8Array(16),
        crc: 0,
        crcOk: true,
        lostCount: record.lostCount,
        rawHex: "",
        event: record.event,
      });
      this.appendRow({
        hostTime: record.hostTime,
        seq: record.seq,
        event: record.event,
        lostCount: record.lostCount,
      });
      if (record.event.srcId === SYS_SRC_ID && record.event.eventId === SYS_EVT_MODE_CHANGE) {
        this.selectedSrcIdx = record.event.arg1 & 0xff;
      }
    }, 50);
  }

  private stopReplay() {
    if (this.replayTimer) {
      clearInterval(this.replayTimer);
      this.replayTimer = null;
    }
  }

  private async enableLogging(requestedPath: string | null) {
    const logDir = "c:/Electronics/GitHubProjects/tangnano20k_dev/11_app/uart_log_tool_webUI/logs";
    await mkdir(logDir, { recursive: true });
    const filePath = requestedPath && requestedPath.trim()
      ? requestedPath
      : join(logDir, `uart_${new Date().toISOString().replace(/[-:TZ.]/g, "").slice(0, 14)}.log`);
    this.logEnabled = true;
    this.logFilePath = filePath;
    this.statusLine = `log enabled: ${filePath}`;
  }

  private async runExclusive(work: () => Promise<void>) {
    if (this.busy) {
      throw new Error("host task busy");
    }
    if (!this.isConnected()) {
      throw new Error("not connected");
    }
    if (this.transport === "replay") {
      throw new Error("replay mode: host command disabled");
    }
    this.busy = true;
    try {
      await work();
    } finally {
      this.busy = false;
    }
  }

  private async sendBytes(payload: Uint8Array) {
    if (this.serial?.isOpen) {
      await new Promise<void>((resolve, reject) => this.serial!.write(Buffer.from(payload), (error) => (error ? reject(error) : resolve())));
      return;
    }
    if (this.socket) {
      await new Promise<void>((resolve, reject) => this.socket!.write(Buffer.from(payload), (error) => (error ? reject(error) : resolve())));
      return;
    }
    throw new Error("no active live transport");
  }

  private async waitForFrame(match: (frame: UartFrame) => boolean, timeoutMs: number) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const index = this.pendingFrames.findIndex(match);
      if (index >= 0) {
        return this.pendingFrames.splice(index, 1)[0];
      }
      await delay(20);
    }
    throw new Error("timed out waiting for frame");
  }

  private async collectHostFrames(srcId: number, eventIds: number[], timeoutMs: number, onFrame: (frame: UartFrame) => boolean) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const index = this.pendingFrames.findIndex((frame) => frame.event.srcId === srcId && eventIds.includes(frame.event.eventId));
      if (index >= 0) {
        const frame = this.pendingFrames.splice(index, 1)[0];
        if (onFrame(frame)) {
          return;
        }
        continue;
      }
      await delay(20);
    }
    throw new Error("timed out waiting for host response");
  }

  private async selectSource(targetIdx: number) {
    if (this.selectedSrcIdx === targetIdx) {
      return;
    }
    for (let step = 0; step < UART_LOG_NUM_SRC + 2; step += 1) {
      await this.sendBytes(Buffer.from([CMD_NEXT_SRC]));
      const frame = await this.waitForFrame((candidate) => candidate.event.srcId === SYS_SRC_ID && candidate.event.eventId === SYS_EVT_MODE_CHANGE, 400);
      this.selectedSrcIdx = frame.event.arg1 & 0xff;
      if (this.selectedSrcIdx === targetIdx) {
        return;
      }
    }
    throw new Error(`timed out selecting source index ${targetIdx}`);
  }

  private async refreshStatusUnlocked() {
    this.statusSummary = "refreshing status registers";
    this.statusLine = this.statusSummary;
    await this.selectSource(HOST_SRC_INDEX);
    this.dropPendingFrames(
      (frame) => frame.event.srcId === SDRAM_HOST_SRC_ID &&
        [HOST_EVT_READ_RSP, HOST_EVT_CMD_ERR].includes(frame.event.eventId),
    );
    for (let offset = 0; offset < STATUS_BYTE_COUNT; offset += 4) {
      await this.sendBytes(buildStatusReadCommand(offset));
      const frame = await this.waitForFrame(
        (candidate) => candidate.event.srcId === SDRAM_HOST_SRC_ID &&
          (
            (candidate.event.eventId === HOST_EVT_READ_RSP && candidate.event.arg0 === offset) ||
            candidate.event.eventId === HOST_EVT_CMD_ERR
          ),
        1000,
      );
      if (frame.event.eventId === HOST_EVT_CMD_ERR) {
        throw new Error(`status refresh failed at 0x${offset.toString(16).toUpperCase().padStart(5, "0")}: cmd_err 0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()}`);
      }
      this.assertAccessStatusOk(frame, `status read 0x${offset.toString(16).toUpperCase().padStart(5, "0")}`);
      const value = frame.event.arg1 >>> 0;
      this.statusBytes[offset + 0] = value & 0xff;
      this.statusBytes[offset + 1] = (value >>> 8) & 0xff;
      this.statusBytes[offset + 2] = (value >>> 16) & 0xff;
      this.statusBytes[offset + 3] = (value >>> 24) & 0xff;
    }
    this.statusSummary = "status registers refreshed";
    this.statusLine = this.statusSummary;
  }

  private async executeSdramBulkRead(
    baseAddr: number,
    words: number,
    onProgress?: (receivedCount: number, packetCount: number) => void,
  ) {
    await this.selectSource(HOST_SRC_INDEX);
    this.dropPendingFrames(
      (frame) => frame.event.srcId === SDRAM_HOST_SRC_ID &&
        [
          HOST_EVT_BULK_OK,
          HOST_EVT_BULK_PROGRESS,
          HOST_EVT_BULK_DONE,
          HOST_EVT_BULK_ERR,
          HOST_EVT_BULK_ABORT,
          HOST_EVT_CMD_ERR,
        ].includes(frame.event.eventId),
    );
    await this.sendBytes(buildBulkReadCommand(baseAddr, words));
    const ackFrame = await this.waitForFrame(
      (candidate) => candidate.event.srcId === SDRAM_HOST_SRC_ID &&
        [
          HOST_EVT_BULK_OK,
          HOST_EVT_BULK_ERR,
          HOST_EVT_BULK_ABORT,
          HOST_EVT_CMD_ERR,
        ].includes(candidate.event.eventId),
      3000,
    );
    this.assertBulkAccepted(ackFrame, baseAddr, words, "SDRAM bulk read");

    const values = new Map<number, number>();
    let packetCount = 0;
    while (true) {
      const frame = await this.waitForFrame(
        (candidate) => candidate.event.srcId === SDRAM_HOST_SRC_ID &&
          [
            HOST_EVT_BULK_PROGRESS,
            HOST_EVT_BULK_DONE,
            HOST_EVT_BULK_ERR,
            HOST_EVT_BULK_ABORT,
            HOST_EVT_CMD_ERR,
          ].includes(candidate.event.eventId),
        5000,
      );
      if (frame.event.eventId === HOST_EVT_BULK_PROGRESS) {
        const progress = decodeBulkReadProgress(frame.event.arg0, frame.event.arg1, frame.event.arg2);
        progress.words.forEach((value, index) => values.set(progress.baseAddr + index, value));
        packetCount += 1;
        onProgress?.(values.size, packetCount);
        continue;
      }
      this.assertBulkDone(frame, baseAddr, words, "SDRAM bulk read");
      return values;
    }
  }

  private async executeBulkWrite(baseAddr: number, words: number, blob: Uint8Array, task: string) {
    await this.selectSource(HOST_SRC_INDEX);
    this.burstTask = task;
    this.burstBaseAddr = baseAddr;
    this.burstWords = words;
    this.burstPackets = Math.ceil(words / 2);
    this.burstPacketsReceived = 0;
    this.dropPendingFrames(
      (frame) => frame.event.srcId === SDRAM_HOST_SRC_ID &&
        [
          HOST_EVT_BULK_OK,
          HOST_EVT_BULK_PROGRESS,
          HOST_EVT_BULK_DONE,
          HOST_EVT_BULK_ABORT,
          HOST_EVT_BULK_ERR,
          HOST_EVT_CMD_ERR,
        ].includes(frame.event.eventId),
    );
    await this.sendBytes(buildBulkWriteCommand(baseAddr, words));
    const ackFrame = await this.waitForFrame(
      (frame) => frame.event.srcId === SDRAM_HOST_SRC_ID &&
        [
          HOST_EVT_BULK_OK,
          HOST_EVT_BULK_ABORT,
          HOST_EVT_BULK_ERR,
          HOST_EVT_CMD_ERR,
        ].includes(frame.event.eventId),
      3000,
    );
    this.assertBulkAccepted(ackFrame, baseAddr, words, task);
    const blocks = iterBulkWriteBlocks(blob);
    for (let index = 0; index < blocks.length; index += 1) {
      await this.sendBytes(blocks[index]);
      const frame = await this.waitForFrame(
        (candidate) => candidate.event.srcId === SDRAM_HOST_SRC_ID &&
          [
            HOST_EVT_BULK_PROGRESS,
            HOST_EVT_BULK_DONE,
            HOST_EVT_BULK_ABORT,
            HOST_EVT_BULK_ERR,
            HOST_EVT_CMD_ERR,
          ].includes(candidate.event.eventId),
        5000,
      );
      if ([HOST_EVT_BULK_ABORT, HOST_EVT_BULK_ERR, HOST_EVT_CMD_ERR].includes(frame.event.eventId)) {
        await this.sendBytes(buildBulkAbortBlock(index & 0xff));
        if (frame.event.eventId === HOST_EVT_CMD_ERR) {
          throw new Error(`bulk write command error 0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()}`);
        }
        throw new Error("bulk write aborted by target");
      }
      if (index === blocks.length - 1 && frame.event.eventId !== HOST_EVT_BULK_DONE) {
        throw new Error("missing bulk done after final block");
      }
      if (frame.event.eventId === HOST_EVT_BULK_DONE) {
        this.assertBulkDone(frame, baseAddr, words, task);
      }
    }
  }

  private async waitForDisplayAck(expectedOp: number) {
    const frame = await this.waitForFrame(
      (candidate) => candidate.event.srcId === DISPLAY_HOST_SRC_ID && [EVT_CMD_ACK, EVT_CMD_ERR].includes(candidate.event.eventId),
      3000,
    );
    if (frame.event.eventId === EVT_CMD_ERR) {
      throw new Error(
        `display command error reason=0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()} detail=0x${(frame.event.arg1 >>> 0).toString(16).toUpperCase()}`,
      );
    }
    if ((frame.event.arg0 & 0x0f) !== expectedOp) {
      throw new Error(`unexpected display ack op ${(frame.event.arg0 & 0xff).toString(16).toUpperCase()}`);
    }
    return frame;
  }

  private async executeEepromBulkWrite(baseAddr: number, blob: Uint8Array) {
    await this.selectSource(0);
    await this.sendBytes(buildEepromBulkWriteCommand(baseAddr, blob.length));
    await this.waitForFrame((frame) => frame.event.srcId === EEPROM_HOST_SRC_ID && frame.event.eventId === HOST_EVT_BULK_OK, 3000);
    const blocks = iterBulkWriteBlocks(blob);
    for (let index = 0; index < blocks.length; index += 1) {
      await this.sendBytes(blocks[index]);
      const frame = await this.waitForFrame((candidate) => candidate.event.srcId === EEPROM_HOST_SRC_ID && [HOST_EVT_BULK_PROGRESS, HOST_EVT_BULK_DONE, HOST_EVT_BULK_ABORT, HOST_EVT_BULK_ERR].includes(candidate.event.eventId), 5000);
      if (frame.event.eventId === HOST_EVT_BULK_ABORT || frame.event.eventId === HOST_EVT_BULK_ERR) {
        await this.sendBytes(buildBulkAbortBlock(index & 0xff));
        throw new Error("EEPROM bulk write aborted by target");
      }
      if (index === blocks.length - 1 && frame.event.eventId !== HOST_EVT_BULK_DONE) {
        throw new Error("missing EEPROM bulk done after final block");
      }
    }
  }

  private buildBurstPreview(values: Map<number, number>, words: number, baseAddr = 0) {
    if (!values.size) {
      return "-";
    }
    const lines: string[] = [];
    const maxWords = Math.min(words, 32);
    for (let idx = 0; idx < maxWords; idx += 4) {
      const chunk: string[] = [];
      for (let inner = idx; inner < Math.min(idx + 4, maxWords); inner += 1) {
        const value = values.get(baseAddr + inner);
        chunk.push(value === undefined ? "--------" : (value >>> 0).toString(16).toUpperCase().padStart(8, "0"));
      }
      lines.push(`${idx.toString(16).toUpperCase().padStart(3, "0")} | ${chunk.join("  ")}`);
    }
    if (words > maxWords) {
      lines.push(`... ${words - maxWords} more words`);
    }
    return lines.join("\n");
  }

  private dropPendingFrames(match: (frame: UartFrame) => boolean) {
    this.pendingFrames = this.pendingFrames.filter((frame) => !match(frame));
  }

  private assertAccessStatusOk(frame: UartFrame, label: string) {
    const status = frame.event.arg2 >>> 0;
    if (status !== 0) {
      throw new Error(`${label} failed with status 0x${status.toString(16).toUpperCase().padStart(8, "0")}`);
    }
  }

  private assertBulkAccepted(frame: UartFrame, baseAddr: number, words: number, label: string) {
    if (frame.event.eventId === HOST_EVT_CMD_ERR) {
      throw new Error(`${label} failed: cmd_err 0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()}`);
    }
    if (frame.event.eventId === HOST_EVT_BULK_ABORT) {
      throw new Error(`${label} failed: bulk abort 0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()}`);
    }
    if (frame.event.eventId === HOST_EVT_BULK_ERR) {
      throw new Error(`${label} failed: bulk error 0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()}`);
    }
    const ackBase = frame.event.arg0 & 0x1f_ffff;
    const ackWords = frame.event.arg1 & 0x1f_ffff;
    if (ackBase !== baseAddr || ackWords !== words) {
      throw new Error(`${label} ack mismatch base=0x${ackBase.toString(16).toUpperCase().padStart(5, "0")} words=${ackWords}`);
    }
  }

  private assertBulkDone(frame: UartFrame, baseAddr: number, words: number, label: string) {
    if (frame.event.eventId === HOST_EVT_CMD_ERR) {
      throw new Error(`${label} failed: cmd_err 0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()}`);
    }
    if (frame.event.eventId === HOST_EVT_BULK_ABORT) {
      throw new Error(`${label} failed: bulk abort 0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()}`);
    }
    if (frame.event.eventId === HOST_EVT_BULK_ERR) {
      throw new Error(`${label} failed: bulk error 0x${(frame.event.arg0 >>> 0).toString(16).toUpperCase()}`);
    }
    const doneBase = frame.event.arg0 & 0x1f_ffff;
    const doneWords = frame.event.arg1 & 0x1f_ffff;
    const completedWords = frame.event.arg2 & 0x1f_ffff;
    if (doneBase !== baseAddr || doneWords !== words) {
      throw new Error(`${label} done mismatch base=0x${doneBase.toString(16).toUpperCase().padStart(5, "0")} words=${doneWords}`);
    }
    if (completedWords !== words) {
      throw new Error(`${label} completed mismatch ${completedWords}/${words}`);
    }
  }

  private ensureBulkWordsComplete(values: Map<number, number>, baseAddr: number, words: number, label: string) {
    for (let offset = 0; offset < words; offset += 1) {
      if (!values.has(baseAddr + offset)) {
        throw new Error(`${label} incomplete: missing word 0x${(baseAddr + offset).toString(16).toUpperCase().padStart(5, "0")}`);
      }
    }
  }
}

declare global {
  var __uartWorkbenchService: WorkbenchService | undefined;
}

export function getWorkbenchService() {
  if (!globalThis.__uartWorkbenchService) {
    globalThis.__uartWorkbenchService = new WorkbenchService();
  }
  return globalThis.__uartWorkbenchService;
}
