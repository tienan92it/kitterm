/**
 * On-screen extra-keys row for touch devices.
 *
 * Software keyboards have no Ctrl, Alt, Esc, Tab, or arrows — the keys a
 * terminal needs most. This renders a compact row of them above the keyboard.
 * Modifiers are sticky: tap Ctrl, then the next key is control-modified, then
 * it releases (the Termux/Blink model). Buttons never take focus, so the
 * keyboard stays up.
 */

import { isKeyboardOpen } from "./keyboard-insets";

export type KeySpec = { key: string; ctrl: boolean; alt: boolean };

/** An action key. `ctrl`/`alt` preset a combo (e.g. Ctrl-C) that fires
 * regardless of the sticky modifiers. */
type ActionKey = { kind: "key"; label: string; key: string; ctrl?: boolean; alt?: boolean };
type ModifierKey = { kind: "mod"; label: string; mod: "ctrl" | "alt" };
/**
 * Puts the soft keyboard away, and brings it back.
 *
 * The odd one out: every other key here exists to keep the keyboard up, and
 * this one exists to drop it, because reading a build log or a diff on a phone
 * needs the screen back. Two labels, because the button has to say what a tap
 * will do — and the keyboard can be dismissed by other means, so which label
 * shows is decided by the tracked inset rather than by anything we remember.
 */
type KeyboardKey = {
  kind: "keyboard";
  /** Shown while the keyboard is closed: a tap opens it. */
  label: string;
  /** Shown while the keyboard is open: a tap dismisses it. */
  labelWhenOpen: string;
};
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
 * What a tap on the keyboard toggle should do, given the keyboard's real state.
 *
 * Pure, because `preventDefault` is the detail that decides whether this button
 * works at all. **Hiding** prevents the default, like every other key here, so
 * focus never leaves the terminal and the blur is ours to make. **Showing must
 * not**: iOS Safari opens the keyboard only for a `focus()` made inside a live
 * user gesture, and preventing the default spends that gesture — the same trap
 * that forced the attach control to be a `<label>` rather than a button.
 */
export function keyboardTapPlan(open: boolean): { open: boolean; preventDefault: boolean } {
  return { open: !open, preventDefault: open };
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

/** How the toggle presents itself for a given keyboard state. */
export function keyboardToggleFace(
  key: { label: string; labelWhenOpen: string },
  open: boolean,
): { label: string; ariaLabel: string } {
  return open
    ? { label: key.labelWhenOpen, ariaLabel: "Hide the keyboard" }
    : { label: key.label, ariaLabel: "Show the keyboard" };
}

export const DEFAULT_LAYOUT: ExtraKey[][] = [
  [
    { kind: "key", label: "Esc", key: "Escape" },
    { kind: "key", label: "Tab", key: "Tab" },
    { kind: "mod", label: "Ctrl", mod: "ctrl" },
    { kind: "key", label: "⌃C", key: "c", ctrl: true },
    { kind: "key", label: "←", key: "ArrowLeft" },
    { kind: "key", label: "↑", key: "ArrowUp" },
    { kind: "key", label: "↓", key: "ArrowDown" },
    { kind: "key", label: "→", key: "ArrowRight" },
    { kind: "keyboard", label: "⌨", labelWhenOpen: "⌨▾" },
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
  /** The keyboard toggle, kept so its label can follow the tracked inset. */
  private keyboardButton: { button: HTMLButtonElement; key: KeyboardKey } | null = null;

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

  private browseButton(): HTMLButtonElement {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "extra-key extra-key-browse";
    btn.textContent = "⌸";
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
    label.append(document.createTextNode("＋"));

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
    btn.textContent = key.label;

    if (key.kind === "keyboard") {
      btn.classList.add("extra-key-keyboard");
      this.keyboardButton = { button: btn, key };
      this.wireKeyboardToggle(btn);
      this.syncKeyboardState();
      return btn;
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
   * focus never leaves the terminal, then blur it deliberately.
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

    const apply = (open: boolean): void => {
      this.onToggleKeyboard?.(open);
      this.renderKeyboardLabel(open);
    };

    btn.addEventListener(
      "touchstart",
      (event) => {
        lastTouchAt = performance.now();
        const plan = keyboardTapPlan(isKeyboardOpen());
        if (plan.preventDefault) {
          // Hiding: hold focus where it is, and make the blur ourselves.
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
      apply(pending ? true : keyboardTapPlan(isKeyboardOpen()).open);
    });
  }

  /** Adopt the keyboard's actual state. Called on every tracked inset change,
   * so dismissing the keyboard by any other means still corrects the label. */
  syncKeyboardState(): void {
    this.renderKeyboardLabel(isKeyboardOpen());
  }

  private renderKeyboardLabel(open: boolean): void {
    const entry = this.keyboardButton;
    if (!entry) return;
    const face = keyboardToggleFace(entry.key, open);
    // Only when it actually changes. The keyboard animates, so the tracker
    // reports a dozen distinct heights per open, and rewriting the label on
    // each one churned the DOM through the whole gesture for no reason.
    if (entry.button.textContent === face.label) return;
    entry.button.textContent = face.label;
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
