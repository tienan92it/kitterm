/**
 * Pane command chords.
 *
 * The governing rule: **never match a chord a terminal application can
 * receive.** A pane is a real shell, so vim, readline, Emacs, and any tmux
 * running *inside* it must keep their keys. Concretely we only match when the
 * Command key is held (macOS sends nothing to the shell for it — `macOptionIsMeta`
 * maps Meta to Option, not Command), or when Ctrl+Shift are held together, which
 * has no distinct encoding in the traditional terminal scheme. That is the same
 * reasoning that already produced the ⌘F / Ctrl+Shift+F pairing for Find.
 *
 * Bare Ctrl+letter and bare Alt+letter must never match.
 *
 * Three chords are deliberately unbound because browsers reserve them and a page
 * cannot preventDefault them:
 *   ⌘W    closes the browser tab — closing a pane is `exit` or the × button
 *   ⌘⌥←/→ switch browser tabs in Chrome and Safari — only ↑/↓ are used
 *
 * Keeping this a pure table means retuning a binding after real-browser testing
 * is a one-line change plus a test update.
 */

import type { Direction, SplitDir } from "./pane-layout";

export type PaneCommand =
  | { type: "split"; dir: SplitDir }
  | { type: "navigate"; dir: Direction }
  | { type: "close" };

/** The subset of KeyboardEvent this module needs, so tests need no DOM. */
export type ChordEvent = Pick<
  KeyboardEvent,
  "key" | "metaKey" | "ctrlKey" | "shiftKey" | "altKey"
>;

const ARROW_DIRECTIONS: Record<string, Direction> = {
  ArrowUp: "up",
  ArrowDown: "down",
};

/**
 * Match a keyboard event to a pane command, or null to let it reach the shell.
 *
 * @param isMac when true, use the ⌘-based chords; otherwise Ctrl+Shift.
 */
export const matchPaneCommand = (event: ChordEvent, isMac: boolean): PaneCommand | null => {
  const key = event.key;

  if (isMac) {
    // Command is required for every macOS chord: without it we would be
    // stealing keys the shell needs.
    if (!event.metaKey || event.ctrlKey) return null;

    if (!event.altKey && (key === "d" || key === "D")) {
      // ⌘D splits side by side; ⌘⇧D stacks.
      return { type: "split", dir: event.shiftKey ? "column" : "row" };
    }
    if (event.altKey && !event.shiftKey) {
      const dir = ARROW_DIRECTIONS[key];
      if (dir) return { type: "navigate", dir };
      if (key === "w" || key === "W") return { type: "close" };
    }
    return null;
  }

  // Non-mac: Ctrl+Shift is the safe prefix.
  if (!event.ctrlKey || !event.shiftKey || event.metaKey) return null;

  if (!event.altKey) {
    if (key === "D" || key === "d") return { type: "split", dir: "row" };
    if (key === "E" || key === "e") return { type: "split", dir: "column" };
    const dir = ARROW_DIRECTIONS[key];
    if (dir) return { type: "navigate", dir };
  } else if (key === "W" || key === "w") {
    return { type: "close" };
  }
  return null;
};

export const isMacPlatform = (): boolean =>
  typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform);
