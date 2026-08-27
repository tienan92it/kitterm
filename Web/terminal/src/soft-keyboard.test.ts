import { describe, expect, it } from "vitest";

import {
  inputModeFor,
  initialKeyboardState,
  onKeyboardInset,
  onKeyboardToggle,
  type KeyboardState,
} from "./soft-keyboard";

const shown = (seenOpen = false): KeyboardState => ({ intent: "shown", seenOpen });
const hidden = (): KeyboardState => ({ intent: "hidden", seenOpen: false });

describe("inputModeFor", () => {
  // "none" is the whole mechanism: a field can be focused and quiet, so a tap
  // on the terminal no longer raises the keyboard.
  it("asks for no keyboard while hidden", () => {
    expect(inputModeFor("hidden")).toBe("none");
    expect(inputModeFor("shown")).toBe("text");
  });
});

describe("onKeyboardToggle", () => {
  it("sets the intent the key asked for", () => {
    expect(onKeyboardToggle(false).intent).toBe("hidden");
    expect(onKeyboardToggle(true).intent).toBe("shown");
  });

  // The keyboard has not appeared yet at the moment the key is pressed.
  it("waits to see the keyboard before trusting a close", () => {
    expect(onKeyboardToggle(true).seenOpen).toBe(false);
  });
});

describe("initialKeyboardState", () => {
  // The whole point of the change: if a phone started shown, the field would
  // carry inputmode="text" and the first tap on the output would raise the
  // keyboard — which is the gesture this removes.
  it("starts a phone with the keyboard away", () => {
    expect(initialKeyboardState(true).intent).toBe("hidden");
  });

  it("leaves a real keyboard alone", () => {
    expect(initialKeyboardState(false).intent).toBe("shown");
  });
});

describe("onKeyboardInset", () => {
  it("confirms a keyboard it asked for", () => {
    expect(onKeyboardInset(shown(), true)).toEqual({ intent: "shown", seenOpen: true });
  });

  // iOS puts a dismiss key above the keyboard and gives no way to refuse it.
  // Pressing it must stick, or the next tap on the terminal undoes it.
  it("adopts a dismissal the user made elsewhere", () => {
    expect(onKeyboardInset(shown(true), false)).toEqual({ intent: "hidden", seenOpen: false });
  });

  // The keyboard animates for a few hundred milliseconds, and the viewport
  // reads closed for all of it. Without the guard this is a dismissal.
  it("does not read the rise of the keyboard as a dismissal", () => {
    expect(onKeyboardInset(shown(false), false)).toEqual(shown(false));
  });

  // An opening we did not ask for is not an instruction. Adopting it would
  // undo a deliberate hide the moment anything else took focus.
  it("ignores a keyboard that appears while hidden", () => {
    expect(onKeyboardInset(hidden(), true)).toEqual(hidden());
  });

  it("ignores a close while already hidden", () => {
    expect(onKeyboardInset(hidden(), false)).toEqual(hidden());
  });

  it("returns the same object when nothing changes, so callers can compare", () => {
    const state = hidden();
    expect(onKeyboardInset(state, true)).toBe(state);
    expect(onKeyboardInset(state, false)).toBe(state);
  });

  // The whole sequence, in the order a phone produces it.
  it("survives hide, tap, show, dismiss", () => {
    let state = initialKeyboardState(true);
    expect(state.intent).toBe("hidden");

    state = onKeyboardInset(state, true); // something else raised one: ignored
    expect(state.intent).toBe("hidden");

    state = onKeyboardToggle(true); // the toolbar key brought it up
    state = onKeyboardInset(state, false); // still animating up
    expect(state.intent).toBe("shown");
    state = onKeyboardInset(state, true);
    state = onKeyboardInset(state, false); // iOS dismiss key
    expect(state.intent).toBe("hidden");
  });
});
