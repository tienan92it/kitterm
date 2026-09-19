import { describe, expect, it } from "vitest";

import { type KnowledgeSummary, type ProjectRef, type ProjectSummary, type UsageDaily, type UsageTokens } from "./sessions-model";
import {
  count,
  DASH,
  hours,
  leakLines,
  modelsPanel,
  readWhereGrouping,
  roundsInRange,
  unitCost,
  VALUE_NOTE,
  valuePanel,
  WHERE_DEFAULT,
  wherePanel,
  type YieldReport,
} from "./sessions-value";

/**
 * What the spend bought (`agent-dashboard`, capability 7): the tiles, the
 * grouping model at each of its four levels, the model rows and the leak
 * lines, over a fixture shaped like the machine this was built on. The
 * rules under test are `corpus/valuemaxxing.md`'s: a row with no source
 * prints a dash and never a zero, the unattributed remainder is a row and
 * the longest bar at the goal grouping, a line and a PR are called
 * proxies, and no rate for the human's time exists anywhere.
 */

const W = "/Users/antran/Workspace";
const zero: UsageTokens = { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 };
const tokens = (input: number, cacheRead: number): UsageTokens => ({ input, output: 100, cacheCreation: 0, cacheRead, requests: 3 });

const kittermRef: ProjectRef = { id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true };
const mdpRef: ProjectRef = { id: "mdp", name: "market-data-pipeline", root: `${W}/NgheNhanTrading/market-data-pipeline`, registered: true };
const notesRef: ProjectRef = { id: "notes", name: "notes", root: `${W}/notes`, registered: true };
const projects: ProjectSummary[] = [
  { ...kittermRef, knowledge: "docs/goals" },
  { ...mdpRef, knowledge: "docs/goals" },
  { ...notesRef, knowledge: "docs/goals" },
];

/** Thirty days: kitterm $976.74, the pipeline $38.91, a home directory
 * $89.47 that no listed project holds, 20.9 API hours over $900 of
 * measured sessions. */
const report: UsageDaily = {
  ok: true,
  timeZone: "Asia/Ho_Chi_Minh",
  from: "2026-08-19",
  to: "2026-09-17",
  refreshedAt: 1,
  recordedSessions: 200,
  days: [],
  totals: {
    costUSD: 1105.12, apportionedUSD: 0, unsplitUSD: 12, tokens: tokens(1_000_000, 200_000_000), sessions: 150, unbilledSessions: 4,
    apiMs: 20.9 * 3_600_000, measuredUSD: 900,
  },
  models: [
    { model: "claude-fable-5-1", name: "Fable 5.1", costUSD: 800.5, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 97 },
    { model: "claude-opus-5[1m]", name: "Opus 5 · 1M", costUSD: 292.62, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 1 },
  ],
  projects: [
    { id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true, costUSD: 976.74, apportionedUSD: 0, tokens: tokens(1, 1), sessions: 92, unbilledSessions: 0 },
    { id: "mdp", name: "market-data-pipeline", root: `${W}/NgheNhanTrading/market-data-pipeline`, registered: true, costUSD: 38.91, apportionedUSD: 0, tokens: tokens(1, 1), sessions: 10, unbilledSessions: 0 },
    { id: "antran", name: "antran", root: "/Users/antran", registered: false, costUSD: 89.47, apportionedUSD: 0, tokens: tokens(1, 1), sessions: 12, unbilledSessions: 0 },
  ],
  roles: [
    { role: "root", costUSD: 765.59, apportionedUSD: 0, sessions: 114, apiMs: 12.8 * 3_600_000, measuredUSD: 700, linesAdded: 23_081 },
    { role: "crew", costUSD: 339.53, apportionedUSD: 0, sessions: 36, apiMs: 8.1 * 3_600_000, measuredUSD: 200, linesAdded: 5_191 },
  ],
  lowCache: [
    { sessionId: "a", project: "kitterm", costUSD: 15.84, cacheShare: 0.94 },
    { sessionId: "b", project: "market-data-pipeline", costUSD: 11.96, cacheShare: 0.93 },
    { sessionId: "c", project: "kitterm", costUSD: 5.74, cacheShare: 0.92 },
  ],
};

