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
 * `KNOWN_BELOW` is a ratchet, not an escape hatch. It names every pair under
 * its floor today, by theme, with the ratio it reads and the surface that
 * holds it there. The list can shrink and it cannot grow. `check` below holds
 * that in four directions:
 *
 * - an unlisted pair that misses its floor fails, named by file, line and
 *   selector;
 * - a listed pair that reaches its floor fails until its entry goes;
 * - a listed pair that reads lower than its entry fails, so nothing listed
 *   gets worse;
 * - a listed pair that reads higher than its entry fails until the entry is
 *   re-recorded, so an entry is always the measured ratio and the floor it
 *   holds is the best one measured.
 *
 * Two tests keep the list itself honest: every entry names a bundled theme,
 * and every entry's `blocker` is the group its surface puts it in. Round 3
 * proved that no lever the goal allows can empty the list; most of what is
 * left is a theme's own foreground on its own background, which the goal does
 * not change. The human ruled on 2026-09-11 that the list is a ratchet, and
 * every entry now says what would clear it, or that only the theme could.
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
 * The surface that holds an entry under its floor, and the lever that would
 * move it. The six groups are the ones `rounds/003.md` measured; they are
 * exclusive and `blockerOf` assigns each pair to exactly one, from its stack.
 * The counts are what each lever reaches at its extreme, measured on
 * 2026-09-11 with the arithmetic `ratioFor` uses, so a reader can tell an
 * entry that waits on work from one that is permanent. Of the 84 entries the
 * levers reach 18; the other 72 fail on the bare surface too, so only the
 * theme's own colours could move them, and the goal does not change those.
 */
type Blocker =
  /**
   * 33 over 11 pairs, on `--ui-surface`, `--ui-surface-2`, `--ui-hover` or
   * `--ui-active`. The lever is the elevation of the four tokens, which round
   * 3 settled at 3/6/9/12 percent of `--ui-lift`. With all four at `--ui-bg`
   * itself, 10 clear and 23 fail on `--ui-bg` too.
   */
  | "elevated"
  /**
   * 19 over 6 pairs, under `--ui-accent-soft`, the accent tint of the
   * selected row and the selected chip. Round 6 opened the tint: the accent
   * is darkened 65% toward black and laid on at 14%, which cleared 13. Of the
   * 19 left, 14 fail on the bare surface too, and 5 clear bare by 0.13 to
   * 0.47, which no tint the eye can see leaves room for: every construction
   * that clears them reads under ΔE 0.01 on nord and gruvbox-dark.
   */
  | "accent-soft"
  /**
   * 6 over 4 pairs, on `--ui-bg-sunken`, the file preview's well. Round 7
   * sank it from 94% to 25% `--ui-bg` toward black, which is black on every
   * bundled theme, and 13 cleared. The 6 left fail on black itself, so only
   * the theme's own colours could move them.
   */
  | "sunken"
  /**
   * 12 over 5 pairs, on `--ui-bg` itself (`--ui-veil` over `--ui-bg` is
   * `--ui-bg`). Only the theme's own colours could move these.
   */
  | "bg"
  /**
   * 11 over 4 pairs, on the danger or warning tint the attention strip paints
   * over `--ui-surface`. The lever is the tint, which no ruling has opened.
   * Without it 1 clears and 10 fail on `--ui-surface` too.
   */
  | "tint"
  /**
   * 3 over 1 pair, `--ui-border` used as a hover fill by
   * `.settings-close:hover`, `.settings-stepper button:hover` and
   * `#search button:hover`. The lever is a different fill: at `--ui-bg` 2
   * clear and synthwave-84 fails on `--ui-bg` too.
   */
  | "border-fill";

const ELEVATED = ["var(--ui-surface)", "var(--ui-surface-2)", "var(--ui-hover)", "var(--ui-active)"];

/** The group a surface stack belongs to, or `undefined` for a surface no group names. */
const blockerOf = (stack: string[]): Blocker | undefined => {
  const [base, ...over] = stack;
  if (over.some((layer) => layer.includes("--ui-accent-soft"))) return "accent-soft";
  if (base.includes("--ui-danger") || base.includes("--ui-warning")) return "tint";
  if (base === "var(--ui-bg-sunken)") return "sunken";
  if (base === "var(--ui-border)") return "border-fill";
  if (ELEVATED.includes(base)) return "elevated";
  if (base === "var(--ui-bg)") return "bg";
  return undefined;
};

