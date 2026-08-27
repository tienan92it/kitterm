/**
 * The key that raises and lowers the software keyboard.
 *
 * It used to be the last key in the extra-keys row, one of nine, sharing that
 * row's width. It is not one of nine: the other keys are things a terminal
 * needs *while* you type, and this one decides whether you are typing at all.
 * It is reached far more often than any of them, so it floats on its own, at
 * the bottom centre, on the line the gear sits on.
 *
 * Touch devices only. There is nothing for it to do where the keyboard is
 * hardware, and the shell never builds one there.
 *
 * **Why two events.** A phone raises the keyboard only for a `focus()` that
 * moves a field from unfocused to focused, made inside a live user gesture, and
 * it reads the field's `inputmode` at that moment and never looks again while
 * the field stays focused. The terminal's field is almost always already
 * focused, so a single handler cannot do it: a blur and a focus in the same
 * task are not that move, and the keyboard stays down. On device that looked
 * like a dead key — tapping it did nothing until the terminal was touched
 * again. So `touchstart` lets go of focus and changes nothing else, and `click`
 * sets the mode and takes focus back one event later, still inside the gesture.
 */

import { KEYBOARD_SLASH_PATH, buildIcon } from "./icons";

/**
 * How the toggle presents itself for a given keyboard state.
 *
 * Struck through while the keyboard is up, because a tap puts it away; plain
 * while it is down, because a tap brings it back. The same convention as every
 * other "-off" icon, so it needs no learning — and the keyboard body never
 * moves between the two, only the stroke over it.
 */
export function keyboardToggleFace(open: boolean): { ariaLabel: string; struck: boolean } {
  return open
    ? { ariaLabel: "Hide the keyboard", struck: true }
    : { ariaLabel: "Show the keyboard", struck: false };
}

export interface KeyboardToggleOptions {
  /** Asked to raise the keyboard (`true`) or put it away (`false`). */
  onToggle: (shown: boolean) => void;
  /** The press has begun: let go of focus, and change nothing else. */
  onArm: () => void;
  /** What the keyboard is doing at the moment the toggle is built. */
  shown: boolean;
}

export class KeyboardToggle {
  readonly element: HTMLElement;
  private readonly button: HTMLButtonElement;
  private readonly slash: SVGPathElement;
  /**
   * What the keyboard is doing, as told by the shell.
   *
   * Not measured. The viewport reports the keyboard's *height*, which lags a
   * tap by the length of the slide animation — deriving the next action from it
   * is what made this button flicker when it lived in the row.
   */
  private shown: boolean;

  constructor(private readonly options: KeyboardToggleOptions) {
    this.shown = options.shown;

    this.element = document.createElement("div");
    this.element.className = "keyboard-toggle-host";

    this.button = document.createElement("button");
    this.button.type = "button";
    this.button.className = "keyboard-toggle";
    // Never a tab stop: focus is the thing this control is careful with.
    this.button.tabIndex = -1;

    // The stroke is built here rather than taken from `ICONS`, because that one
    // path has to stay mutable while every icon in the set stays data.
    const svg = buildIcon("keyboard");
    this.slash = document.createElementNS("http://www.w3.org/2000/svg", "path");
    this.slash.setAttribute("d", KEYBOARD_SLASH_PATH);
    this.slash.style.display = "none";
    svg.append(this.slash);
    this.button.append(svg);

    this.wire();
    this.element.append(this.button);
    this.render(this.shown);
  }

  /** The shell says the keyboard moved — by this key, or by the dismiss key
   * iOS puts above the keyboard and gives no way to refuse. */
  setShown(shown: boolean): void {
    this.shown = shown;
    this.render(shown);
  }

  private wire(): void {
    let armed = false;

    this.button.addEventListener(
      "touchstart",
      () => {
        armed = true;
        this.options.onArm();
      },
      { passive: true },
    );

    this.button.addEventListener("click", () => {
      // A mouse, with no touch before it: the release has to happen here. There
      // is no soft keyboard to raise on such a device, so one task is enough.
      if (!armed) this.options.onArm();
      armed = false;
      const shown = !this.shown;
      this.shown = shown;
      this.options.onToggle(shown);
      this.render(shown);
    });
  }

  /**
   * Both writes, every time, including the first — the accessible name has to
   * be right before anything has moved. There is no guard against repeats: the
   * toggle is told only when the keyboard actually changes, unlike the old key
   * in the row, which followed the viewport and so heard from it a dozen times
   * per slide.
   */
  private render(shown: boolean): void {
    const face = keyboardToggleFace(shown);
    this.slash.style.display = face.struck ? "" : "none";
    this.button.setAttribute("aria-label", face.ariaLabel);
  }
}
