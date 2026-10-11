import { describe, expect, it } from "vitest";

import { type CssRule, contrastRatio, parseCss, readSource, resolveColor, rootVariables } from "./theme-contrast-derive";
import { themeTokens } from "./theme-tokens";
import { TERMINAL_THEMES } from "./themes";

/**
 * The data palette's own coverage (`value-lifetime`, capability 4;
 * `design/foundation.md`, "Data palette"): `--ui-data-1` to `--ui-data-4`
 * are marks, like the five owned colours before them, so
 * `theme-contrast-derive.ts`'s automatic pair derivation does not see them
 * — a mark paints through `background` and `background-clip: text`, never
 * `color`, and the token itself lives in `sessions.css`'s own `:root`
 * block, not `tokens.css`'s, so it is outside the `vars` map
 * `theme-contrast.test.ts` builds for the pages' ordinary text. This file
 * measures the four tokens directly, the way `sessions-css.test.ts`
 * already reads `sessions.css`'s `:root` layer for the five owned colours
 * and the two mark sizes.
 */

const SOURCE = readSource("sessions.css");
const RULES: CssRule[] = parseCss("sessions.css", SOURCE);
const ROOT = RULES.filter((rule) => rule.selector === ":root" && rule.conditions.length === 0);
const token = (name: string): string => {
  const value = ROOT.map((rule) => rule.decls.get(name)).find((v) => v !== undefined);
  if (value === undefined) throw new Error(`${name} is not defined in sessions.css's :root`);
  return value;
};

const DATA_TOKENS = ["--ui-data-1", "--ui-data-2", "--ui-data-3", "--ui-data-4"] as const;

/** The light and the dark half of a `light-dark(light, dark)` token, the
 * same shape `sessions-css.test.ts`'s `darkOf` reads. */
const lightDarkParts = (value: string): { light: string; dark: string } => {
  const m = /^light-dark\((#[0-9a-f]{6}),\s*(#[0-9a-f]{6})\)$/i.exec(value);
  if (!m) throw new Error(`not a light-dark() pair: ${value}`);
  return { light: m[1], dark: m[2] };
};

describe("the data palette is defined as light-dark() pairs, one per measure", () => {
  it("names four tokens, each a 6-digit hex pair", () => {
    for (const name of DATA_TOKENS) expect(() => lightDarkParts(token(name))).not.toThrow();
  });

  it("matches the four values design/foundation.md's Data palette table carries", () => {
    expect(DATA_TOKENS.map((name) => lightDarkParts(token(name)))).toEqual([
      { light: "#11866c", dark: "#04c7a0" },
      { light: "#9c6d1a", dark: "#f7ab07" },
      { light: "#446fe2", dark: "#5582f7" },
      { light: "#e40784", dark: "#fe2497" },
    ]);
  });
});

describe("a .mark.data-N rule paints each token as a background, clipped to the glyph", () => {
  const markRule = (selector: string): CssRule | undefined => RULES.find((r) => r.selector === selector);

  it("paints the four backgrounds", () => {
    expect(DATA_TOKENS.map((_, i) => markRule(`.mark.data-${i + 1}`)?.decls.get("background"))).toEqual(
      DATA_TOKENS.map((name) => `var(${name})`),
    );
  });

  it("clips every data mark's background to its glyph, beside the five owned colours", () => {
    // `parseCss` splits a selector list into one rule per selector, so the
    // one declaration block that clips every mark's background shows up as
    // four rules here, one per `.mark.data-N`, all with the same decls.
    const clipped = RULES.filter((r) => /^\.mark\.data-[1-4]$/.test(r.selector) && r.decls.get("background-clip") === "text");
    expect(clipped.map((r) => r.selector)).toEqual([".mark.data-1", ".mark.data-2", ".mark.data-3", ".mark.data-4"]);
  });
});

const TOKENS = rootVariables(readSource("tokens.css"));

describe("no stylesheet rule claims to size .lifetime-legend-swatch (corpus/05-legend-and-range.md)", () => {
  it("leaves its width to the inline style script sets, since .mark.bar's own width: 0 outranks one class", () => {
    // A single-class selector cannot outrank `.mark.bar`'s two classes, the
    // same reason the tooltip's own swatch sets its 8px inline rather than
    // in the stylesheet (`sessions-lifetime-page.test.ts` pins the inline
    // value on both swatches).
    const rule = RULES.find((r) => r.selector === ".lifetime-legend-swatch" && r.decls.has("width"));
    expect(rule).toBeUndefined();
  });
});

describe("the chart block keeps a right inset, mirroring the tick column on the left (round 8)", () => {
  it("gives .lifetime-chart-block a padding-right of --lifetime-tick-col, so the axis end date never sits flush against the panel's edge", () => {
    // Round 7 widened the plot to fill the whole panel once the end-label
    // column went away; with no right inset the axis's own end date (e.g.
    // `11 Oct`) sat exactly on the panel's right edge and read as cut off.
    // A real-browser check on a scratch daemon confirms the fix: the text
    // now ends 28px (24px at 390) inside the panel, the fake DOM here has
    // no layout engine to pin that measurement itself.
    const rule = RULES.find((r) => r.selector === ".lifetime-chart-block" && r.decls.has("padding-right"));
    expect(rule?.decls.get("padding-right")).toBe("var(--lifetime-tick-col)");
  });
});

describe("each dark value clears the mark floor, 3:1, against every bundled theme's ground", () => {
  // All 17 bundled themes are dark (facts.md); the light half is the human's
  // own measurement in design/foundation.md ("the full range is 4.50 to
  // 10.11"), not retested here for lack of a bundled light theme to measure
  // it against — the same gap the five owned colours already have.
  const MARK_FLOOR = 3;
  for (const theme of TERMINAL_THEMES) {
    it(`${theme.id}`, () => {
      const vars = new Map([...TOKENS, ...Object.entries(themeTokens(theme.colors, { accent: theme.accent }))]);
      const bg = resolveColor("var(--ui-bg)", vars);
      for (const name of DATA_TOKENS) {
        const { dark } = lightDarkParts(token(name));
        const ratio = contrastRatio(resolveColor(dark, vars), bg);
        expect(ratio, `${name} (${dark}) on --ui-bg for ${theme.id}: ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(MARK_FLOOR);
      }
    });
  }
});
