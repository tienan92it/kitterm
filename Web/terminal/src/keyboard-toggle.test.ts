import { describe, expect, it } from "vitest";

import { keyboardToggleFace } from "./keyboard-toggle";

describe("keyboardToggleFace", () => {
  it("announces what a tap will do", () => {
    expect(keyboardToggleFace(true).ariaLabel).toBe("Hide the keyboard");
    expect(keyboardToggleFace(false).ariaLabel).toBe("Show the keyboard");
  });

  // The "-off" convention, as in mic-off and eye-off: struck through while the
  // keyboard is up, because a tap puts it away. Only the stroke changes, so the
  // keyboard body never moves between the two states.
  it("strikes the keyboard through only while it is up", () => {
    expect(keyboardToggleFace(true).struck).toBe(true);
    expect(keyboardToggleFace(false).struck).toBe(false);
  });
});
