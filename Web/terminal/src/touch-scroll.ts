/**
 * Touch-scroll translation for the alternate screen.
 *
 * A vertical swipe means "scroll the scrollback" in a shell but "move within
 * the app" in vim/less/htop — those run on the alternate screen, which has no
 * scrollback, so xterm's default touch-scroll does nothing there and the app
 * feels frozen to a finger. This is the single biggest mobile complaint.
 *
 * We translate a swipe on the alt screen into the input the app actually
 * wants: mouse-wheel events if it turned on mouse reporting, otherwise arrow
 * keys. On the normal screen we do nothing and let xterm scroll the buffer.
 *
 * Natural-scroll convention (matches iOS/Android): dragging the finger UP
 * reveals later content (scroll down / next), dragging DOWN reveals earlier
 * content (scroll up / previous).
 */

export type SwipeTarget = "scrollback" | "arrows" | "mouse";

/** Decide where a swipe goes from the terminal's current mode. */
export function swipeTarget(altScreen: boolean, mouseReporting: boolean): SwipeTarget {
  if (mouseReporting) return "mouse";
  if (altScreen) return "arrows";
  return "scrollback";
}

/** Full-screen apps (less, vim, …) enable application cursor keys (DECCKM),
 * where arrows arrive as SS3 (`ESC O A`) not CSI (`ESC [ A`); many only accept
 * that form. Match the terminal's current mode. */
function arrowUp(appCursorKeys: boolean): string {
  return appCursorKeys ? "\x1bOA" : "\x1b[A";
}
function arrowDown(appCursorKeys: boolean): string {
  return appCursorKeys ? "\x1bOB" : "\x1b[B";
}

/** SGR (1006) mouse wheel at 1-based (col,row); button 64 = up, 65 = down. */
export function mouseWheelSequence(up: boolean, col: number, row: number): string {
  const button = up ? 64 : 65;
  const c = Math.max(1, col);
  const r = Math.max(1, row);
  return `\x1b[<${button};${c};${r}M`;
}

/**
 * Accumulates swipe distance and yields one discrete step per row of vertical
 * movement, so a slow drag still produces smooth stepping and a fast flick
 * produces several steps at once.
 */
export class SwipeAccumulator {
  private acc = 0;

  constructor(private readonly rowHeight: number) {}

  /**
   * Feed a movement delta in screen pixels (down is positive). Returns the
   * signed number of steps to emit: positive = finger moved down (→ scroll
   * up / previous), negative = finger moved up (→ scroll down / next). The
   * consumed distance is removed so sub-row movement carries over.
   */
  feed(deltaY: number): number {
    if (this.rowHeight <= 0) return 0;
    this.acc += deltaY;
    const steps = Math.trunc(this.acc / this.rowHeight);
    this.acc -= steps * this.rowHeight;
    return steps;
  }

  reset(): void {
    this.acc = 0;
  }
}

/**
 * The bytes to send for `steps` of swipe on a given target. `steps > 0` means
 * the finger moved down (reveal earlier content). `position` is the 1-based
 * cell under the finger, reported with each mouse-wheel event (SGR mouse mode).
 * Returns "" for the scrollback target (handled by xterm) or no movement.
 */
export function swipeToInput(
  target: SwipeTarget,
  steps: number,
  position: { col: number; row: number } = { col: 1, row: 1 },
  appCursorKeys = false,
): string {
  if (steps === 0 || target === "scrollback") return "";
  const count = Math.abs(steps);
  const fingerDown = steps > 0;
  if (target === "arrows") {
    // Finger down → earlier content → Up arrow.
    return (fingerDown ? arrowUp(appCursorKeys) : arrowDown(appCursorKeys)).repeat(count);
  }
  // mouse: finger down → wheel up.
  return mouseWheelSequence(fingerDown, position.col, position.row).repeat(count);
}
