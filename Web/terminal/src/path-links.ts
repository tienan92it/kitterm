/**
 * Paths in output, made openable.
 *
 * The hard part is not finding path-shaped text — `links.ts` does that — but
 * knowing whether a candidate names anything, in time to be useful.
 *
 * xterm asks a provider for links when the mouse moves over a row, and acts on
 * them at the following mouse-up. A tap on a phone produces that pair within a
 * few milliseconds, so a provider that goes to the daemon before answering has
 * already missed the gesture. Resolving on hover works on a desktop and never
 * works on a touchscreen, which is the case this feature is for.
 *
 * So confirmation runs ahead of the pointer. Every render reports the rows it
 * drew; those rows are scanned, their candidates confirmed in one batched call,
 * and the answers cached. `provideLinks` then reads the cache and answers
 * synchronously — the same code path serving a mouse and a finger.
 *
 * The cache is keyed by the pane's cwd as well as the token, because
 * `src/main.ts` names a different file after a `cd`.
 *
 * Nothing here asks whether the shell is local. The daemon stats on its own
 * machine, so a shell inside ssh or a container simply produces paths that are
 * not found, and the text stays plain. Gating on "the cwd arrived in-band"
 * would have been wrong twice over: kitterm's own shell integration emits OSC 7
 * on every prompt, so it would disable the feature for the people who installed
 * it — and AGENTS.md records that an earlier gate of that shape was removed as
 * harmful. What remains is a path that exists on both machines, which links to
 * the local one; that is worth revisiting if it ever bites.
 */

import type { IBufferRange, ILink, ILinkProvider, Terminal } from "@xterm/xterm";

import { pathCandidates, type Candidate } from "./links";

/** What the daemon says about one path. */
export interface PathStat {
  exists: boolean;
  dir: boolean;
  resolved: string;
}

/** Asks the daemon about several paths at once. */
export type StatBatch = (paths: readonly string[]) => Promise<Map<string, PathStat>>;

/**
 * Answers about paths, remembered for as long as they can be trusted.
 *
 * Absent paths are remembered too. Output repeats itself — a build log names
 * the same missing file on every line — and without a negative entry each
 * render would ask again.
 */
export class StatCache {
  private entries = new Map<string, PathStat>();
  private context = "";

  /** Point the cache at a directory. A different one empties it, because the
   * same relative path now means a different file. */
  setContext(cwd: string | null): void {
    const next = cwd ?? "";
    if (next === this.context) return;
    this.context = next;
    this.entries.clear();
  }

  get(token: string): PathStat | undefined {
    return this.entries.get(token);
  }

  has(token: string): boolean {
    return this.entries.has(token);
  }

  set(token: string, stat: PathStat): void {
    this.entries.set(token, stat);
  }

  /** Which of these have never been asked about. */
  unknown(tokens: readonly string[]): string[] {
    const out: string[] = [];
    for (const token of tokens) {
      if (!this.entries.has(token) && !out.includes(token)) out.push(token);
    }
    return out;
  }

  get size(): number {
    return this.entries.size;
  }
}

/**
 * The buffer range for a candidate on one row, in xterm's coordinates.
 *
 * xterm counts from 1 and includes both ends; a candidate counts from 0 and
 * excludes its end. Getting this wrong underlines the wrong characters, which
 * is invisible in a unit test of the detection alone.
 */
export function rangeFor(candidate: Candidate, bufferRow: number): IBufferRange {
  return {
    start: { x: candidate.start + 1, y: bufferRow + 1 },
    end: { x: candidate.end, y: bufferRow + 1 },
  };
}

export interface PathLinkOptions {
  /** Ask the daemon about a batch of paths. */
  stat: StatBatch;
  /** A confirmed path was clicked. */
  onOpen: (stat: PathStat, text: string) => void;
  /** The pane's current directory, for cache keying. */
  cwd: () => string | null;
}

/**
 * Registers the provider and keeps its cache fed from what is on screen.
 */
export class PathLinks {
  private readonly cache = new StatCache();
  private readonly disposables: { dispose(): void }[] = [];
  private pending = false;

  constructor(
    private readonly terminal: Terminal,
    private readonly options: PathLinkOptions,
  ) {
    this.disposables.push(
      terminal.onRender(({ start, end }) => {
        void this.confirmRows(start, end);
      }),
    );
    this.disposables.push(terminal.registerLinkProvider(this.provider()));
  }

  dispose(): void {
    for (const item of this.disposables) item.dispose();
    this.disposables.length = 0;
  }

  /**
   * Confirm what the last render put on screen.
   *
   * One request per render at most. Renders arrive in bursts while output
   * streams, and a request per burst would multiply one screen of text into
   * dozens of round trips; the next render re-scans anyway, so a skipped one
   * costs nothing.
   */
  private async confirmRows(start: number, end: number): Promise<void> {
    if (this.pending) return;
    this.cache.setContext(this.options.cwd());

    const tokens: string[] = [];
    for (let row = start; row <= end; row += 1) {
      for (const candidate of this.candidatesOn(this.bufferRow(row))) {
        tokens.push(candidate.text);
      }
    }
    const unknown = this.cache.unknown(tokens);
    if (unknown.length === 0) return;

    this.pending = true;
    try {
      const answers = await this.options.stat(unknown);
      for (const token of unknown) {
        // Absent answers are cached as "no", so repeated output asks once.
        this.cache.set(token, answers.get(token) ?? { exists: false, dir: false, resolved: "" });
      }
    } catch {
      // The daemon is unreachable or the pane lost its session. Leave the cache
      // alone: the text stays plain, and the next render asks again.
    } finally {
      this.pending = false;
    }
  }

  /** Viewport row to absolute buffer row. */
  private bufferRow(viewportRow: number): number {
    return this.terminal.buffer.active.viewportY + viewportRow;
  }

  /**
   * Candidates on one buffer row.
   *
   * A single row: a path that wrapped across two is not linked. Reassembling
   * wrapped rows is what xterm's own URL provider does, and it is worth doing
   * later — but a wrong reassembly links the wrong text, and the failure here
   * is only a missing link.
   */
  private candidatesOn(bufferRow: number): Candidate[] {
    const line = this.terminal.buffer.active.getLine(bufferRow);
    if (!line || line.isWrapped) return [];
    return pathCandidates(line.translateToString(true));
  }

  private provider(): ILinkProvider {
    return {
      provideLinks: (bufferLineNumber, callback) => {
        // xterm counts rows from 1.
        const row = bufferLineNumber - 1;
        const links: ILink[] = [];
        for (const candidate of this.candidatesOn(row)) {
          const stat = this.cache.get(candidate.text);
          if (!stat?.exists) continue;
          links.push({
            range: rangeFor(candidate, row),
            text: candidate.text,
            activate: (event) => {
              event.preventDefault();
              this.options.onOpen(stat, candidate.text);
            },
          });
        }
        callback(links.length > 0 ? links : undefined);
      },
    };
  }
}
