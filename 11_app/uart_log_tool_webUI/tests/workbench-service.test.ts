import assert from "node:assert/strict";
import test from "node:test";

import {
  buildBulkWriteCommand,
  buildDisplayCheckerFrame,
  buildDisplayRefreshCommand,
  buildReadCommand,
  buildStatusWriteCommand,
  buildWriteCommand,
  DISPLAY_FRAMEBUFFER_BASE_ADDR,
  DISPLAY_HOST_SRC_ID,
  DISP_OP_REFRESH,
  HOST_EVT_BULK_DONE,
  HOST_EVT_BULK_OK,
  HOST_EVT_BULK_PROGRESS,
  HOST_EVT_CMD_ERR,
  HOST_EVT_READ_RSP,
  HOST_EVT_WRITE_ACK,
  iterBulkWriteBlocks,
  MAP_WORD_COUNT,
  paddedWordCount,
  SDRAM_HOST_SRC_ID,
  SSD1306_FRAME_BYTES,
  STATUS_BYTE_COUNT,
  EVT_CMD_ACK,
} from "@/lib/workbench/protocol";
import { WorkbenchService } from "@/lib/workbench/service";
import type { UartFrame } from "@/lib/workbench/types";

function makeFrame(
  srcId: number,
  eventId: number,
  arg0 = 0,
  arg1 = 0,
  arg2 = 0,
): UartFrame {
  return {
    sync: 0x7e,
    seq: 0,
    payloadBytes: new Uint8Array(16),
    crc: 0,
    crcOk: true,
    lostCount: 0,
    rawHex: "",
    event: {
      srcId,
      eventId,
      timestamp: 0,
      arg0,
      arg1,
      arg2,
    },
  };
}

function pushFrames(service: WorkbenchService, ...frames: UartFrame[]) {
  const queue = (service as unknown as { pendingFrames: UartFrame[] }).pendingFrames;
  queue.push(...frames);
}

function createHarness(
  onWrite: (payload: Buffer, service: WorkbenchService) => void | Promise<void>,
) {
  const service = new WorkbenchService();
  const writes: Buffer[] = [];

  Object.assign(service as object, {
    transport: "tcp",
    socket: { destroy() {} },
  });

  (service as unknown as {
    selectSource: (targetIdx: number) => Promise<void>;
    sendBytes: (payload: Uint8Array) => Promise<void>;
    reloadDecoder: () => Promise<void>;
  }).selectSource = async (targetIdx: number) => {
    Object.assign(service as object, { selectedSrcIdx: targetIdx });
  };

  (service as unknown as {
    sendBytes: (payload: Uint8Array) => Promise<void>;
  }).sendBytes = async (payload: Uint8Array) => {
    const buffer = Buffer.from(payload);
    writes.push(buffer);
    await onWrite(buffer, service);
  };

  (service as unknown as {
    reloadDecoder: () => Promise<void>;
  }).reloadDecoder = async () => {};

  return { service, writes };
}

test("runStatusSelftest triggers selftest ack and refreshes status words", async () => {
  let statusReadCount = 0;
  const { service, writes } = createHarness((payload, current) => {
    const text = payload.toString("ascii");
    if (text === buildStatusWriteCommand(0x0003c, 0x0000_0001).toString("ascii")) {
      pushFrames(current, makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_WRITE_ACK, 0x0003c, 0x0000_0001, 0));
      return;
    }
    if (text.startsWith("SR ")) {
      const offset = Number.parseInt(text.trim().split(/\s+/)[1], 16);
      const value = 0x5000_0000 + statusReadCount + offset;
      pushFrames(current, makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_READ_RSP, offset, value, 0));
      statusReadCount += 1;
      return;
    }
    assert.fail(`unexpected payload: ${text}`);
  });

  await service.runStatusSelftest();

  const statusBytes = (service as unknown as { statusBytes: Uint8Array }).statusBytes;
  assert.equal(writes.length, 1 + (STATUS_BYTE_COUNT / 4));
  assert.deepEqual(Array.from(statusBytes.slice(0, 4)), [0x00, 0x00, 0x00, 0x50]);
  assert.equal(service.getSnapshot().sdramStatus.summary, "status registers refreshed");
});

