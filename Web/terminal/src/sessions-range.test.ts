import { describe, expect, it } from "vitest";

import { daysAgo, goals, kitterm, mdp, projects, rollup, yieldFor } from "./range-fixture";
import { bandSpend, goalCost, usageRange, type KnowledgeSummary, type ProjectRef } from "./sessions-model";
import { tree } from "./sessions-tree";
import { DASH, leakLines, modelsPanel, valuePanel, wherePanel } from "./sessions-value";

/**
 * Every figure on the page follows the range the USAGE toggles set
 * (`agent-dashboard` round 13, the human's word): the same `from` and
 * `to` the rollup answers. One fixture with sessions, pull requests,
 * releases and round records on both sides of the week boundary
 * (`range-fixture.ts`); each panel is read at 7d and at 90d and the two
 * must differ, in the direction the fixture says. The two ranges are the
 * ones `usageRange` derives for the toggles, so the days are the page's.
 */

const NOW = new Date(2026, 8, 19, 12).getTime();
const week = usageRange(7, NOW);
const quarter = usageRange(90, NOW);
const r7 = rollup(week, NOW);
const r90 = rollup(quarter, NOW);
const y7 = yieldFor(week, NOW);
const y90 = yieldFor(quarter, NOW);
const fleet = goals(NOW);

describe("the ranges", () => {
  it("are a week and ninety days back from today, and the rollup sums what falls inside each", () => {
    expect(week).toEqual({ from: "2026-09-13", to: "2026-09-19" });
    expect(quarter).toEqual({ from: "2026-06-22", to: "2026-09-19" });
    expect([r7.totals.costUSD, r7.totals.sessions]).toEqual([75, 3]);
    expect([r90.totals.costUSD, r90.totals.sessions]).toEqual([195, 5]);
  });
});

describe("the band", () => {
  it("prints the range's dollars with the span as the noun", () => {
    expect(bandSpend(r7, { mode: "cost", span: 7 })).toMatchObject({ value: "$75", noun: "7d" });
    expect(bandSpend(r90, { mode: "cost", span: 90 })).toMatchObject({ value: "$195", noun: "90d" });
  });
});

describe("VALUE", () => {
  it("counts the pull requests, lines and releases merged inside the range and prices them with the range's spend", () => {
    const tiles = (panel: ReturnType<typeof valuePanel>) => panel!.tiles.map((t) => [t.key, t.count, t.rate]);
    expect(tiles(valuePanel(r7, y7, 7))).toEqual([
      ["prs", "2", "$35.00 each"],
      ["lines", "500", "$0.140 each"],
      ["releases", "1", "$70.00 each"],
      ["hours", "3.5", "$21 an hour"],
    ]);
    expect(tiles(valuePanel(r90, y90, 90))).toEqual([
      ["prs", "4", "$47.50 each"],
      ["lines", "2,000", "$0.095 each"],
      ["releases", "2", "$95.00 each"],
      ["hours", "8.5", "$22 an hour"],
    ]);
    expect(valuePanel(r7, y7, 7)!.shortNote).toBe("2 repositories, 7 days");
    expect(valuePanel(r90, y90, 90)!.shortNote).toBe("2 repositories, 90 days");
  });
});

