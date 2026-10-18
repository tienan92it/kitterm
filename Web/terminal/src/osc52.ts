/**
 * OSC 52: a program in the pane puts text on the viewing device's clipboard.
 *
 * `ESC ] 52 ; Pc ; Pd BEL` names a selection (`Pc`, `c` for the clipboard,
 * `p` for the primary, any run of letters) and carries the text as base64
 * (`Pd`). A `Pd` of `?` asks the terminal to answer with the clipboard's
 * content; the pane refuses that and answers nothing, because the daemon
 * passes the answer to whatever program asked, and a program a viewer did
 * not start must not read the viewer's clipboard.
 *
 * Write only, and no addon: xterm.js's own OSC parser hands the payload to
 * `parseOsc52`, which decides, and the pane writes the text. A payload over
 * `OSC52_MAX_DECODED_BYTES` is refused whole rather than cut, so a program
 * never learns that a part of its text arrived.
 */

/** The most text one sequence may put on the clipboard. */
export const OSC52_MAX_DECODED_BYTES = 1 << 20;

export type Osc52Verdict =
  | { kind: "write"; selection: string; text: string }
  | { kind: "refused"; reason: "query" | "empty" | "too-long" | "malformed" };

const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;

/** Decode standard base64 to bytes. Whitespace is dropped first: a program
 * that wraps its base64 is still one payload. Throws on any other byte. */
function decodeBase64(payload: string): Uint8Array {
  const compact = payload.replace(/\s+/g, "");
  if (!BASE64.test(compact) || compact.length % 4 === 1) {
    throw new Error("not base64");
  }
  const binary = atob(compact);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** Decide what an OSC 52 payload (the text after `52;`) asks for. */
export function parseOsc52(data: string): Osc52Verdict {
  const separator = data.indexOf(";");
  if (separator < 0) return { kind: "refused", reason: "malformed" };
  const selection = data.slice(0, separator);
  const payload = data.slice(separator + 1);
  if (payload === "?") return { kind: "refused", reason: "query" };
  if (payload.length === 0) return { kind: "refused", reason: "empty" };
  // Four base64 characters carry three bytes; judged before the decode so
  // an oversized payload costs no buffer.
  if (payload.length > Math.ceil(OSC52_MAX_DECODED_BYTES / 3) * 4) {
    return { kind: "refused", reason: "too-long" };
  }
  let bytes: Uint8Array;
  try {
    bytes = decodeBase64(payload);
  } catch {
    return { kind: "refused", reason: "malformed" };
  }
  if (bytes.length > OSC52_MAX_DECODED_BYTES) return { kind: "refused", reason: "too-long" };
  if (bytes.length === 0) return { kind: "refused", reason: "empty" };
  const text = new TextDecoder("utf-8").decode(bytes);
  return { kind: "write", selection, text };
}
