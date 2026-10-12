import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { daysAgo, goals, kitterm, mdp, rollup, yieldFor } from "./range-fixture";
import { dayLabel, dayKey, usageRange, type DayRange } from "./sessions-model";

/**
 * The `all` range at the page (`plan.md` capability 6;
 * `corpus/05-legend-and-range.md`, rule 2): the toggle gains a fourth
 * choice, `all`, which every figure the range moves follows
 * (`sessions-range-page.test.ts` pins the same claim for 7d/30d/90d). The
 * daemon here answers the lifetime routes with a 90-day spend record, so
 * `all`'s own narrower request narrows to that record's first day once the
 * page's lifetime read has found it, rather than staying at the routes'
 * 400-day bound.
 */

const NOW = new Date(2026, 8, 19, 12).getTime();
/** The whole lifetime spend record: 90 uniform days, so `baseDayOf` finds
 * its first spend day and its base day as the same one, the earliest day
 * here. */
const LIFETIME_SPEND_DAYS = 90;
const FIRST_SPEND_DAY = daysAgo(NOW, LIFETIME_SPEND_DAYS - 1);

const ZERO_TOKENS = { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 };

function lifetimeUsageDays(): unknown[] {
  const out: unknown[] = [];
  for (let i = LIFETIME_SPEND_DAYS - 1; i >= 0; i -= 1) {
    out.push({
      day: daysAgo(NOW, i), costUSD: 10, measuredUSD: 10, apiMs: 3_600_000,
      apportionedUSD: 0, tokens: ZERO_TOKENS, sessions: 1, unbilledSessions: 0, projects: [],
    });
  }
  return out;
}

function lifetimeYieldDays(): unknown[] {
  const out: unknown[] = [];
  for (let i = LIFETIME_SPEND_DAYS - 1; i >= 0; i -= 1) {
    out.push({ day: daysAgo(NOW, i), mergedPullRequests: 1, mergedLines: 100, releases: 0, projects: [] });
  }
  return out;
}

/** Whole days between two `YYYY-MM-DD` query bounds, to tell the lifetime
 * route's wide request apart from the toggle's own narrower one on the one
 * path, `/api/usage/daily`, they share (`sessions-lifetime-fetch.test.ts`). */
function daySpan(query: URLSearchParams): number {
  const from = new Date(query.get("from") ?? "");
  const to = new Date(query.get("to") ?? "");
  return Math.round((to.getTime() - from.getTime()) / 86_400_000);
}

const rangeOf = (query: URLSearchParams): DayRange => ({ from: query.get("from") ?? "", to: query.get("to") ?? "" });

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [kitterm, mdp].map((p) => ({ ...p, knowledge: "docs/goals" })) },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: goals(NOW).filter((g) => g.project.id === "kitterm").map((g) => g.summary) },
  "/api/projects/mdp/knowledge": { ok: true, project: "mdp", goals: goals(NOW).filter((g) => g.project.id === "mdp").map((g) => g.summary) },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  // The toggle's own narrower request (7d/30d/90d, or `all` once the first
  // spend day is known) answers from the session fixture `range-fixture.ts`
  // already uses for 7d/30d/90d; only the lifetime read's wide (>100-day)
  // request answers from the 90-day spend record above.
  "/api/usage/daily": (query: URLSearchParams) =>
    (daySpan(query) > 100
      ? { ok: true, timeZone: "UTC", from: query.get("from"), to: query.get("to"), refreshedAt: NOW, recordedSessions: LIFETIME_SPEND_DAYS, days: lifetimeUsageDays(), totals: { costUSD: 0, apportionedUSD: 0, tokens: ZERO_TOKENS, sessions: 0, unbilledSessions: 0 }, projects: [] }
      : rollup(rangeOf(query), NOW)),
  "/api/yield": (query: URLSearchParams) => yieldFor(rangeOf(query), NOW),
  "/api/yield/daily": (query: URLSearchParams) => ({ ok: true, from: query.get("from"), to: query.get("to"), days: lifetimeYieldDays() }),
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;

beforeAll(async () => {
  vi.spyOn(Date, "now").mockReturnValue(NOW);
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  await import("./sessions");
  await page.settle();
});

const panelNamed = (name: string) => page.root.querySelectorAll(".panel").find((p) => p.classList.contains(name))!;
const toggle = (label: string): FakeElement => page.root.querySelectorAll(".usage-toggle").find((b) => b.textContent === label)!;

function figures() {
  const rowsOf = (panel: FakeElement) => panel.querySelectorAll(".split-row").map((row) => [row.querySelector(".split-name")?.textContent, row.querySelector(".split-spend")?.textContent]);
  return {
    band: page.root.querySelectorAll(".band-cell").filter((c) => c.classList.contains("spend")).map((c) => `${c.querySelector(".band-value")?.textContent} ${c.querySelector(".band-noun")?.textContent}`),
    value: panelNamed("value").querySelectorAll(".yield-tile").map((cell) => cell.querySelector(".yield-count")?.textContent),
    valueNote: panelNamed("value").querySelector(".note-long")?.textContent,
    where: rowsOf(panelNamed("where")),
    models: panelNamed("models").querySelectorAll(".split-row").map((row) => row.querySelector(".split-name")?.textContent),
    leaks: panelNamed("leaks").querySelectorAll(".leak-text").map((l) => l.textContent),
  };
}

