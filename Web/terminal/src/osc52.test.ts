import { describe, expect, it } from "vitest";

import { OSC52_MAX_DECODED_BYTES, parseOsc52 } from "./osc52";

const b64 = (text: string): string =>
  btoa(Array.from(new TextEncoder().encode(text), (byte) => String.fromCharCode(byte)).join(""));

describe("parseOsc52", () => {
  it("decodes a clipboard write to UTF-8 text", () => {
    expect(parseOsc52(`c;${b64("hi")}`)).toEqual({ kind: "write", selection: "c", text: "hi" });
    expect(parseOsc52(`c;${b64("Tiếng Việt — ✓")}`)).toEqual({
      kind: "write",
      selection: "c",
      text: "Tiếng Việt — ✓",
    });
  });

  it("keeps the selection name and accepts an empty one", () => {
    // micro names no selection; lazygit and tmux name `c`.
    expect(parseOsc52(`;${b64("x")}`)).toEqual({ kind: "write", selection: "", text: "x" });
    expect(parseOsc52(`pc;${b64("x")}`)).toMatchObject({ kind: "write", selection: "pc" });
  });

  it("refuses a read request and answers nothing", () => {
    expect(parseOsc52("c;?")).toEqual({ kind: "refused", reason: "query" });
  });

  it("refuses an empty payload rather than clearing anything", () => {
    expect(parseOsc52("c;")).toEqual({ kind: "refused", reason: "empty" });
    // Base64 of nothing is nothing too.
    expect(parseOsc52("c;====")).toEqual({ kind: "refused", reason: "malformed" });
  });

  it("refuses a payload with no selection separator", () => {
    expect(parseOsc52(b64("hi"))).toEqual({ kind: "refused", reason: "malformed" });
  });

  it("refuses bytes that are not base64", () => {
    expect(parseOsc52("c;not base64!")).toEqual({ kind: "refused", reason: "malformed" });
    expect(parseOsc52("c;a")).toEqual({ kind: "refused", reason: "malformed" });
  });

  it("drops whitespace a program wrapped its base64 with", () => {
    const wrapped = b64("hello world").replace(/(.{4})/g, "$1\n");
    expect(parseOsc52(`c;${wrapped}`)).toMatchObject({ kind: "write", text: "hello world" });
  });

  it("takes exactly the cap and refuses one byte over it, whole", () => {
    const atCap = "a".repeat(OSC52_MAX_DECODED_BYTES);
    expect(parseOsc52(`c;${b64(atCap)}`)).toMatchObject({ kind: "write", text: atCap });
    const over = "a".repeat(OSC52_MAX_DECODED_BYTES + 1);
    expect(parseOsc52(`c;${b64(over)}`)).toEqual({ kind: "refused", reason: "too-long" });
  });

  it("refuses an oversized payload before decoding it", () => {
    // Base64 four times the cap could never decode under it.
    const huge = "A".repeat(OSC52_MAX_DECODED_BYTES * 4);
    expect(parseOsc52(`c;${huge}`)).toEqual({ kind: "refused", reason: "too-long" });
  });
});
