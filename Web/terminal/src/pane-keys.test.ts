import { describe, expect, it } from "vitest";

import { isModifierKey, matchPaneCommand, type ChordEvent } from "./pane-keys";

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

describe("browse-files chord", () => {
  it("is Cmd+Alt+O on mac and Ctrl+Shift+Alt+O elsewhere", () => {
    expect(matchPaneCommand(
      { key: "o", metaKey: true, altKey: true, ctrlKey: false, shiftKey: false }, true,
    )).toEqual({ type: "browse-files" });
    expect(matchPaneCommand(
      { key: "O", metaKey: false, altKey: true, ctrlKey: true, shiftKey: true }, false,
    )).toEqual({ type: "browse-files" });
  });

  // A bare "o" is a keystroke for the shell, not a chord.
  it("does not fire without its modifiers", () => {
    expect(matchPaneCommand(
      { key: "o", metaKey: false, altKey: false, ctrlKey: false, shiftKey: false }, true,
    )).toBeNull();
  });
});

describe("Option-composed keys on macOS", () => {
  // Holding Option composes an alternate character, so ⌘⌥O arrives as "ø" and
  // ⌘⌥T as "†". Matching on the character misses every Option chord on a real
  // keyboard, which is why the physical key code is what counts.
  it("matches by physical key when Option has changed the character", () => {
    expect(matchPaneCommand(
      { key: "ø", code: "KeyO", metaKey: true, altKey: true, ctrlKey: false, shiftKey: false }, true,
    )).toEqual({ type: "browse-files" });
    expect(matchPaneCommand(
      { key: "†", code: "KeyT", metaKey: true, altKey: true, ctrlKey: false, shiftKey: false }, true,
    )).toEqual({ type: "new-tab" });
    expect(matchPaneCommand(
      { key: "∑", code: "KeyW", metaKey: true, altKey: true, ctrlKey: false, shiftKey: false }, true,
    )).toEqual({ type: "close" });
  });

  it("still works for events that carry no code", () => {
    expect(matchPaneCommand(
      { key: "o", metaKey: true, altKey: true, ctrlKey: false, shiftKey: false }, true,
    )).toEqual({ type: "browse-files" });
  });
});

// A chord reaches the page as two keydowns. Anything that reacts to "the user
// started typing" sees the modifier first, and acting on it changes the world
// the second half of the chord lands in — which is exactly how ⌘C on a touch
// selection came to clear the selection before its own copy branch ran.
describe("isModifierKey", () => {
  it("is true for a modifier pressed on its own", () => {
    for (const key of ["Control", "Shift", "Meta", "Alt", "AltGraph", "CapsLock"]) {
      expect(isModifierKey({ key })).toBe(true);
    }
  });

  it("is false for the letter that completes a chord", () => {
    // The `c` of ⌘C carries metaKey, but it is not itself a modifier key.
    expect(isModifierKey({ key: "c" })).toBe(false);
    expect(isModifierKey({ key: "Escape" })).toBe(false);
    expect(isModifierKey({ key: "Enter" })).toBe(false);
    expect(isModifierKey({ key: "ArrowUp" })).toBe(false);
    expect(isModifierKey({ key: " " })).toBe(false);
  });
});
