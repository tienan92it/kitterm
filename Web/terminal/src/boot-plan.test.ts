import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { persistedLayout, planBoot } from "./boot-plan";
import { loadLayout, saveLayout, takeLegacySessionId } from "./layout-store";
import { leaf, splitPane } from "./pane-layout";

/** The tab's sessionStorage, as `layout-store.test.ts` stubs it. */
const stubStorage = (): Map<string, string> => {
  const store = new Map<string, string>();
  vi.stubGlobal("sessionStorage", {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
    removeItem: (k: string) => void store.delete(k),
  });
  return store;
};

beforeEach(() => {
  stubStorage();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

/** A tab that had two shells split side by side before the link opened. */
const storeTwoPanes = (): void => {
  saveLayout({
    root: splitPane(leaf("p1"), "p1", "row", "p2"),
    focus: "p2",
    sessions: new Map([
      ["p1", { sessionId: "OLD-1", histKey: "h1" }],
      ["p2", { sessionId: "OLD-2", histKey: "h2" }],
    ]),
  });
};

const SESSION = "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9";

describe("planBoot with a /?session= link", () => {
  it("opens one pane joined to the session and does not read the stored layout", () => {
    storeTwoPanes();
    const read = vi.fn(loadLayout);
    const plan = planBoot({ search: `?session=${SESSION}`, loadLayout: read, takeLegacySessionId });

    expect(plan.linkBoot).toBe(true);
    expect(plan.root).toEqual(leaf("p1"));
    expect(plan.focus).toBe("p1");
    expect(plan.panes).toEqual([{ id: "p1", session: { sessionId: SESSION, cwd: undefined } }]);
    expect(read).not.toHaveBeenCalled();
    // The link pane carries no history key of its own: it observes a shell
    // that is not this tab's (`createPane` sends none while `linkBoot`).
    expect(plan.panes[0]?.session.histKey).toBeUndefined();
  });

  it("carries ?cmd= and ?watch= for the link pane", () => {
    const plan = planBoot({ search: `?session=${SESSION}&cmd=7&watch=1`, loadLayout, takeLegacySessionId });
    expect(plan.commandScroll).toBe(7);
    expect(plan.watch).toBe(true);
  });

  it("reattaches to the same session on a reload once the page stored the link pane", () => {
    storeTwoPanes();
    const first = planBoot({ search: `?session=${SESSION}`, loadLayout, takeLegacySessionId });
    const [pane] = first.panes;
    expect(pane).toBeDefined();

    // The page stores the layout when the pane reports its session, with the
    // pane's own facts (`persistLayout`); the link pane has no history key.
    saveLayout(
      persistedLayout(first.root, first.focus, [
        [pane!.id, { sessionId: SESSION, lastCwd: "/Users/an/work", histKey: null, profile: null }],
      ]),
    );

    // `paneSessionId` strips the query (`history.replaceState`), so the
    // reload boots on a bare `/`.
    const reload = planBoot({ search: "", loadLayout, takeLegacySessionId });

    expect(reload.linkBoot).toBe(false);
    expect(reload.root).toEqual(leaf("p1"));
    expect(reload.panes).toEqual([
      { id: "p1", session: { sessionId: SESSION, cwd: "/Users/an/work", histKey: undefined, profile: undefined } },
    ]);
    // The tab's old two-pane split is gone: the link replaced it on purpose.
    expect(reload.panes.map((p) => p.session.sessionId)).not.toContain("OLD-1");
  });
});

describe("planBoot without a link", () => {
  it("restores the stored layout and runs the pane counter past its ids", () => {
    storeTwoPanes();
    const plan = planBoot({ search: "", loadLayout, takeLegacySessionId });
    expect(plan.linkBoot).toBe(false);
    expect(plan.focus).toBe("p2");
    expect(plan.panes.map((p) => p.session.sessionId)).toEqual(["OLD-1", "OLD-2"]);
    expect(plan.paneCounter).toBe(2);
  });

  it("opens a single fresh pane with nothing stored", () => {
    const plan = planBoot({ search: "", loadLayout, takeLegacySessionId });
    expect(plan.panes).toEqual([{ id: "p1", session: { sessionId: null } }]);
  });

  it("seeds the tab's own layout from a profile link", () => {
    storeTwoPanes();
    const plan = planBoot({ search: "?profile=vm&cwd=/w", loadLayout, takeLegacySessionId });
    expect(plan.linkBoot).toBe(false);
    expect(plan.panes).toEqual([{ id: "p1", session: { sessionId: null, cwd: "/w", profile: "vm" } }]);
  });
});
