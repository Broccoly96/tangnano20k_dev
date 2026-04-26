"use client";

import { startTransition, useDeferredValue, useEffect, useState } from "react";
import { AlertCircle, Cpu, Database, HardDrive, MonitorSmartphone, RefreshCcw, Router } from "lucide-react";

import { ScrollArea } from "@/components/ui/scroll-area";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { PortInfo, TransportMode, WorkbenchSnapshot } from "@/lib/workbench/types";

type ScreenKey = "log" | "sdram-map" | "sdram-rw" | "sdram-status" | "eeprom-map" | "eeprom-rw" | "display";

const navItems: Array<{ key: ScreenKey; label: string; icon: typeof Router }> = [
  { key: "log", label: "Log", icon: Router },
  { key: "sdram-map", label: "SDRAM Map", icon: HardDrive },
  { key: "sdram-rw", label: "SDRAM RW", icon: Cpu },
  { key: "sdram-status", label: "SDRAM STS", icon: RefreshCcw },
  { key: "eeprom-map", label: "EEPROM Map", icon: Database },
  { key: "eeprom-rw", label: "EEPROM RW", icon: Database },
  { key: "display", label: "Display", icon: MonitorSmartphone },
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
  const [displayColor, setDisplayColor] = useState("FF6600");
  const [displayFps, setDisplayFps] = useState("10");
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

          {/* SDRAM MAP */}
          {activeScreen === "sdram-map" ? (
            <TerminalScreen
              label="SDRAM Map" subtitle="16×16 word bulk-read from SDRAM host space"
              summary={snapshot.sdramMap.summary} text={snapshot.sdramMap.text}
              actions={
                <div className="flex gap-2">
                  <DkInput value={mapBaseAddr} onChange={(e) => setMapBaseAddr(e.target.value)} className="w-36" />
                  <CtrlButton onClick={() => void runAction("refreshMap", { baseAddr: mapBaseAddr })} disabled={isLoading} primary>Refresh Map</CtrlButton>
                </div>
              }
            />
          ) : null}

          {/* SDRAM STATUS */}
          {activeScreen === "sdram-status" ? (
            <TerminalScreen
              label="SDRAM Status" subtitle="80-byte status / register block"
              summary={snapshot.sdramStatus.summary} text={snapshot.sdramStatus.text}
              actions={
                <div className="flex flex-wrap gap-2">
                  <CtrlButton onClick={() => void runAction("refreshStatus")} disabled={isLoading} primary>Refresh</CtrlButton>
                  <CtrlButton onClick={() => void runAction("toggleStatusMode")} disabled={isLoading}>Mode:{snapshot.session.statusMode}</CtrlButton>
                  <CtrlButton onClick={() => void runAction("runStatusSelftest")} disabled={isLoading} warn>Selftest</CtrlButton>
                </div>
              }
            />
          ) : null}

          {/* SDRAM RW */}
          {activeScreen === "sdram-rw" ? (
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
                <pre className="rounded-sm border border-white/[0.07] bg-[#05080e] px-4 py-3 text-[13px] font-mono leading-6 text-emerald-400 whitespace-pre-wrap overflow-x-auto">{snapshot.sdramBurst.result}{"\n\n"}{snapshot.sdramBurst.preview}</pre>
              </DkPanel>
            </div>
          ) : null}

          {/* EEPROM MAP */}
          {activeScreen === "eeprom-map" ? (
            <TerminalScreen
              label="EEPROM Map" subtitle="16×16 byte window with ASCII side-by-side"
              summary={snapshot.eepromMap.summary} text={snapshot.eepromMap.text}
              actions={
                <div className="flex gap-2">
                  <DkInput value={eepromMapBase} onChange={(e) => setEepromMapBase(e.target.value)} className="w-36" />
                  <CtrlButton onClick={() => void runAction("refreshEepromMap", { baseAddr: eepromMapBase })} disabled={isLoading} primary>Refresh EEPROM Map</CtrlButton>
                </div>
              }
            />
          ) : null}

          {/* EEPROM RW */}
          {activeScreen === "eeprom-rw" ? (
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
          ) : null}

          {/* DISPLAY */}
          {activeScreen === "display" ? (
            <DkPanel label="SSD1306 Display" subtitle={snapshot.display.summary}>
              <div className="flex flex-wrap gap-2 mb-4">
                <CtrlButton onClick={() => void runAction("displayInit")} disabled={isLoading} primary>Init</CtrlButton>
                <CtrlButton onClick={() => void runAction("displayClear")} disabled={isLoading}>Clear</CtrlButton>
                <CtrlButton onClick={() => void runAction("displayPattern")} disabled={isLoading}>Checker</CtrlButton>
                <CtrlButton onClick={() => void runAction("displayRefresh")} disabled={isLoading}>Refresh</CtrlButton>
                <CtrlButton onClick={() => void runAction("displayOn")} disabled={isLoading}>ON</CtrlButton>
                <CtrlButton onClick={() => void runAction("displayOff")} disabled={isLoading}>OFF</CtrlButton>
                <CtrlButton onClick={() => void runAction("displayAutoOn")} disabled={isLoading}>Auto ON</CtrlButton>
                <CtrlButton onClick={() => void runAction("displayAutoOff")} disabled={isLoading}>Auto OFF</CtrlButton>
              </div>
              <div className="grid gap-3 md:grid-cols-2">
                <DkField label="Framebuffer Fill (000000=off, non-zero=on)">
                  <div className="flex items-center gap-2">
                    <DkInput value={displayColor} onChange={(e) => setDisplayColor(e.target.value)} className="w-36" />
                    <div
                      className="size-7 rounded-sm border border-white/10 shrink-0"
                      style={{ backgroundColor: `#${displayColor}` }}
                    />
                    <CtrlButton onClick={() => void runAction("displayFill", { color: displayColor })} disabled={isLoading} primary>Write + Refresh</CtrlButton>
                  </div>
                </DkField>
                <DkField label="Refresh FPS">
                  <div className="flex items-center gap-2">
                    <DkInput value={displayFps} onChange={(e) => setDisplayFps(e.target.value)} className="w-24" />
                    <CtrlButton onClick={() => void runAction("displaySetFps", { fps: displayFps })} disabled={isLoading}>Apply FPS</CtrlButton>
                  </div>
                </DkField>
              </div>
              <DkField label="Flow">
                <div className="flex items-center gap-2">
                  <span className="text-[12px] font-mono text-slate-500">
                    source2 bulk-write to SDRAM framebuffer @ 0x10000, then source3 refreshes SSD1306 from SDRAM.
                  </span>
                </div>
              </DkField>
            </DkPanel>
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
      <span className="text-[12px] font-mono text-slate-700">{k}</span>
      <span className={`text-[12px] font-mono ${warn ? "text-amber-500" : "text-slate-500"}`}>{v}</span>
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
          ? "border-sky-700/60 bg-sky-600/20 text-sky-300 hover:bg-sky-600/30 hover:border-sky-500"
          : warn
            ? "border-amber-700/50 bg-amber-950/40 text-amber-400 hover:bg-amber-950/60"
            : "border-[#1e2d42] bg-transparent text-slate-400 hover:text-slate-200 hover:bg-white/[0.04] hover:border-slate-600"
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
      className={`h-9 w-full rounded-sm border border-[#1e2d42] bg-[#131d2e] px-2.5 text-[13px] font-mono text-sky-100 placeholder-slate-700 outline-none focus:border-sky-700/70 transition-colors ${className ?? ""}`}
    />
  );
}

function DkField({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="grid gap-1">
      <span className="text-[11px] font-mono uppercase tracking-[0.3em] text-sky-800">{label}</span>
      {children}
    </label>
  );
}

function DkPanel({ label, subtitle, children }: { label: string; subtitle?: string; children: React.ReactNode }) {
  return (
    <div className="rounded-sm border border-white/[0.07] bg-[#0e1521] overflow-hidden">
      <div className="px-4 py-2.5 border-b border-white/[0.06] flex items-baseline gap-3">
        <span className="text-[11px] font-mono uppercase tracking-[0.35em] text-sky-700 shrink-0">{label}</span>
        {subtitle ? <span className="text-[12px] font-mono text-slate-600 truncate">{subtitle}</span> : null}
      </div>
      <div className="p-4">{children}</div>
    </div>
  );
}

function StatRow({ k, v, ok }: { k: string; v: string; ok?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-2 py-0.5">
      <span className="text-slate-700 shrink-0">{k}</span>
      <span className={`truncate text-right ${ok === true ? "text-emerald-400" : ok === false ? "text-slate-600" : "text-slate-300"}`}>{v}</span>
    </div>
  );
}

function KvCell({ k, v }: { k: string; v: string }) {
  return (
    <div className="rounded-sm border border-white/[0.06] bg-[#0c1220] px-3 py-2">
      <div className="text-[11px] font-mono uppercase tracking-[0.25em] text-sky-800">{k}</div>
      <div className="mt-0.5 text-[13px] font-mono font-medium text-slate-200 truncate">{v}</div>
    </div>
  );
}

function RwGroup({ title, result, children }: { title: string; result: string; children: React.ReactNode }) {
  return (
    <div className="rounded-sm border border-white/[0.07] bg-[#0c1220] p-3 mb-3 last:mb-0">
      <div className="flex items-center justify-between gap-2 mb-2.5">
        <span className="text-[13px] font-semibold text-slate-300">{title}</span>
        <span className="text-[12px] font-mono text-sky-700 truncate max-w-[55%]">{result}</span>
      </div>
      <div className="flex flex-wrap gap-2">{children}</div>
    </div>
  );
}

function TerminalScreen({
  label,
  subtitle,
  summary,
  text,
  actions,
}: {
  label: string;
  subtitle: string;
  summary: string;
  text: string;
  actions: React.ReactNode;
}) {
  return (
    <DkPanel label={label} subtitle={subtitle}>
      <div className="flex flex-wrap items-center justify-between gap-3 mb-3">
        <span className="text-[12px] font-mono text-sky-700 truncate">{summary}</span>
        {actions}
      </div>
      <ScrollArea className="h-[calc(100vh-360px)] min-h-[200px]">
        <pre className="min-w-max px-4 py-3 text-[13px] font-mono leading-6 text-emerald-400 bg-[#05080e] rounded-sm border border-white/[0.05] whitespace-pre">{text}</pre>
      </ScrollArea>
    </DkPanel>
  );
}