const yieldReport: YieldReport = {
  ok: true,
  from: "2026-08-19",
  to: "2026-09-17",
  projects: [
    {
      ...kittermRef, root: kittermRef.root!,
      yield: {
        checkout: true, remote: true, branch: "origin/main", mergedPullRequests: 83, mergedLines: 58_853, releases: 24,
        // The three pull requests the goal fixtures name, with their lines
        // (round 10: a goal's lines are priced from these).
        pullRequests: [{ number: 123, lines: 2000 }, { number: 122, lines: 1000 }, { number: 100, lines: 50 }],
      },
    },
    { ...mdpRef, root: mdpRef.root!, yield: { checkout: true, remote: false, branch: "HEAD", releases: 0 } },
    { ...notesRef, root: notesRef.root!, yield: { checkout: false, remote: false } },
  ],
  totals: { checkouts: 2, counted: 1, mergedPullRequests: 83, mergedLines: 58_853, releases: 24 },
};

/** Four goals: one priced with PRs, one with a PR and no Cost line, one
 * priced with no PR, one with nothing in the range, and one whose only
 * round is before the range. */
const goals: { project: ProjectRef; summary: KnowledgeSummary }[] = [
  {
    project: kittermRef,
    summary: {
      project: "kitterm", slug: "workspace-ledger", status: "done",
      rounds: [
        { number: 1, task: "capture-the-spend", started: "2026-09-15", costUSD: 27.74, durationMs: 60 * 60_000, pr: 122, correction: false },
        { number: 2, task: "the-ledger", started: "2026-09-16", costUSD: 12.72, durationMs: 30 * 60_000, pr: 123, correction: true },
        { number: 3, task: "the-numbers-on-the-page", started: "2026-09-16", pr: 123, correction: false },
        { number: 4, task: "answer-from-the-page", started: "2026-09-16", costUSD: 34.66, durationMs: 45 * 60_000, correction: false },
      ],
    },
  },
  {
    project: kittermRef,
    summary: {
      project: "kitterm", slug: "contrast-tokens", status: "done",
      rounds: [
        { number: 1, task: "the-floor", started: "2026-09-10", pr: 100, correction: false },
        { number: 2, task: "the-ratchet", started: "2026-09-11", correction: false },
      ],
    },
  },
  {
    project: kittermRef,
    summary: {
      project: "kitterm", slug: "cost-per-round", status: "done",
      rounds: [{ number: 1, task: "the-line", started: "2026-09-16", costUSD: 33.46, durationMs: 20 * 60_000, correction: false }],
    },
  },
  {
    project: kittermRef,
    summary: { project: "kitterm", slug: "green-ci", status: "done", rounds: [{ number: 1, task: "ci", started: "2026-09-05", correction: false }] },
  },
  {
    project: kittermRef,
    summary: { project: "kitterm", slug: "older", status: "done", rounds: [{ number: 1, task: "old", started: "2026-07-01", costUSD: 99, pr: 1, correction: false }] },
  },
];

const range = { from: report.from, to: report.to };
const empty: UsageDaily = {
  ...report,
  from: "2026-05-01", to: "2026-05-07",
  totals: { costUSD: 0, apportionedUSD: 0, tokens: zero, sessions: 0, unbilledSessions: 0, apiMs: 0, measuredUSD: 0 },
  models: [], projects: [],
  roles: [
    { role: "root", costUSD: 0, apportionedUSD: 0, sessions: 0, apiMs: 0, measuredUSD: 0, linesAdded: 0 },
    { role: "crew", costUSD: 0, apportionedUSD: 0, sessions: 0, apiMs: 0, measuredUSD: 0, linesAdded: 0 },
  ],
  lowCache: [],
};

