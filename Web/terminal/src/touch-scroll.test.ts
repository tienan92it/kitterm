import { describe, expect, it } from "vitest";

import {
  SwipeAccumulator,
  mouseWheelSequence,
  swipeTarget,
  swipeToInput,
} from "./touch-scroll";

describe("swipeTarget", () => {
  it("scrolls the buffer on the normal screen with no mouse reporting", () => {
    expect(swipeTarget(false, false)).toBe("scrollback");
  });
  it("sends arrows on the alt screen", () => {
    expect(swipeTarget(true, false)).toBe("arrows");
  });
  it("prefers mouse wheel whenever the app reports the mouse", () => {
    expect(swipeTarget(true, true)).toBe("mouse");
    expect(swipeTarget(false, true)).toBe("mouse");
  });
});

describe("SwipeAccumulator", () => {
  it("emits one step per row of movement", () => {
    const a = new SwipeAccumulator(20);
    expect(a.feed(10)).toBe(0); // sub-row carries over
    expect(a.feed(10)).toBe(1); // 20px total → 1 step
    expect(a.feed(45)).toBe(2); // 45px → 2 steps, 5px carried
  });
  it("handles upward (negative) movement", () => {
    const a = new SwipeAccumulator(20);
    expect(a.feed(-40)).toBe(-2);
  });
  it("is inert with a non-positive row height", () => {
    expect(new SwipeAccumulator(0).feed(100)).toBe(0);
  });
  it("resets accumulated distance", () => {
    const a = new SwipeAccumulator(20);
    a.feed(15);
    a.reset();
    expect(a.feed(10)).toBe(0);
  });
});

describe("mouseWheelSequence", () => {
  it("encodes SGR wheel up/down at a clamped position", () => {
    expect(mouseWheelSequence(true, 5, 3)).toBe("\x1b[<64;5;3M");
    expect(mouseWheelSequence(false, 0, 0)).toBe("\x1b[<65;1;1M");
  });
});

describe("swipeToInput", () => {
  it("sends nothing for the scrollback target or no movement", () => {
    expect(swipeToInput("scrollback", 3)).toBe("");
    expect(swipeToInput("arrows", 0)).toBe("");
  });
  it("maps finger-down to Up arrow and finger-up to Down arrow (CSI)", () => {
    expect(swipeToInput("arrows", 2)).toBe("\x1b[A\x1b[A");
    expect(swipeToInput("arrows", -3)).toBe("\x1b[B\x1b[B\x1b[B");
  });
  it("uses SS3 arrows in application cursor keys mode (less, vim)", () => {
    expect(swipeToInput("arrows", 1, { col: 1, row: 1 }, true)).toBe("\x1bOA");
    expect(swipeToInput("arrows", -2, { col: 1, row: 1 }, true)).toBe("\x1bOB\x1bOB");
  });
  it("maps finger-down to wheel-up at the cursor", () => {
    expect(swipeToInput("mouse", 1, { col: 2, row: 4 })).toBe("\x1b[<64;2;4M");
    expect(swipeToInput("mouse", -2, { col: 2, row: 4 })).toBe(
      "\x1b[<65;2;4M\x1b[<65;2;4M",
    );
  });
});
