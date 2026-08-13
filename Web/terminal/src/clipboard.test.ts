import { afterEach, describe, expect, it, vi } from "vitest";

import { canReadClipboard, readClipboard, writeClipboard } from "./clipboard";

/** Replace `navigator`; `undefined` models a plain-HTTP origin, where the
 * whole `clipboard` object is missing rather than merely failing. */
const stubNavigator = (clipboard: unknown) => {
  vi.stubGlobal("navigator", clipboard === undefined ? {} : { clipboard });
};

/** A minimal document that records what `execCommand` was asked to do and what
 * was selected when it was asked. */
const stubDocument = (execResult: boolean | (() => boolean)) => {
  const copied: string[] = [];
  let field: Record<string, unknown> | null = null;
  const removed: boolean[] = [];

  vi.stubGlobal("document", {
    activeElement: null,
    body: { append: () => undefined },
    createElement: () => {
      field = {
        value: "",
        style: {},
        setAttribute: () => undefined,
        focus: () => undefined,
        setSelectionRange: () => undefined,
        remove: () => removed.push(true),
      };
      return field;
    },
    execCommand: (command: string) => {
      if (command !== "copy") return false;
      const ok = typeof execResult === "function" ? execResult() : execResult;
      if (ok) copied.push(String(field?.value ?? ""));
      return ok;
    },
  });

  vi.stubGlobal("HTMLElement", class {});
  return { copied, removed };
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("writeClipboard", () => {
  it("uses the async API when the origin has one", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    stubNavigator({ writeText });
    stubDocument(false);

    expect(await writeClipboard("hello")).toBe(true);
    expect(writeText).toHaveBeenCalledWith("hello");
  });

  // The regression: on a `--lan` origin `navigator.clipboard` is undefined, so
  // the old `navigator.clipboard.writeText(...)` threw synchronously and the
  // `.catch` around it never ran. Copy silently did nothing.
  it("falls back to execCommand when there is no async clipboard", async () => {
    stubNavigator(undefined);
    const { copied } = stubDocument(true);

    expect(await writeClipboard("lan text")).toBe(true);
    expect(copied).toEqual(["lan text"]);
  });

  it("falls back when the async write rejects", async () => {
    stubNavigator({ writeText: vi.fn().mockRejectedValue(new Error("denied")) });
    const { copied } = stubDocument(true);

    expect(await writeClipboard("denied then ok")).toBe(true);
    expect(copied).toEqual(["denied then ok"]);
  });

  it("reports false when neither route works, so the caller can show the text", async () => {
    stubNavigator(undefined);
    stubDocument(false);

    expect(await writeClipboard("nowhere")).toBe(false);
  });

  it("removes the scratch field even when execCommand throws", async () => {
    stubNavigator(undefined);
    const { removed } = stubDocument(() => {
      throw new Error("boom");
    });

    expect(await writeClipboard("boom")).toBe(false);
    expect(removed).toEqual([true]);
  });

  it("survives a navigator that throws on property access", async () => {
    vi.stubGlobal("navigator", {
      get clipboard(): never {
        throw new Error("blocked");
      },
    });
    const { copied } = stubDocument(true);

    expect(await writeClipboard("webview")).toBe(true);
    expect(copied).toEqual(["webview"]);
  });
});

describe("readClipboard", () => {
  it("returns the text when the origin allows a read", async () => {
    stubNavigator({ readText: vi.fn().mockResolvedValue("pasted") });
    expect(await readClipboard()).toBe("pasted");
  });

  it("returns null rather than throwing where there is no clipboard", async () => {
    stubNavigator(undefined);
    expect(await readClipboard()).toBeNull();
  });

  it("returns null when the read is denied", async () => {
    stubNavigator({ readText: vi.fn().mockRejectedValue(new Error("denied")) });
    expect(await readClipboard()).toBeNull();
  });

  it("treats an empty clipboard as nothing to paste", async () => {
    stubNavigator({ readText: vi.fn().mockResolvedValue("") });
    expect(await readClipboard()).toBeNull();
  });
});

describe("canReadClipboard", () => {
  it("is true only where readText exists", () => {
    stubNavigator({ readText: () => Promise.resolve("") });
    expect(canReadClipboard()).toBe(true);

    // Write-only is what a plain-HTTP origin gets after the execCommand
    // fallback: pasting has to be driven by the user's own gesture.
    stubNavigator({ writeText: () => Promise.resolve() });
    expect(canReadClipboard()).toBe(false);

    stubNavigator(undefined);
    expect(canReadClipboard()).toBe(false);
  });
});
