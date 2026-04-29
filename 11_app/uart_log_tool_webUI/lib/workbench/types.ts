export type TransportMode = "serial" | "tcp" | "replay";
export type DisplayMode = "raw" | "decode";
export type StatusViewMode = "decode" | "raw";

export type LogLevel = "INFO" | "WARN" | "ERROR" | "DEBUG" | "TRACE";

export interface UartEvent {
  srcId: number;
  eventId: number;
  timestamp: number;
  arg0: number;
  arg1: number;
  arg2: number;
}

export interface UartFrame {
  sync: number;
  seq: number;
  payloadBytes: Uint8Array;
  crc: number;
  crcOk: boolean;
  lostCount: number;
  rawHex: string;
  event: UartEvent;
}

export interface StoredEvent {
  hostTime: string | null;
  seq: number;
  event: UartEvent;
  lostCount: number;
}

export interface DecodedEvent {
  level: LogLevel;
  title: string;
  message: string;
  tags: string[];
}

export interface LogRow {
  hostTime: string;
  seqText: string;
  srcText: string;
  evtText: string;
  timestampText: string;
  arg0Text: string;
  arg1Text: string;
  arg2Text: string;
  crcText: string;
  modeText: string;
  text: string;
  searchText: string;
}

export interface ReplayRecord {
  hostTime: string;
  seq: number;
  event: UartEvent;
  lostCount: number;
}

export interface PortInfo {
  device: string;
  description: string;
  hwid: string;
}

export interface SessionSnapshot {
  connected: boolean;
  transport: TransportMode;
  mode: DisplayMode;
  statusMode: StatusViewMode;
  port: string | null;
  baud: number;
  tcpHost: string;
  tcpPort: number;
  replayPath: string | null;
  selectedSrcIdx: number;
  statusLine: string;
  decoderPath: string;
  decoderLoaded: boolean;
  decoderError: string | null;
  logEnabled: boolean;
  logFilePath: string | null;
  replayFinished: boolean;
  replayLoadError: string | null;
  busy: boolean;
}

export interface StatsSnapshot {
  rxFrames: number;
  crcErrors: number;
  lostEvents: number;
  tcpPackets: number;
  tcpBytes: number;
  lastSeq: string;
  totalRows: number;
}

export interface TextPaneState {
  summary: string;
  text: string;
}

export interface RwState {
  summary: string;
  singleReadResult: string;
  singleWriteResult: string;
  fileWriteResult: string;
}

export interface EepromRwState {
  summary: string;
  singleReadResult: string;
  singleWriteResult: string;
  fileWriteResult: string;
}

export interface BurstState {
  summary: string;
  result: string;
  preview: string;
  baseAddr: number;
  words: number;
  packetCount: number;
  packetsReceived: number;
  task: string;
}

export interface DisplayState {
  summary: string;
}

export interface Ssd1306State {
  summary: string;
  /** Flat 512-byte GDDRAM array in page-address order.
   *  byte[page * 128 + col] — bit(y & 7) = pixel at (col, page*8 + (y & 7)) */
  framebytes: number[];
}

export interface WorkbenchSnapshot {
  session: SessionSnapshot;
  stats: StatsSnapshot;
  rows: LogRow[];
  sdramMap: TextPaneState & { baseAddr: number };
  sdramStatus: TextPaneState;
  sdramRw: RwState;
  sdramBurst: BurstState;
  eepromMap: TextPaneState & { baseAddr: number };
  eepromRw: EepromRwState;
  display: DisplayState;
  ssd1306: Ssd1306State;
}

export interface ConnectPayload {
  transport: TransportMode;
  port?: string | null;
  baud?: number;
  tcpHost?: string;
  tcpPort?: number;
  mode?: DisplayMode;
  decoderPath?: string;
  replayPath?: string | null;
  logFilePath?: string | null;
}

export interface ActionEnvelope<T = Record<string, unknown>> {
  action: string;
  payload?: T;
}