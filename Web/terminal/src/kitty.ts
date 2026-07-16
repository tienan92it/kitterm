/**
 * Minimal Kitty keyboard protocol helper for modern TUIs.
 * Spec: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
 */

export const ENTER_KEY_CODE = 13;

export const KEYBOARD_MODIFIER_SHIFT_BIT = 1;
export const KEYBOARD_MODIFIER_ALT_BIT = 2;
export const KEYBOARD_MODIFIER_CTRL_BIT = 4;
export const KEYBOARD_MODIFIER_META_BIT = 8;

export const KITTY_KEYBOARD_DISAMBIGUATE_FLAG = 1;
export const KITTY_KEYBOARD_SET_MODE_REPLACE = 1;
export const KITTY_KEYBOARD_SET_MODE_OR = 2;
export const KITTY_KEYBOARD_SET_MODE_AND_NOT = 3;

export function buildKittyKeySequence(keyCode: number, modifierBits: number): string {
  return `\x1b[${keyCode};${modifierBits + 1}u`;
}

export function extractKeyboardModifiers(event: KeyboardEvent): number {
  return (
    (event.shiftKey ? KEYBOARD_MODIFIER_SHIFT_BIT : 0) |
    (event.altKey ? KEYBOARD_MODIFIER_ALT_BIT : 0) |
    (event.ctrlKey ? KEYBOARD_MODIFIER_CTRL_BIT : 0) |
    (event.metaKey ? KEYBOARD_MODIFIER_META_BIT : 0)
  );
}

/** Tracks CSI > u / < u / = u flag stack (always at least one entry). */
export class KittyFlagStack {
  private stack: number[] = [0];

  get flags(): number {
    return this.stack[this.stack.length - 1] ?? 0;
  }

  get disambiguateActive(): boolean {
    return (this.flags & KITTY_KEYBOARD_DISAMBIGUATE_FLAG) !== 0;
  }

  push(flags: number): void {
    this.stack.push(flags);
  }

  pop(count = 1): void {
    for (let i = 0; i < count && this.stack.length > 1; i += 1) {
      this.stack.pop();
    }
  }

  set(flags: number, mode: number): void {
    const top = this.stack.length - 1;
    const current = this.stack[top] ?? 0;
    if (mode === KITTY_KEYBOARD_SET_MODE_REPLACE) {
      this.stack[top] = flags;
    } else if (mode === KITTY_KEYBOARD_SET_MODE_OR) {
      this.stack[top] = current | flags;
    } else if (mode === KITTY_KEYBOARD_SET_MODE_AND_NOT) {
      this.stack[top] = current & ~flags;
    }
  }
}
