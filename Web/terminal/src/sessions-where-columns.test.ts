import { describe, expect, it } from "vitest";

import { type KnowledgeSummary, type ProjectRef, type ProjectSummary, type RoundRecord, type UsageDaily, type UsageTokens } from "./sessions-model";
import { DASH, wherePanel, type YieldReport } from "./sessions-value";

/**
 * The three fact cells of `WHERE` at each of its four filters — the count,
 * the pull requests, the unit cost — as the `Components` frame of
 * `corpus/dashboard.pen` draws them (`agent-dashboard` round 12, the
 * frame the human approved on 2026-09-19): `10 goals · 83 PRs · $11.17/PR`
 * by project, `6 tasks · 4 PRs · $0.018/line` by goal, `1 round · PR #122
 * · $0.010/line` by task, `86% · 34.0 h · $61/API hour` by role. The
 * fixture carries the frame's own numbers where one arithmetic can hold
 * them; a cell with no source is a dash.
 */

const W = "/Users/antran/Workspace";
const tokens: UsageTokens = { input: 1, output: 1, cacheCreation: 0, cacheRead: 1, requests: 1 };
const bucket = (ref: ProjectRef, costUSD: number, sessions: number) => ({ ...ref, root: ref.root!, registered: true, costUSD, apportionedUSD: 0, tokens, sessions, unbilledSessions: 0 });

const kitterm: ProjectRef = { id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true };
const mdp: ProjectRef = { id: "mdp", name: "market-data-pipeline", root: `${W}/market-data-pipeline`, registered: true };
const mt5: ProjectRef = { id: "mt5", name: "nghenhan-mt5", root: `${W}/nghenhan-mt5`, registered: true };
const projects: ProjectSummary[] = [kitterm, mdp, mt5].map((p) => ({ ...p, knowledge: "docs/goals" }));

/** The frame's `by project` and `by goal` filters: $959.41 over three
 * roots, the goals' Cost lines claiming $143.85 of it. */
const report: UsageDaily = {
  ok: true, timeZone: "Asia/Ho_Chi_Minh", from: "2026-08-19", to: "2026-09-17", refreshedAt: 1, recordedSessions: 104,
  days: [],
  totals: { costUSD: 959.41, apportionedUSD: 0, unsplitUSD: 0, tokens, sessions: 104, unbilledSessions: 0, apiMs: 42.1 * 3_600_000, measuredUSD: 959.41 },
  models: [],
  projects: [bucket(kitterm, 926.21, 92), bucket(mdp, 30.91, 10), bucket(mt5, 2.29, 2)],
  roles: [],
  lowCache: [],
};

/** The frame's `by role` filter: $2,415 in the fleet, 86% of it in root
 * sessions over 34.0 API hours (`wholeDollars` floors, so the cents sit
 * where the frame's rates come out). */
const fleet: UsageDaily = {
  ...report,
  totals: { ...report.totals, costUSD: 2415.0, sessions: 92, apiMs: 42.1 * 3_600_000, measuredUSD: 2415.0 },
  roles: [
    { role: "root", costUSD: 2074.5, apportionedUSD: 0, sessions: 70, apiMs: 34.0 * 3_600_000, measuredUSD: 2074.5, linesAdded: 40_000 },
    { role: "crew", costUSD: 340.5, apportionedUSD: 0, sessions: 22, apiMs: 8.1 * 3_600_000, measuredUSD: 340.5, linesAdded: 8_000 },
  ],
};

const yieldReport: YieldReport = {
  ok: true, from: report.from, to: report.to,
  projects: [
    { ...kitterm, root: kitterm.root!, yield: { checkout: true, remote: true, branch: "origin/main", mergedPullRequests: 83, mergedLines: 58_853, releases: 24,
      pullRequests: [{ number: 121, lines: 572 }, { number: 122, lines: 1774 }, { number: 123, lines: 1413 }, { number: 124, lines: 414 }] } },
    { ...mdp, root: mdp.root!, yield: { checkout: true, remote: true, branch: "origin/main", mergedPullRequests: 10, mergedLines: 900, releases: 0, pullRequests: [] } },
    // A remote with nothing merged in the range: a dash, never `0 PRs`.
    { ...mt5, root: mt5.root!, yield: { checkout: true, remote: true, branch: "origin/main", mergedPullRequests: 0, mergedLines: 0, releases: 0, pullRequests: [] } },
  ],
  totals: { checkouts: 3, counted: 3, mergedPullRequests: 93, mergedLines: 59_753, releases: 24 },
};

/** A round record; `minutes` is its wall time, the working time the task
 * filter prints (round 13), absent for a record with no Cost line. */
const round = (number: number, task: string, costUSD: number | undefined, pr?: number, minutes?: number): RoundRecord =>
  ({ number, task, started: "2026-09-10", costUSD, pr, correction: false, ...(minutes === undefined ? {} : { durationMs: minutes * 60_000 }) });
const goal = (project: ProjectRef, slug: string, rounds: RoundRecord[]): { project: ProjectRef; summary: KnowledgeSummary } => ({ project, summary: { project: project.id, slug, status: "done", rounds } });

/** kitterm's ten goals: three with rounds in the range (the frame's rows)
 * and seven the count column counts and nothing else; two for the
 * pipeline; none for the MT5 root. */
