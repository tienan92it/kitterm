/**
 * Turning terminal output into things you can open.
 *
 * A terminal prints URLs and paths constantly and every one of them is dead
 * text. On a desktop you paste it somewhere else; on a phone there is nowhere
 * to paste it to, which is the case kitterm exists for.
 *
 * This module decides *what* is a link. It holds no DOM and no network, so the
 * guessing — which is where this feature goes wrong — can be tested directly.
 */

/** A candidate found in a line, and where it sits on that line. */
export interface Candidate {
  /** The text as it appeared. */
  text: string;
  /** 0-based column of the first character. */
  start: number;
  /** 0-based column one past the last character. */
  end: number;
}

/** Trailing punctuation a terminal puts *around* a path rather than in it. */
const TRAILING = /[.,;:!?'"`]+$/;

const CLOSERS: Record<string, string> = { ")": "(", "]": "[", "}": "{", ">": "<" };
const QUOTES = "\"'`";

/**
 * Trim what the sentence added, not what the path contains.
 *
 * `see src/main.ts.` and `(src/main.ts)` and `"src/main.ts",` all name the same
 * file. A closing bracket is only dropped when it is unbalanced, so a real
 * `logs[0].json` keeps its own.
 */
export function trimSurroundings(candidate: Candidate): Candidate {
  let { text, start } = candidate;
  for (;;) {
    let next = text;

    // Unwrap first. Trailing punctuation includes the quote characters, so
    // stripping that before this check would eat the closing half of a quoted
    // path and leave the opening one stranded.
    const head = next.slice(0, 1);
    const tail = next.slice(-1);
    const wrapped = CLOSERS[tail] === head || (head === tail && QUOTES.includes(head));
    if (next.length > 2 && wrapped) {
      next = next.slice(1, -1);
      start += 1;
      text = next;
      continue;
    }

    next = next.replace(TRAILING, "");

    // A closer with no opener to match it: "src/main.ts)". Only that one goes,
    // so a path that opened its own — "logs[0].json" — keeps it.
    const closer = next.slice(-1);
    const opener = CLOSERS[closer];
    if (opener) {
      const opens = next.split(opener).length - 1;
      const closes = next.split(closer).length - 1;
      if (closes > opens) next = next.slice(0, -1);
    }
    if (next === text) break;
    text = next;
  }
  return { text, start, end: start + text.length };
}

/**
 * Whether a token is worth asking the daemon about.
 *
 * Loose on shape and strict on cost. A wrong guess costs one entry in a batched
 * request that comes back `exists: false`, and the text stays plain. A guess
 * never made costs a link the user wanted.
 *
 * What is excluded is what would waste the round trip or mislead: a bare word
 * has no path shape, a URL belongs to the web-links addon, and a flag is an
 * argument rather than a file.
 */
export function looksLikePath(token: string): boolean {
  if (token.length < 2 || token.length > 4096) return false;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(token)) return false;
  if (token.startsWith("-")) return false;
  if (
    token.startsWith("/") ||
    token.startsWith("~/") ||
    token.startsWith("./") ||
    token.startsWith("../")
  ) {
    return true;
  }
  // Otherwise it must carry a separator or an extension to be worth a look.
  return token.includes("/") || /\.[A-Za-z0-9]{1,8}$/.test(token);
}

/**
 * Path-shaped runs in a line of terminal output.
 *
 * Whitespace-delimited, because a terminal has no other separator to go on, and
 * because that is already what the touch selection does when it grabs a path.
 * Anything surviving here is only a *candidate*: whether it names something real
 * is a question for the machine the shell runs on, never for a regex.
 */
export function pathCandidates(line: string): Candidate[] {
  const found: Candidate[] = [];
  const run = /\S+/g;
  let match: RegExpExecArray | null;
  while ((match = run.exec(line)) !== null) {
    const trimmed = trimSurroundings({
      text: match[0],
      start: match.index,
      end: match.index + match[0].length,
    });
    if (looksLikePath(trimmed.text)) found.push(trimmed);
  }
  return found;
}

/**
 * Whether a pane's paths can be resolved against the machine the daemon runs on.
 *
 * A shell inside `ssh` or a container reports its own cwd through OSC 7, and
 * kitterm honours it — right for the tab title, wrong for this. A relative path
 * would then be resolved locally, and `src/main.ts` may well exist here too, as
 * a different file. Absolute paths are no safer: `/etc/hosts` exists on both.
 *
 * So when the cwd arrived in-band, nothing on that pane is linked. A missing
 * link is a small loss; a link that opens the wrong machine's file is a lie.
 */
export function pathsAreLocal(cwdCameInBand: boolean): boolean {
  return !cwdCameInBand;
}