describe("the formats", () => {
  it("groups thousands, prices a cent-scale unit to three decimals, and prints hours", () => {
    expect(count(58_853)).toBe("58,853");
    expect(count(83)).toBe("83");
    expect(unitCost(11.77)).toBe("$11.77");
    expect(unitCost(0.0166)).toBe("$0.017");
    expect(hours(20.9 * 3_600_000)).toBe("20.9");
    expect(hours(312 * 3_600_000)).toBe("312");
  });
});

describe("VALUE", () => {
  it("prints four tiles with a count, a noun in two forms and a unit cost, and one note that names the scope, the span and the caveat", () => {
    // Round 10 (the frames): `merged pull requests` / `merged PRs`, `$11.77
    // each`, `$47 an hour`, and the note `kitterm, 30 days. Proxies for
    // value, not value.`; here two checkouts are counted.
    const panel = valuePanel(report, yieldReport, 30)!;
    // The divisor is the spend of the two checkouts, $976.74 + $38.91, not
    // the fleet's $1,105.12: the research's own number for kitterm.
    expect(panel.tiles.map((t) => [t.key, t.count, t.noun, t.shortNoun, t.rate])).toEqual([
      ["prs", "83", "merged pull requests", "merged PRs", "$12.24 each"],
      ["lines", "58,853", "merged lines added", "merged lines", "$0.017 each"],
      ["releases", "24", "releases", "releases", "$42.32 each"],
      ["hours", "20.9", "hours of model time", "model hours", "$43 an hour"],
    ]);
    expect(panel.note).toBe("2 repositories, 30 days. Proxies for value, not value.");
    expect(panel.shortNote).toBe("2 repositories, 30 days");
    expect(panel.note).toContain(VALUE_NOTE);
    // One counted checkout names the project itself.
    const one: YieldReport = { ...yieldReport, projects: [yieldReport.projects[0], yieldReport.projects[2]] };
    expect(valuePanel(report, one, 7)!.shortNote).toBe("kitterm, 7 days");
  });

  it("prints a dash, never a zero, for a count it has no source for", () => {
    // No yield answer: the three repository tiles have no source; the
    // hours still come from the rollup, and the note has no scope to name.
    const none = valuePanel(report, null, 30)!;
    expect(none.tiles.map((t) => t.count)).toEqual([DASH, DASH, DASH, "20.9"]);
    expect(none.tiles.map((t) => t.rate)).toEqual([DASH, DASH, DASH, "$43 an hour"]);
    expect(none.note).toBe(`30 days. ${VALUE_NOTE}`);
    // A fleet whose checkouts have no remote: PRs and lines unknown,
    // releases a measured zero.
    const noRemote: YieldReport = { ...yieldReport, totals: { checkouts: 2, counted: 0, mergedPullRequests: 0, mergedLines: 0, releases: 0 } };
    expect(valuePanel(report, noRemote, 30)!.tiles.map((t) => t.count)).toEqual([DASH, DASH, "0", "20.9"]);
    expect(valuePanel(report, noRemote, 30)!.tiles[2].rate).toBe(DASH);
    // An old daemon sends no hours.
    const { apiMs: _a, measuredUSD: _m, ...old } = report.totals;
    expect(valuePanel({ ...report, totals: old }, yieldReport, 30)!.tiles[3].count).toBe(DASH);
  });

  it("an empty range prices nothing and draws nothing when the page has no rollup", () => {
    const panel = valuePanel(empty, { ...yieldReport, totals: { checkouts: 2, counted: 1, mergedPullRequests: 0, mergedLines: 0, releases: 0 } }, 7)!;
    expect(panel.tiles.map((t) => [t.count, t.rate])).toEqual([["0", DASH], ["0", DASH], ["0", DASH], [DASH, DASH]]);
    expect(valuePanel(null, yieldReport, 30)).toBeNull();
    expect(valuePanel({ ...report, ok: false }, yieldReport, 30)).toBeNull();
  });

  it("invents no rate for the human's time", () => {
    const text = JSON.stringify(valuePanel(report, yieldReport, 30));
    expect(text).not.toMatch(/human|your time|saved|worth/i);
  });
});

