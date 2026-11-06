import { describe, expect, it } from "vitest";
import type { SftpOperationProgress } from "../types";
import {
  applyOperationEvent,
  clearOperation,
  emptyOperations,
  formatElapsed,
  operationKindKey,
  operationPercent,
} from "./operations";

const event = (patch: Partial<SftpOperationProgress> = {}): SftpOperationProgress => ({
  kind: "prepare",
  phase: "downloading",
  message: "正在下载服务器模组",
  completed: 25,
  total: 100,
  unit: "bytes",
  currentItem: "Alpha.pak",
  finished: false,
  ...patch,
});

describe("operations", () => {
  it("keeps the running operation as current and resets when finished", () => {
    const started = applyOperationEvent(emptyOperations, event(), 1_000);
    expect(started.current?.currentItem).toBe("Alpha.pak");
    expect(started.history).toHaveLength(1);

    const done = applyOperationEvent(started, event({ phase: "done", finished: true }), 2_000);
    expect(done.current).toBeNull();
    expect(done.history).toHaveLength(2);
    expect(done.history.at(-1)?.finished).toBe(true);
  });

  it("trims history to the last 12 entries", () => {
    let state = emptyOperations;
    for (let index = 0; index < 20; index += 1) {
      state = applyOperationEvent(state, event({ message: `第 ${index} 步` }), index);
    }
    expect(state.history).toHaveLength(12);
    expect(state.history.at(-1)?.message).toBe("第 19 步");
  });

  it("returns null percent when total is unknown", () => {
    expect(operationPercent(null)).toBeNull();
    const unknown = applyOperationEvent(emptyOperations, event({ total: 0 }), 0).current;
    expect(operationPercent(unknown)).toBeNull();
    const half = applyOperationEvent(emptyOperations, event({ completed: 50 }), 0).current;
    expect(operationPercent(half)).toBe(50);
    const overflow = applyOperationEvent(emptyOperations, event({ completed: 150 }), 0).current;
    expect(operationPercent(overflow)).toBe(100);
  });

  it("formats elapsed time in mm:ss and h:mm:ss", () => {
    expect(formatElapsed(0)).toBe("00:00");
    expect(formatElapsed(65_000)).toBe("01:05");
    expect(formatElapsed(3_725_000)).toBe("1:02:05");
  });

  it("maps backend kinds to translation keys", () => {
    expect(operationKindKey("prepare")).toBe("operation.kind.prepare");
    expect(operationKindKey("download")).toBe("operation.kind.download");
    expect(operationKindKey("unknown-kind")).toBe("operation.kind.other");
  });
});

describe("clearOperation", () => {
  it("清掉当前操作，历史保留", () => {
    const running = applyOperationEvent(emptyOperations, event({ finished: false }), 0);
    const cleared = clearOperation(running);
    expect(cleared.current).toBeNull();
    expect(cleared.history).toHaveLength(1);
  });

  it("kind 不匹配时不动当前操作", () => {
    const running = applyOperationEvent(emptyOperations, event({ finished: false }), 0);
    expect(clearOperation(running, "download").current).not.toBeNull();
    expect(clearOperation(running, "prepare").current).toBeNull();
  });
});
