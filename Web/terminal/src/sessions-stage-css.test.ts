import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { type CssRule, parseCss } from "./theme-contrast-derive";

/**
 * The sheet of the SESSIONS section as the frames `Sessions 1200`,
 * `Sessions 390` and `Sessions components` of `design/sessions.pen` draw
 * it (`sessions-workflow`, capability 5), on the rules of
 * `design/foundation.md`. `sessions-css.test.ts` keeps the foundation's
 * absences for the whole sheet; this file pins what the section adds.
 */
const SOURCE = readFileSync(new URL("./sessions.css", import.meta.url), "utf8");
const RULES: CssRule[] = parseCss("sessions.css", SOURCE);
const PHONE = "@media (max-width: 767px)";
const wide = (selector: string): Map<string, string> => new Map(RULES.filter((rule) => rule.selector === selector && rule.conditions.length === 0).flatMap((rule) => [...rule.decls]));
const phone = (selector: string): Map<string, string> => new Map(RULES.filter((rule) => rule.selector === selector && rule.conditions.includes(PHONE)).flatMap((rule) => [...rule.decls]));

describe("one status cell at one x on every level (rule 1)", () => {
  it("puts the state's mark and its word in two columns of the line's own grid", () => {
    expect(wide(".line > .mark").get("grid-column")).toBe("smark");
    expect(wide(".main > .state").get("grid-column")).toBe("word");
    expect(wide(".tree").get("--line-cols")).toContain("[smark] 16px [word] 13ch");
    // `.main`, and a session's link around it, share the line's columns.
    expect(wide(".main").get("grid-template-columns")).toBe("subgrid");
    expect(wide(".line > .open").get("grid-template-columns")).toBe("subgrid");
    expect(wide(".main").get("grid-column")).toBe("name / end");
  });

  it("keeps every cell of a line on one row, whatever its order in the line", () => {
    for (const selector of [".line > .mark", ".line > .open", ".main", ".line-name", ".line-detail", ".main > .state", ".main > [data-col]", ".joins"]) {
      expect(wide(selector).get("grid-row"), selector).toBe("1");
    }
  });

  it("holds no state mark in the left column: the triangle and the blank cell alone", () => {
    expect(wide(".line > .mark.disclosure").get("grid-column")).toBe("lead");
    expect(wide(".line > .mark.blank").get("grid-column")).toBe("lead");
    expect(wide(".line > .mark.disclosure").get("width")).toBe("var(--join-w)");
  });
});

describe("the hairline joins (rule 4)", () => {
  const drawn = RULES.filter((rule) => /\.join\b/.test(rule.selector) && [...rule.decls.keys()].some((name) => name.startsWith("border")));

  it("draws each join as a 1 px border in the border colour, and nothing else", () => {
    expect(drawn.length).toBeGreaterThan(0);
    for (const rule of drawn) {
      for (const [name, value] of rule.decls) {
        if (name.startsWith("border")) expect(value, `${rule.selector} ${name}`).toBe("1px solid var(--ui-border)");
      }
    }
    const painted = RULES.filter((rule) => /\.joins?\b/.test(rule.selector) && (rule.decls.has("background") || rule.decls.has("box-shadow") || rule.decls.has("color")));
    expect(painted.map((rule) => rule.selector)).toEqual([]);
  });

  it("runs a line by with `pass`, turns to the line with `tee`, and stops at a last child with `end`", () => {
    expect(wide(".join.pass::before").get("border-left")).toBe("1px solid var(--ui-border)");
    expect(wide(".join.tee::before").get("bottom")).toBe("0");
    expect(wide(".join.end::before").get("bottom")).toBe("50%");
    expect(wide(".join.tee::after").get("border-top")).toBe("1px solid var(--ui-border)");
    expect(wide(".join.end::after").get("top")).toBe("50%");
    expect(RULES.filter((rule) => rule.selector === ".join.none::before" || rule.selector === ".join.none::after")).toEqual([]);
  });

  it("is one level wide per cell, in the left column, as tall as its line", () => {
    expect(wide(".join").get("width")).toBe("var(--join-w)");
    expect(wide(".joins").get("grid-column")).toBe("lead");
    expect(wide(".joins").get("align-self")).toBe("stretch");
  });
});

describe("the header and the REVIEW line", () => {
  it("draws a hairline above the header and one below it, each row one line tall", () => {
    const head = wide(".tree-head");
    expect(head.get("border-top")).toBe("1px solid var(--ui-border)");
    expect(head.get("border-bottom")).toBe("1px solid var(--ui-border)");
    expect(head.get("grid-auto-rows")).toBe("minmax(var(--line-h), auto)");
  });

  it("hides the REVIEW line while the page has nothing to say on it, and never cuts a link off it", () => {
    expect(wide(".review[hidden]").get("display")).toBe("none");
    expect(wide(".review-label[hidden]").get("display")).toBe("none");
    expect(wide(".review").has("text-overflow")).toBe(false);
    expect(wide(".review").get("white-space")).toBeUndefined();
  });

  it("underlines a pull request link, as the foundation rules", () => {
    expect(wide(".pr-link .mark.link").get("text-decoration")).toBe("underline");
  });
});

describe("the phone (rule 7)", () => {
  it("keeps the joins, the name, the status cell, #N and one state word", () => {
    expect(phone(".tree").get("--line-cols")).toBe("[name] minmax(0, 1fr) [smark] 16px [word] 11ch [pr] 12ch [end]");
    expect(phone(".tree").get("--join-w")).toBe("var(--space-3)");
    expect(phone(".main > [data-col]:not(.pr)").get("display")).toBe("none");
    expect(phone(".line-detail").get("display")).toBe("none");
    expect(phone(".pr-prefix").get("display")).toBe("none");
    expect(phone(".pr-words").get("display")).toBe("none");
    expect(phone(".pr-word").get("display")).toBe("inline");
    // At 768 px and up the one word is off and the words are on.
    expect(wide(".pr-word").get("display")).toBe("none");
  });

  it("keeps the header's two labels and the short REVIEW line, and drops the legend", () => {
    expect(phone(".tree-keys").get("display")).toBe("none");
    expect(phone(".tree-head").has("display")).toBe(false);
    expect(phone(".review-long").get("display")).toBe("none");
    expect(phone(".review-short").get("display")).toBe("inline");
    expect(wide(".review-short").get("display")).toBe("none");
  });

  it("keeps the hairline between two sections at both widths", () => {
    expect(wide(".tree-section + .tree-section").get("border-top")).toBe("1px solid var(--ui-border)");
    expect(phone(".tree-section + .tree-section").size).toBe(0);
  });
});
