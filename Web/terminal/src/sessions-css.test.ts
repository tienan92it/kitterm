import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { type CssRule, parseCss } from "./theme-contrast-derive";

/**
 * The fleet view's surface is the terminal's (`fleet-catch-up`, capability
 * 4). Four absences hold it there, each pinned by one case below: no
 * `border-radius` above 2 px, no `box-shadow` other than a hairline, no
 * `color-mix` tint behind text, and no `transition`.
 *
 * The sheet is read with `node:fs`, the way `theme-contrast-derive.ts`
 * reads it: vitest's `css-disable` plugin turns a `?raw` import of a
 * stylesheet into an empty string, and an empty sheet would pass every
 * absence.
 */
const SOURCE = readFileSync(new URL("./sessions.css", import.meta.url), "utf8");
const RULES: CssRule[] = parseCss("sessions.css", SOURCE);

/** `sessions.css:12 .card` for a failure message. */
const at = (rule: CssRule): string => `${rule.sheet}:${rule.line} ${rule.selector}`;

/** Every `(where, property, value)` whose property matches. */
const declarations = (matches: (property: string) => boolean): Array<[string, string, string]> =>
  RULES.flatMap((rule) =>
    [...rule.decls].filter(([name]) => matches(name)).map(([name, value]) => [at(rule), name, value] as [string, string, string]),
  );

/** The lengths a value carries, in px; `null` for one that is not a plain
 * px length (a `var()`, a percentage, a keyword), which no absence allows. */
const lengths = (value: string): Array<number | null> =>
  value
    .replace(/\/.*$/, "")
    .split(/\s+/)
    .filter((part) => part !== "")
    .map((part) => {
      if (part === "0") return 0;
      const px = /^(-?[\d.]+)px$/.exec(part);
      return px ? Number(px[1]) : null;
    });

describe("sessions.css is the terminal's surface", () => {
  it("parses the sheet it pins", () => {
    // An empty read would satisfy every absence below.
    expect(RULES.length).toBeGreaterThan(50);
  });

  it("rounds no corner by more than 2 px", () => {
    const rounded = declarations((p) => p.startsWith("border-") && p.endsWith("radius"))
      .filter(([, , value]) => lengths(value).some((px) => px === null || px > 2))
      .map(([where, name, value]) => `${where} ${name}: ${value}`);
    expect(rounded, "a pill or a card corner; the surface is square").toEqual([]);
  });

  it("casts no shadow other than a hairline", () => {
    // A hairline is one layer, no blur, and every offset and spread within
    // 1 px: the edge a fill used to carry. Anything softer is elevation.
    const soft = declarations((p) => p === "box-shadow")
      .filter(([, , value]) => {
        if (value.trim() === "none") return false;
        const layers = value.split(/,(?![^(]*\))/);
        if (layers.length !== 1) return true;
        const parts = layers[0].replace(/\binset\b/, "").trim().split(/\s+/);
        const offsets = parts.filter((part) => /^-?[\d.]+(px)?$/.test(part)).map((part) => Number.parseFloat(part));
        // x, y, blur, spread: the blur is the third and must be 0.
        if (offsets.length < 2 || offsets.length > 4) return true;
        if (offsets.length >= 3 && offsets[2] !== 0) return true;
        return offsets.some((px) => Math.abs(px) > 1);
      })
      .map(([where, , value]) => `${where} box-shadow: ${value}`);
    expect(soft, "a shadow that is not a 1 px edge").toEqual([]);
  });

  it("tints no surface behind text with color-mix", () => {
    const tinted = declarations((p) => p === "background" || p === "background-color" || p === "background-image")
      .filter(([, , value]) => value.includes("color-mix("))
      .map(([where, name, value]) => `${where} ${name}: ${value}`);
    expect(tinted, "a tint behind text; the state's colour goes on the gutter mark").toEqual([]);
  });

  it("animates nothing", () => {
    const animated = declarations((p) => p.startsWith("transition") || p.startsWith("animation")).map(
      ([where, name, value]) => `${where} ${name}: ${value}`,
    );
    expect(animated).toEqual([]);
  });
});
