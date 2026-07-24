/**
 * On-screen extra-keys row for touch devices.
 *
 * Software keyboards have no Ctrl, Alt, Esc, Tab, or arrows — the keys a
 * terminal needs most. This renders a compact row of them above the keyboard.
 * Modifiers are sticky: tap Ctrl, then the next key is control-modified, then
 * it releases (the Termux/Blink model). Buttons never take focus, so the
 * keyboard stays up.
 */

export type KeySpec = { key: string; ctrl: boolean; alt: boolean };

type ActionKey = { kind: "key"; label: string; key: string };
type ModifierKey = { kind: "mod"; label: string; mod: "ctrl" | "alt" };
export type ExtraKey = ActionKey | ModifierKey;

/** Default two-row layout, ~7 keys per row to fit a phone. */
export const DEFAULT_LAYOUT: ExtraKey[][] = [
  [
    { kind: "key", label: "Esc", key: "Escape" },
    { kind: "mod", label: "Ctrl", mod: "ctrl" },
    { kind: "mod", label: "Alt", mod: "alt" },
    { kind: "key", label: "↑", key: "ArrowUp" },
    { kind: "key", label: "|", key: "|" },
    { kind: "key", label: "Home", key: "Home" },
    { kind: "key", label: "PgUp", key: "PageUp" },
  ],
  [
    { kind: "key", label: "Tab", key: "Tab" },
    { kind: "key", label: "←", key: "ArrowLeft" },
    { kind: "key", label: "↓", key: "ArrowDown" },
    { kind: "key", label: "→", key: "ArrowRight" },
    { kind: "key", label: "/", key: "/" },
    { kind: "key", label: "End", key: "End" },
    { kind: "key", label: "PgDn", key: "PageDown" },
  ],
];

const ARROW_FINAL: Record<string, string> = {
  ArrowUp: "A",
  ArrowDown: "B",
  ArrowRight: "C",
  ArrowLeft: "D",
};

/** Base sequence for a named key, respecting application cursor keys (DECCKM)
 * so arrows/Home/End reach full-screen apps in the form they expect. */
function baseSequence(key: string, appCursorKeys: boolean): string {
  switch (key) {
    case "Escape":
      return "\x1b";
    case "Tab":
      return "\x09";
    case "Enter":
      return "\r";
    case "Backspace":
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

  constructor(
    private readonly onKey: (spec: KeySpec) => void,
    layout: ExtraKey[][] = DEFAULT_LAYOUT,
  ) {
    this.element = document.createElement("div");
    this.element.className = "extra-keys";
    this.element.setAttribute("role", "toolbar");
    this.element.setAttribute("aria-label", "Extra keys");

    for (const row of layout) {
      const rowEl = document.createElement("div");
      rowEl.className = "extra-keys-row";
      for (const key of row) rowEl.append(this.button(key));
      this.element.append(rowEl);
    }
  }

  private button(key: ExtraKey): HTMLButtonElement {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "extra-key";
    btn.textContent = key.label;
    // Never take focus: the terminal's textarea must stay focused so the soft
    // keyboard does not dismiss when a key is tapped.
    btn.tabIndex = -1;
    btn.addEventListener("mousedown", (e) => e.preventDefault());
    btn.addEventListener("touchstart", (e) => e.preventDefault(), { passive: false });

    if (key.kind === "mod") {
      btn.classList.add("extra-key-mod");
      this.modButtons.set(key.mod, btn);
      btn.addEventListener("click", () => {
        this.mods.toggle(key.mod);
        this.refreshModState();
      });
    } else {
      btn.addEventListener("click", () => {
        this.onKey(this.mods.consume(key.key));
        this.refreshModState();
      });
    }
    return btn;
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
