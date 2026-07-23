import { describe, expect, it } from "vitest";

import { ReplayGuard, isQueryResponse } from "./replay-guard";

describe("isQueryResponse", () => {
  it.each([
    ["CPR", "\x1b[24;1R"],
    ["DECXCPR", "\x1b[?24;1R"],
    ["DA1", "\x1b[?1;2c"],
    ["DA1 modern", "\x1b[?64;1;2;6;9;15;18;21;22c"],
    ["DA2", "\x1b[>0;276;0c"],
    ["DSR ready", "\x1b[0n"],
    ["DECRPM", "\x1b[?2026;2$y"],
    ["OSC 11 color report", "\x1b]11;rgb:1e1e/1e1e/1e1e\x07"],
    ["OSC 10 color report ST", "\x1b]10;rgb:ffff/ffff/ffff\x1b\\"],
    ["DCS DECRQSS", "\x1bP1$r0;0m\x1b\\"],
    ["two responses in one chunk", "\x1b[24;1R\x1b[?1;2c"],
  ])("recognizes %s", (_name, chunk) => {
    expect(isQueryResponse(chunk)).toBe(true);
  });

  it.each([
    ["typed text", "ls\r"],
    ["arrow key", "\x1b[A"],
    ["shift-tab", "\x1b[Z"],
    ["F1", "\x1bOP"],
    ["alt-x", "\x1bx"],
    ["mouse report", "\x1b[<0;10;10M"],
    ["bracketed paste", "\x1b[200~echo hi\x1b[201~"],
    ["kitty key", "\x1b[13;5u"],
    ["response followed by typing", "\x1b[24;1Rls"],
    ["bare escape", "\x1b"],
    ["empty", ""],
  ])("passes %s through", (_name, chunk) => {
    expect(isQueryResponse(chunk)).toBe(false);
  });
});

describe("ReplayGuard", () => {
  it("drops query responses only while the replay window is parsing", () => {
    const guard = new ReplayGuard();
    guard.arm(100);

    expect(guard.shouldDrop("\x1b[24;1R")).toBe(true);
    expect(guard.shouldDrop("\x1b[?1;2c")).toBe(true);
    expect(guard.shouldDrop("\x1b[>0;276;0c")).toBe(true);
    expect(guard.shouldDrop("\x1b[?2026;2$y")).toBe(true);

    // User input during the flush is never dropped.
    expect(guard.shouldDrop("ls\r")).toBe(false);
    expect(guard.shouldDrop("\x1b[A")).toBe(false);

    guard.onParsed(60);
    expect(guard.active).toBe(true);
    expect(guard.shouldDrop("\x1b[24;1R")).toBe(true);

    guard.onParsed(40);
    expect(guard.active).toBe(false);
    // Disarmed: a live CPR (e.g. vim asking right now) passes.
    expect(guard.shouldDrop("\x1b[24;1R")).toBe(false);
  });

  it("stays inactive when armed with an empty replay", () => {
    const guard = new ReplayGuard();
    guard.arm(0);
    expect(guard.active).toBe(false);
    expect(guard.shouldDrop("\x1b[24;1R")).toBe(false);
  });

  it("re-arms per reconnect", () => {
    const guard = new ReplayGuard();
    guard.arm(10);
    guard.onParsed(10);
    expect(guard.active).toBe(false);
    guard.arm(5);
    expect(guard.shouldDrop("\x1b[0n")).toBe(true);
  });
});