const goals = [
  goal(kitterm, "workspace-ledger", [
    round(1, "capture-the-quota", 17.74, 122, 45),
    round(2, "the-ledger", 15.84, undefined, 62),
    round(3, "the-numbers-on-the-page", 12.72, 123, 60),
    round(4, "answer-from-the-page", 11.44, 121, 38),
    round(5, "the-floor", 8.0, 124, 25),
    round(6, "the-ratchet", 9.37),
  ]),
  // A task that took two rounds, the second a correction of the first.
  goal(kitterm, "fleet-catch-up", [round(1, "catch-up-plan", 10.0, undefined, 30), round(2, "catch-up-plan", 8.79, undefined, 40), round(3, "catch-up-tree", 9.0, undefined, 20), round(4, "catch-up-folds", 8.0, undefined, 15)]),
  goal(kitterm, "cost-per-round", [round(1, "the-line", 10.0, undefined, 10), round(2, "the-parser", 10.0, undefined, 10), round(3, "the-route", 10.0, undefined, 10), round(4, "the-page", 2.95, undefined, 5)]),
  ...["a", "b", "c", "d", "e", "f", "g"].map((s) => goal(kitterm, `older-${s}`, [])),
  goal(mdp, "ingest", []),
  goal(mdp, "backfill", []),
];
const range = { from: report.from, to: report.to };
const cells = (grouping: "project" | "goal" | "task" | "role", usage = report) =>
  wherePanel(grouping, { report: usage, yield: yieldReport, projects, goals, range })!.rows.map((r) => [r.name, r.spend, r.count, r.units, r.rate]);

describe("WHERE columns per filter (the Components frame)", () => {
  it("by project: the goals, the merged PRs, the cost a PR; a root with no goal and nothing merged prints dashes", () => {
    expect(cells("project")).toEqual([
      ["kitterm", "$926.21", "10 goals", "83 PRs", "$11.16/PR"],
      ["market-data-pipeline", "$30.91", "2 goals", "10 PRs", "$3.09/PR"],
      ["nghenhan-mt5", "$2.29", DASH, DASH, DASH],
    ]);
  });

  it("by goal: the tasks, the PRs, the cost a line; the remainder's share in the count column", () => {
    const panel = wherePanel("goal", { report, yield: yieldReport, projects, goals, range })!;
    // Round 13 (the human's word): every goal is a row, the nine with
    // nothing in the range as dash rows by name; chartered, they replaced
    // `9 more goals`. The remainder stays last.
    expect(cells("goal")).toEqual([
      ["workspace-ledger", "$75.11", "6 tasks", "4 PRs", "$0.018/line"],
      ["fleet-catch-up", "$35.79", "4 tasks", DASH, DASH],
      ["cost-per-round", "$32.95", "4 tasks", DASH, DASH],
      ["backfill", DASH, DASH, DASH, DASH],
      ["ingest", DASH, DASH, DASH, DASH],
      ...["a", "b", "c", "d", "e", "f", "g"].map((s) => [`older-${s}`, DASH, DASH, DASH, DASH]),
      ["no round record", "$815.56", "85%", DASH, DASH],
    ]);
    expect(panel.note).toBe("85% names no round, so it cannot be valued");
  });

  it("by task: the working time, the one PR, the cost a line; a task of two rounds sums their time", () => {
    // Round 13 (the human's word): the count cell is the task's working
    // time, `45m`, `1h 2m`, its rounds' wall time summed; a task with no
    // duration prints a dash. Chartered: round 12's `1 round`, `2 rounds`.
    expect(cells("task")).toEqual([
      ["catch-up-plan", "$18.79", "1h 10m", DASH, DASH],
      ["capture-the-quota", "$17.74", "45m", "PR #122", "$0.010/line"],
      ["the-ledger", "$15.84", "1h 2m", DASH, DASH],
      ["the-numbers-on-the-page", "$12.72", "1h", "PR #123", "$0.009/line"],
      ["answer-from-the-page", "$11.44", "38m", "PR #121", "$0.020/line"],
      ["the-line", "$10.00", "10m", DASH, DASH],
      ["the-parser", "$10.00", "10m", DASH, DASH],
      ["the-route", "$10.00", "10m", DASH, DASH],
      ["the-ratchet", "$9.37", DASH, DASH, DASH],
      ["catch-up-tree", "$9.00", "20m", DASH, DASH],
      ["catch-up-folds", "$8.00", "15m", DASH, DASH],
      ["the-floor", "$8.00", "25m", "PR #124", "$0.019/line"],
      ["the-page", "$2.95", "5m", DASH, DASH],
      ["no round record", "$815.56", "85%", DASH, DASH],
    ]);
  });

  it("by role: the share of the range, the API hours as `34.0 h`, the dollars an API hour in whole dollars", () => {
    expect(cells("role", fleet)).toEqual([
      ["root session", "$2,074.50", "86%", "34.0 h", "$61/API hour"],
      ["crew, worktree", "$340.50", "14%", "8.1 h", "$42/API hour"],
    ]);
    // The share is the remainder's arithmetic: a role with no session has none.
    const none = { ...fleet, roles: [{ role: "root" as const, costUSD: 0, apportionedUSD: 0, sessions: 0, apiMs: 0, measuredUSD: 0, linesAdded: 0 }] };
    expect(cells("role", none)).toEqual([["root session", DASH, DASH, DASH, DASH]]);
  });
});
