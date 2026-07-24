import { describe, expect, it } from "vitest";

import { keyboardInset } from "./keyboard-insets";

describe("keyboardInset", () => {
  it("is zero when the viewport fills the window", () => {
    expect(keyboardInset(800, 800, 0)).toBe(0);
  });

  it("reports the covered height when the keyboard shrinks the viewport", () => {
    // 800px window, keyboard leaves a 500px visual viewport.
    expect(keyboardInset(800, 500, 0)).toBe(300);
  });

  it("accounts for a scrolled visual viewport (offsetTop)", () => {
    expect(keyboardInset(800, 500, 50)).toBe(250);
  });

  it("ignores small gaps that are browser chrome, not a keyboard", () => {
    expect(keyboardInset(800, 770, 0)).toBe(0); // 30px < threshold
  });

  it("never goes negative", () => {
    expect(keyboardInset(800, 820, 0)).toBe(0);
  });

  it("rounds fractional heights", () => {
    expect(keyboardInset(800, 500.4, 0)).toBe(300);
  });
});
