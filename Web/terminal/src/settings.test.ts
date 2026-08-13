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

describe("tab title, keyed by session and by pane", () => {
  it("defaults to no custom title with the folder shown", () => {
    stubLocalStorage();
    expect(loadSettings().tabTitle).toBe("");
    expect(loadSettings().tabTitleShowFolder).toBe(true);
    expect(loadTabTitle("session-a", "hist-a")).toEqual({
      tabTitle: "",
      tabTitleShowFolder: true,
    });
  });

  it("round-trips a session's title", () => {
    stubLocalStorage();
    saveTabTitle("session-a", "hist-a", { tabTitle: "My App", tabTitleShowFolder: false });
    expect(loadTabTitle("session-a", "hist-a")).toEqual({
      tabTitle: "My App",
      tabTitleShowFolder: false,
    });
  });

  it("keeps panes independent, so a new tab starts clean", () => {
    stubLocalStorage();
    saveTabTitle("session-a", "hist-a", { tabTitle: "My App", tabTitleShowFolder: true });
    expect(loadTabTitle("session-b", "hist-b")).toEqual({
      tabTitle: "",
      tabTitleShowFolder: true,
    });
  });

  it("lets an observer read the controller's title for the same session", () => {
    stubLocalStorage();
    saveTabTitle("shared", "hist-controller", {
      tabTitle: "Deploy",
      tabTitleShowFolder: true,
    });
    // A share-link pane has no hist key of its own; the session entry is what
    // it reads, and it must be the controller's name.
    expect(loadTabTitle("shared", null).tabTitle).toBe("Deploy");
  });

  // The regression: a daemon restart or a dead shell mints a new session id for
  // every pane. Keyed only by session, the name vanished and the tab reverted
  // to the folder.
  it("keeps the name when the pane's session id changes", () => {
    stubLocalStorage();
    saveTabTitle("session-old", "hist-a", { tabTitle: "Deploy", tabTitleShowFolder: false });
    expect(loadTabTitle("session-new", "hist-a")).toEqual({
      tabTitle: "Deploy",
      tabTitleShowFolder: false,
    });
  });

  it("prefers the session's own title over the pane's, so observers mirror", () => {
    stubLocalStorage();
    saveTabTitle(null, "hist-a", { tabTitle: "Mine", tabTitleShowFolder: true });
    saveTabTitle("shared", null, { tabTitle: "Theirs", tabTitleShowFolder: true });
    expect(loadTabTitle("shared", "hist-a").tabTitle).toBe("Theirs");
  });

  it("trims the custom title and treats blank as unset", () => {
    stubLocalStorage();
    saveTabTitle("session-a", "hist-a", { tabTitle: "  My App  ", tabTitleShowFolder: true });
    expect(loadTabTitle("session-a", "hist-a").tabTitle).toBe("My App");
    saveTabTitle("session-a", "hist-a", { tabTitle: "   ", tabTitleShowFolder: true });
    expect(loadTabTitle("session-a", "hist-a").tabTitle).toBe("");
  });

  it("prunes old sessions so storage cannot grow without bound", () => {
    stubLocalStorage();
    for (let i = 0; i < 120; i += 1) {
      saveTabTitle(`session-${i}`, null, {
        tabTitle: `T${i}`,
        tabTitleShowFolder: true,
      });
    }
    // Oldest evicted, newest kept.
    expect(loadTabTitle("session-0", null).tabTitle).toBe("");
    expect(loadTabTitle("session-119", null).tabTitle).toBe("T119");
  });

  // A pane's own entry is rewritten every time its session id churns, so it
  // never ages out ahead of the dead ids that pushed the map over the cap.
  it("does not evict a live pane's name as its session ids churn", () => {
    stubLocalStorage();
    saveTabTitle("session-0", "hist-live", { tabTitle: "Deploy", tabTitleShowFolder: true });
    for (let i = 1; i < 120; i += 1) {
      saveTabTitle(`session-${i}`, "hist-live", {
        tabTitle: "Deploy",
        tabTitleShowFolder: true,
      });
    }
    expect(loadTabTitle("session-fresh", "hist-live").tabTitle).toBe("Deploy");
  });

  it("falls back to defaults on corrupt storage", () => {
    stubLocalStorage({ "kitterm:tab-titles": "{not json" });
    expect(loadTabTitle("session-a", "hist-a")).toEqual({
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
      saveTabTitle("session-a", "hist-a", { tabTitle: "My App", tabTitleShowFolder: true }),
    ).not.toThrow();
    expect(loadTabTitle("session-a", "hist-a")).toEqual({
      tabTitle: "",
      tabTitleShowFolder: true,
    });
  });

  it("ignores a write with no key to store it under", () => {
    stubLocalStorage();
    expect(() =>
      saveTabTitle(null, null, { tabTitle: "Nowhere", tabTitleShowFolder: true }),
    ).not.toThrow();
    expect(loadTabTitle(null, null).tabTitle).toBe("");
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
