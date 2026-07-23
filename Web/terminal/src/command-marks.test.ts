import { describe, expect, it } from "vitest";

import { MarkKind, parseOsc133, parseOsc633, unescape633 } from "./command-marks";
import { ClientOpcode, MARK_NO_EXIT, encodeMark } from "./protocol";

describe("parseOsc133", () => {
  it.each([
    ["A", { type: "mark", kind: MarkKind.promptStart, exit: null }],
    ["B", { type: "mark", kind: MarkKind.commandStart, exit: null }],
    ["C", { type: "mark", kind: MarkKind.preExec, exit: null }],
    ["D", { type: "mark", kind: MarkKind.commandEnd, exit: null }],
    ["D;0", { type: "mark", kind: MarkKind.commandEnd, exit: 0 }],
    ["D;127", { type: "mark", kind: MarkKind.commandEnd, exit: 127 }],
  ])("parses %s", (payload, expected) => {
    expect(parseOsc133(payload)).toEqual(expected);
  });

  it("ignores extension parameters on A", () => {
    expect(parseOsc133("A;cl=line")).toEqual({
      type: "mark",
      kind: MarkKind.promptStart,
      exit: null,
    });
  });

  it.each([["P;k=i"], ["Z"], [""], ["D;notanumber"]])(
    "returns null or no exit for unrecognized input %s",
    (payload) => {
      const parsed = parseOsc133(payload);
      if (parsed) {
        expect(parsed).toEqual({ type: "mark", kind: MarkKind.commandEnd, exit: null });
      } else {
        expect(parsed).toBeNull();
      }
    },
  );
});

describe("parseOsc633", () => {
  it("parses the shared letters", () => {
    expect(parseOsc633("D;1")).toEqual({ type: "mark", kind: MarkKind.commandEnd, exit: 1 });
    expect(parseOsc633("A")).toEqual({ type: "mark", kind: MarkKind.promptStart, exit: null });
  });

  it("parses E into a buffered command line", () => {
    expect(parseOsc633("E;ls -la;nonce123")).toEqual({
      type: "commandLine",
      command: "ls -la",
    });
  });

  it("parses E without a nonce", () => {
    expect(parseOsc633("E;git status")).toEqual({
      type: "commandLine",
      command: "git status",
    });
  });

  it("unescapes hex escapes in E", () => {
    // `echo "a;b"` — the semicolon is escaped as \x3b.
    expect(parseOsc633("E;echo a\\x3bb;n")).toEqual({
      type: "commandLine",
      command: "echo a;b",
    });
  });

  it("ignores P properties and empty E", () => {
    expect(parseOsc633("P;Cwd=/tmp")).toBeNull();
    expect(parseOsc633("E;")).toBeNull();
  });
});

describe("unescape633", () => {
  it("handles backslash and hex pairs", () => {
    expect(unescape633("a\\\\b")).toBe("a\\b");
    expect(unescape633("a\\x3bb")).toBe("a;b");
    expect(unescape633("plain")).toBe("plain");
  });
});

describe("encodeMark", () => {
  it("lays out kind, exit, offset, and command", () => {
    const bytes = new Uint8Array(encodeMark(MarkKind.commandEnd, 1, 0x0102, "ls"));
    expect(bytes[0]).toBe(ClientOpcode.mark);
    expect(bytes[1]).toBe(MarkKind.commandEnd);
    const view = new DataView(bytes.buffer);
    expect(view.getInt32(2, false)).toBe(1);
    expect(Number(view.getBigUint64(6, false))).toBe(0x0102);
    expect([...bytes.subarray(14)]).toEqual([...new TextEncoder().encode("ls")]);
  });

  it("uses the Int32.min sentinel when exit is absent", () => {
    const bytes = new Uint8Array(encodeMark(MarkKind.promptStart, null, 0));
    expect(bytes.byteLength).toBe(14);
    const view = new DataView(bytes.buffer);
    expect(view.getInt32(2, false)).toBe(MARK_NO_EXIT);
  });
});
