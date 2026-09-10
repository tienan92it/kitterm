import { describe, expect, it } from "vitest";

import {
  contrastRatio,
  derivePairs,
  floorFor,
  isLargeText,
  type Pair,
  ratioFor,
  readSource,
  resolveColor,
  rootVariables,
} from "./theme-contrast-derive";
import { accentOn, isDarkTheme, luminance, pickAccent, themeTokens } from "./theme-tokens";
import { TERMINAL_THEMES } from "./themes";

/**
 * Every text-and-background pair the two pages paint, on every bundled theme.
 *
 * The pairs are derived, not listed. `theme-contrast-derive.ts` reads
 * `tokens.css`, `sessions.css` and `styles.css` at test time, takes every rule
 * that sets a text colour, a size, a weight, a background or an opacity, and
 * works out the surface that text sits on. A hand list only measures what
 * someone remembered: that is how the proposals chip and the goal meta line
 * each shipped under the floor (rounds 5 and 7 of `projects-and-knowledge`).
 * The old list held five pairs; the derivation holds forty-five.
 *
 * ## How a surface is resolved
 *
 * A text rule does not name its background, and CSS carries no parent pointer,
 * so the rule is four steps, most derived first. `surfacesFor` in the helper
 * holds the code and the same four steps in full.
 *
 * 1. **The element's own paint** — the declarations in force on it. An opaque
 *    background is the surface; a translucent one (`--ui-veil`,
 *    `--ui-accent-soft`) is stacked over what steps 2 and 3 return.
 * 2. **The written ancestry** — a descendant selector names real ancestors, so
 *    `.menu.open .quiet`, `.settings-field select` and `.foreman .row` place
 *    themselves. Walk right to left and take the first ancestor any rule paints.
 * 3. **The block table** — `BLOCK_SURFACES` in the helper, one entry per block
 *    with the reason. A block, never a pair: a new element inside a known block
 *    is measured the day it is written, which is the defect this closes.
 * 4. **Nothing** — the rule is reported unplaced and the first test below fails
 *    naming it. A new block whose surface nobody stated breaks the build.
 *
 * ## What the rule cannot do
 *
 * - **It cannot choose between states.** `.strip-item` wears a warning tint, a
 *   danger tint or `--ui-accent-soft` depending on a class its children's
 *   selectors never mention. The rule does not guess: it collects every
 *   background any rule paints on that class and measures all of them, so the
 *   pair count is larger than the element count and the strictest case wins.
 * - **It does not inherit a font across elements.** `.code-text` takes its
 *   12.5px from `.preview-code`, and the derivation reads no size for it. A
 *   pair with no size takes the small-text floor, which is the safe way to be
 *   wrong.
 * - **It fades the text but not the element under it.** `opacity` is applied to
 *   the text over the resolved surface. The four faded elements paint
 *   `--ui-veil` over the grid, which is `--ui-bg` either way, so the two agree
 *   here; an opaque panel that faded would read a hundredth high.
 * - **It cannot see the terminal grid.** Chrome over the output is measured
 *   against `--term-bg`. A glyph the shell painted underneath is not modelled.
 * - **It does not evaluate `@supports`.** `tokens.css` upgrades
 *   `--ui-accent-on` to `contrast-color()` where the browser has it; the tested
 *   value is the JS-published pole every other browser paints.
 *
 * ## KNOWN_BELOW
 *
 * This round measures; it does not fix. `KNOWN_BELOW` names every pair under
 * its floor with the theme and the ratio, so capability 2 has its target list
 * and capability 3 has something to delete. A listed pair must not get worse
 * and must not start passing without the entry going with it; an unlisted pair
 * must hold its floor.
 */

/** WCAG 1.4.3 for small text. Large text takes 3:1; see `floorFor`. */
const FLOOR = 4.5;

const SHEETS: Array<[name: string, source: string]> = [
  ["sessions.css", readSource("sessions.css")],
  ["styles.css", readSource("styles.css")],
];

