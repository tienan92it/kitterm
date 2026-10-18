import { describe, expect, it } from "vitest";

import { ansiModeState, decrqmReply, privateModeState, type KnownModes } from "./decrqm";

const quiet: KnownModes = {
  applicationCursorKeys: false,
  applicationKeypad: false,
  bracketedPaste: false,
  insert: false,
  mouseTracking: "none",
  origin: false,
  reverseWraparound: false,
  sendFocus: false,
  wraparound: true,
  alternateScreen: false,
  sgrMouse: false,
  cursorBlink: true,
};

const lazygit: KnownModes = {
  ...quiet,
  mouseTracking: "any",
  sgrMouse: true,
  alternateScreen: true,
  bracketedPaste: true,
  sendFocus: true,
  applicationCursorKeys: true,
};

describe("privateModeState", () => {
  it("answers the modes lazygit asks about from the pane's own state", () => {
    expect(privateModeState(1000, lazygit)).toBe(2); // VT200 is not the active protocol: any is
    expect(privateModeState(1003, lazygit)).toBe(1);
    expect(privateModeState(1006, lazygit)).toBe(1);
    expect(privateModeState(1006, quiet)).toBe(2);
    expect(privateModeState(2048, lazygit)).toBe(0); // in-band resize: not recognized
    expect(privateModeState(9001, lazygit)).toBe(0); // win32-input-mode: not recognized
  });

  it("reports the alternate screen for the three names it has", () => {
    for (const mode of [47, 1047, 1049]) {
      expect(privateModeState(mode, lazygit)).toBe(1);
      expect(privateModeState(mode, quiet)).toBe(2);
    }
  });

  it("knows what is always set or always reset", () => {
    expect(privateModeState(8, quiet)).toBe(3);
    expect(privateModeState(67, quiet)).toBe(4);
    expect(privateModeState(1005, quiet)).toBe(4);
    expect(privateModeState(1015, quiet)).toBe(4);
    expect(privateModeState(1048, quiet)).toBe(1);
  });

  it("does not claim a mode the public API cannot see", () => {
    // Synchronized output and pixel mouse reports: xterm tracks them, the
    // API does not expose them, so the honest answer is "not recognized".
    expect(privateModeState(2026, lazygit)).toBe(0);
    expect(privateModeState(1016, lazygit)).toBe(0);
    expect(privateModeState(25, lazygit)).toBe(0);
  });

  it("reads the plain flags", () => {
    expect(privateModeState(1, lazygit)).toBe(1);
    expect(privateModeState(7, quiet)).toBe(1);
    expect(privateModeState(1004, lazygit)).toBe(1);
    expect(privateModeState(2004, lazygit)).toBe(1);
    expect(privateModeState(12, { ...quiet, cursorBlink: false })).toBe(2);
    expect(privateModeState(9, { ...quiet, mouseTracking: "x10" })).toBe(1);
  });
});

describe("ansiModeState", () => {
  it("answers insert mode and the two fixed ones", () => {
    expect(ansiModeState(4, { ...quiet, insert: true })).toBe(1);
    expect(ansiModeState(4, quiet)).toBe(2);
    expect(ansiModeState(2, quiet)).toBe(4);
    expect(ansiModeState(12, quiet)).toBe(3);
    expect(ansiModeState(20, quiet)).toBe(0);
  });
});

describe("decrqmReply", () => {
  it("writes the DECRPM form with the question mark of a private mode", () => {
    expect(decrqmReply([1006], true, lazygit)).toBe("\x1b[?1006;1$y");
    expect(decrqmReply([2048], true, lazygit)).toBe("\x1b[?2048;0$y");
    expect(decrqmReply([4], false, quiet)).toBe("\x1b[4;2$y");
  });

  it("reads a missing or nested parameter as mode 0", () => {
    expect(decrqmReply([], true, quiet)).toBe("\x1b[?0;0$y");
    expect(decrqmReply([[1049]], true, lazygit)).toBe("\x1b[?1049;1$y");
  });
});
