import { describe, expect, it } from "vitest";

import { daysAgo, goals, projects, rollup, yieldFor } from "./range-fixture";
import { bandSpend, dayLabel, goalCost, MAX_RANGE_DAYS, readUsageChoice, usageRange } from "./sessions-model";
import { tree } from "./sessions-tree";
import { DASH, leakLines, modelsPanel, valuePanel, wherePanel } from "./sessions-value";

/**
 * The `all` range (`plan.md` capability 6; `corpus/05-legend-and-range.md`,
 * rule 2): the whole record, from the first spend day, which every panel
 * that follows the range reads the same way it reads 7d/30d/90d
 * (`sessions-range.test.ts`). `allRange` here is wider than every session,
 * pull request and round `range-fixture.ts` carries (the oldest is 76
 * days back), so `all` sees exactly what `90d` sees on this fixture — the
 * point of these tests is the toggle and its wording, not a new number.
 */

const NOW = new Date(2026, 8, 19, 12).getTime();
const allRange = { from: daysAgo(NOW, 100), to: "2026-09-19" };
const rAll = rollup(allRange, NOW);
const yAll = yieldFor(allRange, NOW);
const fleet = goals(NOW);

describe('usageRange("all", …)', () => {
  it("reaches back MAX_RANGE_DAYS, the routes' own bound, before the lifetime read has found the first spend day", () => {
    expect(MAX_RANGE_DAYS).toBe(400);
    const expected = { from: daysAgo(NOW, MAX_RANGE_DAYS - 1), to: "2026-09-19" };
    expect(usageRange("all", NOW)).toEqual(expected);
    expect(usageRange("all", NOW, null)).toEqual(expected);
    expect(usageRange("all", NOW, undefined)).toEqual(expected);
  });

  it("starts at the given first spend day once the page's own lifetime read has found one", () => {
    expect(usageRange("all", NOW, "2026-07-16")).toEqual({ from: "2026-07-16", to: "2026-09-19" });
  });

  it("still steps 7d/30d/90d by days, unaffected by the new branch", () => {
    expect(usageRange(7, NOW)).toEqual({ from: "2026-09-13", to: "2026-09-19" });
    expect(usageRange(90, NOW)).toEqual({ from: "2026-06-22", to: "2026-09-19" });
  });
});

describe("the persisted choice", () => {
  it("reads `all` back from storage like the day-counted spans", () => {
    expect(readUsageChoice('{"mode":"cost","span":"all"}')).toEqual({ mode: "cost", span: "all" });
    expect(readUsageChoice(JSON.stringify({ mode: "tokens", span: "all" }))).toEqual({ mode: "tokens", span: "all" });
  });

  it("still falls back to the default for anything that is not an offered value", () => {
    expect(readUsageChoice('{"mode":"cost","span":"lifetime"}')).toEqual({ mode: "cost", span: 30 });
  });
});

describe("the band", () => {
  it("prints `all`, not a day count, as the noun, and names the whole record in the title", () => {
    const cell = bandSpend(rAll, { mode: "cost", span: "all" });
    expect(cell).toMatchObject({ value: "$195", noun: "all" });
    expect(cell.title).toBe("$195.00: what the whole record cost, if billed at full API rate.");
  });
});

describe("VALUE", () => {
  it("counts everything `90d` does on this fixture, and its note names the first spend day instead of a day count", () => {
    const panel = valuePanel(rAll, yAll, "all")!;
    expect(panel.tiles.map((t) => [t.key, t.count, t.rate])).toEqual([
      ["prs", "4", "$47.50 each"],
      ["lines", "2,000", "$0.095 each"],
      ["releases", "2", "$95.00 each"],
      ["hours", "8.5", "$22 an hour"],
    ]);
    expect(panel.shortNote).toBe(`2 repositories, since ${dayLabel(allRange.from)}`);
    expect(panel.note).toBe(`2 repositories, since ${dayLabel(allRange.from)}. Proxies for value, not value.`);
  });
});

describe("WHERE", () => {
  it("by project: the same rollup bucket and pull requests `90d` reads", () => {
    const panel = wherePanel("project", { report: rAll, yield: yAll, projects, goals: fleet, range: allRange })!;
    expect(panel.rows.map((r) => [r.name, r.spend, r.count, r.units, r.rate])).toEqual([
      ["kitterm", "$170.00", "2 goals", "4 PRs", "$42.50/PR"],
      ["market-data-pipeline", "$20.00", "1 goal", DASH, DASH],
      ["no project", "$5.00", "3%", DASH, DASH],
    ]);
    expect(panel.summary).toBe("$190.00 in 2 repositories · 4 merged PRs · 2,000 lines · 2 releases");
  });

  it("by goal: every round record on record, since all of them start inside `all`", () => {
    const panel = wherePanel("goal", { report: rAll, yield: yAll, projects, goals: fleet, range: allRange })!;
    expect(panel.rows.map((r) => [r.name, r.spend, r.count, r.units, r.rate])).toEqual([
      ["alpha", "$30.00", "4 tasks", "4 PRs", "$0.015/line"],
      ["gamma", "$20.00", "1 task", DASH, DASH],
      ["beta", "$5.00", "2 tasks", DASH, DASH],
      ["no round record", "$140.00", "72%", DASH, DASH],
    ]);
  });
});

describe("MODELS", () => {
  it("is the rollup's per-model split for the whole record", () => {
    const rows = modelsPanel(rAll)!.rows.map((r) => [r.name, r.spend, r.sessions]);
    expect(rows).toEqual([
      ["Fable 5.1", "$145.00", "3 sessions"],
      ["Opus 5 · 1M", "$30.00", "1 session"],
      ["Haiku 4.5", "$20.00", "1 session"],
    ]);
  });
});

describe("LEAKS", () => {
  it("counts every round on record and the rollup's low-cache sessions over it", () => {
    expect(leakLines(rAll, fleet, allRange).map((l) => l.text)).toEqual([
      "2 of 7 rounds carry no Cost line",
      "1 correction in 7 rounds · 2 sessions under 95% cached, $130.00",
    ]);
  });
});

describe("the tree", () => {
  const goalsOf = (id: string) => fleet.filter((g) => g.project.id === id).map((g) => g.summary);
  it("prices a goal from every round record on record, like the project from its bucket", () => {
    expect(goalCost(fleet[0].summary, allRange)).toBe("$30.00");
    expect(goalCost(fleet[1].summary, allRange)).toBe("$5.00");
    const built = tree({ rows: [], projects, goalsOf, approvals: [], proposed: [], usage: rAll, now: NOW });
    const goalFacts = built.sections
      .flatMap((s) => s.lines.flatMap((l) => (l.kind === "fold" ? l.lines : [l])))
      .filter((l) => l.kind === "goal" || l.kind === "project")
      .map((l) => [l.name, l.facts.filter((f) => f.kind === "cost").map((f) => f.text)]);
    expect(goalFacts).toEqual([
      ["kitterm", ["$170.00"]],
      ["alpha", ["$30.00"]],
      ["beta", ["$5.00"]],
      ["market-data-pipeline", ["$20.00"]],
      ["gamma", ["$20.00"]],
    ]);
  });
});
