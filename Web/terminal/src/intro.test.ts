import { afterEach, describe, expect, it, vi } from "vitest";

import { introSections, markIntroSeen, shouldShowIntro } from "./intro";
import { matchPaneCommand, type ChordEvent } from "./pane-keys";

const stubLocalStorage = (entries: Record<string, string> = {}) => {
  const store = new Map(Object.entries(entries));
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => store.set(key, value),
    removeItem: (key: string) => store.delete(key),
  });
  return store;
};

const chord = (event: Partial<ChordEvent>): ChordEvent => ({
  key: "",
  metaKey: false,
  ctrlKey: false,
  shiftKey: false,
  altKey: false,
  ...event,
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("shouldShowIntro", () => {
  it("is true on a browser that has never seen it, false afterwards", () => {
    stubLocalStorage();
    expect(shouldShowIntro()).toBe(true);
    markIntroSeen();
    expect(shouldShowIntro()).toBe(false);
  });

  it("stays quiet where storage is blocked, rather than showing every visit", () => {
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
      removeItem: () => undefined,
    });
    expect(shouldShowIntro()).toBe(false);
    expect(() => markIntroSeen()).not.toThrow();
  });
});

describe("introSections", () => {
  const allRows = (isMac: boolean, touch: boolean) =>
    introSections(isMac, touch).flatMap((section) => section.rows);

  it("gives touch devices gestures, not chords they have no keys for", () => {
    const keys = allRows(true, true).map((row) => row.keys);
    expect(keys).toContain("Long-press");
    expect(keys.some((key) => key.includes("⌘"))).toBe(false);
  });

  it("never advertises the chords the browser reserves", () => {
    // ⌘W closes the tab and ⌘T opens one; a page cannot preventDefault either,
    // which is exactly why pane-keys binds the ⌥ variants instead.
    for (const isMac of [true, false]) {
      const keys = allRows(isMac, false).map((row) => row.keys);
      expect(keys).not.toContain("⌘W");
      expect(keys).not.toContain("⌘T");
      expect(keys).not.toContain("Ctrl+Shift+T");
    }
  });

  it("omits the prompt jumps on platforms that do not bind them", () => {
    // Non-mac has no ⌘, and Ctrl+Shift+arrows already move between panes.
    const nonMac = allRows(false, false).map((row) => row.what);
    expect(nonMac).not.toContain("Jump between prompts");
    expect(allRows(true, false).map((row) => row.what)).toContain("Jump between prompts");
  });

  it("describes every row it lists", () => {
    for (const touch of [true, false]) {
      for (const row of allRows(true, touch)) {
        expect(row.keys.trim().length).toBeGreaterThan(0);
        expect(row.what.trim().length).toBeGreaterThan(0);
      }
    }
  });
});

// A shortcut list that drifts from the bindings is worse than no list, so the
// split chords it claims are matched against the real table.
describe("the card agrees with pane-keys", () => {
  it("splits with the chords it advertises on macOS", () => {
    expect(matchPaneCommand(chord({ key: "d", metaKey: true }), true)).toEqual({
      type: "split",
      dir: "row",
    });
    expect(
      matchPaneCommand(chord({ key: "d", metaKey: true, shiftKey: true }), true),
    ).toEqual({ type: "split", dir: "column" });
  });

  it("splits with the chords it advertises elsewhere", () => {
    expect(
      matchPaneCommand(chord({ key: "D", ctrlKey: true, shiftKey: true }), false),
    ).toEqual({ type: "split", dir: "row" });
    expect(
      matchPaneCommand(chord({ key: "E", ctrlKey: true, shiftKey: true }), false),
    ).toEqual({ type: "split", dir: "column" });
  });

  it("opens the card from the chord it tells you to use", () => {
    expect(matchPaneCommand(chord({ key: "/", metaKey: true }), true)).toEqual({
      type: "show-help",
    });
    // Shift+/ arrives as "?" on most layouts and "/" on some.
    for (const key of ["/", "?"]) {
      expect(
        matchPaneCommand(chord({ key, ctrlKey: true, shiftKey: true }), false),
      ).toEqual({ type: "show-help" });
    }
  });

  it("leaves a bare ? for the shell, which must still receive it", () => {
    expect(matchPaneCommand(chord({ key: "?" }), true)).toBeNull();
    expect(matchPaneCommand(chord({ key: "?", shiftKey: true }), true)).toBeNull();
    expect(matchPaneCommand(chord({ key: "/" }), false)).toBeNull();
  });
});
