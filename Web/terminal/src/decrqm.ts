/**
 * DECRQM: a program asks which modes the terminal has set.
 *
 * `CSI ? Ps $ p` asks about a private mode and `CSI Ps $ p` about an ANSI
 * one; the terminal answers `CSI ? Ps ; Pm $ y` (`CSI Ps ; Pm $ y`), where
 * `Pm` is 0 for a mode it does not know, 1 set, 2 reset, 3 always set, 4
 * always reset. lazygit asks about 2048, 1000, 1006 and 9001 before it
 * draws; neovim and other programs ask about 2026.
 *
 * xterm.js 6.0.0 answers these itself, and its build throws
 * `ReferenceError: i is not defined` on the first one, which ends the
 * parser's write loop: the pane freezes on the last frame before the query
 * (measured 2026-10-18 with `printf '\e[?1000$p'` on this build and on
 * main's). The pane therefore answers DECRQM from here, with the state the
 * public API shows, and returns true so xterm's handler never runs.
 */

/** What the pane knows of the terminal's modes, from `Terminal.modes`, the
 * active buffer and the pane's own tracking. */
export interface KnownModes {
  applicationCursorKeys: boolean;
  applicationKeypad: boolean;
  bracketedPaste: boolean;
  insert: boolean;
  mouseTracking: "none" | "x10" | "vt200" | "drag" | "any";
  origin: boolean;
  reverseWraparound: boolean;
  sendFocus: boolean;
  wraparound: boolean;
  /** The alternate buffer is active (modes 47, 1047, 1049). */
  alternateScreen: boolean;
  /** SGR mouse reports were asked for (`CSI ? 1006 h`). */
  sgrMouse: boolean;
  cursorBlink: boolean;
}

export const enum ModeState {
  NotRecognized = 0,
  Set = 1,
  Reset = 2,
  PermanentlySet = 3,
  PermanentlyReset = 4,
}

const flag = (value: boolean): ModeState => (value ? ModeState.Set : ModeState.Reset);

/** The state of a private mode (`CSI ? Ps $ p`), by xterm.js's own table
 * where the public API shows the answer, else "not recognized". */
export function privateModeState(mode: number, known: KnownModes): ModeState {
  switch (mode) {
    case 1:
      return flag(known.applicationCursorKeys);
    case 6:
      return flag(known.origin);
    case 7:
      return flag(known.wraparound);
    case 8:
      return ModeState.PermanentlySet;
    case 9:
      return flag(known.mouseTracking === "x10");
    case 12:
      return flag(known.cursorBlink);
    case 45:
      return flag(known.reverseWraparound);
    case 66:
      return flag(known.applicationKeypad);
    case 67:
      return ModeState.PermanentlyReset;
    case 1000:
      return flag(known.mouseTracking === "vt200");
    case 1002:
      return flag(known.mouseTracking === "drag");
    case 1003:
      return flag(known.mouseTracking === "any");
    case 1004:
      return flag(known.sendFocus);
    case 1005:
    case 1015:
      return ModeState.PermanentlyReset;
    case 1006:
      return flag(known.sgrMouse);
    case 1048:
      return ModeState.Set;
    case 47:
    case 1047:
    case 1049:
      return flag(known.alternateScreen);
    case 2004:
      return flag(known.bracketedPaste);
    default:
      return ModeState.NotRecognized;
  }
}

/** The state of an ANSI mode (`CSI Ps $ p`). */
export function ansiModeState(mode: number, known: KnownModes): ModeState {
  switch (mode) {
    case 2:
      return ModeState.PermanentlyReset;
    case 4:
      return flag(known.insert);
    case 12:
      return ModeState.PermanentlySet;
    default:
      return ModeState.NotRecognized;
  }
}

/** The DECRPM reply for one query. `params` is what the parser handed the
 * handler; only the first number is the mode, a missing one asks about 0. */
export function decrqmReply(
  params: readonly (number | number[])[],
  isPrivate: boolean,
  known: KnownModes,
): string {
  const first = params[0];
  const mode = typeof first === "number" ? first : Array.isArray(first) ? (first[0] ?? 0) : 0;
  const state = isPrivate ? privateModeState(mode, known) : ansiModeState(mode, known);
  return `\x1b[${isPrivate ? "?" : ""}${mode};${state}$y`;
}
