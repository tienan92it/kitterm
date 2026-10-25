/**
 * The pure parts of the `/edit` page's git tab (`code-editor` round 5,
 * phase 3 of ADR 0005; the frames `Editor 1200 git` and `Editor 390 git`
 * and rules 5, 7 and 9 of `Editor components`): the status answer of
 * `GET /api/git/status` as the page reads it, the badge of a changed file
 * and of a folder that holds one, the words of the `BRANCH` and `CHANGES`
 * sections and of the tab, which diff a change row asks for, and the
 * unified diff text of `GET /api/git/diff` as the `LineDiff` the round 4
 * diff view draws.
 *
 * Nothing here touches the DOM, the clock or the network; `edit.ts` paints
 * what this decides, and `edit-fetch.ts` talks to the daemon.
 */

import type { DiffHunk, DiffLine, LineDiff } from "./line-diff";
import { basename } from "./markdown-view";

// MARK: - The status

export type GitKind = "ordinary" | "renamed" | "copied" | "unmerged" | "untracked" | "ignored";

/** One changed file, as the daemon's parser read it from porcelain v2. */
export interface GitEntry {
  /** Relative to the repository's toplevel. */
  path: string;
  origPath?: string;
  /** The index column of `XY`; `.` for unchanged, `?` for untracked. */
  index: string;
  /** The worktree column of `XY`. */
  worktree: string;
  kind: GitKind;
  additions?: number;
  deletions?: number;
}

export interface GitCounts {
  changed: number;
  staged: number;
  unstaged: number;
  untracked: number;
  conflicts: number;
}

export interface GitStatus {
  /** The repository's toplevel, a real path. */
  root: string;
  branch: string | null;
  upstream: string | null;
  ahead: number;
  behind: number;
  detached: boolean;
  files: GitEntry[];
  counts: GitCounts;
  /** The local branches, by last commit (round 6). */
  branches?: string[];
  /** Whether the daemon takes the writes: `--agent-control` is on. */
  writes?: boolean;
  /** Paths `.gitignore` excludes, relative to `root`, a directory ending in
   * `/` and not listed again for what sits under it; never in `files` or
   * `counts` (round 13, rule 19). Set only when the body carries it, like
   * `branches` and `writes`, so a status from before it reads as before. */
  ignored?: string[];
  /** Set once a read held more than the daemon's cap. */
  ignoredTruncated?: boolean;
}

const KINDS: GitKind[] = ["ordinary", "renamed", "copied", "unmerged", "untracked", "ignored"];

const number = (value: unknown): number => (typeof value === "number" && Number.isFinite(value) ? value : 0);

/** The route's body as a `GitStatus`; a field the body lacks is its zero. */
export function parseStatus(body: unknown): GitStatus {
  const item = (body ?? {}) as Record<string, unknown>;
  const files: GitEntry[] = [];
  for (const raw of Array.isArray(item.files) ? item.files : []) {
    const entry = (raw ?? {}) as Record<string, unknown>;
    if (typeof entry.path !== "string") continue;
    const kind = KINDS.includes(entry.kind as GitKind) ? (entry.kind as GitKind) : "ordinary";
    const out: GitEntry = {
      path: entry.path,
      index: typeof entry.index === "string" ? entry.index : ".",
      worktree: typeof entry.worktree === "string" ? entry.worktree : ".",
      kind,
    };
    if (typeof entry.origPath === "string") out.origPath = entry.origPath;
    if (typeof entry.additions === "number") out.additions = entry.additions;
    if (typeof entry.deletions === "number") out.deletions = entry.deletions;
    files.push(out);
  }
  const counts = (item.counts ?? {}) as Record<string, unknown>;
  const status: GitStatus = {
    root: typeof item.root === "string" ? item.root : "",
    branch: typeof item.branch === "string" ? item.branch : null,
    upstream: typeof item.upstream === "string" ? item.upstream : null,
    ahead: number(item.ahead),
    behind: number(item.behind),
    detached: item.detached === true,
    files,
    counts: {
      changed: number(counts.changed),
      staged: number(counts.staged),
      unstaged: number(counts.unstaged),
      untracked: number(counts.untracked),
      conflicts: number(counts.conflicts),
    },
  };
  // The round 6 fields, set only when the body carries them, so a status
  // from before them reads as before.
  if (Array.isArray(item.branches)) status.branches = item.branches.filter((name): name is string => typeof name === "string");
  if (item.writes === true) status.writes = true;
  // The round 13 fields (rule 19): `ignored` is set whenever the body
  // carries the array, even an empty one, so a repository with nothing
  // ignored still reads as read rather than as a status from before it.
  if (Array.isArray(item.ignored)) status.ignored = item.ignored.filter((path): path is string => typeof path === "string");
  if (item.ignoredTruncated === true) status.ignoredTruncated = true;
  return status;
}

