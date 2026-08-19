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
        ["p1", { sessionId: "abc", cwd: "/tmp", histKey: "k1", profile: "vm" }],
        ["p2", { sessionId: null }],
      ]),
    });

    const loaded = loadLayout();
    expect(loaded?.root).toEqual(root);
    expect(loaded?.focus).toBe("p2");
    expect(loaded?.sessions.get("p1")).toEqual({
      sessionId: "abc",
      cwd: "/tmp",
      histKey: "k1",
      profile: "vm",
    });
    expect(loaded?.sessions.get("p2")).toEqual({
      sessionId: null,
      cwd: undefined,
      histKey: undefined,
    });
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

// The defect: a home-screen app gets a fresh sessionStorage on every launch, so
// under the tab rule it could never reattach. Each launch spawned new shells
// and the scrollback looked lost, while the old shells kept running with
// nothing pointing at them. An installed app is one window the user reopens, so
// it stores per-app instead.
describe("where the layout is stored", () => {
  const stubBoth = () => {
    const session = new Map<string, string>();
    const local = new Map<string, string>();
    const asStorage = (m: Map<string, string>) => ({
      getItem: (k: string) => m.get(k) ?? null,
      setItem: (k: string, v: string) => void m.set(k, v),
      removeItem: (k: string) => void m.delete(k),
    });
    vi.stubGlobal("sessionStorage", asStorage(session));
    vi.stubGlobal("localStorage", asStorage(local));
    return { session, local };
  };

  const asInstalled = (standalone: boolean) => {
    vi.stubGlobal("window", {
      matchMedia: (q: string) => ({ matches: standalone && q.includes("standalone") }),
    });
    vi.stubGlobal("navigator", {});
  };

  const layout: LayoutNode = leaf("p1");

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  it("uses sessionStorage in a browser tab, so a new tab still starts fresh", async () => {
    const stores = stubBoth();
    asInstalled(false);
    const mod = await import("./layout-store");
    mod.saveLayout({ root: layout, focus: "p1", sessions: new Map() });

    expect(stores.session.size).toBe(1);
    expect(stores.local.size).toBe(0);
  });

  it("uses localStorage in an installed app, so relaunching reattaches", async () => {
    const stores = stubBoth();
    asInstalled(true);
    const mod = await import("./layout-store");
    mod.saveLayout({ root: layout, focus: "p1", sessions: new Map() });

    expect(stores.local.size).toBe(1);
    expect(stores.session.size).toBe(0);
    // A relaunch reads the same store and finds the layout.
    expect(mod.loadLayout()?.focus).toBe("p1");
  });

  it("still detects an older iOS home-screen app, which answers no media query", async () => {
    const stores = stubBoth();
    vi.stubGlobal("window", { matchMedia: () => ({ matches: false }) });
    vi.stubGlobal("navigator", { standalone: true });
    const mod = await import("./layout-store");
    mod.saveLayout({ root: layout, focus: "p1", sessions: new Map() });

    expect(stores.local.size).toBe(1);
  });

  it("falls back to a tab when neither signal is available", async () => {
    const stores = stubBoth();
    vi.stubGlobal("window", {});
    vi.stubGlobal("navigator", {});
    const mod = await import("./layout-store");
    mod.saveLayout({ root: layout, focus: "p1", sessions: new Map() });

    expect(stores.session.size).toBe(1);
  });
});
