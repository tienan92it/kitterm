import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { contrastRatio, type CssRule, parseCss, readSource, resolveColor, rootVariables } from "./theme-contrast-derive";
import { themeTokens } from "./theme-tokens";
import { TERMINAL_THEMES } from "./themes";

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

  it("styles no text field: the page takes no typed work", () => {
    // `agent-dashboard`, capability 1: the reply field, `[send]` and the
    // held reason are gone, so a `.reply` rule or a selector that reaches an
    // `input` or a `textarea` is dead and must not return.
    const typed = RULES.filter((rule) =>
      rule.selector
        .split(",")
        .map((part) => part.trim())
        .some((part) => /(^|[\s>+~])(input|textarea)\b/.test(part) || /\.reply(-|\b)/.test(part)),
    ).map(at);
    expect(typed, "a rule for a field the page no longer draws").toEqual([]);
  });
});

/**
 * The design foundation (`agent-dashboard`, capability 2;
 * `corpus/design-foundation.md`, frozen): one space scale, three type sizes,
 * one line height chosen by width, and four owned colours over an inherited
 * ground. Each is pinned below from the sheet's own `:root` layer, the
 * unconditional block at the top of the file.
 */
const ROOT = RULES.filter((rule) => rule.selector === ":root" && rule.conditions.length === 0);
const token = (name: string): string | undefined => ROOT.map((rule) => rule.decls.get(name)).find((v) => v !== undefined);

/** A `margin`, `padding` or `gap` property, longhands included. */
const isSpacing = (property: string): boolean =>
  /^(margin|padding)(-(top|right|bottom|left|block|inline)(-(start|end))?)?$/.test(property) || /^(row-|column-)?gap$/.test(property);

/** The six ground tokens rule C leaves to the terminal's theme. */
const GROUND = ["--ui-bg", "--ui-surface", "--ui-surface-2", "--ui-border", "--ui-text", "--ui-text-muted", "--ui-text-faint", "--ui-lift"];
const OWNED = ["--ui-accent", "--ui-warning", "--ui-danger", "--ui-success"];

