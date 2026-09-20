import {
  dayKey,
  type DayRange,
  type KnowledgeSummary,
  type ProjectRef,
  type ProjectSummary,
  type UsageDaily,
  type UsageModel,
  type UsageProject,
  type UsageRole,
  type UsageTokens,
} from "./sessions-model";
import { type YieldReport } from "./sessions-value";

/**
 * A fleet with sessions, pull requests, releases and round records on both
 * sides of a range boundary, and the two answers the daemon gives for a
 * range over it: `rollup(range)` is what `GET /api/usage/daily` sums
 * inside the days, `yieldFor(range)` what `GET /api/yield` counts there.
 * The page's figures must follow whichever range the toggles set
 * (`agent-dashboard` round 13); `sessions-range.test.ts` pins each panel
 * and `sessions-range-page.test.ts` the page. Test-only; nothing ships it.
 */

const W = "/Users/antran/Workspace";
export const kitterm: ProjectRef = { id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true };
export const mdp: ProjectRef = { id: "mdp", name: "market-data-pipeline", root: `${W}/market-data-pipeline`, registered: true };
export const projects: ProjectSummary[] = [kitterm, mdp].map((p) => ({ ...p, knowledge: "docs/goals" }));

/** `n` days before `now`, as a day key of this clock's zone. */
export function daysAgo(now: number, n: number): string {
  const d = new Date(now);
  return dayKey(new Date(d.getFullYear(), d.getMonth(), d.getDate() - n, 12).getTime());
}

const inRange = (day: string, range: DayRange): boolean => day >= range.from && day <= range.to;

type Session = { day: string; project: ProjectRef | null; model: string; name: string; costUSD: number; apiMs: number; role: "root" | "crew"; cacheShare: number };

/** Five billed sessions: two inside the last week, one last month, one
 * two months back, and one in a home directory no project holds. */
function sessions(now: number): Session[] {
  const h = 3_600_000;
  return [
    { day: daysAgo(now, 1), project: kitterm, model: "claude-fable-5-1", name: "Fable 5.1", costUSD: 40, apiMs: 2 * h, role: "root", cacheShare: 0.98 },
    { day: daysAgo(now, 3), project: kitterm, model: "claude-opus-5[1m]", name: "Opus 5 · 1M", costUSD: 30, apiMs: 1 * h, role: "crew", cacheShare: 0.93 },
    { day: daysAgo(now, 5), project: null, model: "claude-fable-5-1", name: "Fable 5.1", costUSD: 5, apiMs: 0.5 * h, role: "root", cacheShare: 0.99 },
    { day: daysAgo(now, 40), project: kitterm, model: "claude-fable-5-1", name: "Fable 5.1", costUSD: 100, apiMs: 4 * h, role: "root", cacheShare: 0.9 },
    { day: daysAgo(now, 76), project: mdp, model: "claude-haiku-4-5-20251001", name: "Haiku 4.5", costUSD: 20, apiMs: 1 * h, role: "crew", cacheShare: 0.99 },
  ];
}

const tokens: UsageTokens = { input: 1, output: 1, cacheCreation: 0, cacheRead: 1, requests: 1 };

/** The rollup's answer for `range`: every figure summed over the sessions
 * inside it, as `UsageRollup` does. */