describe("WHERE by project", () => {
  const panel = wherePanel("project", { report, yield: yieldReport, projects, goals, range })!;

  it("lists every project with its spend, its sessions, its merged PRs and its cost a PR, dearest first", () => {
    // Round 10 (the frame's columns): spend | count | PRs | unit, and the
    // remainder's count its share. Round 11 (the Components frame, WHERE by
    // project): the unit is a merged pull request, `$11.77/PR`, the noun
    // after a slash; chartered, it replaced `$0.017 a line`.
    expect(panel.rows.map((r) => [r.name, r.spend, r.count, r.units, r.rate, r.remainder])).toEqual([
      ["kitterm", "$976.74", "92 sessions", "83 PRs", "$11.77/PR", false],
      ["market-data-pipeline", "$38.91", "10 sessions", DASH, DASH, false],
      ["notes", DASH, DASH, DASH, DASH, false],
      ["no project", "$89.47", "8%", DASH, DASH, true],
    ]);
  });

  it("prints a dash for a project that is not a checkout, one with no remote, and one with no session", () => {
    const byName = Object.fromEntries(panel.rows.map((r) => [r.name, r]));
    expect(byName.notes.spend, "no session in the range: no source, not $0.00").toBe(DASH);
    expect(byName.notes.title).toContain("not a git checkout");
    expect(byName["market-data-pipeline"].units, "no remote: no pull request to count").toBe(DASH);
    expect(byName["market-data-pipeline"].title).toContain("no remote");
  });

  it("makes the dollars no listed project holds a row", () => {
    const rest = panel.rows.find((r) => r.remainder)!;
    expect(rest.name).toBe("no project");
    expect(rest.spend).toBe("$89.47");
    // The counted checkouts' line at the selector's right (round 10).
    expect(panel.summary).toBe("$1,015.65 in 2 repositories · 83 merged PRs · 58,853 lines · 24 releases");
    expect(wherePanel("project", { report, yield: null, projects, goals, range })!.summary).toBeNull();
    expect(panel.toggles.map((t) => [t.label, t.checked])).toEqual([["project", true], ["goal", false], ["task", false], ["role", false]]);
  });
});

describe("WHERE by goal", () => {
  const panel = wherePanel("goal", { report, yield: yieldReport, projects, goals, range })!;

  it("sums the Cost lines of the rounds started in the range, counts them as tasks and their PRs, and prices a line from the PRs' lines", () => {
    // `workspace-ledger $75.11 6 tasks 4 PRs $0.018/line` in the frame:
    // here 4 rounds, 2 PRs of 3,000 lines together. Round 11: `/line`
    // replaced `a line` (chartered).
    expect(panel.rows.map((r) => [r.name, r.spend, r.count, r.units, r.rate])).toEqual([
      ["workspace-ledger", "$75.12", "4 tasks", "2 PRs", "$0.025/line"],
      ["cost-per-round", "$33.46", "1 task", DASH, DASH],
      ["contrast-tokens", DASH, "2 tasks", "1 PR", DASH],
      ["2 more goals", DASH, DASH, DASH, DASH],
      ["no round record", "$996.54", "90%", DASH, DASH],
    ]);
    // A daemon that sends no lines per pull request prices no line.
    const older = { ...yieldReport, projects: yieldReport.projects.map((p) => ({ ...p, yield: { ...p.yield, pullRequests: undefined } })) };
    expect(wherePanel("goal", { report, yield: older, projects, goals, range })!.rows[0].rate).toBe(DASH);
  });

  it("a group with no spend prints a dash and keeps its PR; a group with no PR prints a dash and keeps its spend", () => {
    const byName = Object.fromEntries(panel.rows.map((r) => [r.name, r]));
    expect(byName["contrast-tokens"].spend).toBe(DASH);
    expect(byName["contrast-tokens"].units).toBe("1 PR");
    expect(byName["cost-per-round"].units).toBe(DASH);
    expect(byName["cost-per-round"].spend).toBe("$33.46");
    expect(byName["cost-per-round"].rate).toBe(DASH);
  });

  it("the unattributed remainder is a row, the longest bar, and says its share in the note", () => {
    const rest = panel.rows.find((r) => r.remainder)!;
    expect(rest.name).toBe("no round record");
    expect(rest.fill).toBe(1);
    expect(Math.max(...panel.rows.filter((r) => !r.remainder).map((r) => r.fill))).toBeLessThan(0.1);
    expect(panel.note).toBe("90% names no round, so it cannot be valued");
    expect(rest.count, "the share sits in the count column").toBe("90%");
  });

  it("folds the goals with nothing in the range into one dash row that names them", () => {
    const folded = panel.rows.find((r) => r.name === "2 more goals")!;
    expect(folded.spend).toBe(DASH);
    expect(folded.title).toContain("green-ci");
    expect(folded.title).toContain("older");
    expect(roundsInRange(goals[4].summary, range)).toEqual([]);
  });
});

