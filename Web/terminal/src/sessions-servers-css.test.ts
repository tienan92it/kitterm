import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { type CssRule, parseCss } from "./theme-contrast-derive";

/**
 * The sheet of the SERVERS section (`running-servers` round 3, rules 10
 * to 12 of `Sessions components`): a block under a hairline with the
 * label in the 84 px gutter, the rows on the line rule with their own
 * columns, the `●` mark in the accent through the mark's clipped
 * background, and the phone's three cells. `sessions-css.test.ts` keeps
 * the foundation's absences for the whole sheet.
 */
const SOURCE = readFileSync(new URL("./sessions.css", import.meta.url), "utf8");
const RULES: CssRule[] = parseCss("sessions.css", SOURCE);
const PHONE = "@media (max-width: 767px)";
const wide = (selector: string): Map<string, string> => new Map(RULES.filter((rule) => rule.selector === selector && rule.conditions.length === 0).flatMap((rule) => [...rule.decls]));
const phone = (selector: string): Map<string, string> => new Map(RULES.filter((rule) => rule.selector === selector && rule.conditions.includes(PHONE)).flatMap((rule) => [...rule.decls]));

describe("the block", () => {
  it("is the tree header's shape: the label in an 84 px gutter, a hairline above, and hidden whole", () => {
    const head = wide(".servers-head");
    expect(head.get("display")).toBe("grid");
    expect(head.get("grid-template-columns")).toBe("84px minmax(0, 1fr)");
    expect(head.get("column-gap")).toBe("var(--space-4)");
    expect(head.get("grid-auto-rows")).toBe("minmax(var(--line-h), auto)");
    expect(head.get("border-top")).toBe("1px solid var(--ui-border)");
    expect(head.has("border-bottom"), "the folds draw the hairline below").toBe(false);
    expect(head.get("margin")).toBe("var(--space-2) 0 0");
    expect(wide(".servers-head[hidden]").get("display")).toBe("none");
    expect(wide(".servers-label")).toEqual(wide(".review-label"));
    expect(wide(".servers").get("margin")).toBe("0");
    expect(wide(".servers").get("color")).toBe("var(--ui-text)");
  });

  it("stacks the rows across both columns with their own cells: the address, where it belongs, who started it, the word, the binds, the age", () => {
    const rows = wide(".servers-rows");
    expect(rows.get("grid-column")).toBe("1 / -1");
    expect(rows.get("display")).toBe("flex");
    expect(rows.get("flex-direction")).toBe("column");
    expect(rows.get("--join-w")).toBe("var(--space-4)");
    expect(rows.get("--line-cols")).toBe("[pr] 16ch [name] minmax(0, 30ch) [detail] minmax(0, 1fr) [word] 6ch [cost] 12ch [last] 10ch [end]");
    // The cells land by the line's own rules, the REVIEW row's.
    expect(wide(".line-review > .main").get("grid-column")).toBe("pr / end");
    expect(["3", "2", "4"].map((n) => wide(`.main > [data-col="${n}"]`).get("grid-column"))).toEqual(["pr", "cost", "last"]);
    expect(wide(".main > .binds").get("color")).toBe("var(--ui-text-muted)");
    // The fold's label follows its triangle (`▶ 17 other servers`), in grey.
    expect(wide(".servers-rows .line-fold .line-name").get("grid-column")).toBe("pr / end");
    expect(wide(".line-fold .line-name").get("color")).toBe("var(--ui-text-muted)");
    for (const selector of [".servers-rows", ".main > .binds"]) {
      for (const prop of ["min-height", "height", "line-height", "padding"]) expect(wide(selector).has(prop), `${selector} ${prop}`).toBe(false);
    }
  });
});

describe("the mark", () => {
  it("is the accent on the mark's clipped background, the colour of what is alive, and never a text colour", () => {
    const mark = wide(".mark.listening");
    expect(mark.get("background")).toBe("var(--ui-accent)");
    expect(mark.get("background-clip")).toBe("text");
    expect(mark.has("color")).toBe(false);
    expect(wide(".line-review > .mark").get("grid-column")).toBe("lead");
  });

  it("underlines the link through the mark, like PR #N", () => {
    expect(wide(".pr-link .mark.link").get("text-decoration")).toBe("underline");
    expect(wide(".mark.link").get("background")).toBe("var(--ui-accent)");
  });
});

describe("the phone", () => {
  it("keeps the mark, the address, where it belongs and one word: three columns, the rest dropped by the line's own rules", () => {
    expect(phone(".servers-rows").get("--line-cols")).toBe("[pr] 15ch [name] minmax(0, 1fr) [word] 5ch [end]");
    expect(phone(".servers-rows").get("--join-w")).toBe("var(--space-3)");
    expect(phone(".servers-head").get("grid-template-columns")).toBe("auto minmax(0, 1fr)");
    expect(phone(".line-detail").get("display")).toBe("none");
    expect(phone(".main > [data-col]:not(.pr)").get("display")).toBe("none");
    // The name truncates with an ellipsis (rule 8), on a phone as at 1200 px.
    expect(wide(".line-name").get("text-overflow")).toBe("ellipsis");
  });
});
