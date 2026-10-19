/**
 * A unified diff of two texts, by line, for `compare` on the `/edit` page
 * (`corpus/02-approved-design.md` rule 8): the buffer against the disk,
 * shown in the editor area in the shape `git diff` prints, with three
 * lines of context around each change.
 *
 * Pure: two strings in, hunks out. The shortest edit script comes from
 * Myers' O(ND) algorithm on the line arrays, which is exact and fast for
 * the files the page can hold (the read cap is 256 KiB), and it needs no
 * library. A file's last newline ends its last line, as `sourceView` reads
 * it; a text with no trailing newline diffs the same lines.
 */

export type DiffLineKind = "context" | "add" | "del";

export interface DiffLine {
  kind: DiffLineKind;
  text: string;
  /** The line's number in the old text (a context or a `-` line). */
  oldNumber?: number;
  /** The line's number in the new text (a context or a `+` line). */
  newNumber?: number;
}

export interface DiffHunk {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  lines: DiffLine[];
}

export interface LineDiff {
  hunks: DiffHunk[];
  added: number;
  removed: number;
}

/** The lines of a text, the last newline ending the last line. */
export function splitLines(text: string): string[] {
  if (text === "") return [];
  const body = text.endsWith("\n") ? text.slice(0, -1) : text;
  return body.split("\n");
}

type Op = { kind: DiffLineKind; oldIndex: number; newIndex: number };

/**
 * Myers' shortest edit script over `a` and `b`, as a list of operations in
 * order: `context` keeps a line of both, `del` takes one of `a`, `add` one
 * of `b`.
 */
function editScript(a: string[], b: string[]): Op[] {
  const n = a.length;
  const m = b.length;
  const max = n + m;
  if (max === 0) return [];
  const offset = max;
  // v[k + offset] is the furthest x reached on diagonal k after d steps;
  // one copy per d is kept for the backtrack.
  let v = new Int32Array(2 * max + 2).fill(-1);
  v[offset + 1] = 0;
  const trace: Int32Array[] = [];
  let found = false;
  for (let d = 0; d <= max && !found; d += 1) {
    trace.push(v);
    const next = new Int32Array(v);
    for (let k = -d; k <= d; k += 2) {
      let x: number;
      if (k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1])) x = v[offset + k + 1];
      else x = v[offset + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) {
        x += 1;
        y += 1;
      }
      next[offset + k] = x;
      if (x >= n && y >= m) {
        found = true;
        break;
      }
    }
    v = next;
  }
  // Backtrack from (n, m) through the kept diagonals.
  const ops: Op[] = [];
  let x = n;
  let y = m;
  for (let d = trace.length - 1; d >= 0; d -= 1) {
    const prev = trace[d];
    const k = x - y;
    let prevK: number;
    if (k === -d || (k !== d && prev[offset + k - 1] < prev[offset + k + 1])) prevK = k + 1;
    else prevK = k - 1;
    const prevX = prev[offset + prevK];
    const prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      x -= 1;
      y -= 1;
      ops.push({ kind: "context", oldIndex: x, newIndex: y });
    }
    if (d > 0) {
      if (x === prevX) {
        y -= 1;
        ops.push({ kind: "add", oldIndex: x, newIndex: y });
      } else {
        x -= 1;
        ops.push({ kind: "del", oldIndex: x, newIndex: y });
      }
    }
  }
  ops.reverse();
  return ops;
}

/** The number of context lines kept around a change, as `git diff` keeps. */
export const CONTEXT_LINES = 3;

/**
 * The unified diff of `oldText` against `newText`: `-` lines are the old
 * text's, `+` lines the new text's. Equal texts give no hunk.
 */
export function lineDiff(oldText: string, newText: string, context: number = CONTEXT_LINES): LineDiff {
  const a = splitLines(oldText);
  const b = splitLines(newText);
  const ops = editScript(a, b);
  const hunks: DiffHunk[] = [];
  let added = 0;
  let removed = 0;

  // Group the operations into hunks: a change, its context on both sides,
  // and the next change when fewer than 2 × context equal lines separate
  // them.
  let i = 0;
  while (i < ops.length) {
    if (ops[i].kind === "context") {
      i += 1;
      continue;
    }
    const start = Math.max(0, i - context);
    let end = i;
    // Extend `end` past every change whose gap to the next is small.
    let last = i;
    while (end < ops.length) {
      if (ops[end].kind !== "context") {
        last = end;
        end += 1;
        continue;
      }
      // A run of context: stop when it is longer than 2 × context and no
      // change follows within it.
      let run = end;
      while (run < ops.length && ops[run].kind === "context") run += 1;
      if (run >= ops.length || run - end > 2 * context) break;
      end = run;
    }
    const stop = Math.min(ops.length, last + 1 + context);
    const lines: DiffLine[] = [];
    let oldStart = -1;
    let newStart = -1;
    let oldLines = 0;
    let newLines = 0;
    for (let j = start; j < stop; j += 1) {
      const op = ops[j];
      if (op.kind === "context") {
        if (oldStart < 0) oldStart = op.oldIndex;
        if (newStart < 0) newStart = op.newIndex;
        lines.push({ kind: "context", text: a[op.oldIndex], oldNumber: op.oldIndex + 1, newNumber: op.newIndex + 1 });
        oldLines += 1;
        newLines += 1;
      } else if (op.kind === "del") {
        if (oldStart < 0) oldStart = op.oldIndex;
        if (newStart < 0) newStart = op.newIndex;
        lines.push({ kind: "del", text: a[op.oldIndex], oldNumber: op.oldIndex + 1 });
        oldLines += 1;
        removed += 1;
      } else {
        if (oldStart < 0) oldStart = op.oldIndex;
        if (newStart < 0) newStart = op.newIndex;
        lines.push({ kind: "add", text: b[op.newIndex], newNumber: op.newIndex + 1 });
        newLines += 1;
        added += 1;
      }
    }
    hunks.push({
      // A hunk with no line on one side starts at the line before, as git
      // prints `@@ -0,0 +1,3 @@` for a file that was empty.
      oldStart: oldLines === 0 ? oldStart : oldStart + 1,
      oldLines,
      newStart: newLines === 0 ? newStart : newStart + 1,
      newLines,
      lines,
    });
    i = stop;
  }
  return { hunks, added, removed };
}

/** `@@ -64,6 +64,10 @@`, the hunk's own line. */
export function hunkHeader(hunk: DiffHunk): string {
  const range = (start: number, count: number): string => (count === 1 ? `${start}` : `${start},${count}`);
  return `@@ -${range(hunk.oldStart, hunk.oldLines)} +${range(hunk.newStart, hunk.newLines)} @@`;
}

/** `+21 −1`, the counts of a diff's top line; `+0 −0` for equal texts. */
export function diffCounts(diff: LineDiff): string {
  return `+${diff.added} −${diff.removed}`;
}
