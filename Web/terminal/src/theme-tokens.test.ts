import { describe, expect, it } from "vitest";

import { isDarkTheme, luminance, pickAccent, saturation, themeTokens } from "./theme-tokens";
import { TERMINAL_THEMES, findThemeById } from "./themes";

describe("luminance / polarity", () => {
  it("separates dark and light backgrounds", () => {
    expect(isDarkTheme("#0d1117")).toBe(true);
    expect(isDarkTheme("#ffffff")).toBe(false);
    expect(isDarkTheme("#fdf6e3")).toBe(false); // solarized light
  });

  it("treats an unknown background as dark rather than guessing wrong", () => {
    expect(isDarkTheme(undefined)).toBe(true);
    expect(luminance("not a colour")).toBe(0);
  });

  it("points elevation the right way for each polarity", () => {
    expect(themeTokens({ background: "#101010" })["--ui-lift"]).toBe("#fff");
    expect(themeTokens({ background: "#fdf6e3" })["--ui-lift"]).toBe("#000");
  });
});

describe("pickAccent", () => {
  it("prefers the theme's own blue", () => {
    expect(pickAccent({ blue: "#58a6ff", brightBlue: "#79c0ff" })).toBe("#79c0ff");
  });

  it("skips a blue that is actually grey", () => {
    // Vesper: `blue` is #a0a0a0. Using it would leave the UI colourless.
    const accent = pickAccent({
      blue: "#a0a0a0",
      brightBlue: "#a0a0a0",
      cyan: "#99ffe4",
      cursor: "#ffc799",
    });
    expect(saturation(accent)).toBeGreaterThanOrEqual(0.25);
  });

  it("honours an explicit accent above everything", () => {
    expect(pickAccent({ blue: "#58a6ff" }, "#ffc799")).toBe("#ffc799");
  });

  it("still returns something for a fully monochrome palette", () => {
    expect(pickAccent({ blue: "#888888", cursor: "#cccccc" })).toBeTruthy();
  });

  it("falls back when the palette is empty", () => {
    expect(pickAccent({})).toBe("#58a6ff");
  });
});

describe("themeTokens", () => {
  it("publishes the raw tier the stylesheet derives from", () => {
    const tokens = themeTokens(
      { background: "#0d1117", foreground: "#e6edf3", blue: "#58a6ff", red: "#f85149" },
      { fontFamily: '"JetBrains Mono", monospace' },
    );
    expect(tokens["--term-bg"]).toBe("#0d1117");
    expect(tokens["--term-fg"]).toBe("#e6edf3");
    expect(tokens["--term-red"]).toBe("#f85149");
    expect(tokens["--term-font"]).toBe('"JetBrains Mono", monospace');
  });

  it("omits absent colours instead of writing empty values", () => {
    const tokens = themeTokens({ background: "#000" });
    expect("--term-red" in tokens).toBe(false);
    expect(tokens["--term-bg"]).toBe("#000");
  });
});

describe("every shipped theme", () => {
  it("yields a usable accent", () => {
    for (const entry of TERMINAL_THEMES) {
      const accent = pickAccent(entry.colors, entry.accent);
      expect(accent, `${entry.id} produced no accent`).toMatch(/^#[0-9a-f]{3,8}$/i);
      // A grey accent is the failure this guards against; every theme should
      // either have a colourful candidate or an explicit override.
      expect(saturation(accent), `${entry.id} accent is grey`).toBeGreaterThan(0.15);
    }
  });

  it("gives Vesper its amber rather than its grey blue", () => {
    const vesper = findThemeById("vesper");
    expect(pickAccent(vesper.colors, vesper.accent)).toBe("#ffc799");
  });
});
