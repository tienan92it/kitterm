import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  LOCAL_FONT_ID,
  escapeCssFontFamily,
  findFontById,
  resolveFontFamily,
} from "./fonts";
import { queryLocalFonts } from "./local-fonts";
import {
  DEFAULT_TAB_TITLE,
  FONT_SIZE_DEFAULT,
  FONT_SIZE_MAX,
  FONT_SIZE_MIN,
  clampFontSize,
  loadSettings,
  loadTabTitle,
  saveTabTitle,
} from "./settings-store";
import { DEFAULT_THEME_ID, findThemeById } from "./themes";

const stubLocalStorage = (entries: Record<string, string> = {}) => {
  const store = new Map(Object.entries(entries));
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => store.set(key, value),
    removeItem: (key: string) => store.delete(key),
  });
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("clampFontSize", () => {
  it("returns the default for non-finite input", () => {
    expect(clampFontSize(Number.NaN)).toBe(FONT_SIZE_DEFAULT);
    expect(clampFontSize(Number.POSITIVE_INFINITY)).toBe(FONT_SIZE_DEFAULT);
  });

  it("clamps to bounds and rounds", () => {
    expect(clampFontSize(0)).toBe(FONT_SIZE_MIN);
    expect(clampFontSize(100)).toBe(FONT_SIZE_MAX);
    expect(clampFontSize(13.4)).toBe(13);
  });
});

describe("loadSettings", () => {
  it("returns defaults when localStorage is empty (regression: size fell to min)", () => {
    stubLocalStorage();
    const settings = loadSettings();
    expect(settings.fontSize).toBe(FONT_SIZE_DEFAULT);
    expect(settings.themeId).toBe(DEFAULT_THEME_ID);
    expect(settings.fontId).toBe("menlo");
    expect(settings.localFontFamily).toBeNull();
  });

  it("reads stored values and falls back on garbage", () => {
    stubLocalStorage({
      "kitterm:font-size": "16",
      "kitterm:theme-id": "dracula",
      "kitterm:font-id": "sf-mono",
      "kitterm:local-font-family": "  JetBrains Mono  ",
    });
    const settings = loadSettings();
    expect(settings.fontSize).toBe(16);
    expect(settings.themeId).toBe("dracula");
    expect(settings.fontId).toBe("sf-mono");
    expect(settings.localFontFamily).toBe("JetBrains Mono");

    stubLocalStorage({
      "kitterm:font-size": "abc",
      "kitterm:theme-id": "no-such-theme",
      "kitterm:font-id": "no-such-font",
    });
    const fallback = loadSettings();
    expect(fallback.fontSize).toBe(FONT_SIZE_DEFAULT);
    expect(fallback.themeId).toBe(DEFAULT_THEME_ID);
    expect(fallback.fontId).toBe("menlo");
  });
});