describe("WHERE by task", () => {
  const panel = wherePanel("task", { report, yield: yieldReport, projects, goals, range })!;

  it("is one row per round started in the range, with its Cost line, its wall time, its PR and its dollars a line", () => {
    expect(panel.rows.map((r) => [r.name, r.spend, r.count, r.units, r.rate])).toEqual([
      ["answer-from-the-page", "$34.66", "45m", DASH, DASH],
      ["the-line", "$33.46", "20m", DASH, DASH],
      ["capture-the-spend", "$27.74", "1h", "PR #122", "$0.028/line"],
      ["the-ledger", "$12.72", "30m", "PR #123", "$0.006/line"],
      ["the-floor", DASH, DASH, "PR #100", DASH],
      ["the-numbers-on-the-page", DASH, DASH, "PR #123", DASH],
      ["2 more rounds", DASH, DASH, DASH, DASH],
      ["no round record", "$996.54", "90%", DASH, DASH],
    ]);
  });

  it("orders the remainder last as the longest bar", () => {
    const last = panel.rows[panel.rows.length - 1];
    expect(last.remainder).toBe(true);
    expect(last.fill).toBe(1);
    expect(panel.rows.filter((r) => r.remainder)).toHaveLength(1);
  });
});

describe("WHERE by role", () => {
  it("prints root and crew with their sessions, their API hours and dollars an API hour, and names the lever", () => {
    // Round 11 (the Components frame, WHERE by role): `$61/API hour`, whole
    // dollars and the noun after a slash; chartered, it replaced `$54.69 an
    // API hour`.
    const panel = wherePanel("role", { report, yield: yieldReport, projects, goals, range })!;
    expect(panel.rows.map((r) => [r.name, r.spend, r.count, r.units, r.rate, r.remainder])).toEqual([
      ["root session", "$765.59", "114 sessions", "12.8 API h", "$54/API hour", false],
      ["crew, worktree", "$339.53", "36 sessions", "8.1 API h", "$24/API hour", false],
    ]);
    expect(panel.note).toBe("A crew is 55% cheaper an API hour");
    expect(panel.summary).toBe("$1,015.65 in 2 repositories · 83 merged PRs · 58,853 lines · 24 releases");
  });

  it("prints a dash for a role with no session, and says so for a daemon with no split", () => {
    const panel = wherePanel("role", { report: empty, yield: null, projects, goals, range })!;
    expect(panel.rows.map((r) => [r.spend, r.count, r.units, r.rate])).toEqual([[DASH, DASH, DASH, DASH], [DASH, DASH, DASH, DASH]]);
    expect(panel.note).toBe("No usage recorded in the range");
    const { roles: _r, ...old } = report;
    expect(wherePanel("role", { report: old, yield: null, projects, goals, range })!.note).toBe("This daemon sends no role split");
  });
});