describe("WHERE", () => {
  const at = (grouping: "project" | "goal" | "task" | "role", range: typeof week, report = range === week ? r7 : r90, yielded = range === week ? y7 : y90) =>
    wherePanel(grouping, { report, yield: yielded, projects, goals: fleet, range })!;
  const cells = (panel: ReturnType<typeof wherePanel>) => panel!.rows.map((r) => [r.name, r.spend, r.count, r.units, r.rate]);

  it("by project: the rollup's bucket, the pull requests and the cost a PR inside the range", () => {
    const p7 = at("project", week);
    expect(cells(p7)).toEqual([
      ["kitterm", "$70.00", "2 goals", "2 PRs", "$35.00/PR"],
      ["market-data-pipeline", DASH, "1 goal", DASH, DASH],
      ["no project", "$5.00", "7%", DASH, DASH],
    ]);
    expect(p7.summary).toBe("$70.00 in 2 repositories · 2 merged PRs · 500 lines · 1 release");
    const p90 = at("project", quarter);
    expect(cells(p90)).toEqual([
      ["kitterm", "$170.00", "2 goals", "4 PRs", "$42.50/PR"],
      ["market-data-pipeline", "$20.00", "1 goal", DASH, DASH],
      ["no project", "$5.00", "3%", DASH, DASH],
    ]);
    expect(p90.summary).toBe("$190.00 in 2 repositories · 4 merged PRs · 2,000 lines · 2 releases");
  });

  it("by goal: only the round records started inside the range are summed, and every goal is a row", () => {
    const g7 = at("goal", week);
    expect(cells(g7)).toEqual([
      ["alpha", "$17.00", "2 tasks", "2 PRs", "$0.034/line"],
      ["beta", DASH, "1 task", DASH, DASH],
      ["gamma", DASH, DASH, DASH, DASH],
      ["no round record", "$58.00", "77%", DASH, DASH],
    ]);
    expect(g7.note).toBe("77% names no round, so it cannot be valued");
    const g90 = at("goal", quarter);
    expect(cells(g90)).toEqual([
      ["alpha", "$30.00", "4 tasks", "4 PRs", "$0.015/line"],
      ["gamma", "$20.00", "1 task", DASH, DASH],
      ["beta", "$5.00", "2 tasks", DASH, DASH],
      ["no round record", "$140.00", "72%", DASH, DASH],
    ]);
    expect(g90.note).toBe("72% names no round, so it cannot be valued");
  });

  it("by task: a task is inside when its round is", () => {
    expect(cells(at("task", week))).toEqual([
      ["ship", "$9.00", "1h 2m", "PR #201", "$0.030/line"],
      ["polish", "$8.00", "45m", "PR #202", "$0.040/line"],
      ["1 more round", DASH, DASH, DASH, DASH],
      ["no round record", "$58.00", "77%", DASH, DASH],
    ]);
    expect(cells(at("task", quarter))).toEqual([
      ["ingest", "$20.00", "1h", DASH, DASH],
      ["seed", "$13.00", "30m", "PR #120", "$0.026/line"],
      ["ship", "$9.00", "1h 2m", "PR #201", "$0.030/line"],
      ["polish", "$8.00", "45m", "PR #202", "$0.040/line"],
      ["plan", "$5.00", "20m", DASH, DASH],
      ["grow", DASH, DASH, "PR #150", DASH],
      ["1 more round", DASH, DASH, DASH, DASH],
      ["no round record", "$140.00", "72%", DASH, DASH],
    ]);
  });

  it("by role: the rollup's split for the range", () => {
    expect(cells(at("role", week))).toEqual([
      ["root session", "$45.00", "60%", "2.5 h", "$18/API hour"],
      ["crew, worktree", "$30.00", "40%", "1.0 h", "$30/API hour"],
    ]);
    expect(cells(at("role", quarter))).toEqual([
      ["root session", "$145.00", "74%", "6.5 h", "$22/API hour"],
      ["crew, worktree", "$50.00", "26%", "2.0 h", "$25/API hour"],
    ]);
  });
});

describe("MODELS", () => {
  it("is the rollup's per-model split for the range", () => {
    const rows = (report: typeof r7) => modelsPanel(report)!.rows.map((r) => [r.name, r.spend, r.sessions]);
    expect(rows(r7)).toEqual([
      ["Fable 5.1", "$45.00", "2 sessions"],
      ["Opus 5 · 1M", "$30.00", "1 session"],
    ]);
    expect(rows(r90)).toEqual([
      ["Fable 5.1", "$145.00", "3 sessions"],
      ["Opus 5 · 1M", "$30.00", "1 session"],
      ["Haiku 4.5", "$20.00", "1 session"],
    ]);
  });
});

describe("LEAKS", () => {
  it("counts the rounds started inside the range and the rollup's low-cache sessions for it", () => {
    expect(leakLines(r7, fleet, week).map((l) => l.text)).toEqual([
      "1 of 3 rounds carry no Cost line",
      "0 corrections in 3 rounds · 1 session under 95% cached, $30.00",
    ]);
    expect(leakLines(r90, fleet, quarter).map((l) => l.text)).toEqual([
      "2 of 7 rounds carry no Cost line",
      "1 correction in 7 rounds · 2 sessions under 95% cached, $130.00",
    ]);
  });
});

