/**
 * Publishes the active terminal theme as CSS custom properties, so the chrome
 * (settings panel, status line, extra keys, fleet page) derives its colours
 * from whatever the terminal is wearing — including themes we have never seen.
 *
 * Pure functions plus one DOM write, kept apart from the app shell so the
 * derivation rules are unit-testable without a browser.
 *
 * Cost: one `:root` write per theme change. Mutating a custom property on the
 * root invalidates style for the whole document, which is why this must never
 * be called per frame — a theme change is a user action, and the app already
 * wrote to `documentElement.style` at exactly this moment.
 */

import type { ITheme } from "@xterm/xterm";

/** sRGB relative luminance (WCAG), used to decide the theme's polarity. */
export const luminance = (hex: string): number => {
  const rgb = parseHex(hex);
  if (!rgb) return 0;
  const channel = (v: number) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2]);
};

export const parseHex = (hex: string): [number, number, number] | null => {
  const value = hex.trim().replace(/^#/, "");
  const full =
    value.length === 3
      ? value
          .split("")
          .map((c) => c + c)
          .join("")
      : value;
  if (!/^[0-9a-f]{6}$/i.test(full)) return null;
  return [
    Number.parseInt(full.slice(0, 2), 16),
    Number.parseInt(full.slice(2, 4), 16),
    Number.parseInt(full.slice(4, 6), 16),
  ];
};

/** A background this bright wants dark text and downward elevation. */
export const isDarkTheme = (background: string | undefined): boolean =>
  background ? luminance(background) < 0.5 : true;

/** How colourful a hex is, 0 (grey) to 1. */
export const saturation = (hex: string): number => {
  const rgb = parseHex(hex);
  if (!rgb) return 0;
  const max = Math.max(...rgb);
  const min = Math.min(...rgb);
  return max === 0 ? 0 : (max - min) / max;
};

/**
 * The colour the UI should accent with.
 *
 * An explicit per-theme accent wins. Otherwise prefer the theme's blue — but
 * only if it is actually a colour: Vesper's `blue` is `#a0a0a0`, pure grey,
 * and using it would leave the interface colourless. Fall back through the
 * remaining ANSI colours to the most saturated one available.
 */
export const pickAccent = (colors: ITheme, explicit?: string): string => {
  if (explicit) return explicit;
  const candidates = [
    colors.brightBlue,
    colors.blue,
    colors.brightCyan,
    colors.cyan,
    colors.brightMagenta,
    colors.magenta,
    colors.cursor,
  ].filter((c): c is string => typeof c === "string" && c.length > 0);

  const colourful = candidates.find((c) => saturation(c) >= 0.25);
  if (colourful) return colourful;
  // Everything is grey (a deliberately monochrome theme): the most saturated
  // of a grey set is still the least wrong, and the cursor is the theme's own
  // idea of "look here".
  return (
    candidates.slice().sort((a, b) => saturation(b) - saturation(a))[0] ?? "#58a6ff"
  );
};

/** The `--term-*` tier for a theme: raw values, no derivation. */
export const themeTokens = (
  colors: ITheme,
  options: { accent?: string; fontFamily?: string } = {},
): Record<string, string> => {
  const dark = isDarkTheme(colors.background);
  const tokens: Record<string, string> = {
    "--ui-lift": dark ? "#fff" : "#000",
    "--term-accent": pickAccent(colors, options.accent),
  };
  const raw: Array<[string, string | undefined]> = [
    ["--term-bg", colors.background],
    ["--term-fg", colors.foreground],
    ["--term-cursor", colors.cursor],
    ["--term-red", colors.red],
    ["--term-green", colors.green],
    ["--term-yellow", colors.yellow],
    ["--term-blue", colors.blue],
    ["--term-magenta", colors.magenta],
    ["--term-cyan", colors.cyan],
    ["--term-font", options.fontFamily],
  ];
  for (const [name, value] of raw) {
    if (value) tokens[name] = value;
  }
  return tokens;
};

/**
 * Write the tier to `:root`, and keep the two things outside CSS's reach in
 * step: `color-scheme` (so form controls and scrollbars match) and the
 * `theme-color` meta (so the phone's status bar and PWA chrome match).
 */
export const applyThemeTokens = (
  colors: ITheme,
  options: { accent?: string; fontFamily?: string } = {},
): void => {
  const root = document.documentElement;
  const tokens = themeTokens(colors, options);
  for (const [name, value] of Object.entries(tokens)) {
    root.style.setProperty(name, value);
  }
  root.style.colorScheme = isDarkTheme(colors.background) ? "dark" : "light";
  if (colors.background) {
    document
      .querySelector('meta[name="theme-color"]')
      ?.setAttribute("content", colors.background);
  }
};
