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
/** The five owned colours (`corpus/palette.md`, amended 2026-09-19). */
const OWNED = ["--ui-accent", "--ui-success", "--ui-warning", "--ui-danger", "--ui-caution"];
/** The two mark sizes, beside the type tokens (round 11). */
const MARK_TOKENS = ["--mark-size", "--mark-size-disclosure"];

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

  it("defines the two mark sizes beside the type tokens: 14 px for a state mark, 11 px for the triangle", () => {
    // Round 11 (the Components frame): the state marks `◐ ? ✓ ! – •` at
    // 14 px in a 16 px column, the disclosure triangle at 11 px in the
    // same column.
    expect(MARK_TOKENS.map(token)).toEqual(["14px", "11px"]);
  });

  it("sets no font size outside the two mark tokens, and no font outside the three type tokens", () => {
    // Chartered in round 11: the rule admitted no `font-size` at all. The
    // two mark tokens are the only sizes a rule may write, and only on a
    // mark: the text keeps its three sizes from the `font` shorthands.
    const sizes = RULES.filter((rule) => rule.decls.has("font-size")).map((rule) => `${rule.selector} font-size: ${rule.decls.get("font-size")}`);
    expect(sizes, "a size that is not one of the two mark tokens, or one on something that is not a mark").toEqual([
      ".mark font-size: var(--mark-size)",
      ".mark.disclosure font-size: var(--mark-size-disclosure)",
    ]);
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

  it("owns the five state colours and inherits the ground from the terminal (rule C)", () => {
    // `corpus/palette.md`, amended 2026-09-19: `light-dark()` takes the
    // light value first. Round 11 added the green done mark and the
    // caution; chartered, the green replaced `var(--ui-text-faint)`.
    expect(token("--ui-accent")).toBe("light-dark(#1d7268, #2a9d8f)");
    expect(token("--ui-success")).toBe("light-dark(#2d6a4f, #52b788)");
    expect(token("--ui-warning")).toBe("light-dark(#8a6415, #e9c46a)");
    expect(token("--ui-danger")).toBe("light-dark(#b0472c, #e76f51)");
    expect(token("--ui-caution")).toBe("light-dark(#b8641f, #f4a261)");
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
    // ground; this measures the seventeen the page can sit on. Round 11
    // added the green and the caution to the hues measured.
    const tokens = rootVariables(readSource("tokens.css"));
    const hues = OWNED.map((name) => [name, darkOf(token(name))] as const);
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
 * A line of the tree (`agent-dashboard`, capability 3, reshaped in round 10
 * to the frame `Dashboard 1200`): every level is one `.line` with the mark
 * at the far left of the page and the indent on the name, one `--space-4`
 * per level at 768 px and up and one `--space-3` on a phone; the state's
 * colour is on the mark alone. Chartered in round 10: the nested
 * `.tree-tasks` list and its `--space-3` padding pinned the card's shape.
 */
describe("a line follows the foundation", () => {
  const nameRules = RULES.filter((rule) => rule.selector === ".line-name");

  it("exists, is one line tall, and indents the name by one level per depth", () => {
    expect(RULES.filter((rule) => rule.selector === ".line").map((rule) => rule.decls.get("min-height")), "a line is one --line-h").toEqual(["var(--line-h)"]);
    expect(nameRules.map((rule) => [rule.conditions.join(" "), rule.decls.get("padding-left")])).toEqual([
      ["", "calc(var(--depth, 0) * var(--space-4))"],
      ["@media (max-width: 767px)", "calc(var(--depth, 0) * var(--space-3))"],
    ]);
    // No nested list carries the indent: the tree is flat lines.
    expect(RULES.filter((rule) => /\.(tree-tasks|tree-task|nested|card)\b/.test(rule.selector)).map(at)).toEqual([]);
  });

  it("paints no owned colour as text: the mark carries the state", () => {
    const coloured = RULES.filter((rule) => /\.(line|state|cost|counter|round|pr|model|since|agents)\b/.test(rule.selector))
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

  it("drop WHERE and LEAKS below 768 px and no other panel", () => {
    // Round 10 (the frame `Dashboard 390`): WHERE and LEAKS are absent on a
    // phone; USAGE, QUOTA, VALUE and MODELS stay, unfolded.
    const dropped = RULES.filter((rule) => rule.conditions.length > 0 && rule.decls.get("display") === "none" && /^\.panel\.\w+$/.test(rule.selector));
    expect(dropped.map((rule) => [rule.selector, rule.conditions.join(" ")])).toEqual([
      [".panel.where", "@media (max-width: 767px)"],
      [".panel.leaks", "@media (max-width: 767px)"],
    ]);
    expect(RULES.filter((rule) => /panel-fold|details/.test(rule.selector) && rule.selector.includes("panel")).map(at), "no panel folds").toEqual([]);
  });

  it("keep only the MODELS label on a phone: USAGE, QUOTA and VALUE lose theirs", () => {
    // Round 10 (the frame `Dashboard 390`): the tiles stand under no label.
    const hidden = RULES.filter((rule) => rule.conditions.length > 0 && rule.decls.get("display") === "none" && /^\.panel\.\w+ > \.panel-label$/.test(rule.selector));
    expect(hidden.map((rule) => rule.selector).sort()).toEqual([".panel.quota > .panel-label", ".panel.usage > .panel-label", ".panel.value > .panel-label"]);
  });

  it("share one name column across QUOTA, MODELS and WHERE, 140 px at 768 px and 92 px on a phone, and one 108 px last column", () => {
    // Round 11 (the approved frames): every bar starts on one x; the
    // quota's bar is 220 px (160 on a phone) and does not fill the row;
    // MODELS's sessions and WHERE's unit cost end on one x.
    const panel = RULES.filter((rule) => rule.selector === ".panel");
    expect(panel.filter((rule) => rule.conditions.length === 0).map((rule) => [rule.decls.get("--name-col"), rule.decls.get("--quota-bar"), rule.decls.get("--last-col")])).toEqual([["140px", "220px", "108px"]]);
    expect(panel.filter((rule) => rule.conditions.length > 0).map((rule) => [rule.conditions.join(" "), rule.decls.get("--name-col"), rule.decls.get("--quota-bar")])).toEqual([
      ["@media (max-width: 767px)", "92px", "160px"],
    ]);
    // A selector can have several rules; they cascade, so the lookup
    // merges them in sheet order.
    const width = (selector: string) => {
      const decls = new Map(RULES.filter((rule) => rule.selector === selector && rule.conditions.length === 0).flatMap((rule) => [...rule.decls]));
      return [decls.get("flex"), decls.get("width")];
    };
    expect(width(".quota-label")).toEqual(["none", "var(--name-col)"]);
    expect(width(".split-name")).toEqual(["none", "var(--name-col)"]);
    expect(width(".quota-track")).toEqual(["none", "var(--quota-bar)"]);
    expect(width(".split-rate")).toEqual(["none", "var(--last-col)"]);
    expect(width(".models .split-units")).toEqual([undefined, "var(--last-col)"]);
    // The track is the surface, the fill a mark: nothing new is painted.
    expect(RULES.filter((rule) => rule.selector === ".quota-track").map((rule) => rule.decls.get("background"))).toEqual(["var(--ui-surface)"]);
    expect(RULES.filter((rule) => /quota-cells|quota-fill\b(?!.*bar)/.test(rule.selector)).map(at), "no ASCII cells").toEqual([]);
  });

  it("draw one divider between MODELS and VALUE, a hairline, and above MODELS on a phone", () => {
    const divider = RULES.filter((rule) => rule.selector === ".panel-divider");
    expect(divider.filter((rule) => rule.conditions.length === 0).map((rule) => [rule.decls.get("border-top"), rule.decls.get("margin")])).toEqual([["1px solid var(--ui-border)", "0 0 var(--space-4)"]]);
    const phone = RULES.filter((rule) => rule.conditions.includes("@media (max-width: 767px)") && rule.decls.has("border-top") && /^\.panel/.test(rule.selector));
    expect(phone.map((rule) => [rule.selector, rule.decls.get("border-top")])).toEqual([[".panel.models", "1px solid var(--ui-border)"]]);
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

  it("puts the brand at the left and the four cells at the right on one line, and below 768 px the brand on its own line over two rows of two, at three lines and no more", () => {
    // Round 10 (the frames): `kitterm` at the left, the counts at the
    // right; on a phone the brand takes a line and the cells a 2×2 grid.
    const wide = bandRoot.filter((rule) => rule.conditions.length === 0);
    expect(wide.map((rule) => rule.decls.get("display"))).toEqual(["flex"]);
    expect(RULES.filter((rule) => rule.selector === ".band-brand" && rule.conditions.length === 0).map((rule) => rule.decls.get("flex"))).toEqual(["1 1 auto"]);
    const narrow = bandRoot.filter((rule) => rule.conditions.length > 0).map((rule) => [rule.conditions.join(" "), rule.decls.get("height"), rule.decls.get("flex-wrap")]);
    expect(narrow).toEqual([["@media (max-width: 767px)", "calc(3 * var(--line-h))", "wrap"]]);
    const cells = RULES.filter((rule) => rule.selector === ".band-cells" && rule.conditions.length > 0 && rule.decls.has("display")).map((rule) => [
      rule.decls.get("display"), rule.decls.get("grid-template-columns"), rule.decls.get("grid-auto-rows"),
    ]);
    expect(cells).toEqual([["grid", "repeat(2, minmax(0, 1fr))", "var(--line-h)"]]);
  });

  it("keeps a cell on one line, cut rather than wrapped, its count at the headline size", () => {
    const cell = RULES.filter((rule) => rule.selector === ".band-cell" && rule.conditions.length === 0);
    expect(cell.map((rule) => rule.decls.get("white-space"))).toEqual(["nowrap"]);
    expect(cell.map((rule) => rule.decls.get("overflow"))).toEqual(["hidden"]);
    expect(RULES.filter((rule) => rule.selector === ".band-value").map((rule) => rule.decls.get("font"))).toEqual(["var(--type-headline)"]);
    expect(RULES.filter((rule) => rule.selector === ".band-brand" && rule.conditions.length === 0).map((rule) => rule.decls.get("font"))).toEqual(["var(--type-heading)"]);
    // The count that carries a state is a mark: text as wide as itself.
    expect(RULES.find((rule) => rule.selector === ".mark.wide")?.decls.get("width")).toBe("auto");
  });

  it("draws no strip, no count line, and nothing sticky", () => {
    const strip = RULES.filter((rule) => /\.(strip|fleet)(-|\b)/.test(rule.selector)).map(at);
    expect(strip, "a rule for the strip the band replaced").toEqual([]);
    const sticky = declarations((p) => p === "position").filter(([, , value]) => value.trim() === "sticky" || value.trim() === "fixed");
    expect(sticky, "principle 2: the frame does not move, and nothing floats over the tree").toEqual([]);
  });
});

/**
 * Every line is one line (`agent-dashboard`, capability 5;
 * `design-foundation.md`, principle 3 and "The line, in detail"; the
 * columns of the frame `Dashboard 1200`, round 10): a line of the tree is
 * one `--line-h` tall and never wraps; its name is the only cell that
 * truncates; its facts sit in four fixed columns at 768 px and up and give
 * way to the state word and one fact on a phone. The marks are characters
 * coloured through a clipped background, so no owned colour is ever
 * `color`; and the one thing that moves is the working mark's character
 * cycle in `sessions.ts`, which is why the sheet animates nothing at all.
 */
describe("every line is one line", () => {
  // A selector can have several unconditional rules; they cascade, so the
  // lookup merges them in sheet order.
  const treeRule = (selector: string): CssRule | undefined => {
    const rules = RULES.filter((rule) => rule.selector === selector && rule.conditions.length === 0);
    return rules.length === 0 ? undefined : { ...rules[0], decls: new Map(rules.flatMap((rule) => [...rule.decls])) };
  };

  it("makes every line one --line-h tall, on one line, and never wraps it", () => {
    const line = treeRule(".line")!;
    expect(line.decls.get("min-height")).toBe("var(--line-h)");
    expect(line.decls.get("display")).toBe("flex");
    expect(line.decls.get("white-space")).toBe("nowrap");
    const wrapping = RULES.filter((rule) => /\.(line|main|row|open|line-approval)\b/.test(rule.selector))
      .filter((rule) => rule.decls.has("flex-wrap"))
      .map(at);
    expect(wrapping, "principle 3: a fact that does not fit is dropped, not wrapped").toEqual([]);
    // The tree paints no card: no surface fill and no rule per line, only
    // the hairline between two top-level sections.
    const BOXES = [".line", ".row", ".row-line", ".tree", ".tree-section", ".main", ".goal-line", ".line-task", ".line-project", ".line-workspace", ".line-approval", ".line-fold", ".tree-section + .tree-section"];
    const filled = RULES.filter((rule) => BOXES.includes(rule.selector) && rule.conditions.length === 0)
      .filter((rule) => rule.decls.has("background") || rule.decls.has("border-top") || rule.decls.has("border-bottom") || rule.decls.has("border"))
      .map((rule) => rule.selector);
    expect(filled).toEqual([".tree-section + .tree-section"]);
  });

  it("holds the facts in four fixed columns at 768 px and up, and one fact beside the state word on a phone", () => {
    const main = treeRule(".main")!;
    expect(main.decls.get("display")).toBe("grid");
    expect(main.decls.get("grid-template-columns")).toBe("minmax(0, 1fr) 17ch 14ch 12ch 10ch");
    expect(treeRule(".main > .state")?.decls.get("grid-column")).toBe("2");
    expect(["2", "3", "4"].map((n) => treeRule(`.main > [data-col="${n}"]`)?.decls.get("grid-column"))).toEqual(["3", "4", "5"]);
    const facts = RULES.filter((rule) => /^\.main > \.(cost|counter|round|pr|model|since|agents)$/.test(rule.selector));
    expect(facts.map((rule) => rule.decls.get("text-align"))).toEqual(facts.map(() => "right"));
    expect(facts.map((rule) => rule.decls.has("text-overflow")), "a fact is never cut with an ellipsis").toEqual(facts.map(() => false));
    const phone = RULES.filter((rule) => rule.conditions.includes("@media (max-width: 767px)"));
    expect(phone.find((rule) => rule.selector === ".main")?.decls.get("display")).toBe("flex");
    expect(phone.find((rule) => rule.selector === ".main > [data-col]:not([data-narrow])")?.decls.get("display")).toBe("none");
  });

  it("truncates the name and nothing else in the tree", () => {
    const NAMES = [".line-name", ".archived-name"];
    const inTree = RULES.filter((rule) => /\.(line|row|open|main|line-|goal-|archived|tree-|folder|state|since|cost|counter|round|pr|model|agents)\b/.test(rule.selector));
    const truncating = inTree.filter((rule) => rule.decls.get("text-overflow") === "ellipsis").map((rule) => rule.selector);
    expect(truncating.sort()).toEqual([...NAMES].sort());
    for (const name of NAMES) {
      const rule = treeRule(name)!;
      expect(rule.decls.get("min-width"), `${name} may shrink`).toBe("0");
      expect(rule.decls.get("overflow"), `${name} clips`).toBe("hidden");
    }
    // An approval's arguments are the one fact that drops, hidden whole, never cut.
    expect(treeRule(".line-approval-input")?.decls.get("flex")).toBe("none");
    expect(treeRule("[data-drop][hidden]")?.decls.get("display")).toBe("none");
    expect(treeRule(".line.measure *")?.decls.get("flex")?.startsWith("0 0 auto"), "every cell at its content width while the page measures").toBe(true);
  });

  it("draws every mark as a character coloured through its background, never through color", () => {
    // Round 11: a mark is 14 px in a 16 px column; chartered, the 16 px
    // replaced `1ch`, the 12 px mark. The triangle is 11 px in the same
    // column, in the faint grey, and never carries a state's colour.
    const mark = treeRule(".mark")!;
    expect(mark.decls.get("-webkit-text-fill-color")).toBe("transparent");
    expect(mark.decls.get("width")).toBe("16px");
    expect(mark.decls.get("font-size")).toBe("var(--mark-size)");
    expect(mark.decls.has("mask") || mark.decls.has("-webkit-mask"), "no masked shape: the glyph is text").toBe(false);
    const disclosure = treeRule(".mark.disclosure")!;
    expect(disclosure.decls.get("font-size")).toBe("var(--mark-size-disclosure)");
    expect(disclosure.decls.get("background")).toBe("var(--ui-text-faint)");
    expect(disclosure.decls.has("width"), "the triangle sits in the mark's own column").toBe(false);
    // The clip sits on every family, after its colour: the `background`
    // shorthand resets it, and an unclipped mark is a box.
    const FAMILIES = ["running", "attention", "failed", "idle", "done", "pending", "unknown", "caution"];
    expect(FAMILIES.map((f) => treeRule(`.mark.${f}`)?.decls.get("background-clip"))).toEqual(FAMILIES.map(() => "text"));
    for (const f of FAMILIES) {
      const rules = RULES.filter((rule) => rule.selector === `.mark.${f}` && rule.conditions.length === 0);
      const colour = rules.findIndex((rule) => rule.decls.has("background"));
      const clip = rules.findIndex((rule) => rule.decls.has("background-clip"));
      expect(clip, `.mark.${f}: the clip comes after the colour`).toBeGreaterThanOrEqual(colour);
    }
    const coloured = RULES.filter((rule) => /\.mark\b/.test(rule.selector) && rule.decls.has("color")).map(at);
    expect(coloured, "an owned colour on a mark is a background, so the ratchet measures it as the non-text mark it is").toEqual([]);
    // The one mark that is not a character, the bar, paints its box again;
    // the tile's rule is the bar stood on end.
    expect(treeRule(".mark.bar")?.decls.get("background-clip")).toBe("border-box");
    expect(treeRule(".mark.bar.rule")?.decls.get("width")).toBe("2px");
    // A blank mark keeps the column and paints nothing.
    expect(treeRule(".mark.blank")?.decls.get("background")).toBe("none");
    // The families the model names each have their colour. The green
    // paints the done mark alone: idle and pending are the faint grey
    // (chartered in round 11: idle wore `--ui-success` while it was grey).
    expect(["running", "attention", "failed", "pending", "idle", "done", "caution"].map((f) => treeRule(`.mark.${f}`)?.decls.get("background"))).toEqual([
      "var(--ui-accent)", "var(--ui-warning)", "var(--ui-danger)", "var(--ui-text-faint)", "var(--ui-text-faint)", "var(--ui-success)", "var(--ui-caution)",
    ]);
    const green = RULES.filter((rule) => [...rule.decls.values()].some((v) => v.includes("--ui-success"))).map((rule) => rule.selector);
    expect(green, "the green paints the ✓ mark and nothing else").toEqual([".mark.done"]);
  });

  it("animates nothing but the working mark, and that as a character cycle outside the sheet", () => {
    // `goal.md`: one animation, and only one. The spinner is a `textContent`
    // swap on a 90 ms timer in `sessions.ts`, gated on
    // `prefers-reduced-motion` there, so the sheet carries no `animation`,
    // no `transition` and no `@keyframes`; any `animation` that ever
    // appears must be the spinner's and must sit under a motion guard.
    const animated = declarations((p) => p.startsWith("animation") || p.startsWith("transition"));
    const outside = RULES.filter((rule) => [...rule.decls.keys()].some((p) => p.startsWith("animation")))
      .filter((rule) => !(rule.selector === ".mark.running" && rule.conditions.some((c) => c.includes("prefers-reduced-motion"))))
      .map(at);
    expect(outside, "an animation that is not the spinner's under a prefers-reduced-motion guard").toEqual([]);
    expect(animated.map(([where, name]) => `${where} ${name}`), "the spinner is a character cycle in sessions.ts, not a CSS animation").toEqual([]);
    expect(SOURCE.includes("@keyframes")).toBe(false);
    expect(RULES.filter((rule) => rule.decls.has("transition")).map(at)).toEqual([]);
  });

  it("prints the vocabulary in the tree's header under a hairline, not on a phone, and folds nothing but the done goals and the page's foot", () => {
    // Round 10: the header is a panel-shaped row, SESSIONS in the gutter;
    // a goal's last done tasks show at both widths, so there is no
    // `.done-tasks` fold and no bucket label.
    const head = treeRule(".tree-head")!;
    expect(head.decls.get("display")).toBe("grid");
    expect(head.decls.get("grid-template-columns")).toBe("84px minmax(0, 1fr)");
    expect(head.decls.get("border-top")).toBe("1px solid var(--ui-border)");
    expect(RULES.find((rule) => rule.selector === ".tree-head" && rule.conditions.length > 0)?.decls.get("display")).toBe("none");
    expect(treeRule(".tree-key")?.decls.get("white-space")).toBe("nowrap");
    expect(RULES.filter((rule) => /\.(done-tasks|bucket)\b/.test(rule.selector)).map(at), "no task fold, no label over a bucket").toEqual([]);
    expect(treeRule(".folds")?.decls.get("border-top")).toBe("1px solid var(--ui-border)");
    expect(treeRule(".fold > summary")?.decls.get("list-style")).toBe("none");
  });
});
