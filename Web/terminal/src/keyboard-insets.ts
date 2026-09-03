/**
 * Keeps the terminal above the software keyboard.
 *
 * On phones the keyboard covers the bottom of the page, hiding the cursor line
 * and — with the extra-keys row — the row itself. The portable signal is
 * `window.visualViewport`: when the keyboard opens, the visual viewport shrinks
 * while the layout viewport does not (iOS Safari) or the meta
 * `interactive-widget=resizes-content` resizes it (Chromium). Either way the
 * gap between them is the keyboard's height.
 *
 * We publish that height as the CSS variable `--keyboard-height`; the layout
 * lifts the extra-keys row and the terminal by it.
 *
 * This module measures and nothing more. What the user *wants* the keyboard to
 * do is `soft-keyboard.ts`, which takes the height reported here as one input.
 */

/**
 * Keyboard height from viewport geometry, clamped to ≥ 0. `layoutHeight` is the
 * full window height; `viewportHeight`/`offsetTop` come from visualViewport.
 * A tiny gap (rounding, browser chrome) is treated as no keyboard.
 */
export function keyboardInset(
  layoutHeight: number,
  viewportHeight: number,
  offsetTop: number,
): number {
  const covered = layoutHeight - (viewportHeight + offsetTop);
  // Below this, it's viewport chrome jitter, not a keyboard.
  return covered > 40 ? Math.round(covered) : 0;
}

/**
 * How long the inset must hold still before the keyboard counts as arrived.
 *
 * A keyboard slides for around a third of a second and the viewport reports a
 * new height every frame of it. Work that costs something — refitting a
 * terminal, telling the shell its new size — belongs at the end of that, not
 * nine times along the way.
 */
const SETTLE_MS = 120;

/**
 * Track the keyboard and publish `--keyboard-height`. Returns a disposer.
 * No-op where visualViewport is unavailable.
 *
 * `onChange` fires only when the height actually changes, so a caller can
 * follow the keyboard without polling: visualViewport emits on every scroll,
 * and most of those carry the same inset. `settled` says whether the keyboard
 * has stopped moving, so a caller can do the cheap part on every frame and the
 * expensive part once.
 */
export function trackKeyboardInsets(
  root: HTMLElement = document.documentElement,
  onChange?: (px: number, settled: boolean) => void,
  settleMs: number = SETTLE_MS,
): () => void {
  const vv = window.visualViewport;
  if (!vv) return () => {};

  let last: number | null = null;
  let settleTimer: ReturnType<typeof setTimeout> | null = null;

  const read = (): number => keyboardInset(window.innerHeight, vv.height, vv.offsetTop);

  // Written only on a real change. A custom property on the root invalidates
  // style for the whole document, and this fires on every scroll.
  const write = (px: number): void => {
    root.style.setProperty("--keyboard-height", `${px}px`);
    last = px;
  };

  const update = (): void => {
    const px = read();
    if (px === last) return;
    write(px);
    onChange?.(px, false);
    if (settleTimer !== null) clearTimeout(settleTimer);
    settleTimer = setTimeout(() => {
      settleTimer = null;
      onChange?.(px, true);
    }, settleMs);
  };

  // The first report is not a slide. Nothing is animating yet, so it arrives
  // settled and no caller holds work for it — a page that opens with no
  // keyboard must not defer its first fit by the settle time.
  const initial = read();
  write(initial);
  onChange?.(initial, true);

  vv.addEventListener("resize", update);
  vv.addEventListener("scroll", update);
  return () => {
    if (settleTimer !== null) clearTimeout(settleTimer);
    vv.removeEventListener("resize", update);
    vv.removeEventListener("scroll", update);
    root.style.removeProperty("--keyboard-height");
  };
}
