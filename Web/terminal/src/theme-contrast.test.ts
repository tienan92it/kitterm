import { describe, expect, it } from "vitest";

import { accentOn, luminance, parseHex, pickAccent, themeTokens } from "./theme-tokens";
import { TERMINAL_THEMES } from "./themes";

/**
 * The fleet page's small text against the surface it sits on, for every
 * bundled theme. The token layer derives `--ui-surface` and
 * `--ui-text-muted` with `color-mix(in oklab, …)`; the mix is reproduced
 * here (Björn Ottosson's Oklab, the matrices browsers use), so the ratios
 * are the ones a browser paints within a few hundredths.
 *
 * The floor is WCAG 1.4.3: 4.5:1 for small text. The accent button text
 * holds it on every theme. The state label is the theme's own foreground,
 * which two themes set under 4.5 on a card; the muted line is the theme's
 * 66% mix in `tokens.css`, under 4.5 on ten, and on twelve against
 * `--ui-surface-2` (the `.tag` chips). `KNOWN_BELOW` names each with
 * the ratio measured here, so the test fails when one gets worse, when an
 * unlisted one drops under the floor, or when a listed one starts passing
 * and the entry is stale.
 *
 * Which class uses which token is `sessions.css`'s side; vitest returns an
 * empty string for a `.css?raw` import, so that mapping is checked by hand
 * with a browser's computed style (rounds/005.md).
 */

const FLOOR = 4.5;

/** The lines measured: the state label and the muted line on `--ui-surface`
 * (the card), and the same two colours on `--ui-surface-2` (the card head,
 * where the goal block and the proposals chip sit, and every `.tag`). */
type Line = "label" | "muted" | "label-2" | "muted-2";

/** Ratios under the floor today, by theme and line (see the file comment). */
const KNOWN_BELOW: Record<string, Partial<Record<Line, number>>> = {
  "github-dark-dimmed": { muted: 3.3, "muted-2": 2.85 },
  "solarized-dark": { label: 3.95, muted: 2.3, "label-2": 3.45, "muted-2": 2.0 },
  nord: { muted: 3.95, "muted-2": 3.4 },
  "one-dark": { muted: 2.95, "muted-2": 2.55 },
  "tokyo-night": { muted: 4.2, "muted-2": 3.65 },
  "tokyo-night-storm": { muted: 3.75, "muted-2": 3.25 },
  "catppuccin-macchiato": { muted: 4.05, "muted-2": 3.55 },
  "catppuccin-mocha": { "muted-2": 3.9 },
  "ayu-mirage": { muted: 3.9, "muted-2": 3.4 },
  "gruvbox-dark": { muted: 4.3, "muted-2": 3.75 },
  "rose-pine": { "muted-2": 4.4 },
  "synthwave-84": { label: 3.6, muted: 2.15, "label-2": 3.1, "muted-2": 1.85 },
};

type RGB = [number, number, number];

const toLinear = (c: number): number => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const toGamma = (c: number): number => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);

function toOklab(hex: string): [number, number, number] {
  const rgb = parseHex(hex);
  if (!rgb) throw new Error(`not a colour: ${hex}`);
  const [r, g, b] = rgb.map((v) => toLinear(v / 255)) as RGB;
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

function fromOklab([L, a, b]: [number, number, number]): string {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3;
  const linear: RGB = [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ];
  const channel = (c: number) => Math.round(Math.min(1, Math.max(0, toGamma(c))) * 255);
  return "#" + linear.map((c) => channel(c).toString(16).padStart(2, "0")).join("");
}

/** `color-mix(in oklab, a <weight>%, b)`. */
function mixOklab(a: string, b: string, weight: number): string {
  const [la, aa, ba] = toOklab(a);
  const [lb, ab, bb] = toOklab(b);
  const w = weight / 100;
  return fromOklab([la * w + lb * (1 - w), aa * w + ab * (1 - w), ba * w + bb * (1 - w)]);
}

/** WCAG 2.x contrast ratio, 1 to 21. */
export function contrast(a: string, b: string): number {
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/** The page's colours for one theme, as `tokens.css` derives them. */
function palette(colors: { background?: string; foreground?: string }, accent: string) {
  const bg = colors.background ?? "#0d1117";
  const text = colors.foreground ?? "#e6edf3";
  const lift = luminance(bg) < 0.5 ? "#fff" : "#000";
  return {
    surface: mixOklab(bg, lift, 93),
    surface2: mixOklab(bg, lift, 88),
    text,
    muted: mixOklab(text, bg, 66),
    accent,
    accentOn: accentOn(accent),
  };
}

function check(theme: string, line: Line, ratio: number): void {
  const known = KNOWN_BELOW[theme]?.[line];
  if (known === undefined) {
    expect(ratio, `${theme} ${line} dropped under ${FLOOR}:1`).toBeGreaterThanOrEqual(FLOOR);
    return;
  }
  expect(ratio, `${theme} ${line} got worse than its KNOWN_BELOW entry`).toBeGreaterThanOrEqual(known);
  expect(ratio, `${theme} ${line} now passes; drop its KNOWN_BELOW entry`).toBeLessThan(FLOOR);
}

describe("every bundled theme on the fleet page", () => {
  for (const entry of TERMINAL_THEMES) {
    const accent = pickAccent(entry.colors, entry.accent);
    const p = palette(entry.colors, accent);

    it(`${entry.id}: the accent button text (--ui-accent-on on --ui-accent) is at least 4.5:1`, () => {
      expect(contrast(p.accentOn, p.accent)).toBeGreaterThanOrEqual(FLOOR);
      expect(themeTokens(entry.colors, { accent: entry.accent })["--term-accent-on"]).toBe(p.accentOn);
    });

    it(`${entry.id}: the state label (--ui-text on --ui-surface)`, () => {
      check(entry.id, "label", contrast(p.text, p.surface));
    });

    it(`${entry.id}: the muted line (--ui-text-muted on --ui-surface)`, () => {
      check(entry.id, "muted", contrast(p.muted, p.surface));
    });

    it(`${entry.id}: the goal meta and the proposals chip (--ui-text on --ui-surface-2)`, () => {
      check(entry.id, "label-2", contrast(p.text, p.surface2));
    });

    it(`${entry.id}: a tag (--ui-text-muted on --ui-surface-2)`, () => {
      check(entry.id, "muted-2", contrast(p.muted, p.surface2));
    });
  }
});

describe("accentOn", () => {
  it("picks the pole with the higher ratio", () => {
    expect(accentOn("#58a6ff")).toBe("#000");
    expect(accentOn("#1f3a8a")).toBe("#fff");
    expect(accentOn("#ffffff")).toBe("#000");
  });
});
