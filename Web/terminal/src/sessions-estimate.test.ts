import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { BILL_TITLE, type ModelRow, type ProjectSummary, runningEstimate, secondsAgo, sessionCost, sessionCostTitle, type UsageDaily } from "./sessions-model";
import { sessionFactColumns, tree } from "./sessions-tree";

/**
 * A running session has a cost (`agent-dashboard`, round 16): Claude Code
 * writes the `cost-state` line at exit, so the cost route prices the
 * transcript's turns so far under `estimate`, and the page prints that as
 * `~$4.20` until the bill lands, when it prints `$4.31` with no `~`. The
 * tooltip says what the figure is and how old; the project's tooltip
 * says what is running under it and on no figure above it. A watch-only
 * token sees no cost, as before.
 */

const NOW = Date.now();
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, knowledge: "docs/goals" };
const ref = { id: kitterm.id, name: kitterm.name, root: kitterm.root!, registered: true };
const range = { from: "2026-08-22", to: "2026-09-20" };

const running: ModelRow = {
  id: "s-running", name: "crew", cwd: kitterm.root!, state: "running", mergedState: "working", marks: 0, project: ref,
  agentModel: "claude-opus-5", agentModelName: "Opus 5", agentTranscript: "/t/running.jsonl", lastOutputAt: NOW - 12_000,
} as ModelRow;
const done: ModelRow = {
  id: "s-done", name: "review", cwd: kitterm.root!, state: "running", mergedState: "completed", marks: 0, project: ref,
  agentModel: "claude-opus-5", agentModelName: "Opus 5", agentTranscript: "/t/done.jsonl", lastOutputAt: NOW - 60_000,
} as ModelRow;

const estimate = { hasBill: false, estimate: { costUSD: 4.2, turns: 12, startTime: Date.parse("2026-09-20T01:00:00Z"), updatedAt: NOW - 12_000 } };
const bill = { hasBill: true, totalCostUSD: 4.31, startTime: Date.parse("2026-09-20T01:00:00Z") };

describe("the cost column of a running session", () => {
  it("prints the estimate as ~$4.20 and the bill as $4.31 with no ~, the dash with neither", () => {
    expect(sessionCost(estimate, range)).toBe("~$4.20");
    expect(sessionCost(bill, range)).toBe("$4.31");
    expect(sessionCost({ hasBill: false }, range)).toBeNull();
    expect(sessionCost(null, range)).toBeNull();
    expect(sessionCost(undefined, range)).toBeNull();
    // The bill wins over an estimate the page still holds.
    expect(sessionCost({ ...bill, estimate: estimate.estimate }, range)).toBe("$4.31");
  });

  it("places the estimate in the range by its first turn, like a bill by its start", () => {
    const old = { from: "2026-08-01", to: "2026-08-31" };
    expect(sessionCost(estimate, old)).toBeNull();
    expect(sessionCost(bill, old)).toBeNull();
    // No start: counted, as a bill with no start is.
    expect(sessionCost({ hasBill: false, estimate: { costUSD: 1, turns: 1, updatedAt: NOW } }, old)).toBe("~$1.00");
  });

  it("says in the tooltip how many turns the estimate prices and how old it is", () => {
    expect(sessionCostTitle(estimate, NOW)).toBe("estimated from 12 turns · updated 12s ago");
    expect(sessionCostTitle({ hasBill: false, estimate: { costUSD: 0.5, turns: 1, updatedAt: NOW - 4 * 60_000 } }, NOW)).toBe("estimated from 1 turn · updated 4m ago");
    expect(sessionCostTitle(bill, NOW)).toBe(BILL_TITLE);
    expect(sessionCostTitle(null, NOW)).toBe(BILL_TITLE);
    expect(secondsAgo(0)).toBe("0s ago");
    expect(secondsAgo(59_999)).toBe("59s ago");
    expect(secondsAgo(3 * 3_600_000)).toBe("3h ago");
    // The fact cell carries it.
    expect(sessionFactColumns("~$4.20", "Opus 5", "claude-opus-5", "12s", "estimated from 12 turns · updated 12s ago").map((f) => [f.kind, f.text, f.column, f.narrow, f.title])).toEqual([
      ["cost", "~$4.20", 2, true, "estimated from 12 turns · updated 12s ago"], ["model", "Opus 5", 3, false, "claude-opus-5"], ["since", "12s", 4, false, undefined],
    ]);
    expect(sessionFactColumns("$4.31", null, undefined, null)[0].title).toBe(BILL_TITLE);
  });

  it("sums a project's running estimates for its tooltip and adds nothing to a figure", () => {
    const billOf = (id: string) => (id === "s-running" ? estimate : id === "s-done" ? bill : id === "s-two" ? { hasBill: false, estimate: { costUSD: 2.2, turns: 3, updatedAt: NOW } } : undefined);
    expect(runningEstimate([running, done], billOf)).toBe("+ ~$4.20 running");
    expect(runningEstimate([running, done, { id: "s-two" }], billOf)).toBe("+ ~$6.40 running");
    expect(runningEstimate([done], billOf)).toBeNull();
    expect(runningEstimate([], billOf)).toBeNull();

    const usage: UsageDaily = {
      ok: true, timeZone: "UTC", from: range.from, to: range.to, refreshedAt: NOW, recordedSessions: 1, days: [],
      totals: { costUSD: 926.21, apportionedUSD: 0, tokens: { input: 1, output: 1, cacheCreation: 0, cacheRead: 0, requests: 1 }, sessions: 1, unbilledSessions: 0 },
      projects: [{ ...ref, costUSD: 926.21, apportionedUSD: 0, tokens: { input: 1, output: 1, cacheCreation: 0, cacheRead: 0, requests: 1 }, sessions: 1, unbilledSessions: 0 }],
    };
    const built = tree({ rows: [running, done], projects: [kitterm], goalsOf: () => [], approvals: [], proposed: [], usage, billOf, now: NOW });
    const [section] = built.sections;
    const [project, first, second] = section.lines;
    // The project's figure is the rollup's; the estimate is its tooltip.
    expect(project.facts.map((f) => f.text)).toEqual(["$926.21", "1 agent"]);
    expect(project.title).toBe(`${kitterm.root}\nno goal folder\n+ ~$4.20 running`);
    expect([first.name, first.facts.map((f) => f.text), first.facts[0].title]).toEqual(["crew", ["~$4.20", "Opus 5", "now"], "estimated from 12 turns · updated 12s ago"]);
    expect([second.name, second.facts.map((f) => f.text), second.facts[0].title]).toEqual(["review", ["$4.31", "Opus 5", "1m"], BILL_TITLE]);
    // Without a rollup no cost is on the page, and the tooltip carries no
    // estimate either.
    const bare = tree({ rows: [running, done], projects: [kitterm], goalsOf: () => [], approvals: [], proposed: [], usage: null, billOf, now: NOW });
    expect(bare.sections[0].lines[1].facts.map((f) => f.kind)).toEqual(["model", "since"]);
  });
});