interface Below {
  /** The group the pair's surface puts it in; `blockerOf` checks it. */
  blocker: Blocker;
  /** Theme id to the ratio the pair reads there, floored to two places. */
  themes: Record<string, number>;
}

/**
 * Ratios under the floor today, by pair and theme, measured by this file.
 * Pair first, because a token change clears part of a row. The comment on
 * each pair says which themes its lever reaches and which fail without the
 * blocker too.
 *
 * 84 entries over 31 pairs. The list read 273 after round 1 derived it, 178
 * after round 2 raised the two muted tokens, 134 after round 3 lowered the
 * elevation, 110 after round 5 opened the three opacities round 3 left
 * alone (`.settings-gear` at 0.35 and 0.65 and `.keyboard-toggle` at 0.75;
 * those three pairs went whole, 24 entries, and their keys collapsed into
 * `--ui-text on --ui-bg + --ui-veil`, which already carried synthwave-84),
 * 97 after round 6 darkened `--ui-accent-soft`, and 84 after round 7 sank
 * `--ui-bg-sunken` to black (four pairs went whole). No ratio fell and no new
 * entry appeared.
 */
const KNOWN_BELOW: Record<string, Below> = {
  "--code-comment on --ui-bg-sunken": {
    blocker: "sunken",
    // The well is black; solarized-dark and synthwave-84 fail even there, so
    // only the theme's own colours could move them.
    themes: {
      "solarized-dark": 4.27,
      "synthwave-84": 3.89,
    },
  },
  "--code-error on --ui-bg-sunken": {
    blocker: "sunken",
    // The well is black; gruvbox-dark fails even there, so only the theme's
    // own colours could move it.
    themes: {
      "gruvbox-dark": 3.81,
    },
  },
  "--code-string on --ui-bg-sunken": {
    blocker: "sunken",
    // The well is black; rose-pine fails even there, so only the theme's own
    // colours could move it.
    themes: {
      "rose-pine": 4.01,
    },
  },
  "--ui-accent on --ui-bg + --ui-accent-soft": {
    blocker: "accent-soft",
    // nord clears bare by 0.13, and no tint it can see leaves that room;
    // solarized-dark and gruvbox-dark fail on the bare surface too.
    themes: {
      "solarized-dark": 3.72,
      "nord": 4.17,
      "gruvbox-dark": 3.23,
    },
  },
  "--ui-accent on --ui-surface": {
    blocker: "elevated",
    // At --ui-bg itself the pair clears nord; solarized-dark and gruvbox-dark
    // fail on --ui-bg too.
    themes: {
      "solarized-dark": 3.81,
      "nord": 4.30,
      "gruvbox-dark": 3.25,
    },
  },
  "--ui-accent on --ui-surface + --ui-accent-soft": {
    blocker: "accent-soft",
    // solarized-dark, nord and gruvbox-dark fail on the bare surface too; only
    // the theme's own colours could move them.
    themes: {
      "solarized-dark": 3.50,
      "nord": 3.90,
      "gruvbox-dark": 3.04,
    },
  },
  "--ui-danger on --ui-bg": {
    blocker: "bg",
    // Only the theme's own colours could move this.
    themes: {
      "solarized-dark": 3.24,
      "nord": 3.05,
      "one-dark": 4.38,
      "gruvbox-dark": 2.69,
      "monokai": 3.92,
      "synthwave-84": 4.45,
    },
  },
  "--ui-danger on --ui-surface-2": {
    blocker: "elevated",
    // At --ui-bg itself the pair clears dracula; solarized-dark, nord,
    // one-dark, gruvbox-dark, monokai and synthwave-84 fail on --ui-bg too.
    themes: {
      "solarized-dark": 2.79,
      "dracula": 3.87,
      "nord": 2.61,
      "one-dark": 3.74,
      "gruvbox-dark": 2.30,
      "monokai": 3.36,
      "synthwave-84": 3.84,
    },
  },
  "--ui-text on --ui-active": {
    blocker: "elevated",
    // At --ui-bg itself the pair clears solarized-dark; synthwave-84 fails on
    // --ui-bg too.
    themes: {
      "solarized-dark": 3.46,
      "synthwave-84": 3.13,
    },
  },
  "--ui-text on --ui-bg": {
    blocker: "bg",
    // Only the theme's own colours could move this.
    themes: {
      "synthwave-84": 4.31,
    },
  },
  "--ui-text on --ui-bg + --ui-accent-soft": {
    blocker: "accent-soft",
    // solarized-dark clears bare by 0.24, and no tint it can see leaves that
    // room; synthwave-84 fails on the bare surface too.
    themes: {
      "solarized-dark": 4.33,
      "synthwave-84": 3.57,
    },
  },
  "--ui-text on --ui-bg + --ui-veil": {
    blocker: "bg",
    // Only the theme's own colours could move this.
    themes: {
      "synthwave-84": 4.31,
    },
  },
  "--ui-text on --ui-border": {
    blocker: "border-fill",
    // A fill of --ui-bg would clear solarized-dark and one-dark; synthwave-84
    // fails on --ui-bg too.
    themes: {
      "solarized-dark": 2.87,
      "one-dark": 3.98,
      "synthwave-84": 2.61,
    },
  },
  "--ui-text on --ui-hover": {
    blocker: "elevated",
    // At --ui-bg itself the pair clears solarized-dark; synthwave-84 fails on
    // --ui-bg too.
    themes: {
      "solarized-dark": 3.74,
      "synthwave-84": 3.42,
    },
  },
  "--ui-text on --ui-surface": {
    blocker: "elevated",
    // At --ui-bg itself the pair clears solarized-dark; synthwave-84 fails on
    // --ui-bg too.
    themes: {
      "solarized-dark": 4.43,
      "synthwave-84": 4.00,
    },
  },
  "--ui-text on --ui-surface + --ui-accent-soft": {
    blocker: "accent-soft",
    // solarized-dark and synthwave-84 fail on the bare surface too; only the
    // theme's own colours could move them.
    themes: {
      "solarized-dark": 4.08,
      "synthwave-84": 3.32,
    },
  },
  "--ui-text on --ui-surface + --ui-veil": {
    blocker: "elevated",
    // synthwave-84 fails on --ui-bg too; only the theme's own colours could
    // move it.
    themes: {
      "synthwave-84": 4.29,
    },
  },
  "--ui-text on --ui-surface-2": {
    blocker: "elevated",
    // At --ui-bg itself the pair clears solarized-dark; synthwave-84 fails on
    // --ui-bg too.
    themes: {
      "solarized-dark": 4.08,
      "synthwave-84": 3.71,
    },
  },
  "--ui-text on color-mix(in srgb, --ui-danger 8%, --ui-surface)": {
    blocker: "tint",
    // solarized-dark and synthwave-84 fail on --ui-surface too; only the
    // theme's own colours could move it.
    themes: {
      "solarized-dark": 4.34,
      "synthwave-84": 3.68,
    },
  },
  "--ui-text on color-mix(in srgb, --ui-warning 10%, --ui-surface)": {
    blocker: "tint",
    // solarized-dark and synthwave-84 fail on --ui-surface too; only the
    // theme's own colours could move it.
    themes: {
      "solarized-dark": 3.96,
      "synthwave-84": 3.10,
    },
  },
  "--ui-text-faint on --ui-bg-sunken": {
    blocker: "sunken",
    // The well is black; solarized-dark and synthwave-84 fail even there, so
    // only the theme's own colours could move them.
    themes: {
      "solarized-dark": 4.27,
      "synthwave-84": 3.89,
    },
  },
  "--ui-text-faint on --ui-surface": {
    blocker: "elevated",
    // github-dark-dimmed, solarized-dark, one-dark and synthwave-84 fail on
    // --ui-bg too; only the theme's own colours could move it.
    themes: {
      "github-dark-dimmed": 4.17,
      "solarized-dark": 2.87,
      "one-dark": 3.74,
      "synthwave-84": 2.63,
    },
  },
  "--ui-text-faint on --ui-surface + --ui-accent-soft": {
    blocker: "accent-soft",
    // tokyo-night-storm and ayu-mirage clear bare by 0.34 and 0.47, and no
    // tint they can see leaves that room; github-dark-dimmed, solarized-dark,
    // one-dark and synthwave-84 fail on the bare surface too.
    themes: {
      "github-dark-dimmed": 3.62,
      "solarized-dark": 2.64,
      "one-dark": 3.31,
      "tokyo-night-storm": 4.28,
      "ayu-mirage": 4.19,
      "synthwave-84": 2.18,
    },
  },
  "--ui-text-muted on --ui-bg": {
    blocker: "bg",
    // Only the theme's own colours could move this.
    themes: {
      "solarized-dark": 3.60,
      "synthwave-84": 3.31,
    },
  },
  "--ui-text-muted on --ui-bg + --ui-accent-soft": {
    blocker: "accent-soft",
    // one-dark clears bare by 0.32, and no tint it can see leaves that room;
    // solarized-dark and synthwave-84 fail on the bare surface too.
    themes: {
      "solarized-dark": 3.29,
      "one-dark": 4.23,
      "synthwave-84": 2.74,
    },
  },
  "--ui-text-muted on --ui-bg + --ui-veil": {
    blocker: "bg",
    // Only the theme's own colours could move this.
    themes: {
      "solarized-dark": 3.60,
      "synthwave-84": 3.31,
    },
  },
  "--ui-text-muted on --ui-hover": {
    blocker: "elevated",
    // At --ui-bg itself the pair clears github-dark-dimmed and one-dark;
    // solarized-dark and synthwave-84 fail on --ui-bg too.
    themes: {
      "github-dark-dimmed": 4.33,
      "solarized-dark": 2.84,
      "one-dark": 3.81,
      "synthwave-84": 2.63,
    },
  },
  "--ui-text-muted on --ui-surface": {
    blocker: "elevated",
    // At --ui-bg itself the pair clears one-dark; solarized-dark and
    // synthwave-84 fail on --ui-bg too.
    themes: {
      "solarized-dark": 3.37,
      "one-dark": 4.49,
      "synthwave-84": 3.07,
    },
  },
  "--ui-text-muted on --ui-surface-2": {
    blocker: "elevated",
    // At --ui-bg itself the pair clears one-dark; solarized-dark and
    // synthwave-84 fail on --ui-bg too.
    themes: {
      "solarized-dark": 3.10,
      "one-dark": 4.11,
      "synthwave-84": 2.85,
    },
  },
  "--ui-text-muted on color-mix(in srgb, --ui-danger 8%, --ui-surface)": {
    blocker: "tint",
    // solarized-dark, one-dark and synthwave-84 fail on --ui-surface too; only
    // the theme's own colours could move it.
    themes: {
      "solarized-dark": 3.30,
      "one-dark": 4.06,
      "synthwave-84": 2.83,
    },
  },
  "--ui-text-muted on color-mix(in srgb, --ui-warning 10%, --ui-surface)": {
    blocker: "tint",
    // Without the tint the pair clears github-dark-dimmed; solarized-dark,
    // one-dark and synthwave-84 fail on --ui-surface too.
    themes: {
      "github-dark-dimmed": 4.39,
      "solarized-dark": 3.00,
      "one-dark": 3.60,
      "synthwave-84": 2.38,
    },
  },
};

