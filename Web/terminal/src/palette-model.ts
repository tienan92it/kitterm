/**
 * The pure parts of the `/edit` page's quick-open palette (`code-editor`
 * round 14, rule 8 of `corpus/07-projects-and-tree.md`, rule 25 of `Editor
 * components 2`, `design/editor.pen`): the groups ⌘P paints, built from the
 * file index `GET /api/files/index` answers and the project list `edit.ts`
 * already holds for the home page and the switcher.
 *
 * Nothing here touches the DOM, the clock or the network; `edit.ts` paints
 * what this decides, and `edit-fetch.ts` talks to the daemon.
 */

import { type FileTag, tagFor } from "./edit-tags";
import { editUrl, type ProjectCheckout, type ProjectEntry, type ProjectLine, projectLine } from "./edit-model";
import { type MatchResult, matchPath, fuzzyMatch, highlightRuns, type NameRun, splitPath } from "./palette-match";

export const PALETTE_PLACEHOLDER = "file name or project";
export const PALETTE_KEYS = "↑ ↓ choose · Enter opens · Esc closes";
export const PALETTE_EMPTY = "No file or project matches.";
export const PALETTE_MAX_FILES = 8;

/** One file row: the type tag, the name split into matched and plain runs
 * (rule 25: the matched letters at weight 600, underlined — never the
 * directory, which stays plain), and the directory in the faint grey.
 * `path` is the file's absolute path (the repository's root joined with
 * the index's relative one), what `/edit?path=` opens. */
export interface PaletteFileRow {
  kind: "file";
  path: string;
  tag: FileTag | null;
  runs: NameRun[];
  directory: string;
}

/** The repository's root joined with a path the index gave relative to it
 * (the same join `edit.ts`'s `entryPathOf` makes for a git change row). */
export function absolutePath(root: string, relative: string): string {
  return root === "/" ? `/${relative}` : `${root}/${relative}`;
}

/** One project row: the home line without the radio (rule 25) — the same
 * `ProjectLine` the home page and the switcher paint. */
export interface PaletteProjectRow {
  kind: "project";
  line: ProjectLine;
}

export type PaletteRow = PaletteFileRow | PaletteProjectRow;

export interface PaletteGroups {
  /** At most `PALETTE_MAX_FILES`, best match first; empty with no
   * repository or no match. */
  files: PaletteFileRow[];
  /** Every file the query matched, for the `FILES N` label and the fold
   * line; `0` with no repository, whatever the query. */
  fileCount: number;
  /** Every project the query matched, best match first; no cap. */
  projects: PaletteProjectRow[];
  /** `fileCount === 0 && projects.length === 0`: the empty sentence
   * replaces both groups. */
  empty: boolean;
}

interface Scored<T> {
  entry: T;
  match: MatchResult;
}

/** `entries` whose `match` finds something, best score first, ties broken
 * by `tiebreak` so the order is deterministic (an empty query scores every
 * entry `0`, so the tiebreak alone orders them). */
function matchAll<T>(entries: readonly T[], match: (entry: T) => MatchResult | null, tiebreak: (a: T, b: T) => number): Scored<T>[] {
  const scored: Scored<T>[] = [];
  for (const entry of entries) {
    const result = match(entry);
    if (result) scored.push({ entry, match: result });
  }
  scored.sort((a, b) => b.match.score - a.match.score || tiebreak(a.entry, b.entry));
  return scored;
}

function fileRow(root: string, relative: string, match: MatchResult): PaletteFileRow {
  const { name, directory } = splitPath(relative);
  const offset = directory === "" ? 0 : directory.length + 1;
  return { kind: "file", path: absolutePath(root, relative), tag: tagFor(name), runs: highlightRuns(name, match.positions, offset), directory };
}

/**
 * The matches for `query` (rule 25): a file's whole relative path is what
 * the matcher scores (so a directory segment can narrow the search and the
 * base-name bonus still favours a match in the file's own name), but only
 * the letters inside the base name are ever painted — the directory stays
 * plain, faint text. A project matches on its name alone, "the same way"
 * `corpus/07-projects-and-tree.md` rule 8 asks for files. `index` is `null`
 * with no repository (the home page's rule 1, carried into the palette by
 * the round 14 brief's "with no repository, the palette lists projects
 * alone"): no `FILES` group then, whatever the query, which is what makes
 * `fileCount` `0` without a special case.
 */
export function paletteGroups(
  index: { root: string; files: readonly string[] } | null,
  projects: readonly ProjectEntry[],
  statuses: ReadonlyMap<string, ProjectCheckout>,
  query: string,
): PaletteGroups {
  const fileMatches = matchAll(index?.files ?? [], (path) => matchPath(query, path), (a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const projectMatches = matchAll(projects, (project) => fuzzyMatch(query, project.name), (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  const root = index?.root ?? "";
  const files = fileMatches.slice(0, PALETTE_MAX_FILES).map(({ entry, match }) => fileRow(root, entry, match));
  const projectRows: PaletteProjectRow[] = projectMatches.map(({ entry }) => ({ kind: "project", line: projectLine(entry, statuses.get(entry.root)) }));
  return {
    files,
    fileCount: fileMatches.length,
    projects: projectRows,
    empty: fileMatches.length === 0 && projectMatches.length === 0,
  };
}

/** `N more files: type more of the name`, `null` while every match already
 * shows (rule 25). */
export function moreFilesLine(fileCount: number): string | null {
  const more = fileCount - PALETTE_MAX_FILES;
  return more > 0 ? `${more} more files: type more of the name` : null;
}

/** The flat, selectable order a row lives at: every file row, then every
 * project row, for `↑` `↓` (rule 25). */
export function paletteRows(groups: PaletteGroups): PaletteRow[] {
  return [...groups.files, ...groups.projects];
}

/** The next selected index for `↑` or `↓`, clamped to the row list (no
 * wrap); `-1` with no row. */
export function movePaletteSelection(count: number, selected: number, direction: "up" | "down"): number {
  if (count === 0) return -1;
  const at = selected < 0 ? (direction === "down" ? -1 : count) : selected;
  const next = direction === "down" ? at + 1 : at - 1;
  return Math.min(Math.max(next, 0), count - 1);
}

/** Where `Enter` or a click on a row opens: a file's own `/edit` URL, or a
 * project's root. */
export function paletteRowUrl(row: PaletteRow, session: string | null): string {
  return row.kind === "file" ? editUrl(row.path, session) : editUrl(row.line.root);
}
