import { describe, expect, it } from "vitest";

import {
  type CssRule,
  contrastRatio,
  derivePairs,
  parseCss,
  ratioFor,
  readSource,
  resolveColor,
  rootVariables,
} from "./theme-contrast-derive";
import { themeTokens } from "./theme-tokens";
import { TERMINAL_THEMES } from "./themes";

/**
 * The foundation's proofs for the Markdown views (`markdown-preview` round
 * 3; `corpus/01-approved-design.md` rules 1 to 4, 8 and 13).
 *
 * The rendered rules live in `styles.css`, where `theme-contrast.test.ts`
 * already measures every pair they paint against every bundled theme. This
 * file pins what that ratchet does not: the `md-*` sizes and the measure
 * the foundation names as the one exception to its type scale, the tokens
 * each rule wears, the light value of the well, and the pairs of `md.css`,
 * the page's own sheet, which the frozen sheet list does not read.
 */

const STYLES = readSource("styles.css");
const MD = readSource("md.css");
const TOKENS = rootVariables(readSource("tokens.css"));
const RULES: CssRule[] = parseCss("styles.css", STYLES);

const root = RULES.find((rule) => rule.selector === ":root" && rule.decls.has("--md-body"));
/** The value in force for `property` on `selector`: the last rule of that
 * selector that sets it, as the cascade reads a sheet (the parser splits a
 * selector list into one rule per selector, so a heading's shared rule and
 * its own are two). */
const decl = (selector: string, property: string): string | undefined => {
  let value: string | undefined;
  for (const rule of RULES) if (rule.selector === selector && rule.decls.has(property)) value = rule.decls.get(property);
  return value;
};

