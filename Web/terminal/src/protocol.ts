/** KittermProtocol binary frames — mirrors Sources/KittermProtocol/Frame.swift */

export const ClientOpcode = {
  input: 0,
  resize: 1,
  pause: 2,
  resume: 3,
} as const;

export const ServerOpcode = {
  output: 0,
  title: 1,
  sessionMeta: 2,
  cwd: 3,
  exit: 4,
  sessionId: 5,
  resize: 6,
  role: 7,
} as const;

export type SessionRole = "controller" | "observer";

export type SessionMeta = {
  shell: string;
  pid: number;
  cwd: string;
};

export type ServerFrame =
  | { type: "output"; data: Uint8Array }
  | { type: "title"; title: string }
  | { type: "sessionMeta"; meta: SessionMeta }
  | { type: "cwd"; cwd: string }
  | { type: "exit"; code: number }
  | { type: "sessionId"; id: string }
  | { type: "resize"; cols: number; rows: number }
  | { type: "role"; role: SessionRole };

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

export function encodeInput(data: string | Uint8Array): ArrayBuffer {
  const payload = typeof data === "string" ? textEncoder.encode(data) : data;
  const out = new Uint8Array(1 + payload.byteLength);
  out[0] = ClientOpcode.input;
  out.set(payload, 1);
  return out.buffer;
}

export function encodeResize(cols: number, rows: number): ArrayBuffer {
  const out = new Uint8Array(5);
  out[0] = ClientOpcode.resize;
  out[1] = (cols >> 8) & 0xff;
  out[2] = cols & 0xff;
  out[3] = (rows >> 8) & 0xff;
  out[4] = rows & 0xff;
  return out.buffer;
}

export function encodePause(): ArrayBuffer {
  return new Uint8Array([ClientOpcode.pause]).buffer;
}

export function encodeResume(): ArrayBuffer {
  return new Uint8Array([ClientOpcode.resume]).buffer;
}

function readU16BE(view: DataView, offset: number): number {
  return view.getUint16(offset, false);
}

function readI32BE(view: DataView, offset: number): number {
  return view.getInt32(offset, false);
}

function readLengthPrefixedString(
  view: DataView,
  bytes: Uint8Array,
  offset: { value: number },
): string {
  if (offset.value + 2 > bytes.length) {
    throw new Error("truncated session meta string length");
  }
  const len = readU16BE(view, offset.value);
  offset.value += 2;
  if (offset.value + len > bytes.length) {
    throw new Error("truncated session meta string");
  }
  const slice = bytes.subarray(offset.value, offset.value + len);
  offset.value += len;
  return textDecoder.decode(slice);
}

function decodeSessionMeta(payload: Uint8Array): SessionMeta {
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  const offset = { value: 0 };
  const shell = readLengthPrefixedString(view, payload, offset);
  if (offset.value + 4 > payload.length) {
    throw new Error("truncated session meta pid");
  }
  const pid = readI32BE(view, offset.value);
  offset.value += 4;
  const cwd = readLengthPrefixedString(view, payload, offset);
  if (offset.value !== payload.length) {
    throw new Error("trailing session meta bytes");
  }
  return { shell, pid, cwd };
}

export function decodeServerFrame(buffer: ArrayBuffer): ServerFrame {
  const bytes = new Uint8Array(buffer);
  if (bytes.length === 0) {
    throw new Error("empty frame");
  }
  const opcode = bytes[0];
  const payload = bytes.subarray(1);
  switch (opcode) {
    case ServerOpcode.output:
      return { type: "output", data: payload };
    case ServerOpcode.title:
      return { type: "title", title: textDecoder.decode(payload) };
    case ServerOpcode.sessionMeta:
      return { type: "sessionMeta", meta: decodeSessionMeta(payload) };
    case ServerOpcode.cwd:
      return { type: "cwd", cwd: textDecoder.decode(payload) };
    case ServerOpcode.exit: {
      if (payload.length !== 4) {
        throw new Error("invalid exit payload");
      }
      const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
      return { type: "exit", code: view.getInt32(0, false) };
    }
    case ServerOpcode.sessionId:
      return { type: "sessionId", id: textDecoder.decode(payload) };
    case ServerOpcode.resize: {
      if (payload.length !== 4) {
        throw new Error("invalid resize payload");
      }
      const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
      return { type: "resize", cols: view.getUint16(0, false), rows: view.getUint16(2, false) };
    }
    case ServerOpcode.role: {
      if (payload.length !== 1) {
        throw new Error("invalid role payload");
      }
      return { type: "role", role: payload[0] === 1 ? "observer" : "controller" };
    }
    default:
      throw new Error(`unknown server opcode ${opcode}`);
  }
}
