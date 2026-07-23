/**
 * Shell-integration mark parsing — OSC 133 (FinalTerm semantic prompts) and
 * OSC 633 (VS Code's superset). Pure functions; the pane registers the OSC
 * handlers, buffers the 633;E command line, and forwards marks to the daemon.
 *
 * OSC 133: `A` prompt start · `B` prompt end / input start · `C` output
 * start · `D[;exit]` command finished.
 * OSC 633: same letters, plus `E;<cmdline>[;<nonce>]` carrying the exact
 * command line (with `\xAB` hex escapes), and `P;Key=Value` properties.
 */

/** Mirrors KittermProtocol.MarkKind. */
export const MarkKind = {
  promptStart: 0,
  commandStart: 1,
  preExec: 2,
  commandEnd: 3,
} as const;

export type MarkKindValue = (typeof MarkKind)[keyof typeof MarkKind];

export type ParsedMark =
  /** A semantic mark to report. */
  | { type: "mark"; kind: MarkKindValue; exit: number | null }
  /** 633;E — the exact command line; buffer it and attach it to the next
   * preExec mark instead of reporting a mark of its own. */
  | { type: "commandLine"; command: string };

/** Longest command line forwarded to the daemon (mirrors maxMarkCommandBytes). */
export const MAX_MARK_COMMAND_BYTES = 2048;

const LETTER_KINDS: Record<string, MarkKindValue> = {
  A: MarkKind.promptStart,
  B: MarkKind.commandStart,
  C: MarkKind.preExec,
  D: MarkKind.commandEnd,
};

function markForLetter(letter: string, exitField: string): ParsedMark | null {
  const kind = LETTER_KINDS[letter];
  if (kind === undefined) return null;
  let exit: number | null = null;
  if (kind === MarkKind.commandEnd && exitField !== "") {
    const parsed = Number.parseInt(exitField, 10);
    if (Number.isSafeInteger(parsed)) exit = parsed;
  }
  return { type: "mark", kind, exit };
}

/** Parse an OSC 133 payload (`A`, `B`, `C`, `D;0`, …). Returns null for
 * anything unrecognized — unknown extensions must not become marks. */
export function parseOsc133(payload: string): ParsedMark | null {
  const parts = payload.split(";");
  return markForLetter(parts[0], parts[1] ?? "");
}

/** Unescape 633;E's encoding: `\xAB` hex pairs and `\\`. */
export function unescape633(value: string): string {
  return value.replace(/\\(\\|x[0-9a-fA-F]{2})/g, (_all, esc: string) =>
    esc === "\\" ? "\\" : String.fromCharCode(Number.parseInt(esc.slice(1), 16)),
  );
}

/** Parse an OSC 633 payload. `P;Key=Value` and unknown letters yield null. */
export function parseOsc633(payload: string): ParsedMark | null {
  const separator = payload.indexOf(";");
  const letter = separator === -1 ? payload : payload.slice(0, separator);
  const rest = separator === -1 ? "" : payload.slice(separator + 1);
  if (letter === "E") {
    // `E;<cmdline>[;<nonce>]` — the nonce authenticates the report against
    // spoofing by command output; we drop it and keep the command text.
    const nonceSeparator = rest.lastIndexOf(";");
    const raw = nonceSeparator === -1 ? rest : rest.slice(0, nonceSeparator);
    const command = unescape633(raw);
    if (command === "") return null;
    return { type: "commandLine", command };
  }
  return markForLetter(letter, rest.split(";")[0] ?? "");
}
