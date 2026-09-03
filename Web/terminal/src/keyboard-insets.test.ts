import { afterEach, describe, expect, it, vi } from "vitest";

import { keyboardInset, trackKeyboardInsets } from "./keyboard-insets";

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

  // A keyboard slides for about a third of a second and reports a new height
  // every frame. `settled` is what lets a caller move the box on each one and
  // pay for a refit only at the end.
  it("marks a moving keyboard unsettled, and says so once it stops", async () => {
    const listeners = stubViewport(800);
    const { root } = styleRoot();
    const seen: Array<[number, boolean]> = [];
    trackKeyboardInsets(root, (px, settled) => seen.push([px, settled]), 20);

    // The first report is the page opening, not a slide, and arrives settled.
    expect(seen).toEqual([[0, true]]);
    seen.length = 0;

    for (const height of [700, 600, 520, 470, 464]) {
      (window.visualViewport as { height: number }).height = height;
      listeners.get("resize")?.();
    }
    expect(seen.every(([, settled]) => !settled)).toBe(true);
    expect(seen.at(-1)?.[0]).toBe(336);

    await new Promise((r) => setTimeout(r, 60));
    // Exactly one settled report, carrying the height it came to rest at.
    expect(seen.filter(([, settled]) => settled)).toEqual([[336, true]]);
  });

  // Each new height restarts the wait, so a slide never settles mid-way.
  it("does not settle while heights keep arriving", async () => {
    const listeners = stubViewport(800);
    const { root } = styleRoot();
    const seen: Array<[number, boolean]> = [];
    trackKeyboardInsets(root, (px, settled) => seen.push([px, settled]), 40);

    seen.length = 0;
    for (const height of [700, 600, 520]) {
      (window.visualViewport as { height: number }).height = height;
      listeners.get("resize")?.();
      await new Promise((r) => setTimeout(r, 20));
    }
    expect(seen.some(([, settled]) => settled)).toBe(false);
  });

  // A property on the root invalidates style for the whole document, and this
  // fires on every scroll — most of which carry the height it already has.
  it("writes the property only when the height changes", () => {
    const listeners = stubViewport(464);
    const writes: string[] = [];
    const props = new Map<string, string>();
    const root = {
      style: {
        setProperty: (k: string, v: string) => { writes.push(v); props.set(k, v); },
        getPropertyValue: (k: string) => props.get(k) ?? "",
        removeProperty: (k: string) => void props.delete(k),
      },
    } as unknown as HTMLElement;

    trackKeyboardInsets(root, undefined, 1000);
    const afterStart = writes.length;
    listeners.get("scroll")?.();
    listeners.get("scroll")?.();
    listeners.get("resize")?.();
    expect(writes.length).toBe(afterStart);
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

    // The user dismissed it somewhere else; the viewport grows back. The zero
    // is what tells `soft-keyboard.ts` to adopt that dismissal.
    (window.visualViewport as { height: number }).height = 800;
    listeners.get("resize")?.();
    expect(seen).toEqual([336, 0]);
    expect(root.style.getPropertyValue("--keyboard-height")).toBe("0px");
  });
});
