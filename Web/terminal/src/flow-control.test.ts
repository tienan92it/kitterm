import { describe, expect, it, vi } from "vitest";

import { OutputFlowControl } from "./flow-control";

const makeFlowControl = (highWater: number, lowWater: number) => {
  const onPause = vi.fn();
  const onResume = vi.fn();
  const flow = new OutputFlowControl({ onPause, onResume }, highWater, lowWater);
  return { flow, onPause, onResume };
};

describe("OutputFlowControl", () => {
  it("pauses once when pending exceeds the high watermark", () => {
    const { flow, onPause } = makeFlowControl(100, 20);
    flow.enqueue(60);
    expect(onPause).not.toHaveBeenCalled();
    flow.enqueue(60); // 120 > 100
    expect(onPause).toHaveBeenCalledTimes(1);
    expect(flow.isPaused).toBe(true);
    flow.enqueue(60); // already paused — no second pause
    expect(onPause).toHaveBeenCalledTimes(1);
  });

  it("resumes once when pending drains to the low watermark", () => {
    const { flow, onResume } = makeFlowControl(100, 20);
    flow.enqueue(150);
    flow.dequeue(100); // 50 > 20 — still paused
    expect(onResume).not.toHaveBeenCalled();
    expect(flow.isPaused).toBe(true);
    flow.dequeue(30); // 20 <= 20 — resume
    expect(onResume).toHaveBeenCalledTimes(1);
    expect(flow.isPaused).toBe(false);
    flow.dequeue(20); // already resumed — no second resume
    expect(onResume).toHaveBeenCalledTimes(1);
  });

  it("never resumes without a prior pause and clamps pending at zero", () => {
    const { flow, onResume } = makeFlowControl(100, 20);
    flow.enqueue(10);
    flow.dequeue(50);
    expect(flow.pendingBytes).toBe(0);
    expect(onResume).not.toHaveBeenCalled();
  });

  it("supports repeated pause/resume cycles", () => {
    const { flow, onPause, onResume } = makeFlowControl(100, 20);
    for (let cycle = 1; cycle <= 3; cycle += 1) {
      flow.enqueue(150);
      flow.dequeue(150);
      expect(onPause).toHaveBeenCalledTimes(cycle);
      expect(onResume).toHaveBeenCalledTimes(cycle);
    }
  });
});
