import { describe, expect, it } from "vitest";

import {
  ClientOpcode,
  ServerOpcode,
  decodeServerFrame,
  encodeInput,
  encodePause,
  encodeResize,
  encodeResume,
} from "./protocol";

const frame = (opcode: number, ...payload: number[]): ArrayBuffer =>
  new Uint8Array([opcode, ...payload]).buffer;

const utf8 = (s: string): number[] => [...new TextEncoder().encode(s)];

/** Length-prefixed string as sessionMeta encodes it: u16be length + bytes. */
const lenPrefixed = (s: string): number[] => {
  const bytes = utf8(s);
  return [(bytes.length >> 8) & 0xff, bytes.length & 0xff, ...bytes];
};

describe("client encoders", () => {
  it("encodes input with the opcode byte first", () => {
    const bytes = new Uint8Array(encodeInput("hi"));
    expect(bytes[0]).toBe(ClientOpcode.input);
    expect([...bytes.subarray(1)]).toEqual(utf8("hi"));
  });

  it("accepts raw bytes as input", () => {
    const bytes = new Uint8Array(encodeInput(new Uint8Array([0x03])));
    expect([...bytes]).toEqual([ClientOpcode.input, 0x03]);
  });

  it("encodes resize big-endian", () => {
    // 300 = 0x012C, 80 = 0x0050
    expect([...new Uint8Array(encodeResize(300, 80))]).toEqual([
      ClientOpcode.resize, 0x01, 0x2c, 0x00, 0x50,
    ]);
  });

  it("encodes pause and resume as bare opcodes", () => {
    expect([...new Uint8Array(encodePause())]).toEqual([ClientOpcode.pause]);
    expect([...new Uint8Array(encodeResume())]).toEqual([ClientOpcode.resume]);
  });
});

describe("decodeServerFrame", () => {
  it("decodes output as raw bytes", () => {
    const decoded = decodeServerFrame(frame(ServerOpcode.output, 1, 2, 3));
    expect(decoded).toEqual({ type: "output", data: new Uint8Array([1, 2, 3]) });
  });

  it("decodes an empty output frame", () => {
    const decoded = decodeServerFrame(frame(ServerOpcode.output));
    expect(decoded.type === "output" && decoded.data.length).toBe(0);
  });

  it("decodes title and cwd as UTF-8", () => {
    expect(decodeServerFrame(frame(ServerOpcode.title, ...utf8("wörk")))).toEqual({
      type: "title",
      title: "wörk",
    });
    expect(decodeServerFrame(frame(ServerOpcode.cwd, ...utf8("/tmp/ä")))).toEqual({
      type: "cwd",
      cwd: "/tmp/ä",
    });
  });

  it("decodes sessionId", () => {
    const id = "4b1f0f2a-0000-4000-8000-000000000000";
    expect(decodeServerFrame(frame(ServerOpcode.sessionId, ...utf8(id)))).toEqual({
      type: "sessionId",
      id,
    });
  });

  it("decodes exit, including negative codes", () => {
    expect(decodeServerFrame(frame(ServerOpcode.exit, 0, 0, 0, 130))).toEqual({
      type: "exit",
      code: 130,
    });
    // -1 as i32be
    expect(decodeServerFrame(frame(ServerOpcode.exit, 0xff, 0xff, 0xff, 0xff))).toEqual({
      type: "exit",
      code: -1,
    });
  });

  it("decodes resize", () => {
    expect(decodeServerFrame(frame(ServerOpcode.resize, 0x01, 0x2c, 0x00, 0x50))).toEqual({
      type: "resize",
      cols: 300,
      rows: 80,
    });
  });

  it("decodes both roles", () => {
    expect(decodeServerFrame(frame(ServerOpcode.role, 0))).toEqual({
      type: "role",
      role: "controller",
    });
    expect(decodeServerFrame(frame(ServerOpcode.role, 1))).toEqual({
      type: "role",
      role: "observer",
    });
  });

  it("decodes sessionMeta", () => {
    const payload = [
      ...lenPrefixed("/bin/zsh"),
      0x00, 0x00, 0x30, 0x39, // pid 12345
      ...lenPrefixed("/Users/me"),
    ];
    expect(decodeServerFrame(frame(ServerOpcode.sessionMeta, ...payload))).toEqual({
      type: "sessionMeta",
      meta: { shell: "/bin/zsh", pid: 12345, cwd: "/Users/me" },
    });
  });
});

describe("decodeServerFrame — malformed input", () => {
  it("rejects an empty frame", () => {
    expect(() => decodeServerFrame(new ArrayBuffer(0))).toThrow(/empty frame/);
  });

  it("rejects an unknown opcode", () => {
    expect(() => decodeServerFrame(frame(99))).toThrow(/unknown server opcode 99/);
  });

  it.each([
    ["exit", ServerOpcode.exit, [0, 0, 0]],
    ["exit", ServerOpcode.exit, [0, 0, 0, 0, 0]],
    ["resize", ServerOpcode.resize, [0, 1]],
    ["role", ServerOpcode.role, []],
    ["role", ServerOpcode.role, [0, 0]],
  ])("rejects a wrong-length %s payload", (name, opcode, payload) => {
    expect(() => decodeServerFrame(frame(opcode, ...payload))).toThrow(
      new RegExp(`invalid ${name} payload`),
    );
  });

  it("rejects sessionMeta truncated in the string length", () => {
    expect(() => decodeServerFrame(frame(ServerOpcode.sessionMeta, 0x00))).toThrow(
      /truncated session meta string length/,
    );
  });

  it("rejects sessionMeta whose string runs past the end", () => {
    expect(() =>
      decodeServerFrame(frame(ServerOpcode.sessionMeta, 0x00, 0x10, 0x61)),
    ).toThrow(/truncated session meta string/);
  });

  it("rejects sessionMeta truncated before the pid", () => {
    expect(() =>
      decodeServerFrame(frame(ServerOpcode.sessionMeta, ...lenPrefixed("sh"), 0x00)),
    ).toThrow(/truncated session meta pid/);
  });

  it("rejects sessionMeta with trailing bytes", () => {
    const payload = [
      ...lenPrefixed("sh"),
      0, 0, 0, 1,
      ...lenPrefixed("/"),
      0xff, // unexpected
    ];
    expect(() => decodeServerFrame(frame(ServerOpcode.sessionMeta, ...payload))).toThrow(
      /trailing session meta bytes/,
    );
  });
});
