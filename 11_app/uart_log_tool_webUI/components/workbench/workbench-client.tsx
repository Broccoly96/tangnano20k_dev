"use client";

import React, { startTransition, useCallback, useDeferredValue, useEffect, useRef, useState } from "react";
import { AlertCircle, Database, HardDrive, MonitorSmartphone, RefreshCcw, Router, ScanLine } from "lucide-react";

import { ScrollArea } from "@/components/ui/scroll-area";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { PortInfo, TransportMode, WorkbenchSnapshot } from "@/lib/workbench/types";

type ScreenKey = "log" | "sdram" | "sdram-status" | "eeprom" | "ssd1306" | "ocr";

const navItems: Array<{ key: ScreenKey; label: string; icon: typeof Router }> = [
  { key: "log",          label: "Log",       icon: Router },
  { key: "sdram",        label: "SDRAM",     icon: HardDrive },
  { key: "sdram-status", label: "SDRAM STS", icon: RefreshCcw },
  { key: "eeprom",       label: "EEPROM",    icon: Database },
  { key: "ssd1306",      label: "SSD1306",   icon: MonitorSmartphone },
  { key: "ocr",          label: "OCR",        icon: ScanLine },
];

const emptySnapshot: WorkbenchSnapshot = {
  session: {
    connected: false,
    transport: "tcp",
    mode: "decode",
    statusMode: "decode",
    port: null,
    baud: 115200,
    tcpHost: "192.168.10.40",
    tcpPort: 2323,
    replayPath: null,
    selectedSrcIdx: 0,
    statusLine: "idle",
    decoderPath: "",
    decoderLoaded: false,
    decoderError: null,
    logEnabled: false,
    logFilePath: null,
    replayFinished: false,
    replayLoadError: null,
    busy: false,
  },
  stats: {
    rxFrames: 0,
    crcErrors: 0,
    lostEvents: 0,
    tcpPackets: 0,
    tcpBytes: 0,
    lastSeq: "-",
    totalRows: 0,
  },
  rows: [],
  sdramMap: { baseAddr: 0, summary: "idle", text: "-" },
  sdramStatus: { summary: "idle", text: "-" },
  sdramRw: { summary: "idle", singleReadResult: "-", singleWriteResult: "-", fileWriteResult: "-" },
  sdramBurst: { summary: "idle", result: "-", preview: "-", baseAddr: 0, words: 0, packetCount: 0, packetsReceived: 0, task: "-" },
  eepromMap: { baseAddr: 0, summary: "idle", text: "-" },
  eepromRw: { summary: "idle", singleReadResult: "-", singleWriteResult: "-", fileWriteResult: "-" },
  display: { summary: "idle" },
  ssd1306: { summary: "idle", framebytes: new Array(512).fill(0) as number[] },
  ocr: {
    summary: "idle",
    lastClass: null,
    lastChar: null,
    lastScore0: null,
    lastScore1: null,
    lastConfGap: null,
    lastCyclesTotal: null,
    lastCyclesL0: null,
    lastCyclesL1: null,
  },
};

