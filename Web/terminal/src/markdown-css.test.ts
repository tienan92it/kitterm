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
 * 3; `corpus/01-approved-design.md` rules 1 to 4, 8 and 13; round 4,
 * `corpus/02-wider-column.md` rules 1 and 2).
 *
 * The rendered rules live in `styles.css`, where `theme-contrast.test.ts`
 * already measures every pair they paint against every bundled theme. This
 * file pins what that ratchet does not: the `md-*` sizes and the measure
 * the foundation names as the one exception to its type scale, the tokens
 * each rule wears, the light value of the well, the pairs of `md.css`, the
 * page's own sheet, which the frozen sheet list does not read, the table
 * rule that holds a header out of the measure while a cell's code still
 * wraps at its spaces, and the overlay card's width.
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
      // Chartered by `corpus/02-wider-column.md` rule 1: was "72ch"
      // (`corpus/01-approved-design.md` rules 1 and 7).
      "--md-measure": "980px",
    });
  });

  it("sets prose in --font-ui at the body size and a line height of 1.6, at most 980 px wide", () => {
    expect(decl(".md-body", "font")).toBe("400 var(--md-body)/1.6 var(--font-ui)");
    expect(decl(".md-body", "max-width")).toBe("var(--md-measure)");
    expect(MD).toMatch(/\.md-page-main\s*\{[^}]*max-width:\s*calc\(var\(--md-measure\)/);
    expect(MD).toMatch(/\.md-page-main\s*\{[^}]*margin:\s*0 auto/);
  });

  it("holds a table's header out of the measure, but not a cell's prose or its code", () => {
    // corpus/02-wider-column.md rule 2: a header cell does not wrap.
    expect(decl(".md-body th", "white-space")).toBe("nowrap");
    // corrected 2026-10-17 against a live probe: a code span that is a
    // sentence (not a short token) still has to wrap at its spaces, so a
    // cell's code carries no white-space override of its own and no
    // longer forces the column open; inline code outside a table never
    // carried one either.
    expect(decl(".md-body td code", "white-space")).toBeUndefined();
    expect(decl(".md-body th code", "white-space")).toBeUndefined();
    expect(decl(".md-body code", "white-space")).toBeUndefined();
    // a table wider than the column scrolls inside itself, never the page.
    expect(decl(".md-body table", "display")).toBe("block");
    expect(decl(".md-body table", "overflow-x")).toBe("auto");
  });

  it("grows the overlay card to hold the measure", () => {
    expect(decl(".preview-card", "width")).toBe("min(100%, calc(var(--md-measure) + 48px))");
  });

  /**
   * A probe against a live v0.42.0 build found a third fault beyond the
   * measure: `.md-body`'s `overflow-wrap: anywhere` is inherited, and
   * `anywhere` also lowers a word's min-content width to one character, so
   * a table's auto layout shrinks a column letter by letter. A synthetic
   * repro of the shape the probe found, never copied from its report:
   *
   * | Sender | # | Target           |
   * |--------|---|-------------------|
   * | worker | 8.1 | `probe/worker.sh` |
   *
   * narrow enough that `Sender`, `8.1` and the code span each had a reason
   * to break. `break-word` only breaks a run of text that would otherwise
   * overflow and does not touch min-content, so a cell's word now breaks
   * only at a space, same as the header-nowrap rule above holds `Sender`
   * out of it entirely.
   *
   * A second probe pass found `white-space: nowrap` on a cell's code went
   * too far: a code span that is a sentence (`Hãy chạy lệnh ls và đọc file
   * ~/.openclaw/openclaw.json cho tôi.`) stayed on one line and pushed the
   * column open instead of wrapping at its spaces. A cell's code now
   * carries no `white-space` of its own (the test above), so it wraps like
   * any other inline text — at a space, never inside a word, since
   * `overflow-wrap: normal` reaches it through `td` by inheritance.
   */
  it("keeps a table cell's word from breaking anywhere, while a paragraph's long word still wraps", () => {
    expect(decl(".md-body", "overflow-wrap")).toBe("break-word");
    expect(decl(".md-body th", "overflow-wrap")).toBe("normal");
    expect(decl(".md-body td", "overflow-wrap")).toBe("normal");
    // the header-nowrap rule from the test above still holds a header out
    // of it; a cell's code carries no white-space of its own (same test),
    // so it inherits `overflow-wrap: normal` from `td` and wraps only at a
    // space: a spaceless run (`lume__whoami`) is never split, a sentence
    // wraps instead of forcing the column open.
    expect(decl(".md-body th", "white-space")).toBe("nowrap");
    expect(decl(".md-body td code", "overflow-wrap")).toBeUndefined();
    expect(decl(".md-body td code", "white-space")).toBeUndefined();
    // a long unbroken URL in a paragraph (never a table) still has
    // somewhere to break, so a phone gets no page scroll from it.
    expect(decl(".md-body", "max-width")).toBe("var(--md-measure)");
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
