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
 * `KNOWN_BELOW` names every pair under its floor with the theme and the ratio,
 * so capability 3 has something to delete. A listed pair must not get worse and
 * must not start passing without the entry going with it; an unlisted pair must
 * hold its floor.
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
 * Pair first, because a token change clears part of a row.
 *
 * 134 entries over 38 pairs, after round 3 lowered the elevation of
 * `--ui-surface`, `--ui-surface-2`, `--ui-hover` and `--ui-active` from
 * 7/12/17/23 percent of `--ui-lift` to 3/6/9/12, and dropped the 0.55 opacity
 * `.pane-close` wore on a touch device. That cleared 44 of the 178 entries
 * round 2 left, and one whole pair: `--ui-text-muted on --ui-bg + --ui-veil at
 * 55% opacity` no longer exists, because the element no longer fades. No
 * ratio fell, and no pair that passed started failing.
 *
 * **The elevation lever is now spent, and it could never have emptied this
 * table.** Only 18 of the 38 pairs paint on one of the four elevated tokens at
 * all; the rest sit on `--ui-bg`, `--ui-bg-sunken`, `--ui-border`,
 * `--ui-accent-soft`, or under one of the three opacities the goal did not
 * open. Measured: with all four tokens set to `--ui-bg` itself, 136 entries
 * still miss 4.5:1, and sinking them well below `--ui-bg` bottoms out at 115.
 * The reason is that `--ui-text-muted` reads 3.61 on `--ui-bg` on
 * solarized-dark and 3.32 on synthwave-84, and `--ui-text` itself reads 4.32
 * on `--ui-bg` on synthwave-84 — under the floor before any surface exists.
 * No elevation can beat a theme's own foreground on its own background.
 *
 * The remainder, grouped by the surface that holds it down. The groups are
 * exclusive and they cover all 134:
 *
 * - **33 over 11 pairs, on the four elevated tokens.** Eight themes, led by
 *   solarized-dark and synthwave-84. Every one of the 33 is a theme whose text
 *   or whose red or blue already misses the floor on `--ui-bg`, so no surface
 *   near `--ui-bg` can carry it. They need the theme's own colours to move.
 * - **32 over 6 pairs, under `--ui-accent-soft`.** The selected row and the
 *   selected chip paint the accent at 18% over the surface. The tint is not
 *   one of the tokens the ruling opened.
 * - **24 over 3 pairs, under an opacity the ruling did not open**:
 *   `.settings-gear` at 0.35 and 0.65, `.keyboard-toggle` at 0.75. The same
 *   change `.pane-close` just took would clear all 24: at full strength the
 *   three keys collapse into `--ui-text on --ui-bg + --ui-veil`, which already
 *   carries its one failing theme.
 * - **19 over 8 pairs, on `--ui-bg-sunken`.** The file preview. `--ui-bg-sunken`
 *   is a well, not a lift, and the ruling named four lifted tokens.
 * - **12 over 5 pairs, on `--ui-bg` itself.** Nothing but a theme's colours can
 *   move these.
 * - **11 over 4 pairs, on a `--ui-danger` or `--ui-warning` tint over
 *   `--ui-surface`.** The attention strip. The tint is not opened either.
 * - **3, on `--ui-border` used as a hover fill** by `.settings-close:hover`,
 *   `.settings-stepper button:hover` and `#search button:hover`.
 */
