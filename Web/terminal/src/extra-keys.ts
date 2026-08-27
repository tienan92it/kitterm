/**
 * On-screen extra-keys row for touch devices.
 *
 * Software keyboards have no Ctrl, Alt, Esc, Tab, or arrows — the keys a
 * terminal needs most. This renders a compact row of them above the keyboard.
 * Modifiers are sticky: tap Ctrl, then the next key is control-modified, then
 * it releases (the Termux/Blink model). Buttons never take focus, so the
 * keyboard stays up.
 */

import { KEYBOARD_SLASH_PATH, buildIcon, type IconName } from "./icons";

export type KeySpec = { key: string; ctrl: boolean; alt: boolean };

/** An action key. `ctrl`/`alt` preset a combo (e.g. Ctrl-C) that fires
 * regardless of the sticky modifiers.
 *
 * `icon` draws the key instead of lettering it, and `label` becomes its
 * accessible name. Keys that *are* words keep their letters — see `icons.ts`
 * for why the row is split that way. */
type ActionKey = {
  kind: "key";
  label: string;
  key: string;
  ctrl?: boolean;
  alt?: boolean;
  icon?: IconName;
};
type ModifierKey = { kind: "mod"; label: string; mod: "ctrl" | "alt" };
/**
 * Puts the soft keyboard away, and brings it back.
 *
 * The odd one out: every other key here exists to keep the keyboard up, and
 * this one exists to drop it, because reading a build log or a diff on a phone
 * needs the screen back.
 *
 * Drawn rather than lettered. The obvious glyph, U+2328, renders as a detailed
 * little keyboard that carries far more line work than a 20px button can show,
 * and it looks different on every platform. A path we own stays legible at this
 * size, matches the stroke weight of the rest of the UI, and takes
 * `currentColor` with the theme.
 */
type KeyboardKey = { kind: "keyboard" };
export type ExtraKey = ActionKey | ModifierKey | KeyboardKey;

/** One row of the keys a soft keyboard lacks and a terminal needs most: escape
 * and tab, sticky Ctrl for the long tail (Ctrl-D/Z/A/E…), a one-tap Ctrl-C
 * because it is by far the most common, and the four arrows. Deliberately
 * short — extra clutter is why the first version felt complicated. */
/** Held keys repeat like a hardware keyboard: a pause, then steady. */
export const KEY_REPEAT_DELAY_MS = 400;
export const KEY_REPEAT_INTERVAL_MS = 55;