const TOKENS = rootVariables(readSource("tokens.css"));

/** The `--term-*` and `--ui-*` tiers as one table, for one theme. */
const paletteFor = (theme: (typeof TERMINAL_THEMES)[number]): Map<string, string> =>
  new Map([...TOKENS, ...Object.entries(themeTokens(theme.colors, { accent: theme.accent }))]);

const { pairs, holes } = derivePairs(SHEETS, paletteFor(TERMINAL_THEMES[0]));

/**
 * Ratios under the floor today, by pair and theme, measured by this file.
 * Pair first, because capability 2 raises a token and clears a whole row.
 *
 * Ten of these are theme-owned colours the goal's exclusions put out of reach:
 * `--code-error`, `--code-keyword`, `--code-name` and `--code-string`, which
 * are the theme's own ANSI colours; the three `--ui-accent` pairs; the two
 * `--ui-danger` pairs; and `--ui-text` on `--ui-bg`, where synthwave-84's own
 * foreground reads 4.32 on its own background. Capability 2 can move only
 * `--ui-text-muted` and `--ui-text-faint`, which `--code-punct` and
 * `--code-comment` alias, so those two clear with them. The ten are recorded
 * with their ratios so the human decides, which is what the goal's last
 * exclusion asks for.
 */
const KNOWN_BELOW: Record<string, Record<string, number>> = {
  "--code-comment on --ui-bg-sunken": {
    "github-dark": 3.62,
    "github-dark-dimmed": 2.70,
    "vesper": 4.01,
    "solarized-dark": 2.09,
    "dracula": 3.87,
    "nord": 3.24,
    "one-dark": 2.55,
    "tokyo-night": 3.07,
    "tokyo-night-storm": 3.02,
    "catppuccin-mocha": 3.27,
    "catppuccin-macchiato": 3.18,
    "ayu-mirage": 3.03,
    "night-owl": 3.38,
    "gruvbox-dark": 3.34,
    "monokai": 3.92,
    "synthwave-84": 2.00,
    "rose-pine": 3.45,
  },
  "--code-error on --ui-bg-sunken": {
    "solarized-dark": 3.40,
    "nord": 3.27,
    "gruvbox-dark": 2.83,
    "monokai": 4.13,
  },
  "--code-keyword on --ui-bg-sunken": {
    "solarized-dark": 3.46,
    "gruvbox-dark": 3.66,
  },
  "--code-name on --ui-bg-sunken": {
    "solarized-dark": 4.27,
    "gruvbox-dark": 3.66,
  },
  "--code-punct on --ui-bg-sunken": {
    "github-dark-dimmed": 4.15,
    "solarized-dark": 2.91,
    "one-dark": 3.77,
    "synthwave-84": 2.73,
  },
  "--code-string on --ui-bg-sunken": {
    "rose-pine": 3.48,
  },
  "--ui-accent on --ui-bg + --ui-accent-soft": {
    "solarized-dark": 3.20,
    "nord": 3.46,
    "one-dark": 4.25,
    "tokyo-night-storm": 4.19,
    "gruvbox-dark": 2.83,
  },
  "--ui-accent on --ui-surface": {
    "solarized-dark": 3.41,
    "nord": 3.86,
    "gruvbox-dark": 2.89,
  },
  "--ui-accent on --ui-surface + --ui-accent-soft": {
    "github-dark-dimmed": 4.14,
    "solarized-dark": 2.73,
    "dracula": 4.34,
    "nord": 2.96,
    "one-dark": 3.61,
    "tokyo-night": 4.21,
    "tokyo-night-storm": 3.55,
    "catppuccin-macchiato": 3.92,
    "gruvbox-dark": 2.40,
  },
  "--ui-danger on --ui-bg": {
    "solarized-dark": 3.24,
    "nord": 3.05,
    "one-dark": 4.38,
    "gruvbox-dark": 2.69,
    "monokai": 3.92,
    "synthwave-84": 4.45,
  },
  "--ui-danger on --ui-surface-2": {
    "github-dark-dimmed": 3.83,
    "solarized-dark": 2.36,
    "dracula": 3.27,
    "nord": 2.20,
    "one-dark": 3.15,
    "tokyo-night-storm": 3.99,
    "catppuccin-macchiato": 4.33,
    "night-owl": 4.05,
    "gruvbox-dark": 1.95,
    "monokai": 2.85,
    "synthwave-84": 3.23,
  },
  "--ui-text on --ui-active": {
    "github-dark-dimmed": 3.97,
    "solarized-dark": 2.47,
    "one-dark": 3.40,
    "synthwave-84": 2.23,
  },
  "--ui-text on --ui-bg": {
    "synthwave-84": 4.31,
  },
  "--ui-text on --ui-bg + --ui-accent-soft": {
    "solarized-dark": 3.72,
    "synthwave-84": 2.72,
  },
  "--ui-text on --ui-bg + --ui-veil": {
    "synthwave-84": 4.31,
  },
  "--ui-text on --ui-bg + --ui-veil at 35% opacity": {
    "github-dark": 2.89,
    "github-dark-dimmed": 2.16,
    "vesper": 3.19,
    "solarized-dark": 1.71,
    "dracula": 2.97,
    "nord": 2.49,
    "one-dark": 2.04,
    "tokyo-night": 2.44,
    "tokyo-night-storm": 2.37,
    "catppuccin-mocha": 2.58,
    "catppuccin-macchiato": 2.49,
    "ayu-mirage": 2.39,
    "night-owl": 2.66,
    "gruvbox-dark": 2.60,
    "monokai": 3.01,
    "synthwave-84": 1.56,
    "rose-pine": 2.73,
  },
  "--ui-text on --ui-bg + --ui-veil at 65% opacity": {
    "github-dark-dimmed": 4.08,
    "solarized-dark": 2.80,
    "one-dark": 3.67,
    "synthwave-84": 2.52,
  },
  "--ui-text on --ui-bg + --ui-veil at 75% opacity": {
    "solarized-dark": 3.28,
    "one-dark": 4.39,
    "synthwave-84": 2.96,
  },
  "--ui-text on --ui-border": {
    "solarized-dark": 2.87,
    "one-dark": 3.98,
    "synthwave-84": 2.61,
  },
  "--ui-text on --ui-hover": {
    "solarized-dark": 2.96,
    "one-dark": 4.09,
    "synthwave-84": 2.69,
  },
  "--ui-text on --ui-surface": {
    "solarized-dark": 3.97,
    "synthwave-84": 3.63,
  },
  "--ui-text on --ui-surface + --ui-accent-soft": {
    "solarized-dark": 3.17,
    "one-dark": 4.00,
    "synthwave-84": 2.31,
  },
  "--ui-text on --ui-surface + --ui-veil": {
    "synthwave-84": 4.26,
  },
  "--ui-text on --ui-surface-2": {
    "solarized-dark": 3.46,
    "synthwave-84": 3.13,
  },
  "--ui-text on color-mix(in srgb, --ui-danger 8%, --ui-surface)": {
    "solarized-dark": 3.89,
    "synthwave-84": 3.35,
  },
  "--ui-text on color-mix(in srgb, --ui-warning 10%, --ui-surface)": {
    "solarized-dark": 3.54,
    "one-dark": 4.39,
    "synthwave-84": 2.81,
  },
  "--ui-text-faint on --ui-bg-sunken": {
    "github-dark": 3.62,
    "github-dark-dimmed": 2.70,
    "vesper": 4.01,
    "solarized-dark": 2.09,
    "dracula": 3.87,
    "nord": 3.24,
    "one-dark": 2.55,
    "tokyo-night": 3.07,
    "tokyo-night-storm": 3.02,
    "catppuccin-mocha": 3.27,
    "catppuccin-macchiato": 3.18,
    "ayu-mirage": 3.03,
    "night-owl": 3.38,
    "gruvbox-dark": 3.34,
    "monokai": 3.92,
    "synthwave-84": 2.00,
    "rose-pine": 3.45,
  },
  "--ui-text-faint on --ui-surface": {
    "github-dark": 3.15,
    "github-dark-dimmed": 2.15,
    "vesper": 3.50,
    "solarized-dark": 1.67,
    "dracula": 3.04,
    "nord": 2.51,
    "one-dark": 2.00,
    "tokyo-night": 2.54,
    "tokyo-night-storm": 2.39,
    "catppuccin-mocha": 2.68,
    "catppuccin-macchiato": 2.52,
    "ayu-mirage": 2.43,
    "night-owl": 2.89,
    "gruvbox-dark": 2.64,
    "monokai": 3.10,
    "synthwave-84": 1.60,
    "rose-pine": 2.89,
  },
  "--ui-text-faint on --ui-surface + --ui-accent-soft": {
    "github-dark": 2.15,
    "github-dark-dimmed": 1.52,
    "vesper": 2.24,
    "solarized-dark": 1.33,
    "dracula": 2.09,
    "nord": 1.93,
    "one-dark": 1.47,
    "tokyo-night": 1.84,
    "tokyo-night-storm": 1.76,
    "catppuccin-mocha": 1.86,
    "catppuccin-macchiato": 1.80,
    "ayu-mirage": 1.62,
    "night-owl": 2.04,
    "gruvbox-dark": 2.19,
    "monokai": 2.07,
    "synthwave-84": 1.02,
    "rose-pine": 1.90,
  },
  "--ui-text-muted on --ui-bg": {
    "github-dark-dimmed": 3.95,
    "solarized-dark": 2.77,
    "one-dark": 3.57,
    "synthwave-84": 2.60,
  },
  "--ui-text-muted on --ui-bg + --ui-accent-soft": {
    "github-dark-dimmed": 2.76,
    "solarized-dark": 2.18,
    "dracula": 4.22,
    "nord": 3.54,
    "one-dark": 2.56,
    "tokyo-night": 3.61,
    "tokyo-night-storm": 3.27,
    "catppuccin-mocha": 3.70,
    "catppuccin-macchiato": 3.45,
    "ayu-mirage": 3.07,
    "night-owl": 4.24,
    "gruvbox-dark": 4.23,
    "monokai": 4.21,
    "synthwave-84": 1.64,
    "rose-pine": 3.93,
  },
  "--ui-text-muted on --ui-bg + --ui-veil": {
    "github-dark-dimmed": 3.95,
    "solarized-dark": 2.77,
    "one-dark": 3.57,
    "synthwave-84": 2.60,
  },
  "--ui-text-muted on --ui-bg + --ui-veil at 55% opacity": {
    "github-dark": 2.81,
    "github-dark-dimmed": 2.15,
    "vesper": 3.09,
    "solarized-dark": 1.72,
    "dracula": 2.94,
    "nord": 2.48,
    "one-dark": 2.04,
    "tokyo-night": 2.41,
    "tokyo-night-storm": 2.35,
    "catppuccin-mocha": 2.56,
    "catppuccin-macchiato": 2.48,
    "ayu-mirage": 2.37,
    "night-owl": 2.61,
    "gruvbox-dark": 2.58,
    "monokai": 2.97,
    "synthwave-84": 1.62,
    "rose-pine": 2.68,
  },
  "--ui-text-muted on --ui-bg-sunken": {
    "github-dark-dimmed": 4.15,
    "solarized-dark": 2.91,
    "one-dark": 3.77,
    "synthwave-84": 2.73,
  },
  "--ui-text-muted on --ui-hover": {
    "github-dark-dimmed": 2.46,
    "solarized-dark": 1.73,
    "dracula": 3.93,
    "nord": 2.98,
    "one-dark": 2.23,
    "tokyo-night": 3.17,
    "tokyo-night-storm": 2.81,
    "catppuccin-mocha": 3.36,
    "catppuccin-macchiato": 3.06,
    "ayu-mirage": 2.93,
    "night-owl": 3.87,
    "gruvbox-dark": 3.28,
    "monokai": 3.98,
    "synthwave-84": 1.62,
    "rose-pine": 3.83,
  },
  "--ui-text-muted on --ui-surface": {
    "github-dark-dimmed": 3.30,
    "solarized-dark": 2.32,
    "nord": 3.96,
    "one-dark": 2.96,
    "tokyo-night": 4.23,
    "tokyo-night-storm": 3.76,
    "catppuccin-macchiato": 4.09,
    "ayu-mirage": 3.91,
    "gruvbox-dark": 4.33,
    "synthwave-84": 2.19,
  },
  "--ui-text-muted on --ui-surface-2": {
    "github-dark-dimmed": 2.87,
    "solarized-dark": 2.02,
    "nord": 3.43,
    "one-dark": 2.57,
    "tokyo-night": 3.68,
    "tokyo-night-storm": 3.28,
    "catppuccin-mocha": 3.91,
    "catppuccin-macchiato": 3.57,
    "ayu-mirage": 3.41,
    "gruvbox-dark": 3.78,
    "synthwave-84": 1.88,
    "rose-pine": 4.44,
  },
  "--ui-text-muted on color-mix(in srgb, --ui-danger 8%, --ui-surface)": {
    "github-dark-dimmed": 2.97,
    "solarized-dark": 2.28,
    "nord": 3.70,
    "one-dark": 2.69,
    "tokyo-night": 3.75,
    "tokyo-night-storm": 3.36,
    "catppuccin-mocha": 3.92,
    "catppuccin-macchiato": 3.60,
    "ayu-mirage": 3.44,
    "gruvbox-dark": 4.22,
    "synthwave-84": 2.02,
  },
  "--ui-text-muted on color-mix(in srgb, --ui-warning 10%, --ui-surface)": {
    "github-dark-dimmed": 2.85,
    "solarized-dark": 2.07,
    "dracula": 3.90,
    "nord": 3.18,
    "one-dark": 2.39,
    "tokyo-night": 3.47,
    "tokyo-night-storm": 3.11,
    "catppuccin-mocha": 3.44,
    "catppuccin-macchiato": 3.20,
    "ayu-mirage": 3.08,
    "night-owl": 4.11,
    "gruvbox-dark": 3.68,
    "monokai": 4.27,
    "synthwave-84": 1.69,
    "rose-pine": 4.05,
  },
};

