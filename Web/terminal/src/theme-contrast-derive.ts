/**
 * Derives the page's text-and-background pairs from the stylesheets, so a
 * pair nobody remembered to list still gets measured.
 *
 * `theme-contrast.test.ts` used to carry four pairs by hand. A new element's
 * colours were unmeasured until a reviewer noticed, which is how the
 * proposals chip and the goal meta line each shipped under the WCAG floor
 * (rounds 5 and 7 of `projects-and-knowledge`). This module reads
 * `tokens.css`, `sessions.css` and `styles.css` at test time and produces
 * every pair the two pages paint.
 *
 * The CSS is read with `node:fs`, not with a `?raw` import: vitest's
 * `css-disable` plugin matches any id containing `.css?` and replaces the
 * module with an empty string, so `import css from "./sessions.css?raw"`
 * returns `""` under the test runner. `node-fs.d.ts` beside this file
 * declares the one function used, because the project carries no node types
 * and `tsc --noEmit` runs before every build.
 */

import { readFileSync } from "node:fs";

/* --- CSS parsing ---------------------------------------------------------- */

/** One declaration block: its selector list, its declarations, where it is. */
export interface CssRule {
  /** The stylesheet's file name, for a failure message. */
  sheet: string;
  /** 1-based line of the selector. */
  line: number;
  /** One selector of the rule's list, already split on commas. */
  selector: string;
  /** Property to value, later declarations winning. */
  decls: Map<string, string>;
  /** The at-rule conditions the block sits under, outermost first. */
  conditions: string[];
}

const stripComments = (src: string): string => src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));

