/**
 * Who decides whether the software keyboard is up.
 *
 * The answer is: the toolbar key, and nothing else. Before this, focus decided
 * — a focused field summons the keyboard on a phone, so every tap on the
 * terminal brought it back. Putting it away to read a log lasted until the next
 * tap on the log.
 *
 * The mechanism is `inputmode`. A field with `inputmode="none"` takes focus,
 * takes hardware keys, and raises no keyboard, so a pane can be focused and
 * quiet at the same time. That splits two things focus used to conflate: *this
 * pane receives what you type*, and *the keyboard is on screen*.
 *
 * The intent kept here is not "is the keyboard up" — the viewport still answers
 * that, in `keyboard-insets.ts`. It is "does the user want it up", which no
 * measurement can supply. The two meet in one place: when the viewport reports
 * a keyboard we asked for and then watched go away, the user dismissed it
 * somewhere we do not control — iOS builds its own dismiss key above the
 * keyboard and gives no way to refuse it — and the intent follows.
 */

/** What the user last asked for. */
export type KeyboardIntent = "shown" | "hidden";

export interface KeyboardState {
  intent: KeyboardIntent;
  /**
   * Whether a keyboard we asked for has actually been seen on screen.
   *
   * A keyboard takes a few hundred milliseconds to slide up, and the viewport
   * reads "closed" for all of it. Without this, the first inset report after a
   * tap on "show" would look exactly like a dismissal and undo the tap.
   */
  seenOpen: boolean;
}

/**
 * Where a session starts.
 *
 * A phone starts hidden. Not a preference — it is what "the toolbar key
 * decides" means. Starting shown would leave `inputmode="text"` on the field,
 * so the first tap anywhere in the output would raise the keyboard, and the
 * first tap is a tap like any other. It also suits the case: a terminal opened
 * on a phone is usually opened to read something, and typing is one key away.
 *
 * Anything with a real keyboard starts shown, because `inputmode` has nothing
 * to say there and there is no toolbar key to press.
 */
export function initialKeyboardState(touchPrimary: boolean): KeyboardState {
  return { intent: touchPrimary ? "hidden" : "shown", seenOpen: false };
}

/** The `inputmode` a field wears for a given intent. */
export function inputModeFor(intent: KeyboardIntent): "text" | "none" {
  return intent === "shown" ? "text" : "none";
}

/** The toolbar key was pressed. This is the only thing that sets intent. */
export function onKeyboardToggle(shown: boolean): KeyboardState {
  return { intent: shown ? "shown" : "hidden", seenOpen: false };
}

/**
 * The viewport reported the keyboard opening or closing.
 *
 * Two rules, and the asymmetry between them is the point:
 *
 * - **It opened while we wanted it shown.** Confirm it, so a later close can be
 *   read as a dismissal.
 * - **It closed after we had seen it open.** Adopt that as the user's intent.
 *   Otherwise the next tap on the terminal would raise a keyboard they had just
 *   put away with the browser's own key.
 *
 * Everything else is ignored. An opening we did not ask for is not an
 * instruction — it is another field somewhere taking focus, or the keyboard
 * still animating shut — and treating it as one would undo a deliberate hide.
 */
export function onKeyboardInset(state: KeyboardState, open: boolean): KeyboardState {
  if (open) {
    if (state.intent !== "shown" || state.seenOpen) return state;
    return { intent: "shown", seenOpen: true };
  }
  if (state.intent !== "shown" || !state.seenOpen) return state;
  return { intent: "hidden", seenOpen: false };
}

/**
 * How far the drawn content has to move to keep its bottom line in place.
 *
 * The canvas is drawn at the size the last fit gave it and hangs from the top
 * of its box. While the fit is held, the box moves and the canvas does not, so
 * the prompt slides behind the keyboard on the way up and a gap opens under it
 * on the way down — and every line jumps back at the moment the fit lands.
 * Moving the canvas by the same amount the box moved holds it all still. The
 * top rows slide out under the pane's clip, which is what should happen.
 *
 * Zero before anything has been fitted: there is no reference to move against.
 */
export function contentShiftPx(boxHeight: number, fittedBoxHeight: number): number {
  if (fittedBoxHeight <= 0) return 0;
  return boxHeight - fittedBoxHeight;
}