describe("the md-* sizes, the one exception to the type scale", () => {
  it("names the five sizes and the measure as tokens", () => {
    expect(root, "a :root block with the md-* tokens").toBeDefined();
    expect(Object.fromEntries([...root!.decls].filter(([name]) => name.startsWith("--md-")))).toEqual({
      "--md-body": "14px",
      "--md-h1": "22px",
      "--md-h2": "17px",
      "--md-h3": "15px",
      "--md-code": "12.5px",
      "--md-measure": "72ch",
    });
  });

  it("sets prose in --font-ui at the body size and a line height of 1.6, at most 72 characters wide", () => {
    expect(decl(".md-body", "font")).toBe("400 var(--md-body)/1.6 var(--font-ui)");
    expect(decl(".md-body", "max-width")).toBe("var(--md-measure)");
    expect(MD).toMatch(/\.md-page-main\s*\{[^}]*max-width:\s*calc\(var\(--md-measure\)/);
    expect(MD).toMatch(/\.md-page-main\s*\{[^}]*margin:\s*0 auto/);
  });

  it("sets the headings at their sizes, semibold, with a hairline under h1 and h2", () => {
    expect(decl(".md-body h1", "font-size")).toBe("var(--md-h1)");
    expect(decl(".md-body h2", "font-size")).toBe("var(--md-h2)");
    expect(decl(".md-body h3", "font-size")).toBe("var(--md-h3)");
    expect(decl(".md-body h1", "border-bottom")).toBe("1px solid var(--ui-border)");
    expect(decl(".md-body h2", "border-bottom")).toBe("1px solid var(--ui-border)");
    for (const level of ["h1", "h2", "h3"]) expect(decl(`.md-body ${level}`, "font-weight"), level).toBe("600");
  });

  it("puts inline code on --ui-surface-2 and a code block on --ui-bg-sunken, each with a hairline", () => {
    expect(decl(".md-body code", "background")).toBe("var(--ui-surface-2)");
    expect(decl(".md-body code", "border")).toBe("1px solid var(--ui-border)");
    expect(decl(".md-body .md-code", "background")).toBe("var(--ui-bg-sunken)");
    expect(decl(".md-body .md-code", "border")).toBe("1px solid var(--ui-border)");
    expect(decl(".md-body th", "background")).toBe("var(--ui-surface-2)");
    expect(decl(".md-body blockquote", "border-left")).toBe("2px solid var(--ui-border)");
    expect(decl(".md-body blockquote", "color")).toBe("var(--ui-text-muted)");
    expect(decl(".md-body a", "color")).toBe("var(--ui-accent)");
    expect(decl(".md-body a", "text-decoration")).toBe("underline");
  });

  it("rounds no Markdown corner above 2 px", () => {
    for (const rule of RULES.filter((r) => r.selector.startsWith(".md-"))) {
      const radius = rule.decls.get("border-radius");
      if (radius !== undefined) expect(radius, rule.selector).toMatch(/^(0|2px)$/);
    }
  });
});

describe("the well on a light theme", () => {
  const paletteFor = (background: string, foreground: string): Map<string, string> =>
    new Map([...TOKENS, ...Object.entries(themeTokens({ background, foreground }))]);
  const luminance = (c: { r: number; g: number; b: number }): number => {
    const lin = (v: number): number => (v / 255 <= 0.04045 ? v / 255 / 12.92 : ((v / 255 + 0.055) / 1.055) ** 2.4);
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
  };

  it("is a light grey under dark text, a step under the page, and keeps its dark value on a dark theme", () => {
    const light = paletteFor("#f6f8fa", "#1f2328");
    const well = resolveColor("var(--ui-bg-sunken)", light);
    const page = resolveColor("var(--ui-bg)", light);
    const surface2 = resolveColor("var(--ui-surface-2)", light);
    expect(luminance(well)).toBeGreaterThan(0.6);
    expect(luminance(well)).toBeLessThan(luminance(surface2));
    expect(luminance(well)).toBeLessThan(luminance(page));
    // Dark text, every token's own colour and every syntax colour clear
    // 4.5:1 on it, the floor the ratchet holds on a dark theme.
    for (const token of ["--ui-text", "--ui-text-muted", "--ui-text-faint"]) {
      expect(contrastRatio(resolveColor(`var(${token})`, light), well), token).toBeGreaterThanOrEqual(4.5);
    }
    const dark = paletteFor("#0d1117", "#e6edf3");
    const darkWell = resolveColor("var(--ui-bg-sunken)", dark);
    expect(luminance(darkWell)).toBeLessThan(0.01);
    // The dark value is the one the ratchet always measured.
    expect(darkWell).toEqual(resolveColor("color-mix(in oklab, var(--ui-bg) 25%, black)", dark));
  });

  it("reads light-dark() by the lift the theme layer publishes", () => {
    const vars = new Map<string, string>([["--ui-lift", "#000"]]);
    expect(resolveColor("light-dark(#ffffff, #000000)", vars)).toEqual({ r: 255, g: 255, b: 255, a: 1 });
    vars.set("--ui-lift", "#fff");
    expect(resolveColor("light-dark(#ffffff, #000000)", vars)).toEqual({ r: 0, g: 0, b: 0, a: 1 });
    expect(resolveColor("light-dark(#ffffff, #000000)", new Map())).toEqual({ r: 0, g: 0, b: 0, a: 1 });
  });
});

describe("md.css, the page's own sheet", () => {
  const palette = (theme: (typeof TERMINAL_THEMES)[number]): Map<string, string> =>
    new Map([...TOKENS, ...Object.entries(themeTokens(theme.colors, { accent: theme.accent }))]);
  const { pairs, holes } = derivePairs([["md.css", MD]], palette(TERMINAL_THEMES[0]));

  it("places every text rule", () => {
    expect(holes.map((h) => `${h.sheet}:${h.line} ${h.selector} — ${h.why}`)).toEqual([]);
    expect(pairs.length).toBeGreaterThan(0);
  });

  /** The pairs under the floor, by theme, with the ratio they read: the
   * theme's own foreground on its own ground, which `theme-contrast.test.ts`
   * lists for the same two themes and which only the theme could move. The
   * list is a ratchet like that one: an entry may go and may not grow. */
  const KNOWN_BELOW: Record<string, Record<string, number>> = {
    "--ui-text on --ui-bg": { "synthwave-84": 4.32 },
    "--ui-text-muted on --ui-bg": { "solarized-dark": 3.61, "synthwave-84": 3.32 },
  };

  it("clears 4.5:1 on every bundled theme, but the pairs the theme itself holds under it", () => {
    const seen: string[] = [];
    for (const theme of TERMINAL_THEMES) {
      const vars = palette(theme);
      for (const pair of pairs) {
        const ratio = ratioFor(pair, vars);
        const known = KNOWN_BELOW[pair.key]?.[theme.id];
        const where = `${pair.key} on ${theme.id} (${pair.rules[0]})`;
        if (known === undefined) {
          expect(ratio, `${where} dropped under ${pair.floor}:1`).toBeGreaterThanOrEqual(pair.floor);
          continue;
        }
        seen.push(`${pair.key}@${theme.id}`);
        expect(ratio, `${where} got worse than its entry`).toBeGreaterThanOrEqual(known - 0.005);
        expect(ratio, `${where} now passes; drop its entry`).toBeLessThan(pair.floor);
        expect(Math.abs(ratio - known), `${where} reads ${ratio.toFixed(2)}; re-record the entry`).toBeLessThan(0.01);
      }
    }
    // Every entry is measured, so a stale one cannot hide.
    const listed = Object.entries(KNOWN_BELOW).flatMap(([key, themes]) => Object.keys(themes).map((t) => `${key}@${t}`));
    expect(seen.sort()).toEqual(listed.sort());
  });

  it("uses the shared tokens and no bare colour", () => {
    for (const rule of parseCss("md.css", MD)) {
      for (const [name, value] of rule.decls) {
        if (name === "color" || name === "background" || name.startsWith("border")) {
          expect(value, `${rule.selector} ${name}`).not.toMatch(/#[0-9a-f]{3,8}\b/i);
        }
      }
    }
  });
});
