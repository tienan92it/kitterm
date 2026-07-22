import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { clearLayout, loadLayout, saveLayout, takeLegacySessionId } from "./layout-store";
import { leaf, splitPane, type LayoutNode } from "./pane-layout";

const stubStorage = (): Map<string, string> => {
  const store = new Map<string, string>();
  vi.stubGlobal("sessionStorage", {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
    removeItem: (k: string) => void store.delete(k),
  });
  return store;
};

let store: Map<string, string>;

beforeEach(() => {
  store = stubStorage();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

const tree = (): LayoutNode => splitPane(leaf("p1"), "p1", "row", "p2");

describe("saveLayout / loadLayout", () => {
  it("round-trips a layout with its sessions", () => {
    const root = tree();
    saveLayout({
      root,
      focus: "p2",
      sessions: new Map([
        ["p1", { sessionId: "abc", cwd: "/tmp" }],
        ["p2", { sessionId: null }],
      ]),
    });

    const loaded = loadLayout();
    expect(loaded?.root).toEqual(root);
    expect(loaded?.focus).toBe("p2");
    expect(loaded?.sessions.get("p1")).toEqual({ sessionId: "abc", cwd: "/tmp" });
    expect(loaded?.sessions.get("p2")).toEqual({ sessionId: null, cwd: undefined });
  });

  it("returns null when nothing is stored", () => {
    expect(loadLayout()).toBeNull();
  });

  it("returns null for corrupt JSON rather than throwing", () => {
    store.set("kitterm:layout", "{not json");
    expect(loadLayout()).toBeNull();
  });

  it("returns null for a future version", () => {
    store.set("kitterm:layout", JSON.stringify({ v: 99, root: { kind: "leaf", pane: "a" } }));
    expect(loadLayout()).toBeNull();
  });

  it("returns null when the tree is malformed", () => {
    store.set("kitterm:layout", JSON.stringify({ v: 1, root: { kind: "nope" } }));
    expect(loadLayout()).toBeNull();
  });

  it("tolerates a missing or junk sessions array", () => {
    store.set("kitterm:layout", JSON.stringify({ v: 1, root: { kind: "leaf", pane: "a" } }));
    expect(loadLayout()?.sessions.size).toBe(0);

    store.set(
      "kitterm:layout",
      JSON.stringify({ v: 1, root: { kind: "leaf", pane: "a" }, sessions: [null, 7, {}] }),
    );
    expect(loadLayout()?.sessions.size).toBe(0);
  });

  it("clears", () => {
    saveLayout({ root: leaf("a"), focus: "a", sessions: new Map() });
    clearLayout();
    expect(loadLayout()).toBeNull();
  });

  it("swallows quota errors on write", () => {
    vi.stubGlobal("sessionStorage", {
      getItem: () => null,
      setItem: () => {
        throw new Error("QuotaExceededError");
      },
      removeItem: () => {},
    });
    expect(() =>
      saveLayout({ root: leaf("a"), focus: "a", sessions: new Map() }),
    ).not.toThrow();
  });

  it("survives sessionStorage being unavailable entirely", () => {
    vi.stubGlobal("sessionStorage", {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {},
      removeItem: () => {},
    });
    expect(loadLayout()).toBeNull();
  });
});

describe("takeLegacySessionId", () => {
  it("reads and consumes the pre-splits key", () => {
    store.set("kitterm:session-id", "legacy-uuid");
    expect(takeLegacySessionId()).toBe("legacy-uuid");
    expect(store.has("kitterm:session-id")).toBe(false);
  });

  it("returns null when absent", () => {
    expect(takeLegacySessionId()).toBeNull();
  });
});