test("single SDRAM read/write succeed on status=0 and reject non-zero status", async () => {
  const successHarness = createHarness((payload, current) => {
    const text = payload.toString("ascii");
    if (text === buildReadCommand(0x00123).toString("ascii")) {
      pushFrames(current, makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_READ_RSP, 0x00123, 0x89ab_cdef, 0));
      return;
    }
    if (text === buildWriteCommand(0x00124, 0x1357_9bdf).toString("ascii")) {
      pushFrames(current, makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_WRITE_ACK, 0x00124, 0x1357_9bdf, 0));
      return;
    }
    assert.fail(`unexpected payload: ${text}`);
  });

  await successHarness.service.singleRead(0x00123);
  await successHarness.service.singleWrite(0x00124, 0x1357_9bdf);
  assert.equal(successHarness.service.getSnapshot().sdramRw.singleReadResult, "0x89ABCDEF");
  assert.equal(successHarness.service.getSnapshot().sdramRw.singleWriteResult, "wrote 0x13579BDF");

  const failureHarness = createHarness((payload, current) => {
    const text = payload.toString("ascii");
    if (text === buildReadCommand(0x00020).toString("ascii")) {
      pushFrames(current, makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_READ_RSP, 0x00020, 0x0000_0000, 0x0000_0002));
      return;
    }
    assert.fail(`unexpected payload: ${text}`);
  });

  await assert.rejects(
    failureHarness.service.singleRead(0x00020),
    /single read 0x00020 failed with status 0x00000002/,
  );
});

test("refreshMap ignores stale bulk frames and loads the requested map window", async () => {
  const baseAddr = 0x00200;
  const { service } = createHarness((payload, current) => {
    const text = payload.toString("ascii");
    if (text.startsWith("BR ")) {
      pushFrames(current, makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_OK, baseAddr, MAP_WORD_COUNT, 0));
      for (let word = 0; word < MAP_WORD_COUNT; word += 2) {
        const packetWords = Math.min(2, MAP_WORD_COUNT - word);
        const arg0 = (((packetWords & 0x3) << 21) | ((baseAddr + word) & 0x1f_ffff)) >>> 0;
        const arg1 = (0x1000_0000 + word) >>> 0;
        const arg2 = packetWords === 2 ? (0x1000_0000 + word + 1) >>> 0 : 0;
        pushFrames(current, makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_PROGRESS, arg0, arg1, arg2));
      }
      pushFrames(current, makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_DONE, baseAddr, MAP_WORD_COUNT, MAP_WORD_COUNT));
      return;
    }
    assert.fail(`unexpected payload: ${text}`);
  });

  pushFrames(
    service,
    makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_OK, 0x12345, 0x55, 0),
    makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_DONE, 0x12345, 0x55, 0x55),
  );

  await service.refreshMap(baseAddr);

  const mapBytes = (service as unknown as { mapBytes: Uint8Array }).mapBytes;
  assert.equal(service.getSnapshot().sdramMap.summary, "loaded 256 words from 0x00200");
  assert.deepEqual(
    Array.from(mapBytes.slice(0, 8)),
    [0x00, 0x00, 0x00, 0x10, 0x01, 0x00, 0x00, 0x10],
  );
});

