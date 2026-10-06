import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { type CssRule, parseCss } from "./theme-contrast-derive";

/**
 * The sheet of the REVIEW rows (`sessions-workflow` round 7,
 * `corpus/02-review-rows.md`): one line per pull request on the line rule
 * and `--line-h`, with the rows' own columns, the mark in the left column,
 * and the phone's three cells. `sessions-css.test.ts` keeps the
 * foundation's absences for the whole sheet: no bare pixel for space, no
 * transition, no radius above 2 px, the owned colours on a mark alone.
 */
const SOURCE = readFileSync(new URL("./sessions.css", import.meta.url), "utf8");
const RULES: CssRule[] = parseCss("sessions.css", SOURCE);
const PHONE = "@media (max-width: 767px)";
const wide = (selector: string): Map<string, string> => new Map(RULES.filter((rule) => rule.selector === selector && rule.conditions.length === 0).flatMap((rule) => [...rule.decls]));
const phone = (selector: string): Map<string, string> => new Map(RULES.filter((rule) => rule.selector === selector && rule.conditions.includes(PHONE)).flatMap((rule) => [...rule.decls]));

describe("the rows block", () => {
  it("spans the header's two columns under the REVIEW header, stacks its lines and hides with the header", () => {
    expect(wide(".review-rows").get("grid-column")).toBe("1 / -1");
    expect(wide(".review-rows").get("display")).toBe("flex");
    expect(wide(".review-rows").get("flex-direction")).toBe("column");
    expect(wide(".review-rows").get("color")).toBe("var(--ui-text)");
    expect(wide(".review-rows[hidden]").get("display")).toBe("none");
  });

  it("takes the line's left column from the space scale and its own columns: PR #N, where it belongs, the title, the words, the size, the wait", () => {
    expect(wide(".review-rows").get("--join-w")).toBe("var(--space-4)");
    expect(wide(".review-rows").get("--line-cols")).toBe("[pr] 9ch [name] minmax(0, 30ch) [detail] minmax(0, 1fr) [word] 13ch [cost] 12ch [last] 10ch [end]");
    // The cells land by the line's own rules: the name, the grey text, the
    // state words, `data-col` 3 (the pull request), 2 (the size), 4 (the wait).
    expect(wide(".line-name").get("grid-column")).toBe("name");
    expect(wide(".line-detail").get("grid-column")).toBe("detail");
    expect(wide(".main > .state").get("grid-column")).toBe("word");
    expect(["3", "2", "4"].map((n) => wide(`.main > [data-col="${n}"]`).get("grid-column"))).toEqual(["pr", "cost", "last"]);
    expect(wide(".line-review > .main").get("grid-column")).toBe("pr / end");
  });

  it("sets no height of its own: a row is a .line, one --line-h tall", () => {
    for (const selector of [".review-rows", ".line-review", ".line-review > .main"]) {
      for (const prop of ["min-height", "height", "line-height", "padding", "margin"]) expect(wide(selector).has(prop), `${selector} ${prop}`).toBe(false);
    }
    expect(wide(".line").get("min-height")).toBe("var(--line-h)");
  });
});

describe("the mark and the size", () => {
  it("puts the row's mark in the left column, one level wide and centred, where a scope's triangle sits", () => {
    const mark = wide(".line-review > .mark");
    expect(mark.get("grid-column")).toBe("lead");
    expect(mark.get("justify-self")).toBe("end");
    expect(mark.get("width")).toBe("var(--join-w)");
    expect(mark.get("justify-content")).toBe("center");
    expect(mark.get("align-items")).toBe("center");
    expect(mark.get("min-height")).toBe("var(--line-h)");
    expect(wide(".line > .mark.disclosure").get("grid-column")).toBe("lead");
  });

  it("right-aligns the size with tabular figures like every fact, and never cuts it with an ellipsis", () => {
    const sizeRule = RULES.find((rule) => rule.selector === ".main > .size" && rule.conditions.length === 0)!;
    expect(sizeRule.decls.get("text-align")).toBe("right");
    expect(sizeRule.decls.get("font-variant-numeric")).toBe("tabular-nums");
    expect(sizeRule.decls.get("color")).toBe("var(--ui-text-muted)");
    expect(sizeRule.decls.has("text-overflow")).toBe(false);
  });

  it("prints the drafts line's name and the header's drafts count in grey", () => {
    expect(wide(".line-fold .line-name").get("color")).toBe("var(--ui-text-muted)");
    expect(wide(".review-drafts").get("color")).toBe("var(--ui-text-muted)");
    expect(RULES.filter((rule) => rule.selector.includes(".review-where"))).toEqual([]);
  });
});

describe("the phone", () => {
  it("keeps the mark, #N, where it belongs and one state word: three columns, the rest dropped by the line's own rules", () => {
    expect(phone(".review-rows").get("--line-cols")).toBe("[pr] 6ch [name] minmax(0, 1fr) [word] 12ch [end]");
    expect(phone(".review-rows").get("--join-w")).toBe("var(--space-3)");
    expect(phone(".line-detail").get("display")).toBe("none");
    expect(phone(".main > [data-col]:not(.pr)").get("display")).toBe("none");
    expect(phone(".pr-words").get("display")).toBe("none");
    expect(phone(".pr-word").get("display")).toBe("inline");
    expect(phone(".pr-prefix").get("display")).toBe("none");
  });
});