// MARK: - The badges (rule 5)

export type BadgeTone = "warning" | "success" | "danger" | "faint";

/** One letter in an owned colour: `M` warning, `A` success, `D` danger,
 * `?` faint for an untracked file, `R` for a rename or a copy, `U` for a
 * conflict. */
export interface Badge {
  letter: "M" | "A" | "D" | "R" | "U" | "?";
  tone: BadgeTone;
}

const LETTER_BADGES: Record<string, Badge> = {
  M: { letter: "M", tone: "warning" },
  T: { letter: "M", tone: "warning" },
  A: { letter: "A", tone: "success" },
  D: { letter: "D", tone: "danger" },
  R: { letter: "R", tone: "warning" },
  C: { letter: "R", tone: "warning" },
};

/** The badge of one entry: the index column when it holds a change, else
 * the worktree column; nothing for an ignored file. */
export function badgeOf(entry: GitEntry): Badge | null {
  switch (entry.kind) {
    case "ignored":
      return null;
    case "untracked":
      return { letter: "?", tone: "faint" };
    case "unmerged":
      return { letter: "U", tone: "danger" };
    case "renamed":
    case "copied":
      return { letter: "R", tone: "warning" };
    case "ordinary": {
      const letter = entry.index !== "." ? entry.index : entry.worktree;
      return LETTER_BADGES[letter] ?? { letter: "M", tone: "warning" };
    }
  }
}

/** The absolute path of an entry. */
export function entryPath(status: GitStatus, entry: GitEntry): string {
  return status.root === "/" ? `/${entry.path}` : `${status.root}/${entry.path}`;
}

/**
 * The badge a tree row wears: a file's own, and `M` on a folder that holds
 * a changed path (the folder rollup of rule 5); `null` on a clean row and
 * with no status.
 */
export function badgeForPath(status: GitStatus | null, path: string, dir: boolean): Badge | null {
  if (!status) return null;
  if (!dir) {
    const entry = status.files.find((file) => entryPath(status, file) === path);
    return entry ? badgeOf(entry) : null;
  }
  const prefix = path === "/" ? "/" : `${path}/`;
  const held = status.files.some((file) => file.kind !== "ignored" && entryPath(status, file).startsWith(prefix));
  return held ? { letter: "M", tone: "warning" } : null;
}

/**
 * Whether `path` (absolute, under `status.root`) is ignored or sits under
 * an ignored directory (rule 19 of `Editor components 2`, `design/editor.pen`): the
 * tree dims such a row — its triangle, tag and name in the faint grey —
 * and still lists it and its children.
 */
export function isIgnoredPath(status: GitStatus | null, path: string): boolean {
  if (!status?.ignored || status.ignored.length === 0) return false;
  const prefix = status.root === "/" ? "/" : `${status.root}/`;
  if (path !== status.root && !path.startsWith(prefix)) return false;
  const relative = path === status.root ? "" : path.slice(prefix.length);
  for (const entry of status.ignored) {
    const dir = entry.endsWith("/") ? entry.slice(0, -1) : entry;
    if (relative === dir || relative.startsWith(`${dir}/`)) return true;
  }
  return false;
}