export function rollup(range: DayRange, now: number): UsageDaily {
  const inside = sessions(now).filter((s) => inRange(s.day, range));
  const sum = (list: Session[]): number => list.reduce((t, s) => t + s.costUSD, 0);
  const byProject = new Map<string, UsageProject>();
  for (const s of inside) {
    const ref = s.project ?? { id: "antran", name: "antran", root: "/Users/antran", registered: false };
    const root = ref.root ?? "";
    const bucket = byProject.get(root) ?? { ...ref, root, costUSD: 0, apportionedUSD: 0, tokens, sessions: 0, unbilledSessions: 0 };
    byProject.set(root, { ...bucket, costUSD: bucket.costUSD + s.costUSD, sessions: bucket.sessions + 1 });
  }
  const byModel = new Map<string, UsageModel>();
  for (const s of inside) {
    const row = byModel.get(s.model) ?? { model: s.model, name: s.name, costUSD: 0, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 0 };
    byModel.set(s.model, { ...row, costUSD: row.costUSD + s.costUSD, sessions: row.sessions + 1 });
  }
  const role = (name: "root" | "crew"): UsageRole => {
    const own = inside.filter((s) => s.role === name);
    return { role: name, costUSD: sum(own), apportionedUSD: 0, sessions: own.length, apiMs: own.reduce((t, s) => t + s.apiMs, 0), measuredUSD: sum(own), linesAdded: own.length * 100 };
  };
  return {
    ok: true,
    timeZone: "Asia/Ho_Chi_Minh",
    from: range.from,
    to: range.to,
    refreshedAt: now,
    recordedSessions: inside.length,
    days: [],
    totals: { costUSD: sum(inside), apportionedUSD: 0, unsplitUSD: 0, tokens, sessions: inside.length, unbilledSessions: 0, apiMs: inside.reduce((t, s) => t + s.apiMs, 0), measuredUSD: sum(inside) },
    models: [...byModel.values()].sort((a, b) => b.costUSD - a.costUSD),
    projects: [...byProject.values()],
    roles: [role("root"), role("crew")],
    lowCache: inside.filter((s) => s.costUSD > 5 && s.cacheShare < 0.95).map((s) => ({ project: s.project?.name ?? "antran", costUSD: s.costUSD, cacheShare: s.cacheShare })),
  };
}

/** kitterm's four merged pull requests and two releases: two of each
 * inside the last week, the rest older. */
export function yieldFor(range: DayRange, now: number): YieldReport {
  const prs = [
    { number: 201, lines: 300, day: daysAgo(now, 2) },
    { number: 202, lines: 200, day: daysAgo(now, 4) },
    { number: 150, lines: 1000, day: daysAgo(now, 49) },
    { number: 120, lines: 500, day: daysAgo(now, 71) },
  ].filter((pr) => inRange(pr.day, range));
  const releases = [daysAgo(now, 3), daysAgo(now, 45)].filter((day) => inRange(day, range)).length;
  const lines = prs.reduce((t, pr) => t + pr.lines, 0);
  return {
    ok: true,
    from: range.from,
    to: range.to,
    projects: [
      { ...kitterm, root: kitterm.root!, yield: { checkout: true, remote: true, branch: "origin/main", mergedPullRequests: prs.length, mergedLines: lines, releases, pullRequests: prs.map(({ number, lines: l }) => ({ number, lines: l })) } },
      { ...mdp, root: mdp.root!, yield: { checkout: true, remote: false, branch: "HEAD", releases: 0 } },
    ],
    totals: { checkouts: 2, counted: 1, mergedPullRequests: prs.length, mergedLines: lines, releases },
  };
}

/** Three goals whose records straddle the week: `alpha` with four rounds
 * over ten weeks, `beta` with one last month and one this week that
 * carries no Cost line, `gamma` in the pipeline two months back. */
export function goals(now: number): { project: ProjectRef; summary: KnowledgeSummary }[] {
  const m = 60_000;
  return [
    {
      project: kitterm,
      summary: {
        project: "kitterm", slug: "alpha", goal: "alpha", status: "active", round: 1, budget: 3, costUSD: 30, tasks: [{ slug: "ship", state: "pending" }],
        rounds: [
          { number: 1, task: "seed", started: daysAgo(now, 70), costUSD: 13, durationMs: 30 * m, pr: 120, correction: true },
          { number: 2, task: "grow", started: daysAgo(now, 48), pr: 150, correction: false },
          { number: 3, task: "polish", started: daysAgo(now, 4), costUSD: 8, durationMs: 45 * m, pr: 202, correction: false },
          { number: 4, task: "ship", started: daysAgo(now, 2), costUSD: 9, durationMs: 62 * m, pr: 201, correction: false },
        ],
      },
    },
    {
      project: kitterm,
      summary: {
        project: "kitterm", slug: "beta", goal: "beta", status: "done", round: 2, budget: 3, costUSD: 5,
        rounds: [
          { number: 1, task: "plan", started: daysAgo(now, 30), costUSD: 5, durationMs: 20 * m, correction: false },
          { number: 2, task: "fix", started: daysAgo(now, 6), correction: false },
        ],
      },
    },
    {
      project: mdp,
      summary: {
        project: "mdp", slug: "gamma", goal: "gamma", status: "done", round: 1, budget: 3, costUSD: 20,
        rounds: [{ number: 1, task: "ingest", started: daysAgo(now, 76), costUSD: 20, durationMs: 60 * m, correction: false }],
      },
    },
  ];
}
