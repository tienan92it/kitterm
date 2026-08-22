import { describe, expect, it } from "vitest";

import {
  StickyModifiers,
  type KeySpec,
  keyBytes,
  ghostClickShouldAct,
  keyboardTapPlan,
  keyboardToggleFace,
  repeatsOnHold,
  DEFAULT_LAYOUT,
} from "./extra-keys";

const spec = (over: Partial<KeySpec> = {}): KeySpec => ({
  key: "a",
  ctrl: false,
  alt: false,
  ...over,
});

describe("keyBytes", () => {
  it("emits plain named-key sequences", () => {
    expect(keyBytes(spec({ key: "Escape" }))).toBe("\x1b");
    expect(keyBytes(spec({ key: "Tab" }))).toBe("\x09");
    expect(keyBytes(spec({ key: "PageUp" }))).toBe("\x1b[5~");
    expect(keyBytes(spec({ key: "|" }))).toBe("|");
  });

  it("respects application cursor keys for arrows/Home/End", () => {
    expect(keyBytes(spec({ key: "ArrowUp" }), false)).toBe("\x1b[A");
    expect(keyBytes(spec({ key: "ArrowUp" }), true)).toBe("\x1bOA");
    expect(keyBytes(spec({ key: "Home" }), false)).toBe("\x1b[H");
    expect(keyBytes(spec({ key: "Home" }), true)).toBe("\x1bOH");
  });

  it("maps Ctrl on a letter to its control code", () => {
    expect(keyBytes(spec({ key: "c", ctrl: true }))).toBe("\x03");
    expect(keyBytes(spec({ key: "a", ctrl: true }))).toBe("\x01");
    expect(keyBytes(spec({ key: "[", ctrl: true }))).toBe("\x1b"); // Ctrl-[ = Esc
  });

  it("emits modified CSI for Ctrl+arrow", () => {
    expect(keyBytes(spec({ key: "ArrowRight", ctrl: true }))).toBe("\x1b[1;5C");
    expect(keyBytes(spec({ key: "ArrowLeft", ctrl: true }))).toBe("\x1b[1;5D");
  });

  it("prefixes ESC for Alt", () => {
    expect(keyBytes(spec({ key: "f", alt: true }))).toBe("\x1bf");
    expect(keyBytes(spec({ key: "b", alt: true }))).toBe("\x1bb");
  });

  it("combines Ctrl and Alt", () => {
    expect(keyBytes(spec({ key: "c", ctrl: true, alt: true }))).toBe("\x1b\x03");
  });
});

describe("StickyModifiers", () => {
  it("consumes a key with no modifiers by default", () => {
    const m = new StickyModifiers();
    expect(m.consume("Escape")).toEqual({ key: "Escape", ctrl: false, alt: false });
  });

  it("applies an armed modifier to the next key, then releases it", () => {
    const m = new StickyModifiers();
    m.toggle("ctrl");
    expect(m.state).toEqual({ ctrl: true, alt: false });
    expect(m.consume("ArrowUp")).toEqual({ key: "ArrowUp", ctrl: true, alt: false });
    expect(m.state).toEqual({ ctrl: false, alt: false }); // released
  });

  it("holds both modifiers until a key consumes them", () => {
    const m = new StickyModifiers();
    m.toggle("ctrl");
    m.toggle("alt");
    expect(m.consume("c")).toEqual({ key: "c", ctrl: true, alt: true });
  });

  it("toggles a modifier off when tapped twice", () => {
    const m = new StickyModifiers();
    m.toggle("alt");
    expect(m.state.alt).toBe(true);
    m.toggle("alt");
    expect(m.state.alt).toBe(false);
  });
});

// The ExtraKeysBar DOM (rendering, focus discipline, tap wiring) is covered by
// the Playwright mobile e2e; vitest runs without a DOM, matching the codebase's
// pure-test convention.

describe("repeatsOnHold", () => {
  // Holding these obviously means "keep going"; holding Esc or Ctrl does not.
  it("covers backspace and the arrows only", () => {
    expect(repeatsOnHold({ kind: "key", label: "⌫", key: "Backspace" })).toBe(true);
    expect(repeatsOnHold({ kind: "key", label: "←", key: "ArrowLeft" })).toBe(true);
    expect(repeatsOnHold({ kind: "key", label: "Esc", key: "Escape" })).toBe(false);
    expect(repeatsOnHold({ kind: "key", label: "Tab", key: "Tab" })).toBe(false);
  });

  it("never repeats a sticky modifier", () => {
    expect(repeatsOnHold({ kind: "mod", label: "Ctrl", mod: "ctrl" })).toBe(false);
  });
});