const KNOWN_BELOW: Record<string, Record<string, number>> = {
  "--code-comment on --ui-bg-sunken": {
    "solarized-dark": 3.22,
    "one-dark": 4.25,
    "synthwave-84": 2.98,
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
    "solarized-dark": 3.78,
    "synthwave-84": 3.48,
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
    "solarized-dark": 3.81,
    "nord": 4.30,
    "gruvbox-dark": 3.25,
  },
  "--ui-accent on --ui-surface + --ui-accent-soft": {
    "solarized-dark": 3.01,
    "nord": 3.24,
    "one-dark": 3.99,
    "tokyo-night-storm": 3.93,
    "catppuccin-macchiato": 4.33,
    "gruvbox-dark": 2.66,
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
    "solarized-dark": 2.79,
    "dracula": 3.87,
    "nord": 2.61,
    "one-dark": 3.74,
    "gruvbox-dark": 2.30,
    "monokai": 3.36,
    "synthwave-84": 3.84,
  },
  "--ui-text on --ui-active": {
    "solarized-dark": 3.46,
    "synthwave-84": 3.13,
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
    "solarized-dark": 3.74,
    "synthwave-84": 3.42,
  },
  "--ui-text on --ui-surface": {
    "solarized-dark": 4.43,
    "synthwave-84": 4.00,
  },
  "--ui-text on --ui-surface + --ui-accent-soft": {
    "solarized-dark": 3.50,
    "one-dark": 4.42,
    "synthwave-84": 2.53,
  },
  "--ui-text on --ui-surface + --ui-veil": {
    "synthwave-84": 4.29,
  },
  "--ui-text on --ui-surface-2": {
    "solarized-dark": 4.08,
    "synthwave-84": 3.71,
  },
  "--ui-text on color-mix(in srgb, --ui-danger 8%, --ui-surface)": {
    "solarized-dark": 4.34,
    "synthwave-84": 3.68,
  },
  "--ui-text on color-mix(in srgb, --ui-warning 10%, --ui-surface)": {
    "solarized-dark": 3.96,
    "synthwave-84": 3.10,
  },
  "--ui-text-faint on --ui-bg-sunken": {
    "solarized-dark": 3.22,
    "one-dark": 4.25,
    "synthwave-84": 2.98,
  },
  "--ui-text-faint on --ui-surface": {
    "github-dark-dimmed": 4.17,
    "solarized-dark": 2.87,
    "one-dark": 3.74,
    "synthwave-84": 2.63,
  },
  "--ui-text-faint on --ui-surface + --ui-accent-soft": {
    "github-dark-dimmed": 2.92,
    "solarized-dark": 2.27,
    "nord": 3.74,
    "one-dark": 2.71,
    "tokyo-night": 3.92,
    "tokyo-night-storm": 3.52,
    "catppuccin-mocha": 3.95,
    "catppuccin-macchiato": 3.67,
    "ayu-mirage": 3.28,
    "synthwave-84": 1.66,
    "rose-pine": 4.29,
  },
  "--ui-text-muted on --ui-bg": {
    "solarized-dark": 3.60,
    "synthwave-84": 3.31,
  },
  "--ui-text-muted on --ui-bg + --ui-accent-soft": {
    "github-dark-dimmed": 3.81,
    "solarized-dark": 2.82,
    "one-dark": 3.46,
    "ayu-mirage": 4.34,
    "synthwave-84": 2.09,
  },
  "--ui-text-muted on --ui-bg + --ui-veil": {
    "solarized-dark": 3.60,
    "synthwave-84": 3.31,
  },
  "--ui-text-muted on --ui-bg-sunken": {
    "solarized-dark": 3.78,
    "synthwave-84": 3.48,
  },
  "--ui-text-muted on --ui-hover": {
    "github-dark-dimmed": 4.33,
    "solarized-dark": 2.84,
    "one-dark": 3.81,
    "synthwave-84": 2.63,
  },
  "--ui-text-muted on --ui-surface": {
    "solarized-dark": 3.37,
    "one-dark": 4.49,
    "synthwave-84": 3.07,
  },
  "--ui-text-muted on --ui-surface-2": {
    "solarized-dark": 3.10,
    "one-dark": 4.11,
    "synthwave-84": 2.85,
  },
  "--ui-text-muted on color-mix(in srgb, --ui-danger 8%, --ui-surface)": {
    "solarized-dark": 3.30,
    "one-dark": 4.06,
    "synthwave-84": 2.83,
  },
  "--ui-text-muted on color-mix(in srgb, --ui-warning 10%, --ui-surface)": {
    "github-dark-dimmed": 4.39,
    "solarized-dark": 3.00,
    "one-dark": 3.60,
    "synthwave-84": 2.38,
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
