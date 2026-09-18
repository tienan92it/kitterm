import { beforeAll, describe, expect, it, vi } from "vitest";

import { installFakePage, type FakePage } from "./fake-page";

/**
 * The page with the four panels in place (`agent-dashboard`, capability
 * 7), rendered by `sessions.ts` itself against a fleet with a rollup, a
 * yield answer, a role split, a low-cache list, and one goal whose records
 * price two of three rounds. The panels sit between the quota and the
 * tree in one order; `WHERE` opens at the goal grouping with the amber
 * remainder row; and no workspace, project or goal heading carries a cache
 * share any more, which is the removal `corpus/valuemaxxing.md` asked for.
 */

const NOW = 1_758_000_000_000;
const W = "/w";
const kitterm = { id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true, knowledge: "docs/goals" };
const notes = { id: "notes", name: "notes", root: `${W}/notes`, registered: true, knowledge: "docs/goals" };
const project = { id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true };

const crew = {
  id: "s-crew",
  name: "spend-bought round 6",
  cwd: `${W}/kitterm/.claude/worktrees/spend-bought`,
  state: "running",
  mergedState: "working",
  marks: 0,
  project,
  labels: { crew: "agent-dashboard", goal: "agent-dashboard", round: "6", task: "the-page-says-what-the-spend-bought" },
  lastOutputAt: NOW,
};
const shell = { ...crew, id: "s-shell", name: "shell", cwd: `${W}/notes`, project: { ...notes }, state: "idle", mergedState: "idle", labels: {} };

const goals = [
  {
    slug: "agent-dashboard", goal: "/sessions is a dashboard", status: "active", round: 6, budget: 3,
    lastRound: 5, lastRecord: "agent-dashboard/rounds/005.md", lastDecision: "done", costUSD: 65.72, inTokens: 80_000_000, cacheReadTokens: 78_000_000,
    tasks: [{ slug: "the-page-says-what-the-spend-bought", state: "pending" }],
    rounds: [
      { number: 1, task: "no-input-on-the-page", started: "2026-09-17", costUSD: 7.73, durationMs: 15 * 60_000, pr: 125, correction: false },
      { number: 2, task: "the-foundation-in-the-stylesheet", started: "2026-09-17", costUSD: 11.28, durationMs: 20 * 60_000, pr: 126, correction: false },
      { number: 3, task: "a-task-is-the-fourth-level", started: "2026-09-18", pr: 127, correction: false },
    ],
  },
];

const tokens = { input: 1_000_000, output: 100_000, cacheCreation: 2_000_000, cacheRead: 60_000_000, requests: 100 };
const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [crew, shell] },
  "/api/projects": { projects: [kitterm, notes] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals },
  "/api/projects/notes/knowledge": { ok: true, project: "notes", goals: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/daily": {
    ok: true, timeZone: "UTC", from: "2026-08-20", to: "2026-09-18", refreshedAt: NOW, recordedSessions: 3, days: [],
    totals: { costUSD: 1000, apportionedUSD: 0, unsplitUSD: 0, tokens, sessions: 3, unbilledSessions: 0, apiMs: 10 * 3_600_000, measuredUSD: 1000 },
    models: [
      { model: "claude-fable-5-1", name: "Fable 5.1", costUSD: 900, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 2 },
      { model: "claude-haiku-4-5-20251001", name: "Haiku 4.5", costUSD: 100, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 1 },
    ],
    projects: [
      { id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true, costUSD: 950, apportionedUSD: 0, tokens, sessions: 2, unbilledSessions: 0 },
      { id: "notes", name: "notes", root: `${W}/notes`, registered: true, costUSD: 50, apportionedUSD: 0, tokens, sessions: 1, unbilledSessions: 0 },
    ],
    roles: [
      { role: "root", costUSD: 600, apportionedUSD: 0, sessions: 2, apiMs: 6 * 3_600_000, measuredUSD: 600, linesAdded: 100 },
      { role: "crew", costUSD: 400, apportionedUSD: 0, sessions: 1, apiMs: 4 * 3_600_000, measuredUSD: 400, linesAdded: 900 },
    ],
    lowCache: [{ sessionId: "x", project: "kitterm", costUSD: 15.84, cacheShare: 0.94 }],
  },
  "/api/yield": {
    ok: true, from: "2026-08-20", to: "2026-09-18",
    projects: [
      { ...project, yield: { checkout: true, remote: true, branch: "origin/main", mergedPullRequests: 5, mergedLines: 1234, releases: 2 } },
      { id: "notes", name: "notes", root: `${W}/notes`, registered: true, yield: { checkout: false, remote: false } },
    ],
    totals: { checkouts: 1, counted: 1, mergedPullRequests: 5, mergedLines: 1234, releases: 2 },
  },
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;
/** The page's width, as `matchMedia("(max-width: 767px)")` reports it. */
let phone = false;

