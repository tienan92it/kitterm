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

describe("a pause that stops making progress", () => {
  // The bug this guards: pending only comes down when xterm reports bytes
  // parsed, so a write callback that never arrives pauses the stream for good.
  // The tab then shows no output, a frozen cursor, and typing that goes
  // nowhere — recoverable only by reloading.
  it("resumes on its own when no bytes are ever reported parsed", () => {
    vi.useFakeTimers();
    const events: string[] = [];
    const flow = new OutputFlowControl(
      { onPause: () => events.push("pause"), onResume: () => events.push("resume") },
      100,
      50,
      1000,
    );

    flow.enqueue(500);
    expect(events).toEqual(["pause"]);
    expect(flow.isPaused).toBe(true);

    // The parse callbacks never come.
    vi.advanceTimersByTime(1000);
    expect(events).toEqual(["pause", "resume"]);
    expect(flow.isPaused).toBe(false);
    expect(flow.pendingBytes).toBe(0);
    vi.useRealTimers();
  });

  it("keeps a pause that is still draining", () => {
    vi.useFakeTimers();
    const events: string[] = [];
    const flow = new OutputFlowControl(
      { onPause: () => events.push("pause"), onResume: () => events.push("resume") },
      100,
      50,
      1000,
    );
    flow.enqueue(500);
    // Progress, but not yet below the low water mark.
    for (let i = 0; i < 4; i++) {
      vi.advanceTimersByTime(800);
      flow.dequeue(50);
      expect(flow.isPaused).toBe(true);
    }
    expect(events).toEqual(["pause"]);
    // Once it drains below low water it resumes for the normal reason.
    flow.dequeue(500);
    expect(events).toEqual(["pause", "resume"]);
    vi.useRealTimers();
  });

  it("stops its timer when reset or disposed", () => {
    vi.useFakeTimers();
    const events: string[] = [];
    const flow = new OutputFlowControl(
      { onPause: () => events.push("pause"), onResume: () => events.push("resume") },
      100,
      50,
      1000,
    );
    flow.enqueue(500);
    flow.reset();
    vi.advanceTimersByTime(5000);
    // A reset connection must not fire a stale resume.
    expect(events).toEqual(["pause"]);

    flow.enqueue(500);
    flow.dispose();
    vi.advanceTimersByTime(5000);
    expect(events.filter((e) => e === "resume")).toHaveLength(0);
    vi.useRealTimers();
  });
});