export function WorkbenchClient() {
  const [snapshot, setSnapshot] = useState<WorkbenchSnapshot>(emptySnapshot);
  const [ports, setPorts] = useState<PortInfo[]>([]);
  const [activeScreen, setActiveScreen] = useState<ScreenKey>("log");
  const [errorText, setErrorText] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [transport, setTransport] = useState<TransportMode>("tcp");
  const [port, setPort] = useState("");
  const [baud, setBaud] = useState("115200");
  const [tcpHost, setTcpHost] = useState("192.168.10.40");
  const [tcpPort, setTcpPort] = useState("2323");
  const [decoderPath, setDecoderPath] = useState("");
  const [replayPath, setReplayPath] = useState("");
  const [logFilePath, setLogFilePath] = useState("");
  const [filterText, setFilterText] = useState("");
  const [mapBaseAddr, setMapBaseAddr] = useState("0x00000");
  const [singleReadAddr, setSingleReadAddr] = useState("0x00000");
  const [singleWriteAddr, setSingleWriteAddr] = useState("0x00000");
  const [singleWriteData, setSingleWriteData] = useState("0x00000000");
  const [fileWriteAddr, setFileWriteAddr] = useState("0x00000");
  const [fileWritePath, setFileWritePath] = useState("");
  const [burstBaseAddr, setBurstBaseAddr] = useState("0x00000");
  const [burstWords, setBurstWords] = useState("16");
  const [bulkPattern, setBulkPattern] = useState("0xA5A5A5A5");
  const [eepromMapBase, setEepromMapBase] = useState("0x00000");
  const [eepromReadAddr, setEepromReadAddr] = useState("0x00000");
  const [eepromWriteAddr, setEepromWriteAddr] = useState("0x00000");
  const [eepromWriteData, setEepromWriteData] = useState("0x00");
  const [eepromFileAddr, setEepromFileAddr] = useState("0x00000");
  const [eepromFilePath, setEepromFilePath] = useState("");
  // displayColor removed (Framebuffer Fill feature deleted)
  const [displayFps, setDisplayFps] = useState("10");

  // ── SSD1306 GDDRAM ────────────────────────────────────────────────────────
  const editorCanvasRef = useRef<HTMLCanvasElement>(null);
  const previewCanvasRef = useRef<HTMLCanvasElement>(null);
  const [localFrame, setLocalFrame] = useState<number[]>(() => new Array(512).fill(0));
  const [isPainting, setIsPainting] = useState(false);
  const [paintValue, setPaintValue] = useState(true);
  const [hoveredPixel, setHoveredPixel] = useState<{ x: number; y: number } | null>(null);

  const EDITOR_SCALE = 6;
  const PREVIEW_SCALE = 2;

  const gddramGetPixel = useCallback((frame: number[], x: number, y: number): boolean => {
    const byteIdx = ((y >> 3) * 128) + x;
    return byteIdx < frame.length && ((frame[byteIdx] >> (y & 7)) & 1) === 1;
  }, []);

  const gddramSetPixel = useCallback((frame: number[], x: number, y: number, on: boolean): number[] => {
    const byteIdx = ((y >> 3) * 128) + x;
    if (byteIdx >= frame.length) return frame;
    const next = [...frame];
    if (on) next[byteIdx] = (frame[byteIdx] | (1 << (y & 7))) & 0xff;
    else    next[byteIdx] = (frame[byteIdx] & ~(1 << (y & 7))) & 0xff;
    return next;
  }, []);

  // Draw editor canvas whenever localFrame, hoveredPixel, or active screen changes
  useEffect(() => {
    const canvas = editorCanvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const W = 128, H = 32, S = EDITOR_SCALE;
    ctx.fillStyle = "#030608";
    ctx.fillRect(0, 0, W * S, H * S);
    ctx.fillStyle = "#b8d8b0";
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        if (gddramGetPixel(localFrame, x, y)) {
          ctx.fillRect(x * S, y * S, S - 1, S - 1);
        }
      }
    }
    // Page boundary lines (every 8 rows)
    ctx.strokeStyle = "#1a2a3a";
    ctx.lineWidth = 1;
    for (let p = 0; p <= 4; p++) {
      ctx.beginPath();
      ctx.moveTo(0, p * 8 * S);
      ctx.lineTo(W * S, p * 8 * S);
      ctx.stroke();
    }
    // Column grid every 8 pixels
    ctx.strokeStyle = "#111820";
    for (let c = 0; c <= W; c += 8) {
      ctx.beginPath();
      ctx.moveTo(c * S, 0);
      ctx.lineTo(c * S, H * S);
      ctx.stroke();
    }
    // Hover highlight
    if (hoveredPixel) {
      ctx.strokeStyle = "#38bdf8";
      ctx.lineWidth = 1.5;
      ctx.strokeRect(hoveredPixel.x * S + 0.5, hoveredPixel.y * S + 0.5, S - 1, S - 1);
    }
  }, [localFrame, hoveredPixel, gddramGetPixel, activeScreen]);

  // Draw preview canvas
  useEffect(() => {
    const canvas = previewCanvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const W = 128, H = 32, S = PREVIEW_SCALE;
    ctx.fillStyle = "#030608";
    ctx.fillRect(0, 0, W * S, H * S);
    ctx.fillStyle = "#b8d8b0";
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        if (gddramGetPixel(localFrame, x, y)) {
          ctx.fillRect(x * S, y * S, S, S);
        }
      }
    }
  }, [localFrame, gddramGetPixel, activeScreen]);

  function canvasPixelFromEvent(e: React.MouseEvent<HTMLCanvasElement>): { x: number; y: number } | null {
    const canvas = editorCanvasRef.current;
    if (!canvas) return null;
    const rect = canvas.getBoundingClientRect();
    const x = Math.floor((e.clientX - rect.left) / EDITOR_SCALE);
    const y = Math.floor((e.clientY - rect.top) / EDITOR_SCALE);
    if (x < 0 || x >= 128 || y < 0 || y >= 32) return null;
    return { x, y };
  }

  function handleEditorMouseDown(e: React.MouseEvent<HTMLCanvasElement>) {
    e.preventDefault();
    const pixel = canvasPixelFromEvent(e);
    if (!pixel) return;
    const isOn = gddramGetPixel(localFrame, pixel.x, pixel.y);
    const newValue = e.button === 2 ? false : !isOn;
    setPaintValue(newValue);
    setIsPainting(true);
    setLocalFrame(gddramSetPixel(localFrame, pixel.x, pixel.y, newValue));
  }

  function handleEditorMouseMove(e: React.MouseEvent<HTMLCanvasElement>) {
    const pixel = canvasPixelFromEvent(e);
    setHoveredPixel(pixel);
    if (isPainting && pixel) {
      setLocalFrame((prev) => gddramSetPixel(prev, pixel.x, pixel.y, paintValue));
    }
  }

  async function readGddram() {
    setIsLoading(true);
    setErrorText(null);
    try {
      const response = await fetch("/api/action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "ssd1306ReadFrame" }),
      });
      const data = await response.json() as WorkbenchSnapshot;
      if (!response.ok) {
        throw new Error((data as unknown as { error?: string }).error ?? "read failed");
      }
      startTransition(() => setSnapshot(data));
      setLocalFrame(Array.from(data.ssd1306.framebytes));
    } catch (error) {
      setErrorText(error instanceof Error ? error.message : `${error}`);
    } finally {
      setIsLoading(false);
    }
  }
  const deferredFilter = useDeferredValue(filterText.trim().toLowerCase());

  useEffect(() => {
    void refreshSnapshot();
    void refreshPorts();
  }, []);

  useEffect(() => {
    const timer = setInterval(() => {
      void refreshSnapshot(true);
    }, 450);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    if (!decoderPath && snapshot.session.decoderPath) {
      setDecoderPath(snapshot.session.decoderPath);
      setTransport(snapshot.session.transport);
      setPort(snapshot.session.port ?? "");
      setBaud(`${snapshot.session.baud}`);
      setTcpHost(snapshot.session.tcpHost);
      setTcpPort(`${snapshot.session.tcpPort}`);
      setReplayPath(snapshot.session.replayPath ?? "");
      setLogFilePath(snapshot.session.logFilePath ?? "");
    }
  }, [decoderPath, snapshot.session]);

  const filteredRows = deferredFilter
    ? snapshot.rows.filter((row) => row.searchText.includes(deferredFilter))
    : snapshot.rows;
  const visibleRows = filteredRows.slice(-500).reverse();

  async function refreshSnapshot(silent = false) {
    try {
      const response = await fetch("/api/session", { cache: "no-store" });
      const data = (await response.json()) as WorkbenchSnapshot;
      startTransition(() => setSnapshot(data));
      if (!silent) {
        setErrorText(null);
      }
    } catch (error) {
      if (!silent) {
        setErrorText(error instanceof Error ? error.message : `${error}`);
      }
    }
  }

  async function refreshPorts() {
    try {
      const response = await fetch("/api/ports", { cache: "no-store" });
      const data = (await response.json()) as PortInfo[];
      setPorts(data);
    } catch (error) {
      setErrorText(error instanceof Error ? error.message : `${error}`);
    }
  }

  async function connectOrDisconnect() {
    if (snapshot.session.connected) {
      await runAction("disconnect");
      return;
    }
    await runSessionAction({
      action: "connect",
      payload: {
        transport,
        port: port || null,
        baud: Number.parseInt(baud || "115200", 10),
        tcpHost,
        tcpPort: Number.parseInt(tcpPort || "2323", 10),
        decoderPath,
        replayPath: replayPath || null,
        logFilePath: logFilePath || null,
        mode: snapshot.session.mode,
      },
    });
  }

  async function runSessionAction(body: Record<string, unknown>) {
    setIsLoading(true);
    setErrorText(null);
    try {
      const response = await fetch("/api/session", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await response.json();
      if (!response.ok) {
        throw new Error(data.error ?? "session action failed");
      }
      startTransition(() => setSnapshot(data as WorkbenchSnapshot));
    } catch (error) {
      setErrorText(error instanceof Error ? error.message : `${error}`);
    } finally {
      setIsLoading(false);
    }
  }

  async function runAction(action: string, payload?: Record<string, unknown>) {
    setIsLoading(true);
    setErrorText(null);
    try {
      const response = await fetch("/api/action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action, payload }),
      });
      const data = await response.json();
      if (!response.ok) {
        throw new Error(data.error ?? "action failed");
      }
      startTransition(() => setSnapshot(data as WorkbenchSnapshot));
    } catch (error) {
      setErrorText(error instanceof Error ? error.message : `${error}`);
    } finally {
      setIsLoading(false);
    }
  }

  return (
    <main className="flex h-screen overflow-hidden bg-[#090d13] text-[#c8d4e8]">
      {/* ── SIDEBAR ── */}
      <aside className="w-52 shrink-0 flex flex-col bg-[#0a0e17] border-r border-white/[0.06] overflow-hidden">
        <div className="px-5 pt-5 pb-4 border-b border-white/[0.06]">
          <div className="text-[11px] font-mono uppercase tracking-[0.4em] text-sky-700 mb-1">workbench</div>
          <div className="text-[20px] font-bold tracking-tight text-white leading-none">UART Log</div>
          <div className="mt-1.5 text-[12px] font-mono text-slate-600 truncate leading-none">{snapshot.session.statusLine}</div>
        </div>

        <div className="px-4 py-2.5 border-b border-white/[0.06] flex items-center gap-2">
          <span className={`size-2 rounded-full shrink-0 ${snapshot.session.connected ? "bg-emerald-400 shadow-[0_0_6px_#34d399]" : "bg-slate-700"}`} />
          <span className={`text-[13px] font-mono ${snapshot.session.connected ? "text-emerald-400" : "text-slate-600"}`}>
            {snapshot.session.connected ? "connected" : "offline"}
          </span>
          <span className="ml-auto text-[12px] font-mono text-sky-700">{snapshot.session.transport}</span>
          {snapshot.session.busy ? (
            <span className="text-[12px] font-mono text-amber-400 animate-pulse">busy</span>
          ) : null}
        </div>

        <nav className="flex-1 px-2 py-2 space-y-0.5 overflow-y-auto">
          {navItems.map((item) => {
            const Icon = item.icon;
            const active = item.key === activeScreen;
            return (
              <button
                key={item.key}
                type="button"
                onClick={() => setActiveScreen(item.key)}
                className={`flex w-full items-center gap-2.5 px-3 py-2.5 rounded-sm text-left text-[14px] transition-colors ${
                  active
                    ? "bg-sky-500/[0.12] text-sky-300 border-l-2 border-sky-500 pl-[10px]"
                    : "text-slate-500 hover:text-slate-200 hover:bg-white/[0.04] border-l-2 border-transparent pl-[10px]"
                }`}
              >
                <Icon className="size-3.5 shrink-0" />
                <span className="font-medium">{item.label}</span>
              </button>
            );
          })}
        </nav>

        <div className="px-4 py-3 border-t border-white/[0.06] space-y-1.5">
          <MiniStat k="rx frames" v={`${snapshot.stats.rxFrames}`} />
          <MiniStat k="crc err" v={`${snapshot.stats.crcErrors}`} warn={snapshot.stats.crcErrors > 0} />
          <MiniStat k="lost" v={`${snapshot.stats.lostEvents}`} warn={snapshot.stats.lostEvents > 0} />
          <MiniStat k="last seq" v={snapshot.stats.lastSeq} />
          <MiniStat k="rows" v={`${snapshot.stats.totalRows}`} />
        </div>
      </aside>

      {/* ── CONTENT ── */}
      <div className="flex-1 flex flex-col overflow-hidden min-w-0">
        {/* TRANSPORT CONSOLE */}
        <header className="shrink-0 bg-[#0c1220] border-b border-white/[0.07] px-4 py-3 space-y-2.5">
          {/* Row 1: status + action buttons */}
          <div className="flex flex-wrap items-center gap-2">
            <span className={`text-[12px] font-mono px-2 py-0.5 rounded-sm border ${snapshot.session.decoderLoaded ? "border-emerald-800/60 bg-emerald-950/40 text-emerald-400" : "border-red-800/60 bg-red-950/40 text-red-400"}`}>
              dec:{snapshot.session.decoderLoaded ? "ok" : "err"}
            </span>
            <span className="text-[12px] font-mono text-slate-700">src:{snapshot.session.selectedSrcIdx}</span>
            <span className="text-[12px] font-mono text-slate-700">rows:{snapshot.stats.totalRows}</span>
            <div className="ml-auto flex flex-wrap gap-1.5">
              <CtrlButton onClick={() => void connectOrDisconnect()} disabled={isLoading} primary={!snapshot.session.connected}>
                {snapshot.session.connected ? "Disconnect" : "Connect"}
              </CtrlButton>
              <CtrlButton onClick={() => void runAction("reloadDecoder")} disabled={isLoading}>Reload Dec</CtrlButton>
              <CtrlButton onClick={() => void runAction("setMode", { mode: snapshot.session.mode === "decode" ? "raw" : "decode" })} disabled={isLoading}>
                Mode:{snapshot.session.mode}
              </CtrlButton>
              <CtrlButton onClick={() => void runAction("toggleLog", { logFilePath })} disabled={isLoading}>
                Log:{snapshot.session.logEnabled ? "ON" : "OFF"}
              </CtrlButton>
              <CtrlButton onClick={() => void runAction("clearLogs")} disabled={isLoading}>Clear</CtrlButton>
              <CtrlButton onClick={() => void runAction("sendReset")} disabled={isLoading || !snapshot.session.connected} warn>
                Ctrl+R
              </CtrlButton>
            </div>
          </div>
          {/* Row 2: connection fields */}
          <div className="grid gap-2 md:grid-cols-6 items-end">
            <DkField label="Transport">
              <Select value={transport} onValueChange={(v) => setTransport(v as TransportMode)}>
                <SelectTrigger className="h-9 border-[#1e2d42] bg-[#131d2e] text-sky-100 text-sm font-mono rounded-sm focus:ring-0 focus:ring-offset-0">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="border-[#1e2d42] bg-[#131d2e] text-[#c8d4e8] rounded-sm">
                  <SelectItem value="tcp">tcp</SelectItem>
                  <SelectItem value="serial">serial</SelectItem>
                  <SelectItem value="replay">replay</SelectItem>
                </SelectContent>
              </Select>
            </DkField>
            <DkField label="Port / COM">
              <div className="flex gap-1">
                <Select value={port || "__none__"} onValueChange={(v) => setPort(v === "__none__" ? "" : v)}>
                  <SelectTrigger className="h-9 border-[#1e2d42] bg-[#131d2e] text-sky-100 text-sm font-mono rounded-sm focus:ring-0 focus:ring-offset-0">
                    <SelectValue placeholder="–" />
                  </SelectTrigger>
                  <SelectContent className="border-[#1e2d42] bg-[#131d2e] text-[#c8d4e8] rounded-sm">
                    <SelectItem value="__none__">manual</SelectItem>
                    {ports.map((item) => (
                      <SelectItem key={item.device} value={item.device}>{item.device}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <button
                  type="button"
                  onClick={() => void refreshPorts()}
                  className="h-9 px-2 text-sm font-mono border border-[#1e2d42] bg-[#131d2e] text-slate-500 hover:text-sky-300 hover:border-sky-800 rounded-sm transition-colors shrink-0"
                >
                  ↺
                </button>
              </div>
            </DkField>
            <DkField label="Baud"><DkInput value={baud} onChange={(e) => setBaud(e.target.value)} /></DkField>
            <DkField label="TCP Host"><DkInput value={tcpHost} onChange={(e) => setTcpHost(e.target.value)} /></DkField>
            <DkField label="TCP Port"><DkInput value={tcpPort} onChange={(e) => setTcpPort(e.target.value)} /></DkField>
            <DkField label="Log File"><DkInput value={logFilePath} onChange={(e) => setLogFilePath(e.target.value)} placeholder="optional" /></DkField>
          </div>
          {/* Row 3: decoder + replay */}
          <div className="grid gap-2 md:grid-cols-2">
            <DkField label="Decoder YAML"><DkInput value={decoderPath} onChange={(e) => setDecoderPath(e.target.value)} /></DkField>
            <DkField label="Replay Log Path"><DkInput value={replayPath} onChange={(e) => setReplayPath(e.target.value)} placeholder="required for replay" /></DkField>
          </div>
          {/* Alerts */}
          {errorText ? (
            <div className="flex items-start gap-2 border border-red-800/50 bg-red-950/30 rounded-sm px-3 py-2 text-[13px] font-mono text-red-400">
              <AlertCircle className="mt-0.5 size-3.5 shrink-0" />
              <span>{errorText}</span>
            </div>
          ) : null}
          {snapshot.session.decoderError ? (
            <div className="border border-amber-800/50 bg-amber-950/30 rounded-sm px-3 py-2 text-[13px] font-mono text-amber-400">
              decoder: {snapshot.session.decoderError}
            </div>
          ) : null}
        </header>

        {/* SCREEN AREA */}
        <div className="flex-1 overflow-y-auto p-4 space-y-4">

          {/* LOG */}
          {activeScreen === "log" ? (
            <div className="grid gap-4 xl:grid-cols-[1fr_200px]">
              <DkPanel label="Live Frames" subtitle="19-byte UART log stream">
                <div className="flex flex-wrap items-center gap-2 mb-2">
                  <DkInput value={filterText} onChange={(e) => setFilterText(e.target.value)} placeholder="filter rows…" className="w-52" />
                  <span className="text-[12px] font-mono text-slate-700">filtered:{filteredRows.length}</span>
                  <span className={`text-[12px] font-mono ${snapshot.stats.crcErrors > 0 ? "text-red-500" : "text-slate-700"}`}>crc:{snapshot.stats.crcErrors}</span>
                  <span className={`text-[12px] font-mono ${snapshot.stats.lostEvents > 0 ? "text-amber-500" : "text-slate-700"}`}>lost:{snapshot.stats.lostEvents}</span>
                </div>
                <ScrollArea className="h-[calc(100vh-360px)] min-h-[200px] rounded-sm border border-white/[0.06]">
                  <div className="min-w-[1100px]">
                    <div className="grid grid-cols-[108px_68px_60px_60px_86px_96px_96px_96px_56px_68px_minmax(280px,1fr)] gap-x-2 sticky top-0 bg-[#0a0e17] px-3 py-2 border-b border-white/[0.08]">
                      {["Time", "SEQ", "SRC", "EVT", "TS", "ARG0", "ARG1", "ARG2", "CRC", "Mode", "Text"].map((h) => (
                        <span key={h} className="text-[11px] font-mono uppercase tracking-[0.2em] text-sky-800">{h}</span>
                      ))}
                    </div>
                    {visibleRows.map((row, index) => {
                      const t = row.text.toLowerCase();
                      const rowCls =
                        row.modeText === "raw" ? "text-slate-600" :
                        t.includes("error") || t.includes("fail") ? "bg-red-950/20 text-red-300" :
                        t.includes("warn") ? "bg-amber-950/20 text-amber-300/90" :
                        index % 2 === 0 ? "bg-white/[0.015]" : "";
                      return (
                        <div
                          key={`${row.seqText}-${index}`}
                          className={`grid grid-cols-[108px_68px_60px_60px_86px_96px_96px_96px_56px_68px_minmax(280px,1fr)] gap-x-2 px-3 py-[5px] border-b border-white/[0.04] text-[13px] font-mono ${rowCls}`}
                        >
                          <span className="text-slate-600">{row.hostTime}</span>
                          <span className="text-slate-400">{row.seqText}</span>
                          <span className="text-sky-700">{row.srcText}</span>
                          <span className="text-sky-500">{row.evtText}</span>
                          <span className="text-slate-500">{row.timestampText}</span>
                          <span>{row.arg0Text}</span>
                          <span>{row.arg1Text}</span>
                          <span>{row.arg2Text}</span>
                          <span className={row.crcText === "ok" ? "text-emerald-600" : "text-red-500"}>{row.crcText}</span>
                          <span className="text-slate-700">{row.modeText}</span>
                          <span className="pr-3 truncate">{row.text}</span>
                        </div>
                      );
                    })}
                  </div>
                </ScrollArea>
              </DkPanel>
              <DkPanel label="Stream Stats">
                <div className="space-y-1 text-[13px] font-mono">
                  <StatRow k="transport" v={snapshot.session.transport} />
                  <StatRow k="connected" v={snapshot.session.connected ? "yes" : "no"} ok={snapshot.session.connected} />
                  <StatRow k="port" v={snapshot.session.port ?? "—"} />
                  <StatRow k="baud" v={`${snapshot.session.baud}`} />
                  <StatRow k="tcp host" v={snapshot.session.tcpHost} />
                  <StatRow k="tcp port" v={`${snapshot.session.tcpPort}`} />
                  <div className="border-t border-white/[0.06] my-2" />
                  <StatRow k="rx frames" v={`${snapshot.stats.rxFrames}`} />
                  <StatRow k="tcp pkts" v={`${snapshot.stats.tcpPackets}`} />
                  <StatRow k="tcp bytes" v={`${snapshot.stats.tcpBytes}`} />
                  <StatRow k="last seq" v={snapshot.stats.lastSeq} />
                  <div className="border-t border-white/[0.06] my-2" />
                  <StatRow k="log file" v={snapshot.session.logFilePath ?? "—"} />
                  <StatRow k="replay" v={snapshot.session.replayPath ?? "—"} />
                  <StatRow k="decoder" v={snapshot.session.decoderPath || "—"} />
                </div>
              </DkPanel>
            </div>
          ) : null}

          {/* ── SDRAM (Map + RW unified) ─────────────────────────────── */}
          {activeScreen === "sdram" ? (
            <div className="space-y-4">
              {/* Single R/W + Bulk/Burst side-by-side */}
              <div className="grid gap-4 xl:grid-cols-2">
                <DkPanel label="SDRAM Read / Write" subtitle={snapshot.sdramRw.summary}>
                  <RwGroup title="Single Read" result={snapshot.sdramRw.singleReadResult}>
                    <DkInput value={singleReadAddr} onChange={(e) => setSingleReadAddr(e.target.value)} placeholder="addr" />
                    <CtrlButton onClick={() => void runAction("singleRead", { addr: singleReadAddr })} disabled={isLoading} primary>Read</CtrlButton>
                  </RwGroup>
                  <RwGroup title="Single Write" result={snapshot.sdramRw.singleWriteResult}>
                    <DkInput value={singleWriteAddr} onChange={(e) => setSingleWriteAddr(e.target.value)} placeholder="addr" />
                    <DkInput value={singleWriteData} onChange={(e) => setSingleWriteData(e.target.value)} placeholder="data" />
                    <CtrlButton onClick={() => void runAction("singleWrite", { addr: singleWriteAddr, data: singleWriteData })} disabled={isLoading} primary>Write</CtrlButton>
                  </RwGroup>
                  <RwGroup title="Bulk File Write" result={snapshot.sdramRw.fileWriteResult}>
                    <DkInput value={fileWriteAddr} onChange={(e) => setFileWriteAddr(e.target.value)} placeholder="base addr" />
                    <DkInput value={fileWritePath} onChange={(e) => setFileWritePath(e.target.value)} placeholder=".bin / .hex path" />
                    <CtrlButton onClick={() => void runAction("fileWrite", { baseAddr: fileWriteAddr, filePath: fileWritePath })} disabled={isLoading} primary>Write File</CtrlButton>
                  </RwGroup>
                </DkPanel>

                <DkPanel label="Bulk / Burst" subtitle={snapshot.sdramBurst.summary}>
                  <div className="grid gap-2 grid-cols-3 mb-3">
                    <DkField label="Base Addr"><DkInput value={burstBaseAddr} onChange={(e) => setBurstBaseAddr(e.target.value)} /></DkField>
                    <DkField label="Words"><DkInput value={burstWords} onChange={(e) => setBurstWords(e.target.value)} /></DkField>
                    <DkField label="Pattern"><DkInput value={bulkPattern} onChange={(e) => setBulkPattern(e.target.value)} /></DkField>
                  </div>
                  <div className="flex flex-wrap gap-2 mb-4">
                    <CtrlButton onClick={() => void runAction("bulkRangeRead", { baseAddr: burstBaseAddr, words: burstWords })} disabled={isLoading} primary>Bulk Read</CtrlButton>
                    <CtrlButton onClick={() => void runAction("bulkPatternWrite", { baseAddr: burstBaseAddr, words: burstWords, pattern: bulkPattern })} disabled={isLoading}>Pattern Write</CtrlButton>
                    <CtrlButton onClick={() => void runAction("burstReadTest", { baseAddr: burstBaseAddr, words: burstWords })} disabled={isLoading}>Burst Read</CtrlButton>
                    <CtrlButton onClick={() => void runAction("burstWriteTest", { baseAddr: burstBaseAddr, words: burstWords })} disabled={isLoading}>Burst Write</CtrlButton>
                  </div>
                  <div className="grid grid-cols-2 gap-2 mb-4">
                    <KvCell k="task" v={snapshot.sdramBurst.task} />
                    <KvCell k="packets" v={`${snapshot.sdramBurst.packetsReceived}/${snapshot.sdramBurst.packetCount}`} />
                    <KvCell k="base" v={`0x${snapshot.sdramBurst.baseAddr.toString(16).toUpperCase().padStart(5, "0")}`} />
                    <KvCell k="words" v={`${snapshot.sdramBurst.words}`} />
                  </div>
                  <pre className="rounded-sm border border-white/[0.07] bg-[#05080e] px-4 py-3 text-[13px] font-mono leading-6 text-emerald-300 whitespace-pre-wrap overflow-x-auto">{snapshot.sdramBurst.result}{"\n\n"}{snapshot.sdramBurst.preview}</pre>
                </DkPanel>
              </div>

              {/* Map — bottom */}
              <DkPanel label="SDRAM Map" subtitle="16×16 word window — bulk read from SDRAM host space">
                <div className="flex flex-wrap items-center gap-2 mb-3">
                  <span className="text-[13px] font-mono text-sky-500">{snapshot.sdramMap.summary}</span>
                  <div className="ml-auto flex gap-2">
                    <DkInput value={mapBaseAddr} onChange={(e) => setMapBaseAddr(e.target.value)} className="w-36" />
                    <CtrlButton onClick={() => void runAction("refreshMap", { baseAddr: mapBaseAddr })} disabled={isLoading} primary>Refresh Map</CtrlButton>
                  </div>
                </div>
                <ScrollArea className="h-[480px]">
                  <pre className="min-w-max px-4 py-3 text-[13px] font-mono leading-6 text-emerald-300 bg-[#05080e] rounded-sm border border-white/[0.05] whitespace-pre">{snapshot.sdramMap.text}</pre>
                </ScrollArea>
              </DkPanel>
            </div>
          ) : null}

          {/* ── SDRAM STATUS ─────────────────────────────────────────── */}
          {activeScreen === "sdram-status" ? (
            <DkPanel label="SDRAM Status" subtitle="80-byte register block — status + write-only control">
              <div className="flex flex-wrap items-center gap-2 mb-4">
                <span className="text-[13px] font-mono text-sky-500">{snapshot.sdramStatus.summary}</span>
                <div className="ml-auto flex gap-2">
                  <CtrlButton onClick={() => void runAction("refreshStatus")} disabled={isLoading} primary>Refresh</CtrlButton>
                  <CtrlButton onClick={() => void runAction("toggleStatusMode")} disabled={isLoading}>Mode: {snapshot.session.statusMode}</CtrlButton>
                  <CtrlButton onClick={() => void runAction("runStatusSelftest")} disabled={isLoading} warn>Selftest</CtrlButton>
                </div>
              </div>
              <SdramStatusGrid text={snapshot.sdramStatus.text} />
            </DkPanel>
          ) : null}

          {/* ── EEPROM (Map + RW unified) ────────────────────────────── */}
          {activeScreen === "eeprom" ? (
            <div className="space-y-4">
              {/* R/W controls */}
              <DkPanel label="EEPROM Read / Write" subtitle={snapshot.eepromRw.summary}>
                <div className="grid gap-4 xl:grid-cols-3">
                  <RwGroup title="Single Read" result={snapshot.eepromRw.singleReadResult}>
                    <DkInput value={eepromReadAddr} onChange={(e) => setEepromReadAddr(e.target.value)} placeholder="addr" />
                    <CtrlButton onClick={() => void runAction("eepromSingleRead", { addr: eepromReadAddr })} disabled={isLoading} primary>Read</CtrlButton>
                  </RwGroup>
                  <RwGroup title="Single Write" result={snapshot.eepromRw.singleWriteResult}>
                    <DkInput value={eepromWriteAddr} onChange={(e) => setEepromWriteAddr(e.target.value)} placeholder="addr" />
                    <DkInput value={eepromWriteData} onChange={(e) => setEepromWriteData(e.target.value)} placeholder="data" />
                    <CtrlButton onClick={() => void runAction("eepromSingleWrite", { addr: eepromWriteAddr, data: eepromWriteData })} disabled={isLoading} primary>Write</CtrlButton>
                  </RwGroup>
                  <RwGroup title="Bulk File Write" result={snapshot.eepromRw.fileWriteResult}>
                    <DkInput value={eepromFileAddr} onChange={(e) => setEepromFileAddr(e.target.value)} placeholder="base addr" />
                    <DkInput value={eepromFilePath} onChange={(e) => setEepromFilePath(e.target.value)} placeholder=".bin / .hex path" />
                    <CtrlButton onClick={() => void runAction("eepromFileWrite", { baseAddr: eepromFileAddr, filePath: eepromFilePath })} disabled={isLoading} primary>Write File</CtrlButton>
                  </RwGroup>
                </div>
              </DkPanel>

              {/* Map section — bottom */}
              <DkPanel label="EEPROM Map" subtitle="16×16 byte window with ASCII side-by-side">
                <div className="flex flex-wrap items-center gap-2 mb-3">
                  <span className="text-[13px] font-mono text-sky-500">{snapshot.eepromMap.summary}</span>
                  <div className="ml-auto flex gap-2">
                    <DkInput value={eepromMapBase} onChange={(e) => setEepromMapBase(e.target.value)} className="w-36" />
                    <CtrlButton onClick={() => void runAction("refreshEepromMap", { baseAddr: eepromMapBase })} disabled={isLoading} primary>Refresh Map</CtrlButton>
                  </div>
                </div>
                <ScrollArea className="h-[480px]">
                  <pre className="min-w-max px-4 py-3 text-[13px] font-mono leading-6 text-emerald-300 bg-[#05080e] rounded-sm border border-white/[0.05] whitespace-pre">{snapshot.eepromMap.text}</pre>
                </ScrollArea>
              </DkPanel>
            </div>
          ) : null}

          {/* ── SSD1306 (Display controls + GDDRAM editor) ───────────── */}
          {activeScreen === "ssd1306" ? (
            <div className="space-y-4">
              {/* Display controls */}
              <DkPanel label="SSD1306 Display" subtitle={snapshot.display.summary}>
                <div className="flex flex-wrap items-center gap-2 mb-3">
                  <CtrlButton onClick={() => void runAction("displayInit")} disabled={isLoading} primary>Init</CtrlButton>
                  <CtrlButton onClick={() => void runAction("displayClear")} disabled={isLoading}>Clear</CtrlButton>
                  <CtrlButton onClick={() => void runAction("displayPattern")} disabled={isLoading}>Checker</CtrlButton>
                  <CtrlButton onClick={() => void runAction("displayRefresh")} disabled={isLoading}>Refresh</CtrlButton>
                  <CtrlButton onClick={() => void runAction("displayOn")} disabled={isLoading}>ON</CtrlButton>
                  <CtrlButton onClick={() => void runAction("displayOff")} disabled={isLoading}>OFF</CtrlButton>
                  <CtrlButton onClick={() => void runAction("displayAutoOn")} disabled={isLoading}>Auto ON</CtrlButton>
                  <CtrlButton onClick={() => void runAction("displayAutoOff")} disabled={isLoading}>Auto OFF</CtrlButton>
                  <div className="ml-auto flex items-center gap-2">
                    <span className="text-[13px] font-mono text-slate-400">FPS</span>
                    <DkInput value={displayFps} onChange={(e) => setDisplayFps(e.target.value)} className="w-16" />
                    <CtrlButton onClick={() => void runAction("displaySetFps", { fps: displayFps })} disabled={isLoading}>Set</CtrlButton>
                  </div>
                </div>
              </DkPanel>

              {/* GDDRAM editor controls */}
              <DkPanel label="GDDRAM Editor" subtitle={snapshot.ssd1306.summary}>
                <div className="flex flex-wrap items-center gap-2 mb-3">
                  <CtrlButton onClick={() => void readGddram()} disabled={isLoading} primary>Read Frame</CtrlButton>
                  <CtrlButton onClick={() => void runAction("ssd1306WriteFrame", { framebytes: localFrame })} disabled={isLoading} primary>Write &amp; Refresh</CtrlButton>
                  <CtrlButton onClick={() => setLocalFrame(new Array(512).fill(0))} disabled={isLoading}>Clear</CtrlButton>
                  <CtrlButton onClick={() => setLocalFrame(new Array(512).fill(0xff))} disabled={isLoading}>Fill</CtrlButton>
                  <CtrlButton onClick={() => setLocalFrame((f) => f.map((b) => (~b) & 0xff))} disabled={isLoading}>Invert</CtrlButton>
                </div>
                <div className="h-7 text-[12px] font-mono text-slate-500 leading-7">
                  {hoveredPixel
                    ? `x=${hoveredPixel.x} y=${hoveredPixel.y} → page=${hoveredPixel.y >> 3} bit=${hoveredPixel.y & 7} → byte[0x${((hoveredPixel.y >> 3) * 128 + hoveredPixel.x).toString(16).toUpperCase().padStart(3, "0")}]=0x${(localFrame[(hoveredPixel.y >> 3) * 128 + hoveredPixel.x] ?? 0).toString(16).toUpperCase().padStart(2, "0")} → ${gddramGetPixel(localFrame, hoveredPixel.x, hoveredPixel.y) ? "ON" : "OFF"}`
                    : "hover a pixel to inspect — left-drag: paint ON · right-drag: paint OFF"}
                </div>
              </DkPanel>

              {/* Pixel editor + preview side-by-side */}
              <div className="grid gap-4 xl:grid-cols-[auto_1fr]">
                <DkPanel label="Pixel Editor" subtitle="128 × 32 — 6 px/cell">
                  <div className="overflow-x-auto">
                    <canvas
                      ref={editorCanvasRef}
                      width={128 * 6}
                      height={32 * 6}
                      className="block border border-white/[0.1] cursor-crosshair select-none"
                      onMouseDown={handleEditorMouseDown}
                      onMouseMove={handleEditorMouseMove}
                      onMouseUp={() => setIsPainting(false)}
                      onMouseLeave={() => { setIsPainting(false); setHoveredPixel(null); }}
                      onContextMenu={(e) => e.preventDefault()}
                    />
                  </div>
                  <div className="mt-2 grid grid-cols-4 gap-2 text-[12px] font-mono text-slate-600">
                    <span>P0: y=0–7</span><span>P1: y=8–15</span><span>P2: y=16–23</span><span>P3: y=24–31</span>
                  </div>
                </DkPanel>
                <DkPanel label="Display Preview" subtitle="128 × 32 — 2× scale">
                  <canvas
                    ref={previewCanvasRef}
                    width={128 * 2}
                    height={32 * 2}
                    className="block border border-white/[0.1] mb-3"
                    style={{ imageRendering: "pixelated" }}
                  />
                </DkPanel>
              </div>

              {/* Memory Map */}
              <DkPanel label="GDDRAM Memory Map" subtitle="4 pages × 128 bytes — SSD1306 page addressing">
                <div className="overflow-x-auto">
                  <table className="border-collapse w-full text-[12px] font-mono">
                    <thead>
                      <tr>
                        <th className="text-left text-[11px] text-sky-700 uppercase tracking-[0.2em] pr-4 py-1 w-16">Addr</th>
                        {Array.from({ length: 16 }, (_, i) => (
                          <th key={i} className="text-right text-[11px] text-sky-700 px-1 py-1 w-7">
                            +{i.toString(16).toUpperCase()}
                          </th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {Array.from({ length: 32 }, (_, rowIdx) => {
                        const baseByteIdx = rowIdx * 16;
                        const page = rowIdx >> 3;
                        const isPageBoundary = (rowIdx & 7) === 0;
                        return (
                          <React.Fragment key={rowIdx}>
                            {isPageBoundary ? (
                              <tr>
                                <td colSpan={17} className="text-[11px] font-mono uppercase tracking-[0.2em] text-sky-700 bg-white/[0.04] px-2 py-1 border-t border-sky-900/40">
                                  page {page} — y={page * 8}–{page * 8 + 7}
                                </td>
                              </tr>
                            ) : null}
                            <tr className={`border-b border-white/[0.04] ${rowIdx % 2 === 0 ? "bg-white/[0.01]" : ""}`}>
                              <td className="text-slate-500 pr-4 py-0.5 text-right">0x{baseByteIdx.toString(16).toUpperCase().padStart(3, "0")}</td>
                              {Array.from({ length: 16 }, (_, col) => {
                                const idx = baseByteIdx + col;
                                const val = localFrame[idx] ?? 0;
                                return (
                                  <td key={col} className={`text-right px-1 py-0.5 tabular-nums ${val === 0xff ? "text-emerald-300" : val !== 0 ? "text-emerald-400" : "text-slate-600"}`}>
                                    {val.toString(16).toUpperCase().padStart(2, "0")}
                                  </td>
                                );
                              })}
                            </tr>
                          </React.Fragment>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              </DkPanel>
            </div>
          ) : null}

          {activeScreen === "ocr" ? (
            <div className="space-y-4">
              <DkPanel label="OCR Inference" subtitle={snapshot.ocr.summary}>
                <div className="flex flex-wrap items-center gap-2 mb-4">
                  <CtrlButton
                    onClick={() => void runAction("runOcr")}
                    disabled={isLoading}
                    primary
                  >
                    Run OCR (Z)
                  </CtrlButton>
                </div>
                <div className="grid grid-cols-2 gap-x-8 gap-y-1.5 text-[13px] font-mono">
                  <MiniStat k="Class index" v={snapshot.ocr.lastClass !== null ? `${snapshot.ocr.lastClass}` : "-"} />
                  <MiniStat k="Character" v={snapshot.ocr.lastChar !== null ? `'${snapshot.ocr.lastChar}'` : "-"} />
                  <MiniStat k="Score 0 (top)" v={snapshot.ocr.lastScore0 !== null ? `${snapshot.ocr.lastScore0}` : "-"} />
                  <MiniStat k="Score 1 (2nd)" v={snapshot.ocr.lastScore1 !== null ? `${snapshot.ocr.lastScore1}` : "-"} />
                  <MiniStat k="Confidence gap" v={snapshot.ocr.lastConfGap !== null ? `${snapshot.ocr.lastConfGap}` : "-"} warn={(snapshot.ocr.lastConfGap ?? 1) < 0} />
                </div>
              </DkPanel>

              <DkPanel label="OCR Cycle Counts" subtitle="reported by EVT_OCR_CYCLES">
                <div className="grid grid-cols-2 gap-x-8 gap-y-1.5 text-[13px] font-mono">
                  <MiniStat k="Total cycles" v={snapshot.ocr.lastCyclesTotal !== null ? `${snapshot.ocr.lastCyclesTotal}` : "-"} />
                  <MiniStat k="Layer 0 cycles" v={snapshot.ocr.lastCyclesL0 !== null ? `${snapshot.ocr.lastCyclesL0}` : "-"} />
                  <MiniStat k="Layer 1 cycles" v={snapshot.ocr.lastCyclesL1 !== null ? `${snapshot.ocr.lastCyclesL1}` : "-"} />
                </div>
              </DkPanel>
            </div>
          ) : null}

        </div>
      </div>
    </main>
  );
}

// ── helper components ─────────────────────────────────────────────────────────

function MiniStat({ k, v, warn }: { k: string; v: string; warn?: boolean }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-[13px] font-mono text-slate-500">{k}</span>
      <span className={`text-[13px] font-mono font-medium ${warn ? "text-amber-400" : "text-slate-300"}`}>{v}</span>
    </div>
  );
}

function CtrlButton({
  children,
  onClick,
  disabled,
  primary,
  warn,
}: {
  children: React.ReactNode;
  onClick?: () => void;
  disabled?: boolean;
  primary?: boolean;
  warn?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={`h-8 px-3 text-[13px] font-mono font-semibold rounded-sm border transition-colors disabled:opacity-40 disabled:cursor-not-allowed ${
        primary
          ? "border-sky-600/70 bg-sky-600/25 text-sky-200 hover:bg-sky-600/40 hover:border-sky-400"
          : warn
            ? "border-amber-700/50 bg-amber-950/40 text-amber-300 hover:bg-amber-950/60"
            : "border-[#2a3a52] bg-transparent text-slate-300 hover:text-white hover:bg-white/[0.06] hover:border-slate-500"
      }`}
    >
      {children}
    </button>
  );
}

function DkInput({
  value,
  onChange,
  placeholder,
  className,
}: {
  value: string;
  onChange: (e: React.ChangeEvent<HTMLInputElement>) => void;
  placeholder?: string;
  className?: string;
}) {
  return (
    <input
      value={value}
      onChange={onChange}
      placeholder={placeholder}
      className={`h-9 w-full rounded-sm border border-[#2a3a52] bg-[#131d2e] px-2.5 text-[13px] font-mono text-sky-50 placeholder-slate-600 outline-none focus:border-sky-600/80 transition-colors ${className ?? ""}`}
    />
  );
}

function DkField({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="grid gap-1">
      <span className="text-[12px] font-mono uppercase tracking-[0.25em] text-sky-600">{label}</span>
      {children}
    </label>
  );
}

function DkPanel({ label, subtitle, children }: { label: string; subtitle?: string; children: React.ReactNode }) {
  return (
    <div className="rounded-sm border border-white/[0.08] bg-[#0e1521] overflow-hidden">
      <div className="px-4 py-2.5 border-b border-white/[0.07] flex items-baseline gap-3">
        <span className="text-[12px] font-mono uppercase tracking-[0.3em] text-sky-500 shrink-0">{label}</span>
        {subtitle ? <span className="text-[13px] font-mono text-slate-500 truncate">{subtitle}</span> : null}
      </div>
      <div className="p-4">{children}</div>
    </div>
  );
}

function StatRow({ k, v, ok }: { k: string; v: string; ok?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-2 py-0.5">
      <span className="text-slate-500 shrink-0">{k}</span>
      <span className={`truncate text-right font-medium ${ok === true ? "text-emerald-400" : ok === false ? "text-slate-600" : "text-slate-200"}`}>{v}</span>
    </div>
  );
}

function KvCell({ k, v }: { k: string; v: string }) {
  return (
    <div className="rounded-sm border border-white/[0.07] bg-[#0c1220] px-3 py-2">
      <div className="text-[11px] font-mono uppercase tracking-[0.25em] text-sky-700">{k}</div>
      <div className="mt-0.5 text-[13px] font-mono font-medium text-slate-100 truncate">{v}</div>
    </div>
  );
}

function RwGroup({ title, result, children }: { title: string; result: string; children: React.ReactNode }) {
  return (
    <div className="rounded-sm border border-white/[0.07] bg-[#0c1220] p-3 mb-3 last:mb-0">
      <div className="flex items-center justify-between gap-2 mb-2.5">
        <span className="text-[14px] font-semibold text-slate-200">{title}</span>
        <span className="text-[13px] font-mono text-sky-400 truncate max-w-[55%]">{result}</span>
      </div>
      <div className="flex flex-wrap gap-2">{children}</div>
    </div>
  );
}



// ── SDRAM Status register grid ────────────────────────────────────────────────
// Parses the plain-text status output into structured register cards.
function SdramStatusGrid({ text }: { text: string }) {
  if (!text || text === "-") {
    return <p className="text-[13px] font-mono text-slate-600">No data — press Refresh.</p>;
  }

  const lines = text.split("\n");
  type Block = { regName: string; rawVal: string; fields: string[] };
  const blocks: Block[] = [];
  let current: Block | null = null;

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const isHeader = /^(0x[0-9A-Fa-f]{2}\s+\w|Base:|Control:|Raw\s+words:)/.test(trimmed);
    if (isHeader) {
      if (current) blocks.push(current);
      // parse "0x00 REG_NAME = 0xHHHHHHHH" or plain header
      const m = trimmed.match(/^(0x[\dA-Fa-f]{2}\s+\S+)\s*=\s*(0x[\dA-Fa-f]+)/);
      current = { regName: m ? m[1] : trimmed, rawVal: m ? m[2] : "", fields: [] };
    } else if (current) {
      current.fields.push(trimmed);
    }
  }
  if (current) blocks.push(current);

  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-[12px] font-mono">
        <thead>
          <tr className="border-b border-white/[0.1]">
            <th className="text-left text-[11px] uppercase tracking-[0.2em] text-sky-700 pb-2 pr-4 whitespace-nowrap w-44">Register</th>
            <th className="text-left text-[11px] uppercase tracking-[0.2em] text-sky-700 pb-2 pr-6 whitespace-nowrap w-28">Value</th>
            <th className="text-left text-[11px] uppercase tracking-[0.2em] text-sky-700 pb-2">Fields</th>
          </tr>
        </thead>
        <tbody>
          {blocks.map((block, bi) => (
            <tr key={bi} className={`border-b border-white/[0.04] align-top ${
              bi % 2 === 0 ? "" : "bg-white/[0.015]"
            }`}>
              <td className="py-1.5 pr-4 text-sky-500 whitespace-nowrap">{block.regName}</td>
              <td className="py-1.5 pr-6 text-slate-400 whitespace-nowrap tabular-nums">{block.rawVal}</td>
              <td className="py-1.5">
                <div className="flex flex-wrap gap-x-5 gap-y-0">
                  {block.fields.map((field, fi) => {
                    const ci = field.indexOf(":");
                    if (ci === -1) return <span key={fi} className="text-slate-500">{field}</span>;
                    const fk = field.slice(0, ci).trim();
                    const fv = field.slice(ci + 1).trim();
                    const isFail = (fk.includes("fail") || fk.includes("error") || fk.includes("exhausted")) && fv !== "0";
                    const isGood = (fv === "1" || fv === "PASS" || fv === "DONE") && !fk.includes("fail") && !fk.includes("error") && !fk.includes("exhausted");
                    const isBad = fv === "0" && (fk.includes("pass") || fk.includes("done") || fk.includes("valid") || fk.includes("ok"));
                    return (
                      <span key={fi} className="whitespace-nowrap">
                        <span className="text-slate-600">{fk}=</span>
                        <span className={isFail ? "text-red-400" : isGood ? "text-emerald-400" : isBad ? "text-red-400" : "text-slate-300"}>{fv}</span>
                      </span>
                    );
                  })}
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