describe("the toggle gains `all`", () => {
  it("prints a fourth, unchecked radio beside 7d/30d/90d", () => {
    const spans = panelNamed("usage").querySelectorAll(".usage-toggle").map((b) => [b.textContent, b.getAttribute("aria-checked")]);
    expect(spans).toEqual([["cost", "true"], ["tokens", "false"], ["7d", "false"], ["30d", "true"], ["90d", "false"], ["all", "false"]]);
  });
});

describe("choosing `all`", () => {
  it("asks the toggle's own routes for the record's first spend day, found by the lifetime read already in hand, not the 400-day bound", async () => {
    const before = page.requests.length;
    toggle("all").click();
    await page.settle();
    const asked = page.requests.slice(before);
    const usageAsk = asked.find((u) => u.startsWith("/api/usage/daily?") && !u.includes(`from=${daysAgo(NOW, 399)}`));
    expect(usageAsk).toBe(`/api/usage/daily?from=${FIRST_SPEND_DAY}&to=${dayKey(NOW)}`);
    const yieldAsk = asked.find((u) => u.startsWith("/api/yield?"));
    expect(yieldAsk).toBe(`/api/yield?from=${FIRST_SPEND_DAY}&to=${dayKey(NOW)}`);
    // No new request to the lifetime-only route: the toggle recomputes
    // TOTALS/UNIT COSTS from the one lifetime read already in memory.
    expect(asked.some((u) => u.startsWith("/api/yield/daily"))).toBe(false);
    expect(toggle("all").getAttribute("aria-checked")).toBe("true");
  });

  it("matches what `usageRange(\"all\", …)` itself computes once the first spend day is known", () => {
    expect(usageRange("all", NOW, FIRST_SPEND_DAY)).toEqual({ from: FIRST_SPEND_DAY, to: dayKey(NOW) });
  });

  it("moves every figure the range moves, to the same reading a direct `rollup`/`yieldFor` over the first-spend-day range gives", () => {
    const range = { from: FIRST_SPEND_DAY, to: dayKey(NOW) };
    const r = rollup(range, NOW);
    const y = yieldFor(range, NOW);
    expect(figures()).toEqual({
      band: [`$${Math.floor(r.totals!.costUSD)} all`],
      value: [String(y.totals.mergedPullRequests), String(y.totals.mergedLines).replace(/\B(?=(\d{3})+(?!\d))/g, ","), String(y.totals.releases), "8.5"],
      valueNote: `2 repositories, since ${dayLabel(FIRST_SPEND_DAY)}. Proxies for value, not value.`,
      where: [["alpha", "$30.00"], ["gamma", "$20.00"], ["beta", "$5.00"], ["no round record", "$140.00"]],
      models: ["Fable 5.1", "Opus 5 · 1M", "Haiku 4.5"],
      leaks: ["2 of 7 rounds carry no Cost line", "1 correction in 7 rounds · 2 sessions under 95% cached, $130.00"],
    });
  });

  it("persists the choice in `localStorage`, like the day-counted spans", () => {
    const stored = JSON.parse(localStorage.getItem("kitterm.sessions.usage") ?? "{}") as { mode?: string; span?: unknown };
    expect(stored).toEqual({ mode: "cost", span: "all" });
  });

  it("TOTALS and UNIT COSTS read their lifetime reading unclamped: since the first spend day, which is also the base day here, and print no early-spend note", () => {
    const blocks = panelNamed("value").querySelectorAll(".lifetime-chart-block");
    const totalsBlock = blocks.find((b) => b.classList.contains("totals"))!;
    const unitCostsBlock = blocks.find((b) => b.classList.contains("unit-costs"))!;
    expect(totalsBlock.querySelector(".lifetime-title")?.textContent).toContain(`growth since ${dayLabel(FIRST_SPEND_DAY)}, log scale`);
    expect(unitCostsBlock.querySelector(".lifetime-title")?.textContent).toContain(`dollars, log scale, since ${dayLabel(FIRST_SPEND_DAY)}`);
    expect(panelNamed("value").querySelectorAll(".lifetime-note")).toEqual([]);
  });
});

describe("switching back to 30d", () => {
  it("asks the day-counted range again and the figures differ from `all`'s", async () => {
    const before = page.requests.length;
    toggle("30d").click();
    await page.settle();
    const asked = page.requests.slice(before);
    const { from, to } = usageRange(30, NOW);
    expect(asked.some((u) => u === `/api/usage/daily?from=${from}&to=${to}`)).toBe(true);
    expect(toggle("30d").getAttribute("aria-checked")).toBe("true");
    expect(toggle("all").getAttribute("aria-checked")).toBe("false");
    const stored = JSON.parse(localStorage.getItem("kitterm.sessions.usage") ?? "{}") as { span?: unknown };
    expect(stored.span).toBe(30);
  });
});
