import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";

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
    // Five models whose tail sums past the leader (round 10): the top three
    // by cost, then Others, last whatever its sum.
    models: [
      { model: "claude-fable-5-1", name: "Fable 5.1", costUSD: 100, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 2 },
      { model: "claude-opus-5[1m]", name: "Opus 5 · 1M", costUSD: 90, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 1 },
      { model: "claude-fable-5", name: "Fable 5", costUSD: 80, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 1 },
      { model: "claude-opus-5", name: "Opus 5", costUSD: 70, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 1 },
      { model: "claude-haiku-4-5-20251001", name: "Haiku 4.5", costUSD: 60, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 1 },
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
/** A WHERE row as the frame draws it: name | spend | count | PRs | unit. */
const rowsOf = (panel: ReturnType<typeof panelNamed>) =>
  panel.querySelectorAll(".split-row").map((row) => [
    row.querySelector(".split-name")?.textContent,
    row.querySelector(".split-spend")?.textContent,
    row.querySelector(".split-count")?.textContent,
    row.querySelector(".split-units")?.textContent,
    row.querySelector(".split-rate")?.textContent,
    row.classList.contains("remainder"),
  ]);

describe("the panels", () => {
  it("sit between the band and the tree, in one order with one divider, each with its label in the gutter", () => {
    // Round 11 (the approved frames): USAGE, QUOTA, MODELS, one hairline
    // divider, VALUE, WHERE, LEAKS; the header and the tree follow, then
    // the folds. No notice line: the page holds no action that could
    // fail. Chartered: round 10's order (VALUE, WHERE, MODELS, LEAKS) and
    // its notice.
    const order = page.root.children
      .filter((child): child is Exclude<typeof child, string> => typeof child !== "string")
      .map((child) => `${child.tagName.toLowerCase()}.${child.className.split(" ")[0]}`);
    expect(order.slice(order.indexOf("section.band"))).toEqual([
      "section.band", "p.restart", "section.panel", "section.panel", "section.panel", "hr.panel-divider", "section.panel", "section.panel", "section.panel", "div.tree-head", "div.tree", "div.folds",
    ]);
    expect(panels().map((p) => p.querySelector(".panel-label")?.textContent)).toEqual(["USAGE", "QUOTA", "MODELS", "VALUE", "WHERE", "LEAKS"]);
    expect(panels().map((p) => p.querySelector(".panel-label")?.tagName)).toEqual(["H2", "H2", "H2", "H2", "H2", "H2"]);
  });

  it("USAGE prints the amount, the tokens and the model hours on one row with the toggles, and no title, qualifier or age line", () => {
    const usage = panelNamed("usage");
    const head = usage.querySelector(".usage-head")!;
    expect(head.querySelector(".usage-amount")?.textContent).toBe("$1,000.00");
    expect(head.querySelector(".usage-amount")?.title).toBe("if billed at full API rate");
    expect(head.querySelectorAll(".usage-fact").map((f) => f.textContent)).toEqual(["63.10M tokens", "10.0 h model time"]);
    expect(head.querySelector(".usage-span")?.textContent).toBe("30 days");
    expect(head.querySelectorAll(".usage-toggle").map((b) => [b.textContent, b.getAttribute("aria-checked")])).toEqual([
      ["cost", "true"], ["tokens", "false"], ["7d", "false"], ["30d", "true"], ["90d", "false"],
    ]);
    expect(usage.querySelectorAll(".usage-title")).toEqual([]);
    expect(usage.querySelectorAll(".usage-qualifier")).toEqual([]);
    expect(usage.querySelectorAll(".usage-age")).toEqual([]);
    expect(usage.querySelectorAll(".usage-note"), "nothing apportioned: no note").toEqual([]);
    expect(usage.querySelector(".panel-label")?.title).toMatch(/^rollup refreshed /);
  });

  it("QUOTA holds the no-reading sentence in its content cell", () => {
    const quota = panelNamed("quota");
    expect(quota.querySelector(".quota-note")?.textContent).toBe(
      "No quota reading yet. Run kitterm statusline install, then open a Claude Code session; its statusline posts one.",
    );
    expect(quota.querySelectorAll(".quota-bar")).toEqual([]);
  });

  it("QUOTA draws one bar per window as a track with its fill a mark, accent under 80% and caution from it, the percentage too", async () => {
    // The Components frame, "Quota bar": `Session (5h) [====      ] 19%
    // resets 3h 16m` in the accent, `Weekly [========  ] 87% resets 1d
    // 12h · read just now` in the caution, the label and the reset never
    // coloured. Chartered: the ASCII `[####····]` cells of rounds 4–10.
    const now = Math.floor(Date.now() / 1000);
    routes["/api/usage/limits"] = {
      ok: true, hasReading: true, receivedAt: Date.now() - 20_000, ageSeconds: 20, stale: false,
      rateLimits: { five_hour: { used_percentage: 19, resets_at: now + 3 * 3600 + 16 * 60 + 30 }, seven_day: { used_percentage: 87, resets_at: now + 36 * 3600 + 30 } },
    };
    await page.poll();
    const quota = panelNamed("quota");
    const bars = quota.querySelectorAll(".quota-bar");
    expect(bars.map((b) => b.children.filter((c): c is FakeElement => typeof c !== "string").map((c) => c.className))).toEqual([
      ["quota-label", "quota-track", "quota-percent", "quota-reset"],
      ["quota-label", "quota-track", "quota-percent", "quota-reset", "quota-age"],
    ]);
    expect(bars.map((b) => [b.querySelector(".quota-label")?.textContent, b.querySelector(".quota-percent")?.textContent, b.querySelector(".quota-reset")?.textContent])).toEqual([
      ["Session (5h)", "19%", "resets 3h 16m"], ["Weekly", "87%", "resets 1d 12h"],
    ]);
    expect(bars[1].querySelector(".quota-age")?.textContent).toBe("· read just now");
    // The fill: a bar mark inside the track, sized to the share.
    expect(bars.map((b) => b.querySelector(".quota-track")?.children.map((c) => (typeof c === "string" ? c : `${c.className} ${(c.style as { width?: string }).width}`)))).toEqual([
      ["mark bar quota-fill 19%"], ["mark bar quota-fill caution 87%"],
    ]);
    expect(bars.map((b) => b.querySelector(".quota-track")?.getAttribute("aria-hidden"))).toEqual(["true", "true"]);
    // The percentage is a run of caution text at 80% and over, plain under.
    expect(bars.map((b) => b.querySelector(".quota-percent")?.querySelectorAll(".mark").map((m) => m.className))).toEqual([[], ["mark caution wide"]]);
    expect(bars.map((b) => b.querySelector(".quota-label")?.querySelectorAll(".mark"))).toEqual([[], []]);
    expect(bars.map((b) => b.querySelector(".quota-reset")?.querySelectorAll(".mark"))).toEqual([[], []]);
    expect(quota.textContent).not.toContain("#");
    routes["/api/usage/limits"] = { ok: true, hasReading: false };
    await page.poll();
  });

  it("VALUE prints four tiles behind an accent rule, their nouns in two forms, and one note naming the scope and the span", () => {
    const value = panelNamed("value");
    // kitterm is the one checkout, $950 of the fleet's $1,000: its unit
    // costs divide its own spend; the hour divides the fleet's.
    expect(value.querySelectorAll(".yield-tile").map((t) => [
      t.querySelector(".yield-count")?.textContent, t.querySelector(".yield-noun")?.textContent, t.querySelector(".yield-noun-short")?.textContent, t.querySelector(".yield-rate")?.textContent,
    ])).toEqual([
      ["5", "merged pull requests", "merged PRs", "$190.00 each"],
      ["1,234", "merged lines added", "merged lines", "$0.770 each"],
      ["2", "releases", "releases", "$475.00 each"],
      ["10.0", "hours of model time", "model hours", "$100 an hour"],
    ]);
    expect(value.querySelectorAll(".yield-tile").map((t) => t.querySelector(".mark")?.className)).toEqual(Array(4).fill("mark bar rule"));
    expect(value.querySelector(".note-long")?.textContent).toBe("kitterm, 30 days. Proxies for value, not value.");
    expect(value.querySelector(".note-short")?.textContent).toBe("kitterm, 30 days");
    expect(value.querySelectorAll("details"), "VALUE folds nowhere").toEqual([]);
  });

  it("WHERE opens at the goal grouping with the counted checkouts at the selector's right and the remainder in the amber", () => {
    const where = panelNamed("where");
    expect(where.querySelectorAll(".panel-toggle").map((b) => [b.textContent, b.getAttribute("aria-checked")])).toEqual([
      ["project", "false"], ["goal", "true"], ["task", "false"], ["role", "false"],
    ]);
    expect(where.querySelector(".panel-summary")?.textContent).toBe("$950.00 in kitterm · 5 merged PRs · 1,234 lines · 2 releases");
    expect(rowsOf(where)).toEqual([
      ["agent-dashboard", "$19.01", "3 tasks", "3 PRs", "–", false],
      ["no round record", "$980.99", "98%", "–", "–", true],
    ]);
    const rest = where.querySelectorAll(".remainder")[0];
    // No `?` mark: the name, the bar and the spend wear the amber themselves.
    expect(rest.querySelectorAll(".mark").map((m) => m.className)).toEqual(["mark attention wide", "mark bar attention", "mark attention wide"]);
    expect(rest.querySelector(".split-bar")?.children.map((c) => (typeof c === "string" ? c : c.className))).toEqual(["mark bar attention"]);
    expect(where.querySelector(".note-long")?.textContent).toBe("98% names no round, so it cannot be valued");
    // A bar is a mark, never text: the accent and the amber paint it alone.
    const bars = where.querySelectorAll(".split-bar").map((b) => b.getAttribute("aria-hidden"));
    expect(bars).toEqual(["true", "true"]);
  });

  it("MODELS is one bar per model with its spend to the cent, in whole dollars for a phone, and its sessions, and no cache share", () => {
    const models = panelNamed("models");
    expect(models.querySelectorAll(".split-row").map((row) => [
      row.querySelector(".split-name")?.textContent, row.querySelector(".split-spend")?.textContent, row.querySelector(".split-short")?.textContent, row.querySelector(".split-units")?.textContent,
    ])).toEqual([
      ["Fable 5.1", "$100.00", "$100", "2 sessions"],
      ["Opus 5 · 1M", "$90.00", "$90", "1 session"],
      ["Fable 5", "$80.00", "$80", "1 session"],
      ["Others", "$130.00", "$130", "2 sessions"],
    ]);
    // Others sums past the leader and is still the last row.
    expect(models.querySelectorAll(".split-row").map((r) => r.getAttribute("data-key"))).toEqual(["claude-fable-5-1", "claude-opus-5[1m]", "claude-fable-5", "more"]);
    expect(models.textContent).not.toContain("cached");
    expect(models.querySelectorAll("details"), "MODELS folds nowhere").toEqual([]);
  });

  it("LEAKS is two lines: the unpriced rounds, then the corrections and the low-cache sessions joined", () => {
    const leaks = panelNamed("leaks");
    expect(leaks.querySelectorAll(".leak-line").map((l) => [l.querySelector(".mark")?.className, l.querySelector(".leak-text")?.textContent])).toEqual([
      ["mark attention", "1 of 3 rounds carry no Cost line"],
      ["mark pending", "0 corrections in 3 rounds · 1 session under 95% cached, $15.84"],
    ]);
  });

  it("takes no typed input: the selector is a radio group of buttons", () => {
    expect(page.root.querySelectorAll("input")).toHaveLength(0);
    expect(page.root.querySelectorAll("select")).toHaveLength(0);
    expect(panelNamed("where").querySelectorAll("button").every((b) => b.getAttribute("role") === "radio")).toBe(true);
  });
});

describe("MODELS keeps Others last", () => {
  it("puts the summed row after the top three by cost at both widths, whatever its sum", async () => {
    // Round 10, the human's word: top three by cost, then the others as
    // one row more. The fixture's tail, $130, sums past its leader, $100.
    const names = () => panelNamed("models").querySelectorAll(".split-name").map((n) => n.textContent);
    for (const width of [false, true]) {
      phone = width;
      await page.poll();
      expect(names(), width ? "390 px" : "1200 px").toEqual(["Fable 5.1", "Opus 5 · 1M", "Fable 5", "Others"]);
    }
    phone = false;
    await page.poll();
  });
});

describe("on a phone", () => {
  it("paints the same panels: the sheet hides WHERE and LEAKS, and nothing folds (round 10)", async () => {
    // Chartered in round 10: the frame `Dashboard 390` draws VALUE and
    // MODELS open and WHERE and LEAKS absent, so the DOM is the same at
    // both widths and the stylesheet decides what shows.
    phone = true;
    await page.poll();
    expect(page.root.querySelectorAll(".panel-fold")).toEqual([]);
    // Round 11: the same order at both widths, the divider between MODELS
    // and VALUE (chartered: round 10's order).
    expect(panels().map((p) => p.querySelector(".panel-label")?.textContent)).toEqual(["USAGE", "QUOTA", "MODELS", "VALUE", "WHERE", "LEAKS"]);
    const order = page.root.children.filter((c): c is FakeElement => typeof c !== "string").map((c) => c.className.split(" ")[0]);
    expect(order.slice(order.indexOf("panel"), order.indexOf("tree-head"))).toEqual(["panel", "panel", "panel", "panel-divider", "panel", "panel", "panel"]);
    expect(panelNamed("value").querySelectorAll(".yield-tile")).toHaveLength(4);
    expect(panelNamed("models").querySelectorAll(".split-short").map((s) => s.textContent)).toEqual(["$100", "$90", "$80", "$130"]);
    phone = false;
    await page.poll();
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
    // The workspace heading over the two projects, then kitterm, its goal
    // (round 10: a goal's cost is the same `cost` cell as a heading's),
    // then notes.
    expect(page.root.querySelectorAll(".cost").map((c) => c.textContent)).toEqual(["$1,000.00", "$950.00", "$65.72", "$50.00"]);
    expect(page.root.querySelector(".goal-line")?.querySelector(".cost")?.textContent).toBe("$65.72");
  });

  it("prints the share in one place only: the LEAKS exception line", () => {
    const everywhere = page.root.textContent.match(/\d+% cached/g) ?? [];
    expect(everywhere).toEqual(["95% cached"]);
  });
});