const check = (pair: Pair, theme: string, ratio: number): void => {
  const known = KNOWN_BELOW[pair.key]?.[theme];
  const where = `${pair.key} on ${theme}; first written at ${pair.rules[0]}`;
  if (known === undefined) {
    expect(ratio, `${where} dropped under ${pair.floor}:1`).toBeGreaterThanOrEqual(pair.floor);
    return;
  }
  expect(ratio, `${where} got worse than its KNOWN_BELOW entry`).toBeGreaterThanOrEqual(known);
  expect(ratio, `${where} now passes; drop its KNOWN_BELOW entry`).toBeLessThan(pair.floor);
};

describe("the derivation covers the two stylesheets", () => {
  /**
   * The loud failure of step 4. A rule the surface rule cannot place is a hole
   * in the measurement, not a pair to skip: it is named here with its file and
   * line so whoever added it says what it sits on.
   */
  it("places every text rule in sessions.css and styles.css", () => {
    const named = holes.map((h) => `${h.sheet}:${h.line} ${h.selector} — ${h.why}`);
    expect(named, "add a BLOCK_SURFACES entry for each, or say why it holds no text").toEqual([]);
  });

  it("measures more pairs than the hand list did", () => {
    // The list this replaced held five: the accent button, the state label and
    // the muted line on --ui-surface, and the same two on --ui-surface-2.
    expect(pairs.length).toBeGreaterThan(5);
    expect(pairs.every((p) => p.rules.length > 0)).toBe(true);
  });

  it("resolves every colour it derived on every theme", () => {
    const unresolved: string[] = [];
    for (const theme of TERMINAL_THEMES) {
      const vars = paletteFor(theme);
      for (const pair of pairs) {
        try {
          resolveColor(pair.color, vars);
          for (const layer of pair.stack) resolveColor(layer, vars);
        } catch (error) {
          unresolved.push(`${theme.id} ${pair.key}: ${(error as Error).message}`);
        }
      }
    }
    expect(unresolved).toEqual([]);
  });

  it("carries no KNOWN_BELOW entry for a pair the derivation no longer finds", () => {
    const found = new Set(pairs.map((p) => p.key));
    expect(Object.keys(KNOWN_BELOW).filter((key) => !found.has(key))).toEqual([]);
  });
});

