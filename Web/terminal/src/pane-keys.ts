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
  | { type: "close" }
  | { type: "new-tab" }
  | { type: "browse-files" }
  | { type: "show-help" };

/** The subset of KeyboardEvent this module needs, so tests need no DOM. */
export type ChordEvent = Pick<
  KeyboardEvent,
  "key" | "metaKey" | "ctrlKey" | "shiftKey" | "altKey"
> & { code?: string };

/**
 * The letter a chord is about, independent of what Option did to it.
 *
 * Holding Option on macOS composes an alternate character, so ⌘⌥O arrives as
 * "ø" and ⌘⌥T as "†". Matching `key` therefore misses every Option chord on a
 * real keyboard. `code` describes the physical key and is unaffected; `key` is
 * the fallback for events that carry no code.
 */
const chordLetter = (event: ChordEvent): string => {
  const code = event.code;
  if (code && code.length === 4 && code.startsWith("Key")) return code[3].toLowerCase();
  return event.key.toLowerCase();
};

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
    // ⌘/ — the shortcut list. Bare `?` would be the obvious key and is what
    // every other app uses, but here it is a character the shell must receive.
    if (!event.altKey && key === "/") return { type: "show-help" };
    if (event.altKey && !event.shiftKey) {
      const dir = ARROW_DIRECTIONS[key];
      if (dir) return { type: "navigate", dir };
      const letter = chordLetter(event);
      if (letter === "w") return { type: "close" };
      // ⌘⌥T — ⌘T and ⌘⇧T are browser-reserved and not interceptable.
      if (letter === "t") return { type: "new-tab" };
      // ⌘⌥O — "open", for picking a file or folder to hand to what is running.
      if (letter === "o") return { type: "browse-files" };
    }
    return null;
  }

  // Non-mac: Ctrl+Shift is the safe prefix.
  if (!event.ctrlKey || !event.shiftKey || event.metaKey) return null;

  if (!event.altKey) {
    if (key === "D" || key === "d") return { type: "split", dir: "row" };
    if (key === "E" || key === "e") return { type: "split", dir: "column" };
    // Ctrl+Shift+/ — with Shift held this arrives as "?" on most layouts and
    // "/" on some, so accept both rather than depend on the keycap.
    if (key === "/" || key === "?") return { type: "show-help" };
    const dir = ARROW_DIRECTIONS[key];
    if (dir) return { type: "navigate", dir };
  } else {
    if (chordLetter(event) === "w") return { type: "close" };
    // Ctrl+Shift+Alt+T — Ctrl+Shift+T is reopen-closed-tab, reserved.
    if (chordLetter(event) === "t") return { type: "new-tab" };
    // Ctrl+Shift+Alt+O — "open", matching the mac chord.
    if (chordLetter(event) === "o") return { type: "browse-files" };
  }
  return null;
};

export const isMacPlatform = (): boolean =>
  typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform);
