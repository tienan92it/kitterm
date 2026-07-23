import { describe, expect, it } from "vitest";

import { matchPaneCommand, type ChordEvent } from "./pane-keys";

const chord = (over: Partial<ChordEvent> & { key: string }): ChordEvent => ({
  metaKey: false,
  ctrlKey: false,
  shiftKey: false,
  altKey: false,
  ...over,
});

describe("matchPaneCommand — macOS", () => {
  it("⌘D splits side by side", () => {
    expect(matchPaneCommand(chord({ key: "d", metaKey: true }), true)).toEqual({
      type: "split",
      dir: "row",
    });
  });

  it("⌘⇧D splits stacked", () => {
    expect(
      matchPaneCommand(chord({ key: "D", metaKey: true, shiftKey: true }), true),
    ).toEqual({ type: "split", dir: "column" });
  });

  it("⌘⌥↑/↓ navigate", () => {
    expect(
      matchPaneCommand(chord({ key: "ArrowUp", metaKey: true, altKey: true }), true),
    ).toEqual({ type: "navigate", dir: "up" });
    expect(
      matchPaneCommand(chord({ key: "ArrowDown", metaKey: true, altKey: true }), true),
    ).toEqual({ type: "navigate", dir: "down" });
  });

  it("⌘⌥W closes", () => {
    expect(
      matchPaneCommand(chord({ key: "w", metaKey: true, altKey: true }), true),
    ).toEqual({ type: "close" });
  });

  it("⌘⌥T opens a new tab", () => {
    expect(
      matchPaneCommand(chord({ key: "t", metaKey: true, altKey: true }), true),
    ).toEqual({ type: "new-tab" });
  });

  it("leaves bare ⌘T alone — the browser owns it for new tab", () => {
    expect(matchPaneCommand(chord({ key: "t", metaKey: true }), true)).toBeNull();
  });

  it("leaves ⌘⌥←/→ alone — Chrome and Safari own them for tab switching", () => {
    expect(
      matchPaneCommand(chord({ key: "ArrowLeft", metaKey: true, altKey: true }), true),
    ).toBeNull();
    expect(
      matchPaneCommand(chord({ key: "ArrowRight", metaKey: true, altKey: true }), true),
    ).toBeNull();
  });

  it("leaves bare ⌘W alone — the browser closes the tab and we cannot stop it", () => {
    expect(matchPaneCommand(chord({ key: "w", metaKey: true }), true)).toBeNull();
  });

  it("ignores ⌘F so the existing search handler keeps it", () => {
    expect(matchPaneCommand(chord({ key: "f", metaKey: true }), true)).toBeNull();
  });
});

describe("matchPaneCommand — non-mac", () => {
  it("Ctrl+Shift+D splits side by side", () => {
    expect(
      matchPaneCommand(chord({ key: "D", ctrlKey: true, shiftKey: true }), false),
    ).toEqual({ type: "split", dir: "row" });
  });

  it("Ctrl+Shift+E splits stacked", () => {
    expect(
      matchPaneCommand(chord({ key: "E", ctrlKey: true, shiftKey: true }), false),
    ).toEqual({ type: "split", dir: "column" });
  });

  it("Ctrl+Shift+arrows navigate", () => {
    expect(
      matchPaneCommand(chord({ key: "ArrowUp", ctrlKey: true, shiftKey: true }), false),
    ).toEqual({ type: "navigate", dir: "up" });
  });

  it("Ctrl+Shift+Alt+W closes", () => {
    expect(
      matchPaneCommand(
        chord({ key: "W", ctrlKey: true, shiftKey: true, altKey: true }),
        false,
      ),
    ).toEqual({ type: "close" });
  });

  it("Ctrl+Shift+Alt+T opens a new tab", () => {
    expect(
      matchPaneCommand(
        chord({ key: "T", ctrlKey: true, shiftKey: true, altKey: true }),
        false,
      ),
    ).toEqual({ type: "new-tab" });
  });

  it("leaves Ctrl+Shift+T alone — reopen-closed-tab is reserved", () => {
    expect(
      matchPaneCommand(chord({ key: "T", ctrlKey: true, shiftKey: true }), false),
    ).toBeNull();
  });

  it("does not use the macOS chords", () => {
    expect(matchPaneCommand(chord({ key: "d", metaKey: true }), false)).toBeNull();
  });
});

/** The whole point of the module: a pane is a real shell. */
describe("keys the shell must keep", () => {
  it.each([
    ["Ctrl+B (tmux prefix, vim page-up)", { key: "b", ctrlKey: true }],
    ["Ctrl+C (SIGINT)", { key: "c", ctrlKey: true }],
    ["Ctrl+D (EOF)", { key: "d", ctrlKey: true }],
    ["Ctrl+A (readline start-of-line)", { key: "a", ctrlKey: true }],
    ["Ctrl+R (reverse search)", { key: "r", ctrlKey: true }],
    ["Alt+F (readline forward-word)", { key: "f", altKey: true }],
    ["Alt+D (readline kill-word)", { key: "d", altKey: true }],
    ["a plain letter", { key: "d" }],
    ["a bare arrow", { key: "ArrowUp" }],
    ["Shift+D", { key: "D", shiftKey: true }],
  ])("%s is never a pane command", (_label, over) => {
    const event = chord(over as Partial<ChordEvent> & { key: string });
    expect(matchPaneCommand(event, true)).toBeNull();
    expect(matchPaneCommand(event, false)).toBeNull();
  });

  it("ignores Ctrl+⌘ combinations on macOS", () => {
    expect(
      matchPaneCommand(chord({ key: "d", metaKey: true, ctrlKey: true }), true),
    ).toBeNull();
  });
});