describe("polarity", () => {
  /**
   * `--ui-lift` flips to black on a light theme and one set of formulas covers
   * both polarities, so a light theme is measured by the same pairs the day it
   * is bundled. `facts.md` recorded that no bundled theme was light; that still
   * holds, and this test says so out loud rather than leaving it implied.
   */
  it("has no light theme among the bundled ones, so every pair is measured dark", () => {
    const light = TERMINAL_THEMES.filter((t) => !isDarkTheme(t.colors.background)).map((t) => t.id);
    expect(light, "a light theme arrived; check its pairs and update facts.md").toEqual([]);
    expect(TERMINAL_THEMES.length).toBe(17);
  });

  it("derives --ui-lift from the theme's own background", () => {
    expect(themeTokens({ background: "#0d1117" })["--ui-lift"]).toBe("#fff");
    expect(themeTokens({ background: "#fdf6e3" })["--ui-lift"]).toBe("#000");
  });
});

describe("the WCAG large-text threshold", () => {
  it("is 24px regular or 18.66px bold, and 600 is not bold", () => {
    expect(isLargeText(24, 400)).toBe(true);
    expect(isLargeText(23.9, 400)).toBe(false);
    expect(isLargeText(18.66, 700)).toBe(true);
    expect(isLargeText(18.66, 600)).toBe(false);
    expect(isLargeText(18.65, 700)).toBe(false);
    expect(isLargeText(null, 700)).toBe(false);
    expect(floorFor(24, 400)).toBe(3);
    expect(floorFor(20, 600)).toBe(FLOOR);
  });

  /**
   * Nothing either page prints is large by that definition: the biggest is the
   * fleet page's 20px/600 `h1`. Every pair therefore takes 4.5:1 today. The
   * rule is applied per pair regardless, so a heading that grows to 24px drops
   * to 3:1 on its own.
   */
  it("puts every pair the two pages paint at 4.5:1 today", () => {
    expect(pairs.filter((p) => p.floor !== FLOOR).map((p) => p.key)).toEqual([]);
  });
});

describe.each(TERMINAL_THEMES.map((t) => [t.id, t] as const))("%s", (id, theme) => {
  const vars = paletteFor(theme);

  it("puts black or white on the accent, whichever contrasts more", () => {
    const accent = pickAccent(theme.colors, theme.accent);
    expect(contrastRatio(resolveColor(accentOn(accent), vars), resolveColor(accent, vars))).toBeGreaterThanOrEqual(
      FLOOR,
    );
    expect(themeTokens(theme.colors, { accent: theme.accent })["--term-accent-on"]).toBe(accentOn(accent));
  });

  for (const pair of pairs) {
    it(pair.key, () => {
      check(pair, id, ratioFor(pair, vars));
    });
  }
});

describe("accentOn", () => {
  it("picks the pole with the higher ratio", () => {
    expect(accentOn("#58a6ff")).toBe("#000");
    expect(accentOn("#1f3a8a")).toBe("#fff");
    expect(accentOn("#ffffff")).toBe("#000");
  });

  it("agrees with the luminance the token layer uses", () => {
    expect(luminance("#ffffff")).toBeCloseTo(1, 5);
    expect(luminance("#000000")).toBe(0);
  });
});
