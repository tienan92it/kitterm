import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { type CssRule, derivePairs, parseCss, ratioFor, readSource, rootVariables } from "./theme-contrast-derive";
import { themeTokens } from "./theme-tokens";
import { TERMINAL_THEMES } from "./themes";

/**
 * The foundation's proofs for the `/edit` page (`code-editor` round 4;
 * `design/foundation.md`, the 16 rules of the `Editor components` frame).
 * `edit.css` is the page's own sheet, which the frozen sheet list of
 * `theme-contrast.test.ts` does not read, so this file pins what that
 * ratchet pins for the fleet view: the tokens the page defines, the
 * absences (no bare pixel for margin, padding or gap; no `font-size` but the
 * two mark tokens; no radius above 2 px; no shadow; no transition), the
 * owned colours on a mark's background and never on `color`, the three
 * foundation additions the human approved (the editor at `md-code`, the
 * diff line colours, the `keys-` bar), and every text pair the sheet paints
 * against every bundled theme.
 */
const SOURCE = readFileSync(new URL("./edit.css", import.meta.url), "utf8");
const RULES: CssRule[] = parseCss("edit.css", SOURCE);
const TOKENS = rootVariables(readSource("tokens.css"));

const at = (rule: CssRule): string => `${rule.sheet}:${rule.line} ${rule.selector}`;

const declarations = (matches: (property: string) => boolean): Array<[string, string, string]> =>
  RULES.flatMap((rule) =>
    [...rule.decls].filter(([name]) => matches(name)).map(([name, value]) => [at(rule), name, value] as [string, string, string]),
  );

const decl = (selector: string, property: string): string | undefined => {
  let value: string | undefined;
  for (const rule of RULES) if (rule.selector === selector && rule.decls.has(property)) value = rule.decls.get(property);
  return value;
};

const root = RULES.find((rule) => rule.selector === ":root" && rule.decls.has("--space-1"));

