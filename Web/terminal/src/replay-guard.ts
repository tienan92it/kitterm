/**
 * Drops stale terminal-query responses while a replay flush is parsing.
 *
 * Replayed output can contain device queries (DA, DSR/CPR, DECRQM, OSC color
 * queries, DECRQSS) that some program sent while the client was away. xterm.js
 * answers them automatically through onData — and forwarding those answers
 * would inject bytes into the shell's stdin long after the program that asked
 * has moved on (vim reading a stray `\x1b[?64;1c` as keystrokes).
 *
 * The guard stays armed until the announced replay window has fully parsed
 * (fed by the same write-completion callbacks that drive flow control). While
 * armed, onData chunks that are exactly query responses are dropped; real user
 * input — arrows, mouse reports, pastes — never matches and passes through.
 *
 * The daemon's batcher may merge the replay tail with the first live bytes
 * into one frame, so the guard can over-cover by at most one parse window. A
 * live query cannot complete a round trip inside that window, so nothing real
 * is ever dropped.
 */

/** One terminal→application query response. */
const RESPONSE =
  "\\x1b\\[\\??\\d+(?:;\\d+)*R" + // CPR / DECXCPR cursor position
  "|\\x1b\\[\\?\\d+(?:;\\d+)*c" + // DA1 device attributes
  "|\\x1b\\[>\\d+(?:;\\d+)*c" + // DA2 secondary device attributes
  "|\\x1b\\[\\d+n" + // DSR status (`0n` ready)
  "|\\x1b\\[\\?\\d+;\\d+\\$y" + // DECRPM mode report
  "|\\x1b\\]\\d+;[^\\x07\\x1b]*(?:\\x07|\\x1b\\\\)" + // OSC color report
  "|\\x1bP[^\\x1b]*\\x1b\\\\"; // DCS response (DECRQSS, XTGETTCAP)

/** A chunk consisting only of query responses (xterm emits each response as
 * its own onData call, but a burst of several is still only responses). */
const QUERY_RESPONSES_ONLY = new RegExp(`^(?:${RESPONSE})+$`);

export function isQueryResponse(data: string): boolean {
  return QUERY_RESPONSES_ONLY.test(data);
}

export class ReplayGuard {
  private remaining = 0;

  /** Called on `logState`: the next `replayLen` output bytes are replay. */
  arm(replayLen: number): void {
    this.remaining = replayLen;
  }

  get active(): boolean {
    return this.remaining > 0;
  }

  /** Feed parse-completion byte counts (the write-callback totals). */
  onParsed(bytes: number): void {
    this.remaining = Math.max(0, this.remaining - bytes);
  }

  /** True when this onData chunk is a stale query answer to swallow. */
  shouldDrop(data: string): boolean {
    return this.active && isQueryResponse(data);
  }
}