/** The dark value of a `light-dark(light, dark)` token. */
const darkOf = (value: string | undefined): string => {
  const m = /^light-dark\(#[0-9a-f]{6},\s*(#[0-9a-f]{6})\)$/i.exec(value ?? "");
  if (!m) throw new Error(`not a light-dark() pair: ${value}`);
  return m[1];
};

describe("sessions.css carries the design foundation", () => {
  it("defines the five space tokens and the three type tokens", () => {
    expect([1, 2, 3, 4, 5].map((n) => token(`--space-${n}`))).toEqual(["4px", "8px", "12px", "16px", "24px"]);
    // A type token is a `font` shorthand: weight, size, line height, family.
    expect(token("--type-headline")).toMatch(/^600 18px\/[\d.]+ var\(--font-mono\)$/);
    expect(token("--type-heading")).toMatch(/^600 13px\/[\d.]+ var\(--font-mono\)$/);
    expect(token("--type-body")).toMatch(/^400 12px\/[\d.]+ var\(--font-mono\)$/);
  });

  it("writes no bare pixel for margin, padding or gap", () => {
    const bare = declarations(isSpacing)
      .filter(([, , value]) => /(^|[^\w.-])-?\d*\.?\d+px\b/.test(value))
      .map(([where, name, value]) => `${where} ${name}: ${value}`);
    expect(bare, "space comes from the scale: var(--space-1) to var(--space-5)").toEqual([]);
  });

  it("sets no font size outside the three type tokens", () => {
    const sizes = declarations((p) => p === "font-size").map(([where, , value]) => `${where} font-size: ${value}`);
    expect(sizes, "a fourth size; hierarchy comes from weight and colour").toEqual([]);
    const fonts = declarations((p) => p === "font")
      .filter(([, , value]) => !/^(inherit|var\(--type-(headline|heading|body)\))$/.test(value.trim()))
      .map(([where, , value]) => `${where} font: ${value}`);
    expect(fonts, "a font that is not one of the three tokens").toEqual([]);
  });

  it("chooses the line height by width: 44 px below 768 px, 28 px at and above it", () => {
    expect(token("--line-h")).toBe("44px");
    const wide = RULES.filter((rule) => rule.decls.has("--line-h") && rule.conditions.length > 0).map((rule) => [
      rule.selector,
      rule.conditions.join(" "),
      rule.decls.get("--line-h"),
    ]);
    expect(wide).toEqual([[":root", "@media (min-width: 768px)", "28px"]]);
    // No control and no other rule sets it: density follows the width alone.
    expect(RULES.filter((rule) => rule.decls.has("--line-h") && rule.selector !== ":root").map(at)).toEqual([]);
  });

  it("owns the four state colours and inherits the ground from the terminal (rule C)", () => {
    // `corpus/palette.md`: `light-dark()` takes the light value first.
    expect(token("--ui-accent")).toBe("light-dark(#1d7268, #2a9d8f)");
    expect(token("--ui-warning")).toBe("light-dark(#8a6415, #e9c46a)");
    expect(token("--ui-danger")).toBe("light-dark(#b0472c, #e76f51)");
    // A finished thing is grey.
    expect(token("--ui-success")).toBe("var(--ui-text-faint)");
    const redeclared = RULES.flatMap((rule) =>
      [...rule.decls.keys()].filter((name) => GROUND.includes(name)).map((name) => `${at(rule)} ${name}`),
    );
    expect(redeclared, "the ground and the three greys keep deriving from the terminal in tokens.css").toEqual([]);
  });

  it("paints an owned colour on the mark alone, never as text, a background or a border", () => {
    const owned = new RegExp(`var\\((${OWNED.join("|")})\\)`);
    const misuse = RULES.flatMap((rule) =>
      [...rule.decls]
        .filter(([name, value]) => owned.test(value) && (name === "color" || name.startsWith("border") || name.startsWith("background")))
        .filter(([name]) => !(name === "background" && /^\.mark\b/.test(rule.selector)))
        .map(([name, value]) => `${at(rule)} ${name}: ${value}`),
    );
    expect(misuse, "principle 5: colour marks what needs attention, on the one-character mark").toEqual([]);
  });

  it("clears 3:1 for each owned hue on the ground and the surface of every bundled theme", () => {
    // WCAG 1.4.11: a state mark is a non-text element and takes 3:1. The hues
    // are constants; the ground under them is the terminal's, so every theme
    // is a different pair. `corpus/palette.md` measured the palette's own
    // ground; this measures the seventeen the page can sit on.
    const tokens = rootVariables(readSource("tokens.css"));
    const hues = ["--ui-accent", "--ui-warning", "--ui-danger"].map((name) => [name, darkOf(token(name))] as const);
    const under: string[] = [];
    for (const theme of TERMINAL_THEMES) {
      const vars = new Map([...tokens, ...Object.entries(themeTokens(theme.colors, { accent: theme.accent }))]);
      for (const surface of ["var(--ui-bg)", "var(--ui-surface)"]) {
        const ground = resolveColor(surface, vars);
        for (const [name, hex] of hues) {
          const ratio = contrastRatio(resolveColor(hex, vars), ground);
          if (ratio < 3) under.push(`${name} on ${surface} on ${theme.id}: ${ratio.toFixed(2)}`);
        }
      }
    }
    expect(under).toEqual([]);
  });
});

/**
 * The fourth level (`agent-dashboard`, capability 3; `design-foundation.md`,
 * Hierarchy): a task is one line under its goal, set in by one indent
 * level, and its state's colour is on the gutter mark alone.
 */
describe("a task line follows the foundation", () => {
  const taskRules = RULES.filter((rule) => /\.(tree-tasks|tree-task|line-task|tag-state|line-fact|line-name)\b/.test(rule.selector));

  it("exists, is one line tall, and indents by one level", () => {
    expect(taskRules.length).toBeGreaterThan(0);
    const heights = taskRules.filter((rule) => rule.selector.endsWith(".line-task")).map((rule) => rule.decls.get("min-height"));
    expect(heights, "a task line is one --line-h, like a row").toEqual(["var(--line-h)"]);
    const indents = taskRules.filter((rule) => rule.selector.endsWith(".tree-tasks")).map((rule) => rule.decls.get("padding"));
    expect(indents, "one indent level is --space-3").toEqual(["0 0 0 var(--space-3)"]);
  });

  it("paints no owned colour as text: the mark carries the state", () => {
    const coloured = taskRules
      .filter((rule) => !rule.selector.includes(".mark"))
      .flatMap((rule) => [...rule.decls].filter(([name, value]) => name === "color" && OWNED.some((owned) => value.includes(owned))).map(() => at(rule)));
    expect(coloured).toEqual([]);
    expect(RULES.some((rule) => rule.selector === ".mark.pending"), "the pending task's faint dot").toBe(true);
  });
});

/**
 * The panels (`agent-dashboard`, capability 7; `design-foundation.md`, "The
 * panels"; `corpus/valuemaxxing.md`): a label in an 84 px gutter beside the
 * content at 768 px and above, stacked below it, where LEAKS drops whole;
 * a bar is a mark, so the accent and the amber paint it and nothing else
 * new; and the cache share is on no heading, which the sheet expresses by
 * naming no class for one.
 */
describe("the panels say what the spend bought", () => {
  const panel = RULES.filter((rule) => rule.selector === ".panel");

  it("put the label in an 84 px gutter at 768 px and stack it below", () => {
    expect(panel.filter((rule) => rule.conditions.length === 0).map((rule) => rule.decls.get("grid-template-columns"))).toEqual(["84px minmax(0, 1fr)"]);
    expect(panel.filter((rule) => rule.conditions.length > 0).map((rule) => [rule.conditions.join(" "), rule.decls.get("grid-template-columns")])).toEqual([
      ["@media (max-width: 767px)", "minmax(0, 1fr)"],
    ]);
  });

  it("drop LEAKS below 768 px and no other panel", () => {
    const dropped = RULES.filter((rule) => rule.conditions.length > 0 && rule.decls.get("display") === "none" && /^\.panel\./.test(rule.selector));
    expect(dropped.map((rule) => [rule.selector, rule.conditions.join(" ")])).toEqual([[".panel.leaks", "@media (max-width: 767px)"]]);
  });

  it("draw a bar as a mark, in the accent, and the remainder's in the amber", () => {
    const bar = RULES.filter((rule) => rule.selector === ".mark.bar");
    expect(bar.map((rule) => rule.decls.get("background"))).toEqual(["var(--ui-accent)"]);
    expect(bar.map((rule) => rule.decls.get("mask"))).toEqual(["none"]);
    expect(RULES.filter((rule) => rule.selector === ".mark.bar.attention").map((rule) => rule.decls.get("background"))).toEqual(["var(--ui-warning)"]);
  });

  it("name no class for a cache share: no heading carries one", () => {
    // The share left every workspace, project and goal heading; it lives
    // in the LEAKS line's text alone, which no selector styles apart.
    const share = RULES.filter((rule) => /cache|share/i.test(rule.selector)).map(at);
    expect(share, "a rule for a cache share on a heading").toEqual([]);
    const headingCost = RULES.filter((rule) => /\.(cost|goal-cost)\b/.test(rule.selector));
    expect(headingCost.length, "the heading's cost rule still exists; the share left it").toBeGreaterThan(0);
  });
});

/**
 * The band (`agent-dashboard`, capability 4; `design-foundation.md`,
 * principle 2): one row, one height, always. The height is set, not a
 * minimum, and the box clips, so no count and no noun can move the frame;
 * below 768 px the cells wrap to two rows of two at twice the height. The
 * strip it replaces is gone, and nothing on the page is sticky.
 */
describe("the band is a fixed frame", () => {
  const bandRules = RULES.filter((rule) => /^(a\.)?\.?band(-|\b)/.test(rule.selector.replace(/^a\./, ".")));
  const bandRoot = RULES.filter((rule) => rule.selector === ".band");

  it("sets one height from the line token, not a minimum, and clips", () => {
    const plain = bandRoot.filter((rule) => rule.conditions.length === 0);
    expect(plain.map((rule) => rule.decls.get("height"))).toEqual(["var(--line-h)"]);
    expect(plain.map((rule) => rule.decls.get("overflow"))).toEqual(["hidden"]);
    expect(bandRules.flatMap((rule) => [...rule.decls.keys()].filter((name) => name === "min-height" || name === "max-height").map(() => at(rule)))
      .filter((where) => !where.includes(".band-cell")), "a band whose height can move").toEqual([]);
  });

  it("wraps to two rows of two below 768 px, at twice the height and no more", () => {
    const narrow = bandRoot.filter((rule) => rule.conditions.length > 0).map((rule) => [
      rule.conditions.join(" "),
      rule.decls.get("height"),
      rule.decls.get("grid-template-columns"),
    ]);
    expect(narrow).toEqual([["@media (max-width: 767px)", "calc(2 * var(--line-h))", "repeat(2, minmax(0, 1fr))"]]);
    const wide = bandRoot.filter((rule) => rule.conditions.length === 0).map((rule) => rule.decls.get("grid-template-columns"));
    expect(wide).toEqual(["repeat(4, minmax(0, 1fr))"]);
  });

  it("keeps a cell one line tall and on one line, cut rather than wrapped", () => {
    const cell = RULES.filter((rule) => rule.selector === ".band-cell");
    expect(cell.map((rule) => rule.decls.get("height"))).toEqual(["var(--line-h)"]);
    expect(cell.map((rule) => rule.decls.get("white-space"))).toEqual(["nowrap"]);
    expect(cell.map((rule) => rule.decls.get("overflow"))).toEqual(["hidden"]);
    // The row tracks are the line height too, so no cell can stretch one.
    expect(bandRoot.filter((rule) => rule.conditions.length === 0).map((rule) => rule.decls.get("grid-auto-rows"))).toEqual(["var(--line-h)"]);
  });

  it("draws no strip, no count line, and nothing sticky", () => {
    const strip = RULES.filter((rule) => /\.(strip|fleet)(-|\b)/.test(rule.selector)).map(at);
    expect(strip, "a rule for the strip the band replaced").toEqual([]);
    const sticky = declarations((p) => p === "position").filter(([, , value]) => value.trim() === "sticky" || value.trim() === "fixed");
    expect(sticky, "principle 2: the frame does not move, and nothing floats over the tree").toEqual([]);
  });
});