describe("edit.css carries the foundation", () => {
  it("parses the sheet it pins", () => {
    expect(RULES.length).toBeGreaterThan(40);
    expect(root, "a :root block with the tokens").toBeDefined();
  });

  it("defines the space scale, the type shorthands, the two mark sizes and the line height", () => {
    expect(root!.decls.get("--space-1")).toBe("4px");
    expect(root!.decls.get("--space-2")).toBe("8px");
    expect(root!.decls.get("--space-3")).toBe("12px");
    expect(root!.decls.get("--space-4")).toBe("16px");
    expect(root!.decls.get("--space-5")).toBe("24px");
    expect(root!.decls.get("--type-heading")).toBe("600 13px/1.5 var(--font-mono)");
    expect(root!.decls.get("--type-body")).toBe("400 12px/1.5 var(--font-mono)");
    // The editor at `md-code`, 12.5 px with a line height of 1.6 (rule 6,
    // the foundation's addition of 2026-10-18).
    expect(root!.decls.get("--type-code")).toBe("400 12.5px/1.6 var(--font-mono)");
    expect(root!.decls.get("--mark-size")).toBe("14px");
    expect(root!.decls.get("--mark-size-disclosure")).toBe("11px");
    expect(root!.decls.get("--line-h")).toBe("44px");
    expect(SOURCE).toMatch(/@media \(min-width: 768px\)\s*\{\s*:root\s*\{[^}]*--line-h: 28px/);
    expect(root!.decls.get("--sidebar-w")).toBe("280px");
  });

  it("owns the four state colours and leaves the ground and the greys to tokens.css", () => {
    expect(root!.decls.get("--ui-accent")).toBe("light-dark(#1d7268, #2a9d8f)");
    expect(root!.decls.get("--ui-success")).toBe("light-dark(#2d6a4f, #52b788)");
    expect(root!.decls.get("--ui-warning")).toBe("light-dark(#8a6415, #e9c46a)");
    expect(root!.decls.get("--ui-danger")).toBe("light-dark(#b0472c, #e76f51)");
    for (const token of ["--ui-bg", "--ui-surface", "--ui-surface-2", "--ui-border", "--ui-text", "--ui-text-muted", "--ui-text-faint", "--ui-bg-sunken"]) {
      expect(root!.decls.has(token), token).toBe(false);
    }
  });

  it("writes no bare pixel for margin, padding or gap", () => {
    const bare = declarations((p) => p === "margin" || p === "padding" || p === "gap" || /^(margin|padding)-/.test(p))
      .filter(([, , value]) => /(^|\s)\d*\.?\d+px/.test(value))
      .map(([where, name, value]) => `${where} ${name}: ${value}`);
    expect(bare).toEqual([]);
  });

  it("sets font-size only on the marks, and every other font through a token", () => {
    const sizes = declarations((p) => p === "font-size").map(([where, , value]) => `${where} font-size: ${value}`);
    expect(sizes.every((line) => line.includes("var(--mark-size"))).toBe(true);
    expect(sizes.length).toBeGreaterThan(0);
    const fonts = declarations((p) => p === "font").filter(([, , value]) => value !== "inherit");
    expect(fonts.every(([, , value]) => /^var\(--type-/.test(value)), fonts.map((f) => f.join(" ")).join("\n")).toBe(true);
  });

  it("rounds no corner by more than 2 px, casts no shadow and animates nothing but the saving mark", () => {
    const rounded = declarations((p) => p.endsWith("radius"))
      .filter(([, , value]) => !/^(0|2px)$/.test(value))
      .map(([where, , value]) => `${where} ${value}`);
    expect(rounded).toEqual([]);
    expect(declarations((p) => p === "box-shadow")).toEqual([]);
    expect(declarations((p) => p.startsWith("transition"))).toEqual([]);
    const animated = declarations((p) => p.startsWith("animation")).map(([where]) => where);
    expect(animated.every((where) => where.includes(".edit-state.accent .edit-mark")), animated.join("\n")).toBe(true);
  });

  it("paints the owned colours on a mark's background, never on color, but the diff's lines", () => {
    const owned = /var\(--ui-(accent|success|warning|danger)\)/;
    const coloured = declarations((p) => p === "color")
      .filter(([, , value]) => owned.test(value))
      .map(([where]) => where);
    // The foundation's one exception (2026-10-18): a `+` line in success and
    // a `−` line in danger over its whole text.
    expect(coloured.sort()).toEqual(
      ["edit.css .edit-diff-line.add .edit-diff-text", "edit.css .edit-diff-line.del .edit-diff-text"].map((s) => {
        const rule = RULES.find((r) => at(r).endsWith(s.slice("edit.css ".length)));
        return rule ? at(rule) : s;
      }).sort(),
    );
    expect(decl(".edit-diff-line.add .edit-diff-text", "color")).toBe("var(--ui-success)");
    expect(decl(".edit-diff-line.del .edit-diff-text", "color")).toBe("var(--ui-danger)");
    expect(decl(".edit-diff-line.hunk .edit-diff-text", "color")).toBe("var(--code-link)");
    // No owned colour behind text or on a border.
    const behind = declarations((p) => p === "background" || p === "background-color" || p.startsWith("border"))
      .filter(([where, , value]) => owned.test(value) && !where.includes(".edit-mark") && !where.includes(".edit-state-word") && !/edit-(save|terminal|bar-button|diff-back|key-save)/.test(where))
      .map(([where, name, value]) => `${where} ${name}: ${value}`);
    expect(behind).toEqual([]);
    for (const tone of ["warning", "accent", "success"]) {
      expect(decl(`.edit-mark.${tone}`, "background")).toBe(`var(--ui-${tone})`);
      expect(decl(`.edit-state-word.${tone}`, "background")).toBe(`var(--ui-${tone})`);
    }
    expect(decl(".edit-mark.danger", "background")).toBe("var(--ui-danger)");
    expect(decl(".edit-mark", "background-clip")).toBe("text");
    expect(decl(".edit-mark", "-webkit-text-fill-color")).toBe("transparent");
  });

  it("draws the editor on the well, its gutter faint with a hairline, and the open row on surface-2", () => {
    expect(decl(".edit-editor .cm-editor", "background")).toBe("var(--ui-bg-sunken)");
    expect(decl(".edit-editor .cm-editor", "font")).toBe("var(--type-code)");
    expect(decl(".edit-editor .cm-gutters", "color")).toBe("var(--ui-text-faint)");
    expect(decl(".edit-editor .cm-gutters", "border-right")).toBe("1px solid var(--ui-border)");
    expect(decl(".edit-editor .cm-gutters", "min-width")).toBe("var(--gutter-w)");
    expect(root!.decls.get("--gutter-w")).toBe("36px");
    expect(SOURCE).toMatch(/--gutter-w: 48px/);
    expect(decl(".edit-row.open", "background")).toBe("var(--ui-surface-2)");
    expect(decl(".edit-row", "height")).toBe("var(--line-h)");
    expect(decl(".edit-triangle", "font-size")).toBe("var(--mark-size-disclosure)");
    for (const kind of ["comment", "string", "number", "keyword", "name", "attr", "link", "error", "punct"]) {
      expect(decl(`.tok-${kind}`, "color"), kind).toBe(`var(--code-${kind})`);
    }
  });

  it("puts the bars on the surface under a hairline and the key bar at 44 px above the keyboard", () => {
    expect(decl(".edit-bar", "background")).toBe("var(--ui-surface)");
    expect(decl(".edit-bar", "border-bottom")).toBe("1px solid var(--ui-border)");
    expect(decl(".edit-bar", "min-height")).toBe("44px");
    expect(decl(".edit-keys", "height")).toBe("44px");
    expect(decl(".edit-keys", "background")).toBe("var(--ui-surface)");
    expect(decl(".edit-keys", "border-top")).toBe("1px solid var(--ui-border)");
    expect(decl(".edit-keys", "bottom")).toBe("var(--keyboard-height)");
    expect(decl(".edit-key", "height")).toBe("44px");
    expect(decl(".edit-key", "min-width")).toBe("44px");
    expect(decl(".edit-header", "height")).toBe("var(--line-h)");
    expect(decl(".edit-header", "border-bottom")).toBe("1px solid var(--ui-border)");
    // The first rule: the phone's media rule takes the hairline away again.
    expect(RULES.find((r) => r.selector === ".edit-sidebar")?.decls.get("border-right")).toBe("1px solid var(--ui-border)");
    expect(RULES.find((r) => r.selector === ".edit-body")?.decls.get("grid-template-columns")).toBe("var(--sidebar-w) minmax(0, 1fr)");
  });
});

describe("edit.css, the page's own sheet, on every bundled theme", () => {
  const palette = (theme: (typeof TERMINAL_THEMES)[number]): Map<string, string> =>
    new Map([...TOKENS, ...(root ? [...root.decls] : []), ...Object.entries(themeTokens(theme.colors, { accent: theme.accent }))]);
  const { pairs, holes } = derivePairs([["edit.css", SOURCE]], palette(TERMINAL_THEMES[0]));

  it("places every text rule", () => {
    expect(holes.map((h) => `${h.sheet}:${h.line} ${h.selector} — ${h.why}`)).toEqual([]);
    expect(pairs.length).toBeGreaterThan(0);
  });

  /** The pairs under the floor, by theme, with the ratio they read. A
   * ratchet like the fleet view's: an entry may go and may not grow. */
  const KNOWN_BELOW: Record<string, Record<string, number>> = {
    // The theme's own foreground and greys on its own ground, which only
    // the theme could move; the same pairs `theme-contrast.test.ts` holds
    // for the fleet view, measured here on 2026-10-19.
    "--ui-text on --ui-bg": { "synthwave-84": 4.32 },
    "--ui-text-muted on --ui-bg": { "solarized-dark": 3.61, "synthwave-84": 3.32 },
    "--ui-text-faint on --ui-bg": { "github-dark-dimmed": 4.46, "solarized-dark": 3.08, "one-dark": 4.02, "synthwave-84": 2.84 },
    "--ui-text on --ui-surface": { "solarized-dark": 4.44, "synthwave-84": 4.01 },
    "--ui-text-muted on --ui-surface": { "solarized-dark": 3.37, "one-dark": 4.49, "synthwave-84": 3.08 },
    "--ui-text on --ui-surface-2": { "solarized-dark": 4.08, "synthwave-84": 3.72 },
    "--ui-text-faint on --ui-bg-sunken": { "solarized-dark": 4.28, "synthwave-84": 3.9 },
    "--code-comment on --ui-bg-sunken": { "solarized-dark": 4.28, "synthwave-84": 3.9 },
    "--code-error on --ui-bg-sunken": { "gruvbox-dark": 3.81 },
    "--code-string on --ui-bg-sunken": { "rose-pine": 4.02 },
  };

  it("clears 4.5:1 on every bundled theme, but the pairs recorded", () => {
    const seen: string[] = [];
    const failures: string[] = [];
    for (const theme of TERMINAL_THEMES) {
      const vars = palette(theme);
      for (const pair of pairs) {
        const ratio = ratioFor(pair, vars);
        const known = KNOWN_BELOW[pair.key]?.[theme.id];
        const where = `${pair.key} on ${theme.id} (${pair.rules[0]})`;
        if (known === undefined) {
          if (ratio < pair.floor) failures.push(`${where} reads ${ratio.toFixed(2)} under ${pair.floor}`);
          continue;
        }
        seen.push(`${pair.key}@${theme.id}`);
        expect(ratio, `${where} got worse than its entry`).toBeGreaterThanOrEqual(known - 0.005);
        expect(ratio, `${where} now passes; drop its entry`).toBeLessThan(pair.floor);
        expect(Math.abs(ratio - known), `${where} reads ${ratio.toFixed(2)}; re-record the entry`).toBeLessThan(0.01);
      }
    }
    expect(failures).toEqual([]);
    const listed = Object.entries(KNOWN_BELOW).flatMap(([key, themes]) => Object.keys(themes).map((t) => `${key}@${t}`));
    expect(seen.sort()).toEqual(listed.sort());
  });

  it("uses the shared tokens and no bare colour outside :root", () => {
    for (const rule of RULES) {
      if (rule.selector === ":root") continue;
      for (const [name, value] of rule.decls) {
        if (name === "color" || name === "background" || name.startsWith("border")) {
          expect(value, `${rule.selector} ${name}`).not.toMatch(/#[0-9a-f]{3,8}\b/i);
        }
      }
    }
  });
});
