import { afterEach, describe, expect, it, vi } from "vitest";

import { isKeyboardOpen, keyboardInset, trackKeyboardInsets } from "./keyboard-insets";

describe("keyboardInset", () => {
  it("is zero when the viewport fills the window", () => {
    expect(keyboardInset(800, 800, 0)).toBe(0);
  });

  it("reports the covered height when the keyboard shrinks the viewport", () => {
    // 800px window, keyboard leaves a 500px visual viewport.
    expect(keyboardInset(800, 500, 0)).toBe(300);
  });

  it("accounts for a scrolled visual viewport (offsetTop)", () => {
    expect(keyboardInset(800, 500, 50)).toBe(250);
  });

  it("ignores small gaps that are browser chrome, not a keyboard", () => {
    expect(keyboardInset(800, 770, 0)).toBe(0); // 30px < threshold
  });

  it("never goes negative", () => {
    expect(keyboardInset(800, 820, 0)).toBe(0);
  });

  it("rounds fractional heights", () => {
    expect(keyboardInset(800, 500.4, 0)).toBe(300);
  });
});

describe("isKeyboardOpen", () => {
  const rootWith = (value: string | null): HTMLElement =>
    ({
      style: {
        getPropertyValue: (name: string) =>
          name === "--keyboard-height" && value !== null ? value : "",
      },
    }) as unknown as HTMLElement;

  it("is open for a tracked inset above zero", () => {
    expect(isKeyboardOpen(rootWith("336px"))).toBe(true);
  });

  it("is closed at zero", () => {
    expect(isKeyboardOpen(rootWith("0px"))).toBe(false);
  });

  // No tracker running reads as closed, so the toggle offers to *show* the
  // keyboard. Showing one that is already up costs nothing; hiding one that is
  // already down would strand the user with no keyboard and no obvious way back.
  it("is closed when nothing has published an inset", () => {
    expect(isKeyboardOpen(rootWith(null))).toBe(false);
  });
});

describe("trackKeyboardInsets change notification", () => {
  const stubViewport = (height: number) => {
    const listeners = new Map<string, () => void>();
    vi.stubGlobal("window", {
      innerHeight: 800,
      visualViewport: {
        height,
        offsetTop: 0,
        addEventListener: (t: string, fn: () => void) => void listeners.set(t, fn),
        removeEventListener: (t: string) => void listeners.delete(t),
      },
    });
    return listeners;
  };

  const styleRoot = () => {
    const props = new Map<string, string>();
    return {
      props,
      root: {
        style: {
          setProperty: (k: string, v: string) => void props.set(k, v),
          getPropertyValue: (k: string) => props.get(k) ?? "",
          removeProperty: (k: string) => void props.delete(k),
        },
      } as unknown as HTMLElement,
    };
  };

  afterEach(() => vi.unstubAllGlobals());

  it("reports the inset once on start", () => {
    stubViewport(464);
    const { root } = styleRoot();
    const seen: number[] = [];
    trackKeyboardInsets(root, (px) => seen.push(px));
    expect(seen).toEqual([336]);
  });

  // visualViewport fires on every scroll and most carry the same inset. A
  // caller redrawing on each one would repaint constantly for no change.
  it("stays quiet while the inset is unchanged", () => {
    const listeners = stubViewport(464);
    const { root } = styleRoot();
    const seen: number[] = [];
    trackKeyboardInsets(root, (px) => seen.push(px));
    listeners.get("scroll")?.();
    listeners.get("resize")?.();
    expect(seen).toEqual([336]);
  });

  it("reports a keyboard that closed by other means", () => {
    const listeners = stubViewport(464);
    const { root } = styleRoot();
    const seen: number[] = [];
    trackKeyboardInsets(root, (px) => seen.push(px));

    // The user dismissed it somewhere else; the viewport grows back.
    (window.visualViewport as { height: number }).height = 800;
    listeners.get("resize")?.();
    expect(seen).toEqual([336, 0]);
    expect(isKeyboardOpen(root)).toBe(false);
  });
});