describe("tab title, keyed by session", () => {
  it("defaults to no custom title with the folder shown", () => {
    stubLocalStorage();
    expect(loadSettings().tabTitle).toBe("");
    expect(loadSettings().tabTitleShowFolder).toBe(true);
    expect(loadTabTitle("session-a")).toEqual({
      tabTitle: "",
      tabTitleShowFolder: true,
    });
  });

  it("round-trips a session's title", () => {
    stubLocalStorage();
    saveTabTitle("session-a", { tabTitle: "My App", tabTitleShowFolder: false });
    expect(loadTabTitle("session-a")).toEqual({
      tabTitle: "My App",
      tabTitleShowFolder: false,
    });
  });

  it("keeps sessions independent, so a new tab starts clean", () => {
    stubLocalStorage();
    saveTabTitle("session-a", { tabTitle: "My App", tabTitleShowFolder: true });
    expect(loadTabTitle("session-b")).toEqual({
      tabTitle: "",
      tabTitleShowFolder: true,
    });
  });

  it("lets an observer read the controller's title for the same session", () => {
    stubLocalStorage();
    saveTabTitle("shared", { tabTitle: "Deploy", tabTitleShowFolder: true });
    // Same key, as an observer tab of that session would read it.
    expect(loadTabTitle("shared").tabTitle).toBe("Deploy");
  });

  it("trims the custom title and treats blank as unset", () => {
    stubLocalStorage();
    saveTabTitle("session-a", { tabTitle: "  My App  ", tabTitleShowFolder: true });
    expect(loadTabTitle("session-a").tabTitle).toBe("My App");
    saveTabTitle("session-a", { tabTitle: "   ", tabTitleShowFolder: true });
    expect(loadTabTitle("session-a").tabTitle).toBe("");
  });

  it("prunes old sessions so storage cannot grow without bound", () => {
    stubLocalStorage();
    for (let i = 0; i < 60; i += 1) {
      saveTabTitle(`session-${i}`, {
        tabTitle: `T${i}`,
        tabTitleShowFolder: true,
      });
    }
    // Oldest evicted, newest kept.
    expect(loadTabTitle("session-0").tabTitle).toBe("");
    expect(loadTabTitle("session-59").tabTitle).toBe("T59");
  });

  it("falls back to defaults on corrupt storage", () => {
    stubLocalStorage({ "kitterm:tab-titles": "{not json" });
    expect(loadTabTitle("session-a")).toEqual({
      tabTitle: "",
      tabTitleShowFolder: true,
    });
  });

  it("survives localStorage being unavailable", () => {
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
      removeItem: () => undefined,
    });
    expect(() =>
      saveTabTitle("session-a", { tabTitle: "My App", tabTitleShowFolder: true }),
    ).not.toThrow();
    expect(loadTabTitle("session-a")).toEqual({
      tabTitle: "",
      tabTitleShowFolder: true,
    });
  });

  it("keeps the shared defaults immutable", () => {
    expect(Object.isFrozen(DEFAULT_TAB_TITLE)).toBe(true);
  });
});

describe("findThemeById / findFontById", () => {
  it("fall back to defaults for unknown ids", () => {
    expect(findThemeById("nope").id).toBe(DEFAULT_THEME_ID);
    expect(findFontById("nope").id).toBe("menlo");
  });
});

describe("escapeCssFontFamily", () => {
  it("escapes quotes and backslashes", () => {
    expect(escapeCssFontFamily('Weird "Font"')).toBe('Weird \\"Font\\"');
    expect(escapeCssFontFamily("Back\\slash")).toBe("Back\\\\slash");
  });
});

describe("resolveFontFamily", () => {
  it("quotes the local family with a monospace fallback", () => {
    expect(resolveFontFamily(LOCAL_FONT_ID, "JetBrains Mono")).toBe(
      '"JetBrains Mono", Menlo, Monaco, monospace',
    );
  });

  it("falls back to the registry when no local family is set", () => {
    expect(resolveFontFamily(LOCAL_FONT_ID, null)).toBe("Menlo, Monaco, monospace");
    expect(resolveFontFamily("menlo", null)).toBe(
      "Menlo, Monaco, 'Courier New', monospace",
    );
  });
});

describe("queryLocalFonts", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("dedupes and sorts family names", async () => {
    vi.stubGlobal("window", {
      queryLocalFonts: async () => [
        { family: "Zed Mono", fullName: "", postscriptName: "", style: "" },
        { family: "Arial", fullName: "", postscriptName: "", style: "" },
        { family: "Arial", fullName: "", postscriptName: "", style: "" },
        { family: "", fullName: "", postscriptName: "", style: "" },
      ],
    });
    await expect(queryLocalFonts()).resolves.toEqual(["Arial", "Zed Mono"]);
  });

  it("returns [] when the API throws or is missing", async () => {
    vi.stubGlobal("window", {
      queryLocalFonts: async () => {
        throw new DOMException("denied", "SecurityError");
      },
    });
    await expect(queryLocalFonts()).resolves.toEqual([]);

    vi.stubGlobal("window", {});
    await expect(queryLocalFonts()).resolves.toEqual([]);
  });
});
