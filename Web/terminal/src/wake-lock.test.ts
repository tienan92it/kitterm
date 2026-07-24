import { describe, expect, it, vi } from "vitest";

import { WakeLockManager, type WakeSentinel } from "./wake-lock";

function fakeSentinel(): WakeSentinel & { released: boolean; fireRelease: () => void } {
  let handler: (() => void) | null = null;
  const s = {
    released: false,
    release: vi.fn(async () => {
      s.released = true;
    }),
    addEventListener: (_t: "release", h: () => void) => {
      handler = h;
    },
    fireRelease: () => handler?.(),
  };
  return s as unknown as WakeSentinel & { released: boolean; fireRelease: () => void };
}

describe("WakeLockManager", () => {
  it("acquires a lock when wanted and visible", async () => {
    const s = fakeSentinel();
    const m = new WakeLockManager({ request: async () => s, isVisible: () => true });
    await m.setWanted(true);
    expect(m.held).toBe(true);
  });

  it("does not acquire while hidden", async () => {
    const request = vi.fn(async () => fakeSentinel());
    const m = new WakeLockManager({ request, isVisible: () => false });
    await m.setWanted(true);
    expect(m.held).toBe(false);
    expect(request).not.toHaveBeenCalled();
  });

  it("acquires on return to visibility if still wanted", async () => {
    let visible = false;
    const m = new WakeLockManager({ request: async () => fakeSentinel(), isVisible: () => visible });
    await m.setWanted(true);
    expect(m.held).toBe(false);
    visible = true;
    await m.onVisibilityChange();
    expect(m.held).toBe(true);
  });

  it("releases when no longer wanted", async () => {
    const s = fakeSentinel();
    const m = new WakeLockManager({ request: async () => s, isVisible: () => true });
    await m.setWanted(true);
    await m.setWanted(false);
    expect(m.held).toBe(false);
    expect(s.released).toBe(true);
  });

  it("does not re-acquire on visibility when not wanted", async () => {
    const request = vi.fn(async () => fakeSentinel());
    const m = new WakeLockManager({ request, isVisible: () => true });
    await m.onVisibilityChange();
    expect(m.held).toBe(false);
    expect(request).not.toHaveBeenCalled();
  });

  it("clears its state when the browser releases the lock", async () => {
    const s = fakeSentinel();
    const m = new WakeLockManager({ request: async () => s, isVisible: () => true });
    await m.setWanted(true);
    expect(m.held).toBe(true);
    s.fireRelease(); // browser dropped it (e.g. tab hidden)
    expect(m.held).toBe(false);
  });

  it("is a no-op where the API is unsupported", async () => {
    const m = new WakeLockManager({ request: async () => null, isVisible: () => true });
    await m.setWanted(true);
    expect(m.held).toBe(false);
  });
});