// MARK: - The words (rule 7)

/** `CHANGES 3 · 2 staged`, the section's label. */
export function changesLabel(counts: GitCounts): string {
  return `CHANGES ${counts.changed} · ${counts.staged} staged`;
}

/** `[x] git 3`: the tab with the count of changed files, `[ ] git` before
 * the status is read. */
export function gitTabLabel(checked: boolean, counts: GitCounts | null): string {
  const box = checked ? "[x]" : "[ ]";
  return counts ? `${box} git ${counts.changed}` : `${box} git`;
}

/** The `BRANCH` row: the name (`HEAD` when detached), `↑1 ↓0` against
 * the upstream or `no upstream`, and whether the head is detached. */
export function branchLine(status: GitStatus): { name: string; ab: string; detached: boolean } {
  return {
    name: status.branch ?? "HEAD",
    ab: status.upstream ? `↑${status.ahead} ↓${status.behind}` : "no upstream",
    detached: status.detached,
  };
}

/** `+21 −1` for a change row: a count prints when it is above zero, both
 * print as `+0` when neither is, and a dash stands for counts the daemon
 * could not give (a binary file). */
export function entryCounts(entry: GitEntry): string {
  if (entry.additions === undefined || entry.deletions === undefined) return "–";
  const parts: string[] = [];
  if (entry.additions > 0) parts.push(`+${entry.additions}`);
  if (entry.deletions > 0) parts.push(`−${entry.deletions}`);
  return parts.length ? parts.join(" ") : "+0";
}

/** The row's name: the file's name, with `old → new` for a rename. */
export function entryName(entry: GitEntry): string {
  if (entry.origPath && entry.origPath !== entry.path) return `${basename(entry.origPath)} → ${basename(entry.path)}`;
  return basename(entry.path);
}

/** Whether a change row asks for the index's diff (`staged=1`): the file
 * has a staged change and no working-tree change. */
export function wantsStaged(entry: GitEntry): boolean {
  return entry.kind !== "untracked" && entry.kind !== "unmerged" && entry.index !== "." && entry.worktree === ".";
}

/**
 * What the diff compares, after the counts on the diff view's top line:
 * `working tree against HEAD` when the file has no staged change (then the
 * index equals `HEAD` for it), `index against HEAD` for a staged-only
 * file, `working tree against index` when both sides changed, and
 * `untracked, all added`.
 */
export function diffWhat(entry: GitEntry, staged: boolean): string {
  if (entry.kind === "untracked") return "untracked, all added";
  if (staged) return "index against HEAD";
  if (entry.index === "." || entry.kind === "unmerged") return "working tree against HEAD";
  return "working tree against index";
}

// MARK: - The unified diff (rule 9)

const HUNK = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

/**
 * The text `git diff` printed as the hunks the diff view draws: the lines
 * before the first `@@` (the `diff --git`, `index`, `---` and `+++`
 * lines) are not shown, a `\ No newline at end of file` line is kept as a
 * note, and a hunk's numbers come from its own header.
 */
export function parseUnifiedDiff(text: string): LineDiff {
  const hunks: DiffHunk[] = [];
  let added = 0;
  let removed = 0;
  let hunk: DiffHunk | null = null;
  let oldAt = 0;
  let newAt = 0;
  const lines = text.endsWith("\n") ? text.slice(0, -1).split("\n") : text.split("\n");
  for (const line of lines) {
    const header = HUNK.exec(line);
    if (header) {
      hunk = {
        oldStart: Number(header[1]),
        oldLines: header[2] === undefined ? 1 : Number(header[2]),
        newStart: Number(header[3]),
        newLines: header[4] === undefined ? 1 : Number(header[4]),
        lines: [],
      };
      hunks.push(hunk);
      oldAt = hunk.oldStart;
      newAt = hunk.newStart;
      continue;
    }
    if (!hunk) continue;
    const mark = line[0];
    const body = line.slice(1);
    let out: DiffLine;
    if (mark === "+") {
      out = { kind: "add", text: body, newNumber: newAt };
      newAt += 1;
      added += 1;
    } else if (mark === "-") {
      out = { kind: "del", text: body, oldNumber: oldAt };
      oldAt += 1;
      removed += 1;
    } else if (mark === "\\") {
      out = { kind: "note", text: line };
    } else {
      out = { kind: "context", text: body, oldNumber: oldAt, newNumber: newAt };
      oldAt += 1;
      newAt += 1;
    }
    hunk.lines.push(out);
  }
  return { hunks, added, removed };
}