beforeAll(async () => {
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ get matches() { return phone; }, addEventListener(): void {} }));
  await import("./sessions");
  await page.settle();
});

const panels = () => page.root.querySelectorAll(".panel").filter((p) => !p.hidden);
const panelNamed = (name: string) => page.root.querySelectorAll(".panel").find((p) => p.classList.contains(name))!;
const rowsOf = (panel: ReturnType<typeof panelNamed>) =>
  panel.querySelectorAll(".split-row").map((row) => [
    row.querySelector(".split-name")?.textContent,
    row.querySelector(".split-spend")?.textContent,
    row.querySelector(".split-units")?.textContent,
    row.querySelector(".split-rate")?.textContent ?? null,
    row.classList.contains("remainder"),
  ]);

describe("the four panels", () => {
  it("sit between the quota and the tree, in one order, each with its label", () => {
    const order = page.root.children
      .filter((child): child is Exclude<typeof child, string> => typeof child !== "string")
      .map((child) => child.className.split(" ")[0]);
    expect(order.slice(order.indexOf("quota"), order.indexOf("cards") + 1)).toEqual(["quota", "panel", "panel", "panel", "panel", "cards"]);
    expect(panels().map((p) => p.querySelector(".panel-label")?.textContent)).toEqual(["VALUE", "WHERE", "MODELS", "LEAKS"]);
  });

  it("VALUE prints four tiles and the proxies line", () => {
    const value = panelNamed("value");
    // kitterm is the one checkout, $950 of the fleet's $1,000: its unit
    // costs divide its own spend; the hour divides the fleet's.
    expect(value.querySelectorAll(".yield-tile").map((t) => [t.querySelector(".yield-count")?.textContent, t.querySelector(".yield-noun")?.textContent, t.querySelector(".yield-rate")?.textContent])).toEqual([
      ["5", "merged PRs", "$190.00 a PR"],
      ["1,234", "merged lines", "$0.770 a line"],
      ["2", "releases", "$475.00 a release"],
      ["10.0", "model hours", "$100.00 an hour"],
    ]);
    expect(value.querySelector(".panel-note")?.textContent).toBe(
      "A merged line and a merged PR are proxies for value, not value. A unit cost divides the $950.00 spent in 1 repository counted; the hour divides the fleet's.",
    );
  });

  it("WHERE opens at the goal grouping with the unattributed remainder as an amber row", () => {
    const where = panelNamed("where");
    expect(where.querySelectorAll(".panel-toggle").map((b) => [b.textContent, b.getAttribute("aria-checked")])).toEqual([
      ["project", "false"], ["goal", "true"], ["task", "false"], ["role", "false"],
    ]);
    expect(rowsOf(where)).toEqual([
      ["agent-dashboard", "$19.01", "3 PRs", "$6.34 a PR", false],
      ["no round record", "$980.99", "–", "–", true],
    ]);
    const rest = where.querySelectorAll(".remainder")[0];
    expect(rest.querySelectorAll(".mark").map((m) => m.className)).toEqual(["mark attention", "mark bar attention"]);
    expect(rest.querySelector(".split-bar")?.children.map((c) => (typeof c === "string" ? c : c.className))).toEqual(["mark bar attention"]);
    expect(where.querySelector(".panel-note")?.textContent).toBe("98% names no round, so it cannot be valued.");
    // A bar is a mark, never text: the accent and the amber paint it alone.
    const bars = where.querySelectorAll(".split-bar").map((b) => b.getAttribute("aria-hidden"));
    expect(bars).toEqual(["true", "true"]);
  });

  it("MODELS is one bar per model with its spend and sessions, and no cache share", () => {
    const models = panelNamed("models");
    expect(rowsOf(models)).toEqual([
      ["Fable 5.1", "$900.00", "2 sessions", null, false],
      ["Haiku 4.5", "$100.00", "1 session", null, false],
    ]);
    expect(models.textContent).not.toContain("cached");
  });

  it("LEAKS names the unpriced rounds, the corrections and the low-cache sessions, one marked line each", () => {
    const leaks = panelNamed("leaks");
    expect(leaks.querySelectorAll(".leak-line").map((l) => [l.querySelector(".mark")?.className, l.querySelector(".leak-text")?.textContent])).toEqual([
      ["mark attention", "1 of 3 rounds carry no Cost line"],
      ["mark idle", "0 corrections in 3 rounds"],
      ["mark attention", "1 session over $5 under 95% cached, $15.84"],
    ]);
  });

  it("takes no typed input: the selector is a radio group of buttons", () => {
    expect(page.root.querySelectorAll("input")).toHaveLength(0);
    expect(page.root.querySelectorAll("select")).toHaveLength(0);
    expect(panelNamed("where").querySelectorAll("button").every((b) => b.getAttribute("role") === "radio")).toBe(true);
  });
});