// --- the page --------------------------------------------------------------

const usage: UsageDaily = {
  ok: true, timeZone: "UTC", from: range.from, to: range.to, refreshedAt: NOW, recordedSessions: 1, days: [],
  totals: { costUSD: 926.21, apportionedUSD: 0, tokens: { input: 1, output: 1, cacheCreation: 0, cacheRead: 0, requests: 1 }, sessions: 1, unbilledSessions: 0 },
  projects: [{ ...ref, costUSD: 926.21, apportionedUSD: 0, tokens: { input: 1, output: 1, cacheCreation: 0, cacheRead: 0, requests: 1 }, sessions: 1, unbilledSessions: 0 }],
};
const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [running, done] },
  "/api/projects": { projects: [kitterm] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/daily": usage,
  "/api/usage/limits": { ok: true, hasReading: false },
  // What the cost route answers a running session: no bill, the estimate.
  "/api/sessions/s-running/cost": {
    ok: true, hasBill: false, reason: "noCostStateLine", estimated: true,
    estimate: { estimated: true, costUSD: 4.2, turns: 12, inTokens: 900_000, cacheReadTokens: 850_000, outTokens: 30_000, asOf: NOW, startTime: Date.parse("2026-09-20T01:00:00Z"), unpricedModels: [] },
  },
  "/api/sessions/s-done/cost": { ok: true, hasBill: true, estimated: false, bill: { totalCostUSD: 4.31, startTime: Date.parse("2026-09-20T01:00:00Z") } },
};

let page: FakePage;

beforeAll(async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(NOW);
  page = installFakePage(routes);
  await import("./sessions");
  await page.settle();
});

afterAll(() => {
  vi.useRealTimers();
});

const sessionLines = () => page.root.querySelector(".tree")!.querySelectorAll(".row-line");
const costOf = (line: FakeElement) => {
  const cost = line.querySelector(".cost");
  return cost === null ? null : [cost.textContent, cost.getAttribute("data-col"), cost.hasAttribute("data-narrow"), cost.title];
};

describe("the painted line", () => {
  it("prints ~$4.20 for the running session with the estimate's tooltip, $4.31 for the finished one, and the project's tooltip names the running estimate", () => {
    const lines = sessionLines();
    expect(lines.map((l) => l.querySelector(".line-name")?.textContent)).toEqual(["crew", "review"]);
    expect(costOf(lines[0])).toEqual(["~$4.20", "2", true, "estimated from 12 turns · updated 0s ago"]);
    expect(costOf(lines[1])).toEqual(["$4.31", "2", true, BILL_TITLE]);
    // The figure is the cost cell's text: the `~` wears no mark of its own,
    // and the cell is the fact colour like every cost.
    expect(lines[0].querySelector(".cost")?.querySelectorAll(".mark")).toEqual([]);
    const project = page.root.querySelector(".tree")!.querySelector(".line-project")!;
    expect(project.querySelector(".line-name")?.title).toBe(`${kitterm.root}\nno goal folder\n+ ~$4.20 running`);
    expect(project.querySelector(".cost")?.textContent).toBe("$926.21");
  });

  it("prints the bill with no ~ once it lands, on the next ask of the route", async () => {
    routes["/api/sessions/s-running/cost"] = { ok: true, hasBill: true, estimated: false, bill: { totalCostUSD: 4.31, startTime: Date.parse("2026-09-20T01:00:00Z") } };
    // The page asks a running row every 30 s; a poll inside the window
    // keeps the estimate and does not ask again. (The tooltip's age moves
    // with the next repaint, which the signature gates on the facts' text.)
    const asked = () => page.requests.filter((u) => u.includes("/api/sessions/s-running/cost")).length;
    const before = asked();
    vi.setSystemTime(NOW + 12_000);
    await page.poll();
    expect(costOf(sessionLines()[0])?.slice(0, 3)).toEqual(["~$4.20", "2", true]);
    expect(asked()).toBe(before);
    vi.setSystemTime(NOW + 31_000);
    await page.poll();
    expect(asked()).toBe(before + 1);
    expect(costOf(sessionLines()[0])).toEqual(["$4.31", "2", true, BILL_TITLE]);
    expect(page.root.querySelector(".tree")!.querySelector(".line-project")!.querySelector(".line-name")?.title).toBe(`${kitterm.root}\nno goal folder`);
  });
});