// MARK: - The writes (round 6; rules 8, 13 and 14)

/** `[x]` staged, `[ ]` unstaged, `[~]` partly staged (both columns hold a
 * change), the state a change row's toggle shows. */
export type StageState = "staged" | "unstaged" | "partial";

/** The stage state of one entry: an untracked or a conflicted file is
 * unstaged, a file with no index change is unstaged, one with no
 * working-tree change is staged, and one changed on both sides is
 * partial. */
export function stageState(entry: GitEntry): StageState {
  if (entry.kind === "untracked" || entry.kind === "unmerged" || entry.kind === "ignored") return "unstaged";
  if (entry.index === ".") return "unstaged";
  if (entry.worktree === ".") return "staged";
  return "partial";
}

/** The toggle's three glyphs. */
export function stageToggle(state: StageState): string {
  return state === "staged" ? "[x]" : state === "partial" ? "[~]" : "[ ]";
}

/** What a tap on the toggle does: a staged file is unstaged, every other
 * state stages the whole file (a partial one becomes staged, rule 8). */
export function toggleWrite(entry: GitEntry): "stage" | "unstage" {
  return stageState(entry) === "staged" ? "unstage" : "stage";
}

/** `[ commit ]` answers when something is staged and the message holds a
 * word; faint otherwise (rule 7). */
export function commitEnabled(message: string, counts: GitCounts | null): boolean {
  return (counts?.staged ?? 0) > 0 && message.trim() !== "";
}

/** `[ push ]`, with `↑N` inside it while the branch is ahead of its
 * upstream. */
export function pushLabel(status: GitStatus | null): string {
  return status && status.ahead > 0 ? `[ push ↑${status.ahead} ]` : "[ push ]";
}

export type WriteKind = "stage" | "unstage" | "commit" | "push" | "branch";

/** The turning mark and the word a button becomes while its command runs
 * (rule 14): `◐ committing`, `◐ pushing`. */
export function inFlightWord(kind: "commit" | "push"): { mark: string; word: string } {
  return { mark: "◐", word: kind === "commit" ? "committing" : "pushing" };
}

/** The choice that opens the name question in the branch switcher. */
export const NEW_BRANCH = "new branch…";

/** The switcher's options: every local branch (the current one first, so
 * a list the daemon could not give still names it) then `new branch…`. */
export function branchOptions(status: GitStatus): { value: string; label: string; current: boolean }[] {
  const current = status.branch;
  const names = [...(status.branches ?? [])];
  if (current !== null && !names.includes(current)) names.unshift(current);
  const options = names.map((name) => ({ value: name, label: name, current: name === current }));
  options.push({ value: NEW_BRANCH, label: NEW_BRANCH, current: false });
  return options;
}

/** The question before a switch while the buffer holds unsaved edits. The
 * edits stay in the buffer; the file under them may change. */
export const SWITCH_QUESTION = "You have unsaved edits. Switch the branch anyway?";

/** The question `new branch…` asks. */
export const NEW_BRANCH_QUESTION = "Name of the new branch:";

/** The one sentence under the git panel when the daemon takes no write. */
export const NO_WRITES = "Commit, push and branch need the daemon started with --agent-control; use lazygit in a pane.";

/** The last `keep` lines of what a command printed, for the well
 * (rule 14: at most the last 8). */
export function wellLines(lines: readonly string[], keep = 8): string[] {
  return lines.slice(Math.max(0, lines.length - keep));
}