test("bulkRangeRead builds a preview from validated progress packets", async () => {
  const baseAddr = 0x00400;
  const words = 5;
  const { service } = createHarness((payload, current) => {
    const text = payload.toString("ascii");
    if (text.startsWith("BR ")) {
      pushFrames(
        current,
        makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_OK, baseAddr, words, 0),
        makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_PROGRESS, (((2 & 0x3) << 21) | (baseAddr + 0)) >>> 0, 0xAAAA_0000, 0xBBBB_0001),
        makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_PROGRESS, (((2 & 0x3) << 21) | (baseAddr + 2)) >>> 0, 0xCCCC_0002, 0xDDDD_0003),
        makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_PROGRESS, (((1 & 0x3) << 21) | (baseAddr + 4)) >>> 0, 0xEEEE_0004, 0),
        makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_DONE, baseAddr, words, words),
      );
      return;
    }
    assert.fail(`unexpected payload: ${text}`);
  });

  await service.bulkRangeRead(baseAddr, words);

  const snapshot = service.getSnapshot().sdramBurst;
  assert.equal(snapshot.summary, "bulk read complete: 5/5 words");
  assert.equal(snapshot.result, "received 5/5 words");
  assert.match(snapshot.preview, /000 \| AAAA0000  BBBB0001  CCCC0002  DDDD0003/);
  assert.match(snapshot.preview, /004 \| EEEE0004/);
});

test("display checker writes the framebuffer then waits for a fresh refresh ack", async () => {
  const frameWords = paddedWordCount(SSD1306_FRAME_BYTES);
  const totalBlocks = iterBulkWriteBlocks(buildDisplayCheckerFrame()).length;
  let seenBulkCommand = false;
  let blockIndex = 0;

  const { service, writes } = createHarness((payload, current) => {
    if (!seenBulkCommand) {
      assert.equal(payload.toString("ascii"), buildBulkWriteCommand(DISPLAY_FRAMEBUFFER_BASE_ADDR, frameWords).toString("ascii"));
      seenBulkCommand = true;
      pushFrames(current, makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_OK, DISPLAY_FRAMEBUFFER_BASE_ADDR, frameWords, 0));
      return;
    }

    if (blockIndex < totalBlocks) {
      blockIndex += 1;
      if (blockIndex === totalBlocks) {
        pushFrames(current, makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_BULK_DONE, DISPLAY_FRAMEBUFFER_BASE_ADDR, frameWords, frameWords));
      } else {
        const completedWords = Math.min(blockIndex * 16, frameWords);
        pushFrames(
          current,
          makeFrame(
            SDRAM_HOST_SRC_ID,
            HOST_EVT_BULK_PROGRESS,
            DISPLAY_FRAMEBUFFER_BASE_ADDR + completedWords,
            completedWords,
            frameWords - completedWords,
          ),
        );
      }
      return;
    }

    assert.equal(payload.toString("ascii"), buildDisplayRefreshCommand().toString("ascii"));
    pushFrames(current, makeFrame(DISPLAY_HOST_SRC_ID, EVT_CMD_ACK, DISP_OP_REFRESH, 0, 0));
  });

  pushFrames(service, makeFrame(DISPLAY_HOST_SRC_ID, EVT_CMD_ACK, 0x0000_0003, 0, 0));

  await service.displayCommand("pattern");

  assert.equal(service.getSnapshot().display.summary, "pattern framebuffer refreshed");
  assert.equal(blockIndex, totalBlocks);
  assert.equal(writes.length, 1 + totalBlocks + 1);
});

test("single SDRAM write surfaces HOST_EVT_CMD_ERR as an action failure", async () => {
  const { service } = createHarness((payload, current) => {
    const text = payload.toString("ascii");
    if (text === buildWriteCommand(0x00040, 0xDEAD_BEEF).toString("ascii")) {
      pushFrames(current, makeFrame(SDRAM_HOST_SRC_ID, HOST_EVT_CMD_ERR, 0x0000_00E1, 0, 0));
      return;
    }
    assert.fail(`unexpected payload: ${text}`);
  });

  await assert.rejects(
    service.singleWrite(0x00040, 0xDEAD_BEEF),
    /single write failed: cmd_err 0xE1/,
  );
});
