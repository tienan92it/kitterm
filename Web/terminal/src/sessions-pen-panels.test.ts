import { describe, expect, it } from "vitest";

import {
  agentsLabel,
  DONE_TASKS_SHOWN,
  idleShellsLabel,
  isIdleShell,
  latestDoneGoal,
  roundCounter,
  shownTasks,
  wholeDollars,
  type KnowledgeSummary,
  type ModelRow,
  type TaskLine,
  type UsageDaily,
} from "./sessions-model";
import { apportionedNote, scopeOf, usageHead, whereSummary, type YieldReport } from "./sessions-value";

/**
 * The wording the frames `Dashboard 1200` and `Dashboard 390` fix
 * (`agent-dashboard`, round 10), at the model: the USAGE headline row and
 * its one note, the scope a unit cost is read in, the whole-dollar forms,
 * the `r0/3` counter, the `N agents` fact, the idle-shell rule, and which
 * done goal and which done tasks a project shows open.
 */

const tokens = { input: 1_000_000_000, output: 30_000_000, cacheCreation: 400_000_000, cacheRead: 3_000_000_000, requests: 1000 };
const report: UsageDaily = {
  ok: true,
  timeZone: "UTC",
  from: "2026-08-19",
  to: "2026-09-17",
  refreshedAt: 1,
  recordedSessions: 200,
  days: [],
  totals: { costUSD: 2316.83, apportionedUSD: 1446, tokens, sessions: 150, unbilledSessions: 4, apiMs: 20.9 * 3_600_000, measuredUSD: 990 },
  projects: [
    { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, costUSD: 976.74, apportionedUSD: 0, tokens, sessions: 92, unbilledSessions: 0 },
    { id: "mdp", name: "market-data-pipeline", root: "/w/t/mdp", registered: true, costUSD: 38.91, apportionedUSD: 0, tokens, sessions: 10, unbilledSessions: 0 },
  ],
};
const yieldReport: YieldReport = {
  ok: true,
  from: report.from,
  to: report.to,
  projects: [
    { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, yield: { checkout: true, remote: true, branch: "origin/main", mergedPullRequests: 83, mergedLines: 58_853, releases: 24 } },
    { id: "mdp", name: "market-data-pipeline", root: "/w/t/mdp", registered: true, yield: { checkout: false, remote: false } },
  ],
  totals: { checkouts: 1, counted: 1, mergedPullRequests: 83, mergedLines: 58_853, releases: 24 },
};

describe("the USAGE headline row", () => {
  it("prints the dollars at the headline size with the tokens and the model hours beside them, and the span for a phone", () => {
    expect(usageHead(report, { mode: "cost", span: 30 })).toEqual({
      amount: "$2,316.83",
      facts: ["4.43B tokens", "20.9 h model time"],
      span: "30 days",
      title: "if billed at full API rate",
    });
  });

  it("swaps the amount and the first fact in tokens mode, and leaves out the hours an old daemon does not send", () => {
    expect(usageHead(report, { mode: "tokens", span: 7 })).toMatchObject({ amount: "4.43B", facts: ["$2,316.83", "20.9 h model time"], span: "7 days" });
    const { apiMs: _a, ...old } = report.totals;
    expect(usageHead({ ...report, totals: old }, { mode: "cost", span: 90 })!.facts).toEqual(["4.43B tokens"]);
    expect(usageHead(null, { mode: "cost", span: 30 })).toBeNull();
    expect(usageHead({ ...report, ok: false }, { mode: "cost", span: 30 })).toBeNull();
  });

  it("has one note, the apportioned dollars, and none when nothing was apportioned or in tokens mode", () => {
    expect(apportionedNote(report.totals, "cost")).toBe("$1,446.00 apportioned across midnight");
    expect(apportionedNote({ ...report.totals, apportionedUSD: 0 }, "cost")).toBeNull();
    expect(apportionedNote(report.totals, "tokens")).toBeNull();
    expect(apportionedNote(null, "cost")).toBeNull();
  });
});