describe("the tree", () => {
  const goalsOf = (id: string) => fleet.filter((g) => g.project.id === id).map((g) => g.summary);
  const goalFacts = (report: typeof r7) => {
    const built = tree({ rows: [], projects, goalsOf, approvals: [], proposed: [], usage: report, now: NOW });
    return built.sections.flatMap((s) => s.lines.flatMap((l) => (l.kind === "fold" ? l.lines : [l])))
      .filter((l) => l.kind === "goal" || l.kind === "project")
      .map((l) => [l.name, l.facts.filter((f) => f.kind === "cost" || f.kind === "counter").map((f) => f.text)]);
  };

  it("prices a goal from its round records started inside the rollup's range, like the project from its bucket", () => {
    expect(goalCost(fleet[0].summary, week)).toBe("$17.00");
    expect(goalCost(fleet[0].summary, quarter)).toBe("$30.00");
    expect(goalCost(fleet[1].summary, week)).toBeNull();
    expect(goalCost(fleet[1].summary, quarter)).toBe("$5.00");
    expect(goalFacts(r7)).toEqual([
      ["kitterm", ["$70.00"]],
      ["alpha", ["$17.00", "r1/3"]],
      ["beta", ["r2/3"]],
      ["market-data-pipeline", ["$0.00"]],
      ["gamma", ["r1/3"]],
    ]);
    expect(goalFacts(r90)).toEqual([
      ["kitterm", ["$170.00"]],
      ["alpha", ["$30.00", "r1/3"]],
      ["beta", ["$5.00", "r2/3"]],
      ["market-data-pipeline", ["$20.00"]],
      ["gamma", ["$20.00", "r1/3"]],
    ]);
  });
});

describe("the goal filter over thirty goals", () => {
  it("lists every goal and has no `more` row; the remainder stays last", () => {
    const thirty = Array.from({ length: 30 }, (_, i): { project: ProjectRef; summary: KnowledgeSummary } => ({
      project: i % 2 === 0 ? kitterm : mdp,
      summary: {
        project: i % 2 === 0 ? "kitterm" : "mdp", slug: `goal-${String(i).padStart(2, "0")}`, status: "done",
        // Every third goal has a priced round this week; the rest have a
        // round outside the range or none at all.
        rounds: i % 3 === 0 ? [{ number: 1, started: daysAgo(NOW, 2), costUSD: (i + 1) / 10, correction: false }] : i % 3 === 1 ? [{ number: 1, started: daysAgo(NOW, 60), correction: false }] : [],
      },
    }));
    const panel = wherePanel("goal", { report: r7, yield: y7, projects, goals: thirty, range: week })!;
    expect(panel.rows).toHaveLength(31);
    expect(panel.rows.filter((r) => /\bmore\b/.test(r.name))).toEqual([]);
    expect(panel.rows.filter((r) => r.name.startsWith("goal-"))).toHaveLength(30);
    expect(panel.rows[panel.rows.length - 1].remainder).toBe(true);
    // The priced rows first, dearest first; then the unpriced by name.
    expect(panel.rows.slice(0, 3).map((r) => [r.name, r.spend])).toEqual([["goal-27", "$2.80"], ["goal-24", "$2.50"], ["goal-21", "$2.20"]]);
    expect(panel.rows.slice(10, 13).map((r) => [r.name, r.spend])).toEqual([["goal-01", DASH], ["goal-02", DASH], ["goal-04", DASH]]);
  });
});

describe("the task filter's working time", () => {
  it("prints the round's wall time from its Cost line, sums a task of two rounds, and a dash with none", () => {
    const m = 60_000;
    const summary: KnowledgeSummary = {
      project: "kitterm", slug: "delta", status: "active",
      rounds: [
        { number: 1, task: "one", started: week.from, costUSD: 1, durationMs: 45 * m, correction: false },
        { number: 2, task: "two", started: week.from, costUSD: 1, durationMs: 62 * m, correction: false },
        { number: 3, task: "two", started: week.to, costUSD: 1, durationMs: 30 * m, correction: true },
        { number: 4, task: "three", started: week.to, costUSD: 1, correction: false },
        { number: 5, task: "four", started: week.to, costUSD: 3, durationMs: 25 * 3_600_000, correction: false },
      ],
    };
    const panel = wherePanel("task", { report: r7, yield: y7, projects, goals: [{ project: kitterm, summary }], range: week })!;
    expect(panel.rows.map((r) => [r.name, r.count])).toEqual([
      ["four", "1d 1h"],
      ["two", "1h 32m"],
      ["one", "45m"],
      ["three", DASH],
      ["no round record", "91%"],
    ]);
    expect(JSON.stringify(panel.rows)).not.toMatch(/\d rounds?"/);
  });
});