const parseDecls = (body: string): Map<string, string> => {
  const decls = new Map<string, string>();
  let depth = 0;
  let start = 0;
  const parts: string[] = [];
  for (let i = 0; i < body.length; i += 1) {
    const c = body[i];
    if (c === "(") depth += 1;
    else if (c === ")") depth -= 1;
    else if (c === ";" && depth === 0) {
      parts.push(body.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(body.slice(start));
  for (const part of parts) {
    const colon = part.indexOf(":");
    if (colon < 0) continue;
    const name = part.slice(0, colon).trim().toLowerCase();
    const value = part.slice(colon + 1).trim();
    if (name && value) decls.set(name, value.replace(/\s*!important$/, ""));
  }
  return decls;
};

/**
 * A small stylesheet parser: enough for these two files and no more. It keeps
 * at-rule conditions (`@media`, `@supports`) as strings and splits a selector
 * list into one rule per selector, so every selector is placed on its own.
 */
export const parseCss = (sheet: string, src: string): CssRule[] => {
  const text = stripComments(src);
  const rules: CssRule[] = [];
  const conditions: string[] = [];
  let i = 0;
  let head = "";
  let headLine = 1;
  let line = 1;
  const headStart = () => {
    if (head.trim() === "") headLine = line;
  };
  while (i < text.length) {
    const c = text[i];
    if (c === "\n") line += 1;
    if (c === "{") {
      const prelude = head.trim();
      head = "";
      if (prelude.startsWith("@")) {
        conditions.push(prelude);
        i += 1;
        continue;
      }
      // A declaration block: find its end, honouring nothing but braces, which
      // is all these files contain inside a rule.
      let depth = 1;
      let j = i + 1;
      for (; j < text.length && depth > 0; j += 1) {
        if (text[j] === "{") depth += 1;
        else if (text[j] === "}") depth -= 1;
      }
      const body = text.slice(i + 1, j - 1);
      const decls = parseDecls(body);
      for (const selector of prelude.split(",")) {
        const trimmed = selector.trim().replace(/\s+/g, " ");
        if (trimmed) rules.push({ sheet, line: headLine, selector: trimmed, decls, conditions: [...conditions] });
      }
      for (let k = i; k < j; k += 1) if (text[k] === "\n") line += 1;
      i = j;
      head = "";
      continue;
    }
    if (c === "}") {
      conditions.pop();
      i += 1;
      head = "";
      continue;
    }
    headStart();
    head += c;
    i += 1;
  }
  return rules;
};

/* --- colour values -------------------------------------------------------- */

/** Straight (not premultiplied) sRGB with alpha, 0-255 and 0-1. */
export type Rgba = { r: number; g: number; b: number; a: number };

const NAMED: Record<string, Rgba> = {
  white: { r: 255, g: 255, b: 255, a: 1 },
  black: { r: 0, g: 0, b: 0, a: 1 },
  transparent: { r: 0, g: 0, b: 0, a: 0 },
};

const parseHexColor = (hex: string): Rgba | null => {
  const value = hex.trim().replace(/^#/, "");
  const full = value.length === 3 || value.length === 4 ? value.split("").map((c) => c + c).join("") : value;
  if (!/^[0-9a-f]{6}([0-9a-f]{2})?$/i.test(full)) return null;
  const n = (at: number) => Number.parseInt(full.slice(at, at + 2), 16);
  return { r: n(0), g: n(2), b: n(4), a: full.length === 8 ? n(6) / 255 : 1 };
};

export const toHex = (c: Rgba): string =>
  "#" + [c.r, c.g, c.b].map((v) => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, "0")).join("");

/** Splits a function's arguments on top-level commas. */
const splitArgs = (inner: string): string[] => {
  const args: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < inner.length; i += 1) {
    const c = inner[i];
    if (c === "(") depth += 1;
    else if (c === ")") depth -= 1;
    else if (c === "," && depth === 0) {
      args.push(inner.slice(start, i));
      start = i + 1;
    }
  }
  args.push(inner.slice(start));
  return args.map((a) => a.trim());
};

/** Reads `name(...)` at the head of an expression. */
const readFn = (expr: string): { name: string; args: string[] } | null => {
  const match = /^([a-z-]+)\(/i.exec(expr.trim());
  if (!match) return null;
  const open = expr.indexOf("(");
  let depth = 0;
  for (let i = open; i < expr.length; i += 1) {
    if (expr[i] === "(") depth += 1;
    else if (expr[i] === ")") {
      depth -= 1;
      if (depth === 0) return { name: match[1].toLowerCase(), args: splitArgs(expr.slice(open + 1, i)) };
    }
  }
  return null;
};

const srgbToLinear = (c: number): number => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const linearToSrgb = (c: number): number => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);

const toOklab = (c: Rgba): [number, number, number] => {
  const [r, g, b] = [c.r, c.g, c.b].map((v) => srgbToLinear(v / 255));
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
};

const fromOklab = ([L, a, b]: [number, number, number], alpha: number): Rgba => {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3;
  const linear = [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ];
  const [r, g, bb] = linear.map((c) => Math.round(Math.min(1, Math.max(0, linearToSrgb(c))) * 255));
  return { r, g, b: bb, a: alpha };
};

/**
 * `color-mix(in <space>, a <p>%, b <q>%)` for the two spaces `tokens.css`
 * uses. Percentages follow the CSS rule: a missing one is the remainder, and
 * the mix is premultiplied by alpha so mixing toward `transparent` gives the
 * first colour at that alpha.
 */
export const colorMix = (space: string, a: Rgba, pa: number | null, b: Rgba, pb: number | null): Rgba => {
  let wa = pa;
  let wb = pb;
  if (wa === null && wb === null) [wa, wb] = [50, 50];
  else if (wa === null) wa = 100 - (wb as number);
  else if (wb === null) wb = 100 - wa;
  const sum = (wa as number) + (wb as number);
  const fa = ((wa as number) / sum) * a.a;
  const fb = ((wb as number) / sum) * b.a;
  const alpha = fa + fb;
  if (alpha === 0) return { r: 0, g: 0, b: 0, a: 0 };
  if (space === "oklab") {
    const la = toOklab(a);
    const lb = toOklab(b);
    return fromOklab(
      [0, 1, 2].map((i) => (la[i] * fa + lb[i] * fb) / alpha) as [number, number, number],
      alpha,
    );
  }
  return {
    r: (a.r * fa + b.r * fb) / alpha,
    g: (a.g * fa + b.g * fb) / alpha,
    b: (a.b * fa + b.b * fb) / alpha,
    a: alpha,
  };
};

/** Paints `over` on top of `under`; both straight alpha, the result opaque. */
export const composite = (over: Rgba, under: Rgba): Rgba => {
  const a = over.a + under.a * (1 - over.a);
  if (a === 0) return { r: 0, g: 0, b: 0, a: 0 };
  const ch = (o: number, u: number) => (o * over.a + u * under.a * (1 - over.a)) / a;
  return { r: ch(over.r, under.r), g: ch(over.g, under.g), b: ch(over.b, under.b), a };
};

export class UnresolvedColor extends Error {}

/**
 * Evaluates a CSS colour expression against a variable table: `var()` with a
 * fallback, `color-mix()`, hex, and the three named colours these sheets use.
 * Anything else throws, because a colour the test cannot compute is a hole in
 * the measurement.
 */
export const resolveColor = (expr: string, vars: Map<string, string>, seen: string[] = []): Rgba => {
  const value = expr.trim();
  const named = NAMED[value.toLowerCase()];
  if (named) return named;
  const hex = parseHexColor(value);
  if (hex) return hex;
  const fn = readFn(value);
  if (fn?.name === "var") {
    const name = fn.args[0];
    if (seen.includes(name)) throw new UnresolvedColor(`${name} refers to itself`);
    const bound = vars.get(name);
    if (bound !== undefined) return resolveColor(bound, vars, [...seen, name]);
    if (fn.args.length > 1) return resolveColor(fn.args.slice(1).join(","), vars, [...seen, name]);
    throw new UnresolvedColor(`${name} has no value and no fallback`);
  }
  if (fn?.name === "color-mix") {
    const [inSpace, ...rest] = fn.args;
    const space = inSpace.replace(/^in\s+/, "").trim();
    if (space !== "oklab" && space !== "srgb") throw new UnresolvedColor(`colour space ${space}`);
    const part = (arg: string): [Rgba, number | null] => {
      const pct = /\s([0-9.]+)%$/.exec(arg);
      const colour = pct ? arg.slice(0, arg.length - pct[0].length) : arg;
      return [resolveColor(colour, vars, seen), pct ? Number(pct[1]) : null];
    };
    const [a, pa] = part(rest[0]);
    const [b, pb] = part(rest[1]);
    return colorMix(space, a, pa, b, pb);
  }
  throw new UnresolvedColor(`cannot evaluate ${value}`);
};

/* --- WCAG ----------------------------------------------------------------- */

const relativeLuminance = (c: Rgba): number => {
  const [r, g, b] = [c.r, c.g, c.b].map((v) => srgbToLinear(v / 255));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};

/** WCAG 2.x contrast ratio, 1 to 21. Both colours must already be opaque. */
export const contrastRatio = (a: Rgba, b: Rgba): number => {
  const la = relativeLuminance(a);
  const lb = relativeLuminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
};

/**
 * WCAG 1.4.3: text is large at 18.66px bold or 24px regular, and large text
 * passes at 3:1 instead of 4.5:1. "Bold" is weight 700 or more; 600 is not,
 * which is why the 20px `h1` and the 17px intro title still take 4.5:1.
 */
export const isLargeText = (px: number | null, weight: number | null): boolean => {
  if (px === null) return false;
  if (px >= 24) return true;
  return px >= 18.66 && (weight ?? 400) >= 700;
};

export const floorFor = (px: number | null, weight: number | null): number => (isLargeText(px, weight) ? 3 : 4.5);

/* --- selectors ------------------------------------------------------------ */

/** One compound selector: `.menu.open`, `button:hover`, `input[type="text"]`. */
export interface Compound {
  element: string;
  id: string;
  classes: string[];
  pseudos: string[];
  attributes: string[];
}

const parseCompound = (text: string): Compound => {
  const compound: Compound = { element: "", id: "", classes: [], pseudos: [], attributes: [] };
  const tokens = text.match(/\[[^\]]*\]|::?[a-z-]+(\([^)]*\))?|[.#][^.#:[\s]+|^[a-z*][a-z0-9-]*/gi) ?? [];
  for (const token of tokens) {
    if (token.startsWith("[")) compound.attributes.push(token);
    else if (token.startsWith(":")) compound.pseudos.push(token);
    else if (token.startsWith(".")) compound.classes.push(token.slice(1));
    else if (token.startsWith("#")) compound.id = token.slice(1);
    else compound.element = token.toLowerCase();
  }
  return compound;
};

/** Splits a selector into compounds, dropping the combinators. */
export const parseSelector = (selector: string): Compound[] =>
  selector
    .replace(/\s*[>+~]\s*/g, " ")
    .split(/\s+/)
    .filter(Boolean)
    .map(parseCompound);

const subset = (a: readonly string[], b: readonly string[]): boolean => a.every((x) => b.includes(x));

/** True when a rule written for `rule` also styles an element matching `on`. */
const compoundApplies = (rule: Compound, on: Compound): boolean =>
  (rule.element === "" || rule.element === "*" || rule.element === on.element) &&
  (rule.id === "" || rule.id === on.id) &&
  subset(rule.classes, on.classes) &&
  subset(rule.pseudos, on.pseudos) &&
  subset(rule.attributes, on.attributes);

/** True when `rule` names the same element with extra classes: a sibling state
 * the selector does not mention, such as `.chip.on` beside `.chip`. */
const compoundVariant = (rule: Compound, on: Compound): boolean =>
  // A bare `input` or `#search` has no class to share, so nothing is a variant
  // of it: without this, every classed rule in the sheet would count as one.
  on.classes.length > 0 &&
  (rule.element === "" || rule.element === on.element) &&
  (rule.id === "" || rule.id === on.id) &&
  subset(on.classes, rule.classes) &&
  rule.classes.length > on.classes.length &&
  subset(rule.pseudos, on.pseudos);

/** True when the rule's written ancestors are a subsequence of the element's. */
const contextApplies = (rule: Compound[], on: Compound[]): boolean => {
  let at = 0;
  for (const want of rule) {
    while (at < on.length && !compoundApplies(want, on[at])) at += 1;
    if (at === on.length) return false;
    at += 1;
  }
  return true;
};

const specificity = (c: Compound[]): number =>
  c.reduce((n, x) => n + (x.id ? 1000 : 0) + (x.classes.length + x.pseudos.length + x.attributes.length) * 10 + (x.element ? 1 : 0), 0);

/* --- the cascade ---------------------------------------------------------- */

/** A parsed rule with its selector already split. */
interface Placed extends CssRule {
  compounds: Compound[];
}

const conditionsApply = (rule: string[], on: string[]): boolean => rule.every((c) => on.includes(c));

/**
 * The declarations in force on the element a rule was written for: every rule
 * whose selector also matches that element, in specificity then document
 * order. This is what makes `.tally.quiet` inherit `.tally`'s 12px and
 * `.tag.program` inherit `.tag`'s surface without either being listed.
 */
const cascadeFor = (all: Placed[], target: Placed): Map<string, string> => {
  const applies = all.filter(
    (r) =>
      conditionsApply(r.conditions, target.conditions) &&
      compoundApplies(r.compounds[r.compounds.length - 1], target.compounds[target.compounds.length - 1]) &&
      contextApplies(r.compounds.slice(0, -1), target.compounds.slice(0, -1)),
  );
  applies.sort((a, b) => specificity(a.compounds) - specificity(b.compounds) || all.indexOf(a) - all.indexOf(b));
  const decls = new Map<string, string>();
  for (const rule of applies) for (const [k, v] of rule.decls) decls.set(k, v);
  return decls;
};

const FONT_SHORTHAND = /(?:^|\s)(\d+(?:\.\d+)?)px(?:\s*\/\s*[\d.]+)?\s+(?=[a-z"(-])/i;

/** The font size and weight in force, from `font-size`/`font-weight` or the
 * `font` shorthand these sheets use (`600 14px/1.3 var(--font-ui)`). */
export const fontOf = (decls: Map<string, string>): { px: number | null; weight: number | null } => {
  let px: number | null = null;
  let weight: number | null = null;
  const shorthand = decls.get("font");
  if (shorthand) {
    const size = FONT_SHORTHAND.exec(shorthand);
    if (size) px = Number(size[1]);
    const w = /^\s*(\d{3})\s/.exec(shorthand);
    if (w) weight = Number(w[1]);
    else if (/^\s*bold\s/.test(shorthand)) weight = 700;
  }
  const size = decls.get("font-size");
  if (size) {
    const value = /^([\d.]+)px$/.exec(size.trim());
    px = value ? Number(value[1]) : null;
  }
  const w = decls.get("font-weight");
  if (w) weight = w.trim() === "bold" ? 700 : /^\d{3}$/.test(w.trim()) ? Number(w.trim()) : weight;
  return { px, weight };
};

/* --- the surface rule ----------------------------------------------------- */

/**
 * The rule that maps an element to what it sits on, in four steps, most
 * derived first. It is stated here and defended in `theme-contrast.test.ts`.
 *
 * 1. **The element's own paint.** The declarations in force on it set a
 *    background. An opaque one is the surface; a translucent one (`--ui-veil`,
 *    `--ui-accent-soft`, `none`) is stacked over what step 2 or 3 returns.
 * 2. **The written ancestry.** A descendant selector names real ancestors:
 *    `.menu.open .quiet`, `.settings-field select`, `.foreman .row`. Walk them
 *    right to left and take the first one any rule paints.
 * 3. **The block table below.** CSS carries no parent pointer, so a leaf
 *    written on its own (`.goal-meta`, `.tok-comment`, `.state`) has nothing to
 *    walk. One entry per block says which surface that block's elements sit on,
 *    with the reason. A block, not a pair: a new element inside a known block
 *    is measured the day it is written, which is the defect this closes.
 * 4. **Nothing.** The rule reports the selector as unplaced and the test fails
 *    naming it. Adding a block without saying what it sits on breaks the build.
 *
 * Where an ancestor or the element itself can be in several states, the rule
 * does not choose: it collects every background any rule paints on that class
 * and measures the text against all of them. `.strip-item` is warning-tinted,
 * danger-tinted or accent-soft; `.file-picker-row` is transparent or
 * accent-soft. That is the "parent class combination" case, and measuring the
 * whole set is the conservative answer rather than a guess.
 */
export interface Surface {
  /** Painted bottom to top; the composite of the stack is the surface. */
  stack: string[];
  /** Which step placed it, for the failure message. */
  how: string;
}

/**
 * Step 3. One entry per block: the class (or element name) written on the CSS
 * side, and the surface its elements sit on in the DOM the two pages build.
 * The reason is the part a reviewer checks.
 */
const BLOCK_SURFACES: Array<{ block: string; stack: string[]; why: string }> = [
  // --- sessions.css: the page itself ---
  { block: "html", stack: ["var(--ui-bg)"], why: "the page" },
  { block: "body", stack: ["var(--ui-bg)"], why: "the page" },
  { block: "app", stack: ["var(--ui-bg)"], why: "the terminal page's root" },
  { block: "sessions", stack: ["var(--ui-bg)"], why: "the fleet page's column, on the body" },
  { block: "header", stack: ["var(--ui-bg)"], why: "the page head, on the body" },
  { block: "h1", stack: ["var(--ui-bg)"], why: "the page head, on the body" },
  { block: "count", stack: ["var(--ui-bg)"], why: "beside the h1, on the body" },
  { block: "launch", stack: ["var(--ui-bg)"], why: "beside the h1, on the body" },
  { block: "empty", stack: ["var(--ui-bg)"], why: "in place of the cards, on the body" },
  { block: "filters", stack: ["var(--ui-bg)"], why: "above the cards, on the body" },
  { block: "search", stack: ["var(--ui-bg)"], why: "in .filters, on the body" },
  { block: "chips", stack: ["var(--ui-bg)"], why: "in .filters, on the body" },
  { block: "chip-group", stack: ["var(--ui-bg)"], why: "in .filters, on the body" },
  { block: "chip-label", stack: ["var(--ui-bg)"], why: "in .filters, on the body" },
  { block: "chip", stack: ["var(--ui-bg)"], why: "in .filters, on the body" },
  { block: "notice", stack: ["var(--ui-bg)"], why: "above the cards, on the body" },
  { block: "restart", stack: ["var(--ui-bg)"], why: "above the cards, on the body; it paints its own danger tint over --ui-bg" },
  { block: "cards", stack: ["var(--ui-bg)"], why: "the card column, on the body" },
  // --- sessions.css: the attention strip, itself on the body ---
  { block: "strip", stack: ["var(--ui-bg)"], why: "sticky on the body; it paints --ui-bg itself" },
  { block: "strip-quiet", stack: ["var(--ui-bg)"], why: "in .strip, which paints --ui-bg" },
  { block: "strip-foreman", stack: ["var(--ui-bg)"], why: "in .strip, which paints --ui-bg" },
  { block: "strip-list", stack: ["var(--ui-bg)"], why: "in .strip, which paints --ui-bg" },
  { block: "strip-item", stack: ["var(--ui-bg)"], why: "in .strip; it paints its own tint over --ui-bg" },
  { block: "strip-top", stack: ["@strip-item"], why: "in .strip-item, whatever tint it wears" },
  { block: "strip-what", stack: ["@strip-item"], why: "in .strip-item, whatever tint it wears" },
  { block: "strip-who", stack: ["@strip-item"], why: "in .strip-item, whatever tint it wears" },
  { block: "strip-where", stack: ["@strip-item"], why: "in .strip-item, whatever tint it wears" },
  { block: "strip-waited", stack: ["@strip-item"], why: "in .strip-item, whatever tint it wears" },
  { block: "strip-detail", stack: ["@strip-item"], why: "in .strip-item, whatever tint it wears" },
  { block: "strip-open", stack: ["@strip-item"], why: "in .strip-item, whatever tint it wears" },
  { block: "proposed-actions", stack: ["@strip-item"], why: "in .strip-item, whatever tint it wears" },
  { block: "approval-input", stack: ["@strip-item"], why: "in .strip-item.approval" },
  { block: "approval-actions", stack: ["@strip-item"], why: "in .strip-item.approval" },
  { block: "approval-deny", stack: ["var(--ui-surface-2)"], why: "an .approval-actions button, which paints --ui-surface-2" },
  { block: "approval-allow", stack: ["var(--ui-surface-2)"], why: "an .approval-actions button, which paints --ui-surface-2" },
  // --- sessions.css: the pinned foreman row, on the body ---
  { block: "pinned", stack: ["var(--ui-bg)"], why: "above the cards, on the body" },
  { block: "foreman", stack: ["var(--ui-bg)"], why: "above the cards, on the body; it paints nothing" },
  { block: "foreman-label", stack: ["var(--ui-bg)"], why: "in .foreman, on the body" },
  // --- sessions.css: a project card ---
  { block: "card", stack: ["var(--ui-surface)"], why: "the card paints --ui-surface" },
  { block: "card-head", stack: ["var(--ui-surface-2)"], why: "the head paints --ui-surface-2" },
  { block: "card-title", stack: ["var(--ui-surface-2)"], why: "in .card-head" },
  { block: "card-root", stack: ["var(--ui-surface-2)"], why: "in .card-head" },
  { block: "tallies", stack: ["var(--ui-surface-2)"], why: "in .card-head" },
  { block: "tally", stack: ["var(--ui-surface-2)"], why: "in .card-head" },
  { block: "spawn", stack: ["var(--ui-surface-2)"], why: "in .card-head" },
  { block: "spawn-profile", stack: ["var(--ui-surface-2)"], why: "in .card-head" },
  { block: "spawn-button", stack: ["var(--ui-surface-2)"], why: "in .card-head" },
  { block: "goal", stack: ["var(--ui-surface-2)"], why: "a goal section is a row of .card-head" },
  { block: "goal-facts", stack: ["var(--ui-surface-2)"], why: "in a goal section of .card-head" },
  { block: "goal-top", stack: ["var(--ui-surface-2)"], why: "in a goal section of .card-head" },
  { block: "goal-title", stack: ["var(--ui-surface-2)"], why: "in a goal section of .card-head" },
  { block: "goal-slug", stack: ["var(--ui-surface-2)"], why: "in a goal section of .card-head" },
  { block: "goal-status", stack: ["var(--ui-surface-2)"], why: "in a goal section of .card-head" },
  { block: "goal-meta", stack: ["var(--ui-surface-2)"], why: "in a goal section of .card-head" },
  { block: "goal-next", stack: ["var(--ui-surface-2)"], why: "in a goal section of .card-head" },
  { block: "goal-link", stack: ["var(--ui-surface-2)"], why: "in a goal section of .card-head" },
  { block: "goal-none", stack: ["var(--ui-surface-2)"], why: "in .card-head, in place of a goal section" },
  { block: "crew-head", stack: ["var(--ui-surface)"], why: "a rule above the rows, on the card" },
  { block: "rows", stack: ["var(--ui-surface)"], why: "the row list, on the card" },
  { block: "row", stack: ["var(--ui-surface)"], why: "a row, on the card" },
  { block: "open", stack: ["var(--ui-surface)"], why: "the row's link, on the card" },
  { block: "main", stack: ["var(--ui-surface)"], why: "in a row, on the card" },
  { block: "top", stack: ["var(--ui-surface)"], why: "in a row, on the card" },
  { block: "folder", stack: ["var(--ui-surface)"], why: "in a row, on the card" },
  { block: "state", stack: ["var(--ui-surface)"], why: "in a row, on the card" },
  { block: "sub", stack: ["var(--ui-surface)"], why: "in a row, on the card" },
  { block: "meta", stack: ["var(--ui-surface)"], why: "in a row, on the card" },
  { block: "note", stack: ["var(--ui-surface)"], why: "in a row, on the card" },
  { block: "tag", stack: ["var(--ui-surface)"], why: "a chip in a row; .tag paints its own --ui-surface-2" },
  { block: "actions", stack: ["var(--ui-surface)"], why: "beside a row's text, on the card" },
  { block: "quiet", stack: ["var(--ui-surface)"], why: "a row action, on the card" },
  { block: "more", stack: ["var(--ui-surface)"], why: "the row's menu button, on the card" },
  { block: "menu", stack: ["var(--ui-surface)"], why: "the row's actions; .menu.open paints --ui-surface-2" },
  { block: "archived", stack: ["var(--ui-surface)"], why: "the archive fold, on the card" },
  { block: "archived-list", stack: ["var(--ui-surface)"], why: "in the archive fold, on the card" },
  { block: "archived-name", stack: ["var(--ui-surface)"], why: "in the archive fold, on the card" },
  { block: "archived-meta", stack: ["var(--ui-surface)"], why: "in the archive fold, on the card" },
  // --- styles.css: chrome floating over the terminal grid ---
  { block: "settings-host", stack: ["var(--ui-bg)"], why: "over the grid, whose background is --term-bg" },
  { block: "settings-gear", stack: ["var(--ui-bg)"], why: "over the grid; it paints --ui-veil itself" },
  { block: "keyboard-toggle-host", stack: ["var(--ui-bg)"], why: "over the grid" },
  { block: "keyboard-toggle", stack: ["var(--ui-bg)"], why: "over the grid; it paints --ui-veil itself" },
  { block: "take-control", stack: ["var(--ui-bg)"], why: "over the grid; it paints --ui-veil itself" },
  { block: "pane-close", stack: ["var(--ui-bg)"], why: "over the grid; it paints --ui-veil itself" },
  { block: "status", stack: ["var(--ui-bg)"], why: "over the grid; it paints --ui-veil itself" },
  { block: "search", stack: ["var(--ui-bg)"], why: "over the grid; #search paints --ui-veil itself" },
  { block: "terminal", stack: ["var(--ui-bg)"], why: "the grid's own host" },
  { block: "pane", stack: ["var(--ui-bg)"], why: "the grid's own host" },
  { block: "pane-inner", stack: ["var(--ui-bg)"], why: "the grid's own host" },
  { block: "extra-keys", stack: ["var(--ui-bg-sunken)"], why: "the key row paints --ui-bg-sunken" },
  { block: "extra-keys-row", stack: ["var(--ui-bg-sunken)"], why: "in .extra-keys" },
  { block: "extra-key", stack: ["var(--ui-bg-sunken)"], why: "in .extra-keys; the key paints --ui-hover itself" },
  { block: "extra-key-mod", stack: ["var(--ui-bg-sunken)"], why: "an .extra-key in .extra-keys; armed it paints --ui-accent" },
  // --- styles.css: the settings dialog ---
  { block: "settings-dialog", stack: ["var(--ui-surface)"], why: "the dialog paints --ui-surface" },
  { block: "settings-header", stack: ["var(--ui-surface)"], why: "in the dialog" },
  { block: "settings-close", stack: ["var(--ui-surface)"], why: "in the dialog; it paints --ui-surface-2 itself" },
  { block: "settings-field", stack: ["var(--ui-surface)"], why: "in the dialog" },
  { block: "settings-stepper", stack: ["var(--ui-surface)"], why: "in the dialog" },
  { block: "settings-local-font", stack: ["var(--ui-surface)"], why: "in the dialog" },
  { block: "settings-local-list", stack: ["var(--ui-surface)"], why: "in the dialog; it paints --ui-bg itself" },
  { block: "settings-local-item", stack: ["var(--ui-bg)"], why: "in .settings-local-list, which paints --ui-bg" },
  { block: "settings-local-more", stack: ["var(--ui-surface)"], why: "in the dialog" },
  { block: "settings-local-status", stack: ["var(--ui-surface)"], why: "in the dialog" },
  { block: "settings-check", stack: ["var(--ui-surface)"], why: "in the dialog" },
  { block: "settings-note", stack: ["var(--ui-surface)"], why: "in the dialog" },
  { block: "settings-share", stack: ["var(--ui-surface)"], why: "in the dialog" },
  { block: "settings-about", stack: ["var(--ui-surface)"], why: "in the dialog" },
  { block: "settings-about-update", stack: ["var(--ui-surface)"], why: "in the dialog" },
  // --- styles.css: the getting-started card, over a scrim ---
  { block: "intro-card", stack: ["var(--ui-surface)"], why: "the card paints --ui-surface" },
  { block: "intro-header", stack: ["var(--ui-surface)"], why: "in .intro-card" },
  { block: "intro-title", stack: ["var(--ui-surface)"], why: "in .intro-card" },
  { block: "intro-tagline", stack: ["var(--ui-surface)"], why: "in .intro-card" },
  { block: "intro-body", stack: ["var(--ui-surface)"], why: "in .intro-card" },
  { block: "intro-section-title", stack: ["var(--ui-surface)"], why: "in .intro-card" },
  { block: "intro-rows", stack: ["var(--ui-surface)"], why: "in .intro-card" },
  { block: "intro-keys", stack: ["var(--ui-surface)"], why: "in .intro-card" },
  { block: "intro-what", stack: ["var(--ui-surface)"], why: "in .intro-card" },
  { block: "intro-footer", stack: ["var(--ui-surface)"], why: "in .intro-card" },
  { block: "intro-hint", stack: ["var(--ui-surface)"], why: "in .intro-card" },
  { block: "intro-dismiss", stack: ["var(--ui-surface)"], why: "in .intro-card; it paints --ui-accent itself" },
  // --- styles.css: the touch selection bar and the file preview ---
  { block: "selection-bar", stack: ["var(--ui-bg)"], why: "over the grid; it paints --ui-surface-2 itself" },
  { block: "selection-action", stack: ["var(--ui-surface-2)"], why: "in .selection-bar, which paints --ui-surface-2" },
  { block: "preview-card", stack: ["var(--ui-surface)"], why: "the card paints --ui-surface" },
  { block: "preview-header", stack: ["var(--ui-surface)"], why: "in .preview-card" },
  { block: "preview-heading", stack: ["var(--ui-surface)"], why: "in .preview-header" },
  { block: "preview-title", stack: ["var(--ui-surface)"], why: "in .preview-header" },
  { block: "preview-sub", stack: ["var(--ui-surface)"], why: "in .preview-header" },
  { block: "preview-close", stack: ["var(--ui-surface)"], why: "in .preview-header; it paints --ui-hover itself" },
  { block: "preview-body", stack: ["var(--ui-surface)"], why: "in .preview-card; it paints --ui-bg-sunken itself" },
  { block: "preview-code", stack: ["var(--ui-bg-sunken)"], why: "in .preview-body, which paints --ui-bg-sunken" },
  { block: "code-gutter", stack: ["var(--ui-bg-sunken)"], why: "in .preview-code; it repaints --ui-bg-sunken" },
  { block: "code-text", stack: ["var(--ui-bg-sunken)"], why: "in .preview-code, on --ui-bg-sunken" },
  { block: "preview-note", stack: ["var(--ui-bg-sunken)"], why: "in .preview-body, on --ui-bg-sunken" },
  { block: "tok-comment", stack: ["var(--ui-bg-sunken)"], why: "a token of .code-text, on --ui-bg-sunken" },
  { block: "tok-string", stack: ["var(--ui-bg-sunken)"], why: "a token of .code-text, on --ui-bg-sunken" },
  { block: "tok-number", stack: ["var(--ui-bg-sunken)"], why: "a token of .code-text, on --ui-bg-sunken" },
  { block: "tok-keyword", stack: ["var(--ui-bg-sunken)"], why: "a token of .code-text, on --ui-bg-sunken" },
  { block: "tok-name", stack: ["var(--ui-bg-sunken)"], why: "a token of .code-text, on --ui-bg-sunken" },
  { block: "tok-attr", stack: ["var(--ui-bg-sunken)"], why: "a token of .code-text, on --ui-bg-sunken" },
  { block: "tok-link", stack: ["var(--ui-bg-sunken)"], why: "a token of .code-text, on --ui-bg-sunken" },
  { block: "tok-error", stack: ["var(--ui-bg-sunken)"], why: "a token of .code-text, on --ui-bg-sunken" },
  { block: "tok-punct", stack: ["var(--ui-bg-sunken)"], why: "a token of .code-text, on --ui-bg-sunken" },
  // --- styles.css: the paste prompt and the file picker ---
  { block: "paste-prompt", stack: ["var(--ui-bg)"], why: "over the grid; it paints --ui-surface-2 itself" },
  { block: "paste-prompt-hint", stack: ["var(--ui-surface-2)"], why: "in .paste-prompt, which paints --ui-surface-2" },
  { block: "paste-prompt-field", stack: ["var(--ui-surface-2)"], why: "in .paste-prompt; it paints --ui-bg itself" },
  { block: "paste-prompt-actions", stack: ["var(--ui-surface-2)"], why: "in .paste-prompt" },
  { block: "paste-prompt-button", stack: ["var(--ui-surface-2)"], why: "in .paste-prompt; it paints --ui-hover itself" },
  { block: "file-picker", stack: ["var(--ui-bg)"], why: "over the grid; it paints --ui-surface itself" },
  { block: "file-picker-header", stack: ["var(--ui-surface)"], why: "in .file-picker; it paints --ui-bg-sunken itself" },
  { block: "file-picker-path", stack: ["var(--ui-bg-sunken)"], why: "in .file-picker-header, on --ui-bg-sunken" },
  { block: "file-picker-use", stack: ["var(--ui-bg-sunken)"], why: "in .file-picker-header, on --ui-bg-sunken" },
  { block: "file-picker-search", stack: ["var(--ui-surface)"], why: "in .file-picker, on --ui-surface" },
  { block: "file-picker-input", stack: ["var(--ui-surface)"], why: "in .file-picker-search, on --ui-surface" },
  { block: "file-picker-count", stack: ["var(--ui-surface)"], why: "in .file-picker-search, on --ui-surface" },
  { block: "file-picker-list", stack: ["var(--ui-surface)"], why: "in .file-picker, on --ui-surface" },
  { block: "file-picker-row", stack: ["var(--ui-surface)"], why: "in .file-picker-list, on --ui-surface" },
  { block: "file-picker-name", stack: ["@file-picker-row"], why: "in .file-picker-row, whatever state it is in" },
  { block: "file-picker-size", stack: ["@file-picker-row"], why: "in .file-picker-row, whatever state it is in" },
  { block: "file-picker-hint", stack: ["var(--ui-surface)"], why: "in .file-picker; it paints --ui-bg-sunken itself" },
  { block: "file-picker-empty", stack: ["var(--ui-surface)"], why: "in .file-picker-list, on --ui-surface" },
];

/**
 * Rules the derivation leaves out, each with the reason. Keep this list short
 * and specific: a broad pattern here is the same hole the hand list was.
 */
const NOT_TEXT: Array<{ selector: string; why: string }> = [
  { selector: ".intro-logo", why: "a 40px box holding the logo svg; it carries no text" },
  // WCAG 1.4.3 exempts text that is part of an inactive user interface
  // component. The spawn button and the disabled settings fields fade to 0.5
  // to say they are inactive, which is the exemption, not a defect.
  { selector: ".spawn-button:disabled", why: "an inactive component; WCAG 1.4.3 exempts it" },
  {
    selector: '.settings-check input[type="checkbox"]:disabled',
    why: "an inactive component; WCAG 1.4.3 exempts it",
  },
  { selector: '.settings-field input[type="text"]:disabled', why: "an inactive component; WCAG 1.4.3 exempts it" },
  { selector: ".settings-check:has(input:disabled)", why: "an inactive component; WCAG 1.4.3 exempts it" },
];

/* --- the derivation ------------------------------------------------------- */

/** One text rule of one stylesheet, with everything a ratio needs. */
export interface DerivedRule {
  sheet: string;
  line: number;
  selector: string;
  conditions: string[];
  /** The text colour as written, still a CSS expression. */
  color: string;
  px: number | null;
  weight: number | null;
  /** `opacity` in force, 1 when the element sets none. */
  opacity: number;
  /** Every surface the element can sit on; each one is a pair. */
  surfaces: Surface[];
}

/** A rule the surface rule could not place: a hole in the measurement. */
export interface Hole {
  sheet: string;
  line: number;
  selector: string;
  why: string;
}

const backgroundOf = (decls: Map<string, string>): string | null => {
  const value = decls.get("background-color") ?? decls.get("background");
  if (value === undefined) return null;
  const first = value.trim();
  if (first === "none" || first === "transparent") return "transparent";
  return first;
};

/** True once the expression paints something a reader sees through nothing. */
const isOpaque = (expr: string, probe: Map<string, string>): boolean => {
  try {
    return resolveColor(expr, probe).a >= 1;
  } catch {
    return false;
  }
};

const lastOf = <T,>(items: T[]): T => items[items.length - 1];

/**
 * Every background any rule of this sheet paints on the element, in the
 * conditions of `under`. `loose` widens the match from the element's own class
 * list to any element carrying its first class, which is how an ancestor's
 * unnamed states are found: `.strip-item` is also `.strip-item.failed` and
 * `.strip-item.approval`. Strict, it returns only the states the selector does
 * not name (`.chip.on` beside `.chip`); what the element's own cascade paints
 * is `basePaint`. `transparent` is kept, because it means the surface below
 * shows through.
 */
const paintedOn = (
  all: Placed[],
  compound: Compound,
  context: Compound[],
  under: string[],
  loose: boolean,
): string[] => {
  const found: string[] = [];
  for (const rule of all) {
    if (!conditionsApply(rule.conditions, under)) continue;
    const last = lastOf(rule.compounds);
    const matches = loose
      ? compound.classes.length > 0
        ? last.classes.includes(compound.classes[0]) && subset(last.pseudos, compound.pseudos)
        : compoundApplies(last, compound)
      : compoundVariant(last, compound);
    if (!matches) continue;
    if (compound.element && last.element && last.element !== compound.element) continue;
    if (compound.id && last.id && last.id !== compound.id) continue;
    if (!contextApplies(rule.compounds.slice(0, -1), context)) continue;
    // A state that repaints the text as well is its own rule with its own
    // pair: `.paste-prompt-button.is-primary` puts --ui-accent-on on the
    // accent, never the plain button's --ui-text.
    if (!loose && rule.decls.has("color")) continue;
    const background = backgroundOf(rule.decls);
    if (background !== null && !found.includes(background)) found.push(background);
  }
  return found;
};

/** The background in force on the element itself, cascade only: `null` when no
 * rule sets one, `"transparent"` when the surface below shows through. */
const basePaint = (all: Placed[], compound: Compound, context: Compound[], under: string[]): string | null => {
  let background: string | null = null;
  const applies = all.filter(
    (r) =>
      conditionsApply(r.conditions, under) &&
      compoundApplies(lastOf(r.compounds), compound) &&
      contextApplies(r.compounds.slice(0, -1), context),
  );
  applies.sort((a, b) => specificity(a.compounds) - specificity(b.compounds) || all.indexOf(a) - all.indexOf(b));
  for (const rule of applies) {
    const paint = backgroundOf(rule.decls);
    if (paint !== null) background = paint;
  }
  return background;
};

/** The table entry for a compound. The element's first class is its block:
 * `.menu.open` is a menu that is open, not an `.open` that is a menu. */
const blockEntryFor = (compound: Compound): (typeof BLOCK_SURFACES)[number] | undefined => {
  const names = [...compound.classes, compound.id, compound.element].filter(Boolean);
  for (const name of names) {
    const entry = BLOCK_SURFACES.find((e) => e.block === name);
    if (entry) return entry;
  }
  return undefined;
};

const sameStack = (a: string[], b: string[]): boolean => a.length === b.length && a.every((x, i) => x === b[i]);
const addStack = (into: string[][], stack: string[]): void => {
  if (!into.some((s) => sameStack(s, stack))) into.push(stack);
};

/**
 * Lays the paints an element can wear over what it sits on. An opaque paint
 * replaces the base; a translucent one stacks on it; `transparent` or no paint
 * at all leaves the base showing. The bare base is a candidate only when the
 * element's own cascade leaves it visible — a `.strip-item` always wears one
 * of its three tints, so `--ui-bg` is not one of its surfaces.
 */
const layer = (base: string[][], paints: string[], own: string | null, probe: Map<string, string>): string[][] => {
  const out: string[][] = [];
  const all = own === null ? paints : [own, ...paints.filter((p) => p !== own)];
  if (own === null || own === "transparent") for (const stack of base) addStack(out, stack);
  for (const paint of all) {
    if (paint === "transparent") {
      for (const stack of base) addStack(out, stack);
    } else if (isOpaque(paint, probe)) {
      addStack(out, [paint]);
    } else {
      for (const stack of base) addStack(out, [...stack, paint]);
    }
  }
  return out.length > 0 ? out : base;
};

/** Expands an `@block` reference in a table entry to that block's own surfaces. */
const expandStack = (
  stack: string[],
  all: Placed[],
  under: string[],
  probe: Map<string, string>,
): string[][] => {
  const head = stack[0];
  if (!head.startsWith("@")) return [stack];
  const target = parseCompound("." + head.slice(1));
  const entry = blockEntryFor(target);
  const base = entry ? expandStack(entry.stack, all, under, probe) : [["var(--ui-bg)"]];
  const paints = paintedOn(all, target, [], under, true);
  const own = basePaint(all, target, [], under);
  return layer(base, paints, own, probe).map((s) => [...s, ...stack.slice(1)]);
};

/** The surfaces one compound offers, or `null` when nothing places it. */
const stacksFor = (
  all: Placed[],
  compound: Compound,
  context: Compound[],
  under: string[],
  probe: Map<string, string>,
  loose: boolean,
): string[][] | null => {
  const entry = blockEntryFor(compound);
  const base = entry ? expandStack(entry.stack, all, under, probe) : null;
  const paints = paintedOn(all, compound, context, under, loose);
  const own = basePaint(all, compound, context, under);
  if (paints.length === 0) return base;
  if (base === null) {
    const opaque = paints.filter((p) => p !== "transparent" && isOpaque(p, probe));
    return opaque.length > 0 ? opaque.map((p) => [p]) : null;
  }
  return layer(base, paints, own, probe);
};

/**
 * The surface rule of the doc comment above, applied to one rule.
 * Returns every surface the element can sit on, or a reason it cannot be
 * placed.
 */
const surfacesFor = (
  all: Placed[],
  target: Placed,
  probe: Map<string, string>,
): { surfaces: Surface[] } | { why: string } => {
  const element = lastOf(target.compounds);
  const ancestors = target.compounds.slice(0, -1);

  // Steps 2 and 3: what the element sits on, before its own paint.
  let under: string[][] | null = null;
  let how = "";
  for (let i = ancestors.length - 1; i >= 0 && under === null; i -= 1) {
    under = stacksFor(all, ancestors[i], ancestors.slice(0, i), target.conditions, probe, true);
    if (under !== null) how = `the written ancestor ${target.selector.split(" ").slice(0, i + 1).join(" ")}`;
  }
  if (under === null) {
    const entry = blockEntryFor(element);
    if (!entry) return { why: "no written ancestor paints a background and no block table entry names it" };
    under = expandStack(entry.stack, all, target.conditions, probe);
    how = `the block table: .${entry.block} — ${entry.why}`;
  }

  // Step 1: the element's own paint, and the states its own selector allows.
  const paints = paintedOn(all, element, ancestors, target.conditions, false);
  const own = basePaint(all, element, ancestors, target.conditions);
  const stacks = layer(under, paints, own, probe);
  return {
    surfaces: stacks.map((stack) => ({
      stack,
      how: under.some((b) => sameStack(b, stack)) ? how : `${how}, under the element's own ${lastOf(stack)}`,
    })),
  };
};

/** A rule shapes text when it sets a colour or a size — and when it only
 * repaints the background, because the text above it is then on a new surface
 * (`.extra-key:active`, `.file-picker-row.is-selected`). */
/** Colour keywords that take the value of the element's parent. */
const INHERITED = ["inherit", "currentcolor", "unset"];

const TEXT_PROPERTIES = [
  "color",
  "font-size",
  "font-weight",
  "font",
  "background",
  "background-color",
  // A rule that only fades the element changes what reaches the eye: the gear
  // is 0.35 opaque with a pointer and 0.65 on touch.
  "opacity",
];

/**
 * Reads one stylesheet and returns every text rule it holds with the surface
 * or surfaces its element sits on, plus the rules the surface rule could not
 * place. `probe` is any theme's variable table; it is used only to decide
 * whether a background is opaque, which no theme changes.
 */
export const deriveSheet = (
  sheet: string,
  source: string,
  probe: Map<string, string>,
): { rules: DerivedRule[]; holes: Hole[] } => {
  const parsed = parseCss(sheet, source).map((r) => ({ ...r, compounds: parseSelector(r.selector) }));
  // What `inherit` resolves to: the colour the sheet sets on the document.
  const root =
    parsed.find((r) => (r.selector === "body" || r.selector === "html") && r.decls.has("color"))?.decls.get("color") ??
    "var(--ui-text)";
  const rules: DerivedRule[] = [];
  const holes: Hole[] = [];
  for (const rule of parsed) {
    if (!TEXT_PROPERTIES.some((p) => rule.decls.has(p))) continue;
    if (NOT_TEXT.some((x) => x.selector === rule.selector)) continue;
    const decls = cascadeFor(parsed, rule);
    const { px, weight } = fontOf(decls);
    if (!decls.has("color") && px === null) continue;
    const placed = surfacesFor(parsed, rule, probe);
    if ("why" in placed) {
      holes.push({ sheet, line: rule.line, selector: rule.selector, why: placed.why });
      continue;
    }
    const opacity = Number(decls.get("opacity") ?? "1");
    const written = decls.get("color");
    const color = written === undefined || INHERITED.includes(written.trim().toLowerCase()) ? root : written;
    rules.push({
      sheet,
      line: rule.line,
      selector: rule.selector,
      conditions: rule.conditions,
      color,
      px,
      weight,
      opacity: Number.isFinite(opacity) ? opacity : 1,
      surfaces: placed.surfaces,
    });
  }
  return { rules, holes };
};

/* --- tokens --------------------------------------------------------------- */

/**
 * The `:root` block of `tokens.css`, as a variable table. Only the
 * unconditional block: the `@supports (color: contrast-color(...))` upgrade
 * cannot be evaluated here, and the JS-published `--term-accent-on` is what
 * every browser without it paints.
 */
export const rootVariables = (tokensCss: string): Map<string, string> => {
  const vars = new Map<string, string>();
  for (const rule of parseCss("tokens.css", tokensCss)) {
    if (rule.conditions.length > 0 || rule.selector !== ":root") continue;
    for (const [name, value] of rule.decls) if (name.startsWith("--")) vars.set(name, value);
  }
  return vars;
};

/** Reads a file beside this module. */
export const readSource = (name: string): string => readFileSync(new URL(`./${name}`, import.meta.url), "utf8");

/* --- pairs ---------------------------------------------------------------- */

/** One text-and-background pair, with every rule that produces it. */
export interface Pair {
  /** `--ui-text-muted on --ui-surface`: the key `KNOWN_BELOW` is written in. */
  key: string;
  /** The text colour as written. */
  color: string;
  /** The surface, painted bottom to top. */
  stack: string[];
  /** `opacity` in force on the text, 1 unless the element fades. */
  opacity: number;
  /** 4.5, or 3 where WCAG calls the text large. */
  floor: number;
  /** `sessions.css:250 .tag`, in file order; the first is named in a failure. */
  rules: string[];
}

const short = (expr: string): string => expr.replace(/var\((--[a-z0-9-]+)\)/g, "$1");

const keyOf = (color: string, stack: string[], opacity: number, floor: number): string =>
  `${short(color)} on ${stack.map(short).join(" + ")}` +
  (opacity < 1 ? ` at ${Math.round(opacity * 100)}% opacity` : "") +
  (floor !== 4.5 ? ` (large text)` : "");

/**
 * Every pair the two pages paint, one entry per distinct
 * colour-surface-opacity-floor combination, and every rule the surface rule
 * could not place.
 */
export const derivePairs = (
  sheets: Array<[name: string, source: string]>,
  probe: Map<string, string>,
): { pairs: Pair[]; holes: Hole[] } => {
  const byKey = new Map<string, Pair>();
  const holes: Hole[] = [];
  for (const [name, source] of sheets) {
    const derived = deriveSheet(name, source, probe);
    holes.push(...derived.holes);
    for (const rule of derived.rules) {
      for (const surface of rule.surfaces) {
        const floor = floorFor(rule.px, rule.weight);
        const key = keyOf(rule.color, surface.stack, rule.opacity, floor);
        const at = byKey.get(key) ?? {
          key,
          color: rule.color,
          stack: surface.stack,
          opacity: rule.opacity,
          floor,
          rules: [],
        };
        at.rules.push(`${rule.sheet}:${rule.line} ${rule.selector} — ${surface.how}`);
        byKey.set(key, at);
      }
    }
  }
  return { pairs: [...byKey.values()], holes };
};

/**
 * The ratio a browser paints for one pair on one theme. The surface is
 * composited bottom to top, and a faded element is composited over it: WCAG
 * measures what reaches the eye, not what the declaration says.
 *
 * The element's own background is faded with its text, so this is exact only
 * where the two are close — the gear and the pane close button paint
 * `--ui-veil` over the grid, which is `--ui-bg` either way.
 */
export const ratioFor = (pair: Pair, vars: Map<string, string>): number => {
  let surface = resolveColor(pair.stack[0], vars);
  for (const layer of pair.stack.slice(1)) surface = composite(resolveColor(layer, vars), surface);
  const text = resolveColor(pair.color, vars);
  return contrastRatio(composite({ ...text, a: text.a * pair.opacity }, surface), surface);
};
