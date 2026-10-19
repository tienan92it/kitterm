import { describe, expect, it } from "vitest";

import { mouseWheelSequence, swipeToInput } from "./touch-scroll";

// `touch-scroll.test.ts` pins the SGR form; this file is the X10 form a
// program gets when it asked for reports (`CSI ? 1000 h`) and not for SGR.

describe("mouseWheelSequence in the X10 form", () => {
  it("encodes wheel up and down as one byte each, offset by 32", () => {
    // button 64 → 96 (`), col 5 → 37 (%), row 3 → 35 (#)
    expect(mouseWheelSequence(true, 5, 3, "x10")).toBe("\x1b[M`%#");
    // button 65 → 97 (a), col 1 → 33 (!), row 1 → 33 (!)
    expect(mouseWheelSequence(false, 1, 1, "x10")).toBe("\x1b[Ma!!");
  });

  it("clamps a cell to the 223 the single byte can name", () => {
    expect(mouseWheelSequence(true, 300, 400, "x10")).toBe(
      `\x1b[M\`${String.fromCharCode(255)}${String.fromCharCode(255)}`,
    );
    expect(mouseWheelSequence(true, 0, 0, "x10")).toBe("\x1b[M`!!");
  });

  it("stays SGR when no encoding is named", () => {
    expect(mouseWheelSequence(true, 5, 3)).toBe("\x1b[<64;5;3M");
  });
});

describe("swipeToInput with an encoding", () => {
  it("repeats one X10 report per step at the finger's cell", () => {
    expect(swipeToInput("mouse", 2, { col: 2, row: 4 }, false, "x10")).toBe(
      "\x1b[M`\"$\x1b[M`\"$",
    );
    expect(swipeToInput("mouse", -1, { col: 2, row: 4 }, false, "x10")).toBe('\x1b[Ma"$');
  });

  it("repeats one SGR report per step when the program turned 1006 on", () => {
    expect(swipeToInput("mouse", -2, { col: 7, row: 9 }, false, "sgr")).toBe(
      "\x1b[<65;7;9M\x1b[<65;7;9M",
    );
  });

  it("leaves the arrow and scrollback targets alone", () => {
    expect(swipeToInput("arrows", 1, { col: 1, row: 1 }, true, "x10")).toBe("\x1bOA");
    expect(swipeToInput("scrollback", 1, { col: 1, row: 1 }, false, "x10")).toBe("");
  });
});