describe("backspace", () => {
  // The default branch returns the key name verbatim, so a missing case types
  // the word "Backspace" into the shell.
  it("sends DEL, not its own name", () => {
    expect(keyBytes(spec({ key: "Backspace" }))).toBe("\u007f");
  });

  // Not in the default bar — the system keyboard's delete is the one people
  // reach for — but a custom layout may carry it, and it must send DEL.
  it("is not in the default bar", () => {
    const keys = DEFAULT_LAYOUT.flat();
    expect(keys.some((k) => k.kind === "key" && k.key === "Backspace")).toBe(false);
  });
});

// The row exists to keep the keyboard up; this one key exists to drop it, so
// reading a build log or a diff on a phone gets the screen back.
describe("the keyboard toggle", () => {
  const key = DEFAULT_LAYOUT.flat().find((k) => k.kind === "keyboard");

  it("is in the default row", () => {
    expect(key).toBeDefined();
  });

  // Drawn, not lettered: U+2328 renders as a detailed little keyboard that
  // carries more line work than a 20px button can show, and differs per
  // platform. The key holds no glyph at all now.
  it("carries no glyph, because the icon is drawn", () => {
    expect(key).toEqual({ kind: "keyboard" });
  });

  it("never repeats on hold — a toggle held down must not flap", () => {
    if (!key) throw new Error("unreachable");
    expect(repeatsOnHold(key)).toBe(false);
  });

  // The constraint the issue says decides whether this works at all: iOS Safari
  // opens the keyboard only for a focus() inside a live user gesture, and
  // preventDefault spends that gesture.
  it("does not preventDefault when it is about to show the keyboard", () => {
    expect(keyboardTapPlan(false)).toEqual({ open: true, preventDefault: false });
  });

  it("does preventDefault when hiding, so focus stays in the terminal", () => {
    expect(keyboardTapPlan(true)).toEqual({ open: false, preventDefault: true });
  });

  it("always asks for the opposite of the keyboard's real state", () => {
    expect(keyboardTapPlan(true).open).toBe(false);
    expect(keyboardTapPlan(false).open).toBe(true);
  });

  it("announces what a tap will do", () => {
    expect(keyboardToggleFace(true).ariaLabel).toBe("Hide the keyboard");
    expect(keyboardToggleFace(false).ariaLabel).toBe("Show the keyboard");
  });

  // The "-off" convention, as in mic-off and eye-off: struck through while
  // the keyboard is up, because a tap puts it away. Only the stroke changes,
  // so the keyboard body never moves between the two states.
  it("strikes the keyboard through only while it is up", () => {
    expect(keyboardToggleFace(true).struck).toBe(true);
    expect(keyboardToggleFace(false).struck).toBe(false);
  });
});

// The bug this fixes, found on a phone: tapping to hide blurred on touchstart,
// and the ghost click landed while the keyboard was still sliding shut. The
// inset still read open, so the click concluded "show" and reopened what the
// touch had just closed. Every hide undid itself, which is what the flicker was.
describe("the ghost click after a toggle tap", () => {
  it("does nothing while the keyboard is still closing", () => {
    expect(ghostClickShouldAct(50, false)).toBe(false);
    expect(ghostClickShouldAct(699, false)).toBe(false);
  });

  // The show direction defers to the click on purpose: focusing during
  // touchstart opens the keyboard and the browser's own tap handling then takes
  // focus straight back off, which is the other half of the flicker.
  it("does act when a show was deferred to it, however soon it arrives", () => {
    expect(ghostClickShouldAct(0, true)).toBe(true);
    expect(ghostClickShouldAct(50, true)).toBe(true);
  });

  it("acts for a real mouse click, which no touch preceded", () => {
    expect(ghostClickShouldAct(Number.POSITIVE_INFINITY, false)).toBe(true);
    expect(ghostClickShouldAct(700, false)).toBe(true);
  });
});