describe("the scope a unit cost is read in", () => {
  it("names the one counted checkout, else counts them, and sums their spend", () => {
    expect(scopeOf(report, yieldReport)).toMatchObject({ label: "kitterm", spendUSD: 976.74 });
    const two: YieldReport = { ...yieldReport, projects: yieldReport.projects.map((p) => ({ ...p, yield: { ...p.yield, checkout: true } })) };
    expect(scopeOf(report, two)).toMatchObject({ label: "2 repositories", spendUSD: 976.74 + 38.91 });
    expect(scopeOf(report, null)).toMatchObject({ label: null, spendUSD: 0, checkouts: [] });
  });

  it("is the WHERE selector's right-hand line", () => {
    expect(whereSummary(report, yieldReport)).toBe("$976.74 in kitterm · 83 merged PRs · 58,853 lines · 24 releases");
    expect(whereSummary(report, null)).toBeNull();
    const one: YieldReport = { ...yieldReport, totals: { checkouts: 1, counted: 1, mergedPullRequests: 1, mergedLines: 1, releases: 1 } };
    expect(whereSummary(report, one)).toBe("$976.74 in kitterm · 1 merged PR · 1 line · 1 release");
  });
});

describe("the frame's short forms", () => {
  it("prints whole dollars with the cents cut, thousands grouped", () => {
    expect(wholeDollars(2316.83)).toBe("$2,316");
    expect(wholeDollars(1283.48)).toBe("$1,283");
    expect(wholeDollars(0.4)).toBe("$0");
    expect(wholeDollars(-12.6)).toBe("-$12");
  });

  it("prints the round counter as r0/3", () => {
    expect(roundCounter({ project: "p", round: 0, budget: 3 })).toBe("r0/3");
    expect(roundCounter({ project: "p", round: 6 })).toBe("r6");
    expect(roundCounter({ project: "p" })).toBeNull();
  });

  it("counts the agents at a heading's end and prints nothing for none", () => {
    expect(agentsLabel(0)).toBeNull();
    expect(agentsLabel(1)).toBe("1 agent");
    expect(agentsLabel(2)).toBe("2 agents");
    expect(idleShellsLabel(1)).toBe("1 idle shell");
    expect(idleShellsLabel(3)).toBe("3 idle shells");
  });
});

describe("what leaves the tree for the idle fold", () => {
  const row = (state: ModelRow["mergedState"], extra: Partial<ModelRow> = {}): ModelRow => ({ id: "r", cwd: "/w", mergedState: state, ...extra });

  it("is an idle shell, an exited one, and one with no integration; not a working, waiting, failed or completed agent", () => {
    expect(isIdleShell(row("idle"))).toBe(true);
    expect(isIdleShell(row("exited"))).toBe(true);
    expect(isIdleShell(row("unknown"))).toBe(true);
    expect(isIdleShell({ id: "old", cwd: "/w", state: "idle" })).toBe(true);
    for (const state of ["working", "needs-approval", "needs-input", "failed", "completed"] as const) {
      expect(isIdleShell(row(state)), state).toBe(false);
    }
  });
});

describe("what a project shows open among its done goals and tasks", () => {
  const task = (slug: string, state: TaskLine<ModelRow>["state"]): TaskLine<ModelRow> => ({ slug, state, tag: `[${state}]`, facts: [], rows: [] });

  it("shows every open task and the first two done ones, in the daemon's order", () => {
    expect(DONE_TASKS_SHOWN).toBe(2);
    const tasks = [task("a", "pending"), task("b", "done"), task("c", "working"), task("d", "done"), task("e", "failed"), task("f", "done")];
    expect(shownTasks(tasks).map((t) => t.slug)).toEqual(["a", "b", "c", "d", "e"]);
    expect(shownTasks([task("x", "done")]).map((t) => t.slug)).toEqual(["x"]);
    expect(shownTasks([])).toEqual([]);
  });

  it("opens the done goal whose latest round started last, else the first, and none for none", () => {
    const goal = (slug: string, days: string[]): KnowledgeSummary => ({ project: "p", slug, status: "done", rounds: days.map((started, i) => ({ number: i + 1, started, correction: false })) });
    const older = goal("older", ["2026-09-01", "2026-09-10"]);
    const newer = goal("newer", ["2026-09-12"]);
    const undated: KnowledgeSummary = { project: "p", slug: "undated", status: "done" };
    expect(latestDoneGoal([older, newer])).toBe(newer);
    expect(latestDoneGoal([newer, older])).toBe(newer);
    expect(latestDoneGoal([undated, older])).toBe(older);
    expect(latestDoneGoal([undated])).toBe(undated);
    expect(latestDoneGoal([])).toBeNull();
  });
});