/** Which keys mean "keep going" when held. */
export function repeatsOnHold(key: ExtraKey): boolean {
  if (key.kind !== "key") return false;
  return ["Backspace", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(key.key);
}

/**
 * Whether a click that follows our own touch should act.
 *
 * It must not, and getting this wrong is what made the button flicker. Tapping
 * to hide blurs on touchstart, the keyboard then takes a moment to slide shut,
 * and the ghost click lands while the inset still reads *open* — so anything
 * that re-derives intent from the inset at that instant concludes "show" and
 * reopens exactly what the touch just closed.
 *
 * `showPending` is the one case a ghost click must act on: the show direction
 * defers to the click, because focusing during touchstart is undone by the
 * browser's own tap handling.
 */
export function ghostClickShouldAct(
  msSinceTouch: number,
  showPending: boolean,
  ghostWindowMs = 700,
): boolean {
  if (showPending) return true;
  return msSinceTouch >= ghostWindowMs;
}

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

export const DEFAULT_LAYOUT: ExtraKey[][] = [
  [
    { kind: "key", label: "Esc", key: "Escape" },
    { kind: "key", label: "Tab", key: "Tab" },
    { kind: "mod", label: "Ctrl", mod: "ctrl" },
    { kind: "key", label: "⌃C", key: "c", ctrl: true },
    { kind: "key", label: "Left", key: "ArrowLeft", icon: "arrow-left" },
    { kind: "key", label: "Up", key: "ArrowUp", icon: "arrow-up" },
    { kind: "key", label: "Down", key: "ArrowDown", icon: "arrow-down" },
    { kind: "key", label: "Right", key: "ArrowRight", icon: "arrow-right" },
    { kind: "keyboard" },
  ],
];

const ARROW_FINAL: Record<string, string> = {
  ArrowUp: "A",
  ArrowDown: "B",
  ArrowRight: "C",
  ArrowLeft: "D",
};

/** Base sequence for a named key the soft keyboard lacks, respecting
 * application cursor keys (DECCKM) so arrows/Home/End reach full-screen apps in
 * the form they expect. A literal character (e.g. "|") maps to itself. */
function baseSequence(key: string, appCursorKeys: boolean): string {
  switch (key) {
    case "Escape":
      return "\x1b";
    case "Tab":
      return "\x09";
    case "Backspace":
      // DEL, which is what a terminal expects from the delete key — without
      // this the default branch would send the literal word "Backspace".
      return "\x7f";
    case "ArrowUp":
    case "ArrowDown":
    case "ArrowLeft":
    case "ArrowRight":
      return (appCursorKeys ? "\x1bO" : "\x1b[") + ARROW_FINAL[key];
    case "Home":
      return appCursorKeys ? "\x1bOH" : "\x1b[H";
    case "End":
      return appCursorKeys ? "\x1bOF" : "\x1b[F";
    case "PageUp":
      return "\x1b[5~";
    case "PageDown":
      return "\x1b[6~";
    default:
      return key; // literal character
  }
}

/** Bytes for a key with sticky modifiers applied. */
export function keyBytes(spec: KeySpec, appCursorKeys = false): string {
  const isArrow = spec.key in ARROW_FINAL;
  let seq: string;

  if (spec.ctrl && isArrow) {
    // Modified arrow: CSI 1 ; 5 <final> (modifier 5 = Ctrl).
    seq = `\x1b[1;5${ARROW_FINAL[spec.key]}`;
  } else {
    seq = baseSequence(spec.key, appCursorKeys);
    if (spec.ctrl && seq.length === 1) {
      // Control on a single printable char: mask to the C0 control code.
      seq = String.fromCharCode(seq.charCodeAt(0) & 0x1f);
    }
  }

  // Alt/Meta is an ESC prefix on the (possibly control-modified) sequence.
  if (spec.alt) seq = "\x1b" + seq;
  return seq;
}

/**
 * Sticky one-shot modifier state (the Termux model): tap a modifier to arm it,
 * the next key consumes and releases it. Pure, so it is unit-tested apart from
 * the DOM bar.
 */
export class StickyModifiers {
  private ctrl = false;
  private alt = false;

  get state(): { ctrl: boolean; alt: boolean } {
    return { ctrl: this.ctrl, alt: this.alt };
  }

  toggle(mod: "ctrl" | "alt"): void {
    if (mod === "ctrl") this.ctrl = !this.ctrl;
    else this.alt = !this.alt;
  }

  /** Apply the armed modifiers to a key, then release them. */
  consume(key: string): KeySpec {
    const spec: KeySpec = { key, ctrl: this.ctrl, alt: this.alt };
    this.ctrl = false;
    this.alt = false;
    return spec;
  }
}

/**
 * The DOM row. Emits a {@link KeySpec} on each action-key tap; the caller
 * turns it into bytes for the focused pane (which knows the cursor-keys mode).
 */
export class ExtraKeysBar {
  readonly element: HTMLElement;
  private readonly mods = new StickyModifiers();
  private readonly modButtons = new Map<"ctrl" | "alt", HTMLButtonElement>();
  /** The keyboard toggle, kept so its stroke can follow the keyboard.
   * Only that path moves, so only that path is held. */
  private keyboardButton: { button: HTMLButtonElement; slash: SVGPathElement } | null = null;
  /**
   * What the keyboard is doing, as told by the shell.
   *
   * Not measured. The viewport reports the keyboard's *height*, which lags a
   * tap by the length of the slide animation — deriving the button's next
   * action from it is what made this button flicker: a tap to hide was read
   * back as "still open", so the follow-up click reopened it.
   */
  private keyboardShown = true;

  constructor(
    private readonly onKey: (spec: KeySpec) => void,
    layout: ExtraKey[][] = DEFAULT_LAYOUT,
    private readonly onAttach?: (files: readonly File[]) => void,
    private readonly onBrowse?: () => void,
    private readonly onDismissPicker?: () => void,
    /** Asked to open the keyboard (`true`) or put it away (`false`). The bar
     * decides the direction; the caller owns the terminal that has focus. */
    private readonly onToggleKeyboard?: (open: boolean) => void,
  ) {
    this.element = document.createElement("div");
    this.element.className = "extra-keys";
    this.element.setAttribute("role", "toolbar");
    this.element.setAttribute("aria-label", "Extra keys");

    for (const row of layout) {
      const rowEl = document.createElement("div");
      rowEl.className = "extra-keys-row";
      for (const key of row) rowEl.append(this.button(key));
      if (row === layout[0]) {
        if (this.onBrowse) rowEl.append(this.browseButton());
        if (this.onAttach) rowEl.append(this.attachControl());
      }
      this.element.append(rowEl);
    }
  }

  /** Browse the machine the session runs on and insert a path — no copy, and
   *  folders work too. */
  /**
   * Wire a bar button so it behaves like the others: it never takes focus (the
   * terminal's textarea must keep it or the soft keyboard dismisses), it acts
   * on touchstart, and it ignores the ghost click a browser fires afterwards.
   *
   * `repeat` gives press-and-hold, for keys where holding obviously means "keep
   * going" — backspace and the arrows.
   */
  private wireTap(btn: HTMLButtonElement, act: () => void, repeat = false): void {
    btn.tabIndex = -1;
    let lastTouchAt = -Infinity;
    let holdTimer: ReturnType<typeof setTimeout> | null = null;
    let repeatTimer: ReturnType<typeof setInterval> | null = null;

    const stopHold = () => {
      if (holdTimer !== null) clearTimeout(holdTimer);
      if (repeatTimer !== null) clearInterval(repeatTimer);
      holdTimer = null;
      repeatTimer = null;
    };
    const startHold = () => {
      if (!repeat) return;
      stopHold();
      // Same shape as a hardware key: a pause before it takes, then steady.
      holdTimer = setTimeout(() => {
        repeatTimer = setInterval(act, KEY_REPEAT_INTERVAL_MS);
      }, KEY_REPEAT_DELAY_MS);
    };

    btn.addEventListener("mousedown", (event) => {
      event.preventDefault();
      startHold();
    });
    btn.addEventListener(
      "touchstart",
      (event) => {
        event.preventDefault();
        lastTouchAt = performance.now();
        act();
        startHold();
      },
      { passive: false },
    );
    for (const end of ["touchend", "touchcancel", "mouseup", "mouseleave"]) {
      btn.addEventListener(end, stopHold);
    }
    btn.addEventListener("click", () => {
      stopHold();
      // Ghost clicks arrive well under this after the touch; a deliberate
      // mouse click after a tap on a hybrid device arrives much later.
      if (performance.now() - lastTouchAt < 700) return;
      act();
    });
  }

  /**
   * A keyboard: a rounded body, two rows of key marks with a space bar, and a
   * chevron underneath for the direction.
   *
   * The two rows are what make it read as a keyboard at all. A single bar is
   * simpler still, but it reads as a monitor — the marks are the detail that
   * earns its place. Everything else is left out, because at 20px more line
   * work only turns to mush, which was the complaint about the U+2328 glyph
   * this replaces.
   */
  /**
   * The keyboard toggle: the set's keyboard, with a slash laid over it that is
   * shown or hidden as the keyboard moves. Built here rather than taken whole
   * from `ICONS` because that one path has to stay mutable.
   */
  private buildIcon(): { svg: SVGSVGElement; slash: SVGPathElement } {
    const svg = buildIcon("keyboard");
    const slash = document.createElementNS("http://www.w3.org/2000/svg", "path");
    slash.setAttribute("d", KEYBOARD_SLASH_PATH);
    // Hidden to start with, so the first sync always has something to change
    // and the accessible name is written with it.
    slash.style.display = "none";
    svg.append(slash);
    return { svg, slash };
  }

  private browseButton(): HTMLButtonElement {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "extra-key extra-key-browse";
    btn.append(buildIcon("folder"));
    btn.setAttribute("aria-label", "Browse files on this machine");
    this.wireTap(btn, () => this.onBrowse?.());
    return btn;
  }

  /**
   * Attaching is a `<label>` wrapping the file input, with no JavaScript in the
   * path at all.
   *
   * A button that calls `input.click()` does not work on a phone: the tap
   * handler has to `preventDefault` to keep the terminal focused, and that
   * spends the user gesture, after which the system refuses to open a file
   * picker. A label activates its input natively, so the gesture is never
   * intermediated — and there is no click of ours to recurse through.
   */
  private attachControl(): HTMLElement {
    const label = document.createElement("label");
    label.className = "extra-key extra-key-attach";
    label.title = "Attach a file";
    label.setAttribute("aria-label", "Attach a file");
    label.append(buildIcon("paperclip"));

    const input = document.createElement("input");
    input.type = "file";
    input.multiple = true;
    input.className = "extra-key-file-input";
    input.addEventListener("change", () => {
      const files = Array.from(input.files ?? []);
      if (files.length > 0) this.onAttach?.(files);
      // Cleared so picking the same file twice fires again.
      input.value = "";
      // Activating a label focuses its input, which is what drops the soft
      // keyboard; the system picker takes the screen either way, so the repair
      // is to hand focus back once it closes. Cancelling fires no event at all,
      // so the same is done when the window comes back.
      this.onDismissPicker?.();
    });
    input.addEventListener("cancel", () => this.onDismissPicker?.());
    label.append(input);
    return label;
  }

  private button(key: ExtraKey): HTMLButtonElement {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "extra-key";

    if (key.kind === "keyboard") {
      btn.classList.add("extra-key-keyboard");
      const { svg, slash } = this.buildIcon();
      btn.append(svg);
      btn.setAttribute("aria-label", keyboardToggleFace(false).ariaLabel);
      this.keyboardButton = { button: btn, slash };
      this.wireKeyboardToggle(btn);
      this.renderKeyboardLabel(this.keyboardShown);
      return btn;
    }

    if (key.kind === "key" && key.icon) {
      btn.append(buildIcon(key.icon));
      btn.setAttribute("aria-label", key.label);
    } else {
      btn.textContent = key.label;
    }
    const act = key.kind === "mod" ? () => this.tapModifier(key.mod) : () => this.tapKey(key);
    if (key.kind === "mod") {
      btn.classList.add("extra-key-mod");
      this.modButtons.set(key.mod, btn);
    }

    this.wireTap(btn, act, repeatsOnHold(key));
    return btn;
  }

  /**
   * The keyboard toggle, wired by hand because the two directions need
   * opposite treatment.
   *
   * **Hiding** behaves like every other key: `preventDefault` on touchstart so
   * focus never leaves the terminal.
   *
   * **Showing** must *not* `preventDefault`. iOS Safari opens the keyboard only
   * for a `focus()` made inside a real user gesture, and preventing the default
   * spends that gesture — the same trap the attach control documents, which is
   * why that one is a `<label>` and not a button. So the show direction lets
   * the event run and focuses during it.
   *
   * Because the show path leaves the default alone, the browser may hand focus
   * to this button afterwards and drop the keyboard again. The click that
   * follows re-focuses the terminal, which repairs that and is harmless when
   * nothing stole focus.
   */
  private wireKeyboardToggle(btn: HTMLButtonElement): void {
    btn.tabIndex = -1;
    let lastTouchAt = -Infinity;
    let showOnClick = false;

    const apply = (shown: boolean): void => {
      this.keyboardShown = shown;
      this.onToggleKeyboard?.(shown);
      this.renderKeyboardLabel(shown);
    };

    btn.addEventListener(
      "touchstart",
      (event) => {
        lastTouchAt = performance.now();
        if (this.keyboardShown) {
          // Hiding: hold focus where it is, and make the change ourselves.
          event.preventDefault();
          showOnClick = false;
          apply(false);
          return;
        }
        // Showing: leave the default alone *and do nothing yet*. Focusing here
        // does open the keyboard, and then the browser's own tap handling runs
        // and takes focus straight back off the textarea — which is the
        // flicker. The click below is the first moment nothing will undo it.
        showOnClick = true;
      },
      // Not passive: the hide direction calls preventDefault.
      { passive: false },
    );

    btn.addEventListener("click", () => {
      const pending = showOnClick;
      showOnClick = false;
      if (!ghostClickShouldAct(performance.now() - lastTouchAt, pending)) return;
      // A deferred show, or a real mouse click with no touch before it.
      apply(pending ? true : !this.keyboardShown);
    });
  }

  /** The shell says the keyboard moved — by this button, or by the dismiss key
   * iOS puts above the keyboard and gives no way to refuse. */
  setKeyboardShown(shown: boolean): void {
    this.keyboardShown = shown;
    this.renderKeyboardLabel(shown);
  }

  private renderKeyboardLabel(open: boolean): void {
    const entry = this.keyboardButton;
    if (!entry) return;
    const face = keyboardToggleFace(open);
    const display = face.struck ? "" : "none";
    // Only when it actually changes, so a repeated call costs nothing.
    if (entry.slash.style.display === display) return;
    entry.slash.style.display = display;
    entry.button.setAttribute("aria-label", face.ariaLabel);
  }

  private tapModifier(mod: "ctrl" | "alt"): void {
    this.mods.toggle(mod);
    this.refreshModState();
  }

  private tapKey(key: ActionKey): void {
    const spec = this.mods.consume(key.key);
    // A preset combo (e.g. ⌃C) forces its modifiers on top of any sticky ones.
    this.onKey({
      key: spec.key,
      ctrl: spec.ctrl || key.ctrl === true,
      alt: spec.alt || key.alt === true,
    });
    this.refreshModState();
  }

  private refreshModState(): void {
    const { ctrl, alt } = this.mods.state;
    this.modButtons.get("ctrl")?.classList.toggle("armed", ctrl);
    this.modButtons.get("alt")?.classList.toggle("armed", alt);
  }
}

/** Touch-first device with no precise pointer — where the row earns its space. */
export function isTouchPrimary(): boolean {
  if (typeof navigator === "undefined" || typeof matchMedia === "undefined") return false;
  return navigator.maxTouchPoints > 0 && matchMedia("(pointer: coarse)").matches;
}