/** The two-place floor an entry records. */
const floor2 = (ratio: number): number => Math.floor(ratio * 100) / 100;

const check = (pair: Pair, theme: string, ratio: number): void => {
  const known = KNOWN_BELOW[pair.key]?.themes[theme];
  const where = `${pair.key} on ${theme}; first written at ${pair.rules[0]}`;
  if (known === undefined) {
    expect(ratio, `${where} dropped under ${pair.floor}:1`).toBeGreaterThanOrEqual(pair.floor);
    return;
  }
  expect(ratio, `${where} got worse than its KNOWN_BELOW entry`).toBeGreaterThanOrEqual(known);
  expect(ratio, `${where} now passes; drop its KNOWN_BELOW entry`).toBeLessThan(pair.floor);
  expect(
    floor2(ratio),
    `${where} reads ${floor2(ratio)} and its KNOWN_BELOW entry says ${known}; re-record the entry at what it reads`,
  ).toBeLessThanOrEqual(known);
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

  it("names a bundled theme in every KNOWN_BELOW entry", () => {
    // An entry for a theme that is not bundled is never measured, so it can
    // neither bite nor be dropped.
    const ids = new Set<string>(TERMINAL_THEMES.map((t) => t.id));
    const stray = Object.entries(KNOWN_BELOW).flatMap(([key, { themes }]) =>
      Object.keys(themes)
        .filter((id) => !ids.has(id))
        .map((id) => `${key}: ${id}`),
    );
    expect(stray, "fix the theme id, or drop the entry").toEqual([]);
  });

  it("gives every KNOWN_BELOW entry the blocker its surface puts it in", () => {
    const wrong = pairs
      .filter((p) => KNOWN_BELOW[p.key] !== undefined)
      .filter((p) => blockerOf(p.stack) !== KNOWN_BELOW[p.key].blocker)
      .map(
        (p) =>
          `${p.key}: says ${KNOWN_BELOW[p.key].blocker}, the surface gives ${blockerOf(p.stack) ?? "no group; add a Blocker that names its lever"}`,
      );
    expect(wrong).toEqual([]);
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