describe("WHERE over an empty range and with no rollup", () => {
  it("prints every group as a dash and no remainder", () => {
    for (const grouping of ["project", "goal", "task"] as const) {
      const panel = wherePanel(grouping, { report: empty, yield: null, projects, goals: [], range: { from: empty.from, to: empty.to } })!;
      expect(panel.rows.some((r) => r.remainder), grouping).toBe(false);
      expect(panel.rows.every((r) => r.spend === DASH), grouping).toBe(true);
      expect(panel.note).toBe("No usage recorded in the range");
    }
    expect(wherePanel("goal", { report: null, yield: null, projects, goals, range })).toBeNull();
  });

  it("reads the grouping back from storage and defaults to goal", () => {
    expect(WHERE_DEFAULT).toBe("goal");
    expect(readWhereGrouping("role")).toBe("role");
    expect(readWhereGrouping("euros")).toBe("goal");
    expect(readWhereGrouping(null)).toBe("goal");
  });
});

describe("MODELS", () => {
  it("is one bar per model, dearest first, with the spend and the session count", () => {
    const panel = modelsPanel(report)!;
    expect(panel.rows.map((r) => [r.name, r.spend, r.sessions, r.fill])).toEqual([
      ["Fable 5.1", "$800.50", "97 sessions", 1],
      ["Opus 5 · 1M", "$292.62", "1 session", 292.62 / 800.5],
    ]);
    expect(panel.note).toBe("$12.00 is from records read before the rollup kept the per-model map, in the total and in no row");
    expect(panel.rows.map((r) => r.short), "the phone's whole dollars, the cents cut").toEqual(["$800", "$292"]);
    expect(JSON.stringify(panel)).not.toContain("cached");
  });

  it("draws nothing for an empty split, an old daemon, or no rollup", () => {
    expect(modelsPanel(empty)).toBeNull();
    const { models: _m, ...old } = report;
    expect(modelsPanel(old)).toBeNull();
    expect(modelsPanel(null)).toBeNull();
    expect(modelsPanel({ ...report, totals: { ...report.totals, unsplitUSD: 0 } })!.note).toBeNull();
  });
});

describe("LEAKS", () => {
  it("names the rounds with no Cost line on one line, then the corrections and the sessions under 95% cached joined on a second", () => {
    // Round 10 (the frame): `? 37 of 51 rounds carry no Cost line`, then
    // `· 3 corrections in 51 rounds · 3 sessions under 95% cached, $33.54`.
    expect(leakLines(report, goals).map((l) => [l.key, l.mark, l.text])).toEqual([
      ["unpriced", "attention", "4 of 9 rounds carry no Cost line"],
      ["rest", "pending", "1 correction in 9 rounds · 3 sessions under 95% cached, $33.54"],
    ]);
  });

  it("reports a zero as a grey line and leaves out a fact it has no source for", () => {
    const clean = leakLines(empty, [{ summary: { project: "p", rounds: [{ number: 1, costUSD: 1, correction: false }] } }]);
    expect(clean.map((l) => [l.mark, l.text])).toEqual([
      ["pending", "0 of 1 round carries no Cost line"],
      ["pending", "0 corrections in 1 round · no session under 95% cached"],
    ]);
    const { lowCache: _l, ...old } = report;
    expect(leakLines(old, []).map((l) => l.key)).toEqual([]);
    expect(leakLines(null, goals).map((l) => [l.key, l.text])).toEqual([
      ["unpriced", "4 of 9 rounds carry no Cost line"],
      ["rest", "1 correction in 9 rounds"],
    ]);
    expect(leakLines(report, []).map((l) => [l.key, l.text])).toEqual([["rest", "3 sessions under 95% cached, $33.54"]]);
  });

  it("claims no quality rate and no rework rate", () => {
    const text = JSON.stringify(leakLines(report, goals));
    expect(text).not.toMatch(/quality|rework/i);
  });
});
