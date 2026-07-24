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
 * Track the keyboard and publish `--keyboard-height`. Returns a disposer.
 * No-op where visualViewport is unavailable.
 */
export function trackKeyboardInsets(
  root: HTMLElement = document.documentElement,
): () => void {
  const vv = window.visualViewport;
  if (!vv) return () => {};

  const update = (): void => {
    const px = keyboardInset(window.innerHeight, vv.height, vv.offsetTop);
    root.style.setProperty("--keyboard-height", `${px}px`);
  };

  update();
  vv.addEventListener("resize", update);
  vv.addEventListener("scroll", update);
  return () => {
    vv.removeEventListener("resize", update);
    vv.removeEventListener("scroll", update);
    root.style.removeProperty("--keyboard-height");
  };
}
