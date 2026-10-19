/**
 * The editor and lazygit in the pane's own shell.
 *
 * kitterm runs no editor of its own. "Open in editor" on a path link and the
 * editor layout each open a split and type one command line into its shell,
 * the way a person would: `$EDITOR`, else `micro`, else `vi`, and `lazygit`.
 * The line is visible, echoed, and in the pane's history, so what kitterm
 * did is never a secret, and a program that is missing is named by the shell
 * and by the hint the line prints.
 *
 * Everything here is pure text, so the quoting and the decisions are tested
 * without a shell. The lines are POSIX `sh` syntax, which zsh and bash share;
 * fish prints a syntax error, which is loud rather than wrong.
 */

import type { SplitDir } from "./pane-layout";

/** A path token from the output, less the `:line` or `:line:col` a compiler
 * or a linter appends. */
export interface PathAtLine {
  path: string;
  line?: number;
  column?: number;
}

/**
 * Split `src/a.ts:12:3` into the file and the position. The file is what the
 * daemon is asked about, because `src/a.ts:12:3` names nothing on disk. A
 * token with no digits after a colon is the whole path.
 */
export function splitLineSuffix(text: string): PathAtLine {
  const match = /^(.+?):(\d+)(?::(\d+))?$/.exec(text);
  if (!match) return { path: text };
  const line = Number.parseInt(match[2], 10);
  if (!Number.isSafeInteger(line) || line < 1) return { path: text };
  const result: PathAtLine = { path: match[1], line };
  if (match[3] !== undefined) {
    const column = Number.parseInt(match[3], 10);
    if (Number.isSafeInteger(column) && column >= 1) result.column = column;
  }
  return result;
}

/** The programs the lines check for, and the one hint printed for each. */
export type HintedProgram = "micro" | "lazygit";

/**
 * One line for the pane when a program is missing. macOS gets the Homebrew
 * command; Linux has one package name across apt, dnf and pacman for micro,
 * and lazygit's own page for the rest. The shell runs on the daemon's machine,
 * which the page does not know, so the one line names both.
 */
export function installHint(program: HintedProgram): string {
  const linux =
    program === "micro"
      ? "micro from apt, dnf or pacman (Linux)"
      : "github.com/jesseduffield/lazygit#installation (Linux)";
  return `kitterm: ${program} is not installed. brew install ${program} (macOS); ${linux}`;
}

/**
 * `text` as one argument inside a double-quoted `eval` string.
 *
 * `$EDITOR` can be more than one word (`emacs -nw`, `code --wait`), and only
 * `eval` splits it the same way in zsh and bash. The path then travels inside
 * the string `eval` reads, so it is quoted twice: single quotes for `eval`,
 * and a backslash on every character the outer double quotes would read
 * first (`\`, `$`, a backtick and `"`). A `'` closes the single quotes, is
 * written as `\'`, and opens them again; the outer double quotes leave `\'`
 * as it is.
 */
export function evalArgument(text: string): string {
  const inner = text.replace(/[\\$`"]/g, (char) => `\\${char}`);
  return `'${inner.replace(/'/g, `'\\''`)}'`;
}

/** The editor's first word, for `command -v`; `${e%% *}` in the shell. */
const EDITOR_FIRST_WORD = '"${e%% *}"';

/** Resolve the editor and print the hint when it is missing, falling back to
 * `vi`, which every POSIX system ships. The caller appends what to run. */
const resolveEditor = (): string =>
  `e=\${EDITOR:-micro}; command -v ${EDITOR_FIRST_WORD} >/dev/null 2>&1 || ` +
  `{ echo ${evalArgument(installHint("micro"))}; e=vi; }`;

/**
 * The line that opens `target` in the editor. A file opens at its line when
 * the link carried one (`+12` is what micro, vim, vi, nano and helix take;
 * the column is not carried, because `vi` and `nano` refuse it). The current
 * directory opens as `.` — helix's picker, vim's listing — except in micro,
 * which refuses a directory outright and opens empty instead.
 */
export function editorCommand(target: PathAtLine | { cwd: true }): string {
  if ("cwd" in target) {
    return `${resolveEditor()}; case ${EDITOR_FIRST_WORD} in micro) eval "$e";; *) eval "$e .";; esac`;
  }
  const at = target.line !== undefined ? ` +${target.line}` : "";
  return `${resolveEditor()}; eval "$e${at} ${evalArgument(target.path)}"`;
}

/** The line that starts lazygit, or prints why it cannot. */
export function lazygitCommand(): string {
  return (
    `if command -v lazygit >/dev/null 2>&1; then lazygit; ` +
    `else echo ${evalArgument(installHint("lazygit"))}; fi`
  );
}

/** One split of the layout preset: where the new pane goes, how much of the
 * old pane's box it leaves to the old pane, and what it types. */
export interface PresetSplit {
  dir: SplitDir;
  /** The fraction kept by the pane that was split. */
  ratio: number;
  command: string;
}

/**
 * The editor layout: the focused pane keeps its shell, the editor takes the
 * right-hand two thirds, and lazygit sits under the shell. Both splits are
 * made from the focused pane, in this order.
 */
export function editorLayoutPlan(): PresetSplit[] {
  return [
    { dir: "row", ratio: 0.38, command: editorCommand({ cwd: true }) },
    { dir: "column", ratio: 0.5, command: lazygitCommand() },
  ];
}
