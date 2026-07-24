import { describe, expect, it } from "vitest";

import { StickyModifiers, type KeySpec, keyBytes } from "./extra-keys";

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