describe("on a phone", () => {
  it("folds WHERE and MODELS behind the done goals' fold, one summary line each, and keeps VALUE open", async () => {
    phone = true;
    await page.poll();
    const where = panelNamed("where");
    const models = panelNamed("models");
    const foldOf = (panel: ReturnType<typeof panelNamed>) => panel.querySelectorAll("details").filter((d) => d.classList.contains("panel-fold"));
    expect(foldOf(where)).toHaveLength(1);
    expect(foldOf(models)).toHaveLength(1);
    expect(foldOf(where)[0].querySelector("summary")?.textContent).toBe("where the dollar goes · 98% unattributed");
    expect(foldOf(models)[0].querySelector("summary")?.textContent).toBe("by model · Fable 5.1 $900.00");
    expect(where.querySelectorAll(".panel-label"), "the summary line replaces the label").toHaveLength(0);
    // Closed by default, and the panel inside is the whole panel.
    expect((foldOf(where)[0] as unknown as { open: boolean }).open).toBe(false);
    expect(rowsOf(where)).toHaveLength(2);
    expect(rowsOf(models)).toHaveLength(2);
    // VALUE does not fold: the headline earns its height on a phone.
    expect(foldOf(panelNamed("value"))).toHaveLength(0);
    expect(panelNamed("value").querySelectorAll(".yield-tile")).toHaveLength(4);
    phone = false;
    await page.poll();
    expect(foldOf(panelNamed("where"))).toHaveLength(0);
    expect(panelNamed("where").querySelector(".panel-label")?.textContent).toBe("WHERE");
  });
});

describe("the cache share left every heading", () => {
  it("no workspace, project or goal heading prints a share", () => {
    const headings = [...page.root.querySelectorAll("h2"), ...page.root.querySelectorAll("h3"), ...page.root.querySelectorAll(".goal-line")];
    expect(headings.length).toBeGreaterThan(2);
    for (const h of headings) {
      expect(h.textContent, h.className).not.toMatch(/cached|%/);
    }
    // The workspace heading over the two projects, then each project.
    expect(page.root.querySelectorAll(".cost").map((c) => c.textContent)).toEqual(["$1,000.00", "$950.00", "$50.00"]);
    expect(page.root.querySelectorAll(".goal-cost").map((c) => c.textContent)).toEqual(["$65.72"]);
  });

  it("prints the share in one place only: the LEAKS exception line", () => {
    const everywhere = page.root.textContent.match(/\d+% cached/g) ?? [];
    expect(everywhere).toEqual(["95% cached"]);
  });
});
