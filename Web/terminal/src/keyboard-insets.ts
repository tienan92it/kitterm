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
 * Whether the keyboard is up, read from the inset this module publishes.
 *
 * The single source of truth on purpose: the user can dismiss the keyboard
 * without touching kitterm — the browser's own control, a hardware key, a
 * swipe — and a boolean we kept ourselves would then be wrong. Anything that
 * shows keyboard state has to ask the viewport, not its own memory.
 *
 * An unset property means no tracker is running, which reads as closed. That is
 * the safe default: the toggle then offers to *show* the keyboard, and showing
 * one that is already up costs nothing.
 */
export function isKeyboardOpen(root: HTMLElement = document.documentElement): boolean {
  const raw = root.style.getPropertyValue("--keyboard-height");
  return Number.parseFloat(raw) > 0;
}

/**
 * Track the keyboard and publish `--keyboard-height`. Returns a disposer.
 * No-op where visualViewport is unavailable.
 *
 * `onChange` fires only when the height actually changes, so a caller can
 * follow the keyboard without polling. visualViewport emits on every scroll,
 * and most of those carry the same inset.
 */
export function trackKeyboardInsets(
  root: HTMLElement = document.documentElement,
  onChange?: (px: number) => void,
): () => void {
  const vv = window.visualViewport;
  if (!vv) return () => {};

  let last: number | null = null;
  const update = (): void => {
    const px = keyboardInset(window.innerHeight, vv.height, vv.offsetTop);
    root.style.setProperty("--keyboard-height", `${px}px`);
    if (px === last) return;
    last = px;
    onChange?.(px);
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
