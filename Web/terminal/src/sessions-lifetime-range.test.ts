import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { LIFETIME_NOTE } from "./sessions-value";

/**
 * TOTALS and UNIT COSTS follow the `USAGE`/`VALUE` 7d/30d/90d toggle
 * (`value-lifetime`, capability 5; `corpus/05-legend-and-range.md`): a
 * toggle click recomputes both charts from the one lifetime read already
 * in memory, with no new request, and the note on missing early spend
 * shows only once the chosen range reaches before the base day.
 * `sessions-lifetime-page.test.ts` covers the legend's own DOM and the
 * chart geometry on a small fixture; this file pins the corpus's own
 * numbers against the real 61-day series the human read on 2026-10-09
 * (`/api/usage/daily` and `/api/yield/daily` on the live daemon that day),
 * the same fixture `value-lifetime.test.ts` reconstructs.
 */

const NOW = new Date(2026, 9, 9, 12, 0, 0).getTime();

const kitterm = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, knowledge: "docs/goals" };

const usageDays = [
  { day: "2026-08-10", costUSD: 3.0528, measuredUSD: 3.0528, apiMs: 72000 },
  { day: "2026-08-11", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-12", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-13", costUSD: 14.74, measuredUSD: 14.74, apiMs: 504000 },
  { day: "2026-08-14", costUSD: 6.56, measuredUSD: 6.56, apiMs: 216000 },
  { day: "2026-08-15", costUSD: 10.29, measuredUSD: 10.29, apiMs: 360000 },
  { day: "2026-08-16", costUSD: 8.09, measuredUSD: 8.09, apiMs: 288000 },
  { day: "2026-08-17", costUSD: 3.9, measuredUSD: 3.9, apiMs: 144000 },
  { day: "2026-08-18", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-19", costUSD: 6.41, measuredUSD: 6.41, apiMs: 216000 },
  { day: "2026-08-20", costUSD: 6.63, measuredUSD: 6.63, apiMs: 216000 },
  { day: "2026-08-21", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-22", costUSD: 16.67, measuredUSD: 16.67, apiMs: 612000 },
  { day: "2026-08-23", costUSD: 0.09, measuredUSD: 0.09, apiMs: 0 },
  { day: "2026-08-24", costUSD: 4.08, measuredUSD: 4.08, apiMs: 180000 },
  { day: "2026-08-25", costUSD: 67.61, measuredUSD: 67.61, apiMs: 2268000 },
  { day: "2026-08-26", costUSD: 18.41, measuredUSD: 18.41, apiMs: 504000 },
  { day: "2026-08-27", costUSD: 127.97, measuredUSD: 127.97, apiMs: 4068000 },
  { day: "2026-08-28", costUSD: 0.46, measuredUSD: 0.46, apiMs: 36000 },
  { day: "2026-08-29", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-30", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-31", costUSD: 1.08, measuredUSD: 1.08, apiMs: 36000 },
  { day: "2026-09-01", costUSD: 7.16, measuredUSD: 7.16, apiMs: 504000 },
  { day: "2026-09-02", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-09-03", costUSD: 427.76, measuredUSD: 427.76, apiMs: 23220000 },
  { day: "2026-09-04", costUSD: 419.29, measuredUSD: 419.29, apiMs: 22356000 },
  { day: "2026-09-05", costUSD: 31.41, measuredUSD: 31.41, apiMs: 1944000 },
  { day: "2026-09-06", costUSD: 100.41, measuredUSD: 100.41, apiMs: 7740000 },
  { day: "2026-09-07", costUSD: 176.95, measuredUSD: 176.95, apiMs: 10548000 },
  { day: "2026-09-08", costUSD: 186.96, measuredUSD: 186.96, apiMs: 11592000 },
  { day: "2026-09-09", costUSD: 231.77, measuredUSD: 231.77, apiMs: 13428000 },
  { day: "2026-09-10", costUSD: 319.63, measuredUSD: 319.63, apiMs: 17784000 },
  { day: "2026-09-11", costUSD: 355.24, measuredUSD: 355.24, apiMs: 19440000 },
  { day: "2026-09-12", costUSD: 14.34, measuredUSD: 14.34, apiMs: 684000 },
  { day: "2026-09-13", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-09-14", costUSD: 30.28, measuredUSD: 30.28, apiMs: 1476000 },
  { day: "2026-09-15", costUSD: 227.04, measuredUSD: 227.04, apiMs: 12240000 },
  { day: "2026-09-16", costUSD: 309.55, measuredUSD: 309.55, apiMs: 21636000 },
  { day: "2026-09-17", costUSD: 291.61, measuredUSD: 291.61, apiMs: 16236000 },
  { day: "2026-09-18", costUSD: 533.27, measuredUSD: 533.27, apiMs: 28152000 },
  { day: "2026-09-19", costUSD: 70.39, measuredUSD: 70.39, apiMs: 3744000 },
  { day: "2026-09-20", costUSD: 164.44, measuredUSD: 164.44, apiMs: 11160000 },
  { day: "2026-09-21", costUSD: 207.56, measuredUSD: 207.56, apiMs: 15084000 },
  { day: "2026-09-22", costUSD: 18.17, measuredUSD: 18.17, apiMs: 1620000 },
  { day: "2026-09-23", costUSD: 113.58, measuredUSD: 113.58, apiMs: 8208000 },
  { day: "2026-09-24", costUSD: 59.89, measuredUSD: 59.89, apiMs: 4572000 },
  { day: "2026-09-25", costUSD: 98.95, measuredUSD: 98.95, apiMs: 8748000 },
  { day: "2026-09-26", costUSD: 37.05, measuredUSD: 37.05, apiMs: 3528000 },
  { day: "2026-09-27", costUSD: 2.53, measuredUSD: 2.53, apiMs: 180000 },
  { day: "2026-09-28", costUSD: 265.44, measuredUSD: 265.44, apiMs: 25956000 },
  { day: "2026-09-29", costUSD: 48.94, measuredUSD: 48.94, apiMs: 4824000 },
  { day: "2026-09-30", costUSD: 69.16, measuredUSD: 69.16, apiMs: 6696000 },
  { day: "2026-10-01", costUSD: 78.4, measuredUSD: 78.4, apiMs: 7524000 },
  { day: "2026-10-02", costUSD: 473.83, measuredUSD: 473.83, apiMs: 29052000 },
  { day: "2026-10-03", costUSD: 49.75, measuredUSD: 49.75, apiMs: 3204000 },
  { day: "2026-10-04", costUSD: 123.42, measuredUSD: 123.42, apiMs: 7956000 },
  { day: "2026-10-05", costUSD: 140.11, measuredUSD: 140.11, apiMs: 9252000 },
  { day: "2026-10-06", costUSD: 137.61, measuredUSD: 137.61, apiMs: 13500000 },
  { day: "2026-10-07", costUSD: 135.67, measuredUSD: 135.67, apiMs: 16524000 },
  { day: "2026-10-08", costUSD: 188.42, measuredUSD: 188.42, apiMs: 22248000 },
  { day: "2026-10-09", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
].map((d) => ({ ...d, apportionedUSD: 0, tokens: { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 }, sessions: 1, unbilledSessions: 0, projects: [] }));

const yieldDays = [
  { day: "2026-08-10", mergedPullRequests: 3, mergedLines: 530, releases: 2 },
  { day: "2026-08-11", mergedPullRequests: 3, mergedLines: 656, releases: 3 },
  { day: "2026-08-12", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-13", mergedPullRequests: 2, mergedLines: 1188, releases: 1 },
  { day: "2026-08-14", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-15", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-16", mergedPullRequests: 1, mergedLines: 1956, releases: 1 },
  { day: "2026-08-17", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-18", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-19", mergedPullRequests: 1, mergedLines: 317, releases: 1 },
  { day: "2026-08-20", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-21", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-22", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-23", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-24", mergedPullRequests: 1, mergedLines: 581, releases: 1 },
  { day: "2026-08-25", mergedPullRequests: 4, mergedLines: 551, releases: 2 },
  { day: "2026-08-26", mergedPullRequests: 3, mergedLines: 2524, releases: 1 },
  { day: "2026-08-27", mergedPullRequests: 1, mergedLines: 393, releases: 1 },
  { day: "2026-08-28", mergedPullRequests: 3, mergedLines: 38, releases: 1 },
  { day: "2026-08-29", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-30", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-31", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-09-01", mergedPullRequests: 1, mergedLines: 2815, releases: 0 },
  { day: "2026-09-02", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-09-03", mergedPullRequests: 4, mergedLines: 5094, releases: 3 },
  { day: "2026-09-04", mergedPullRequests: 7, mergedLines: 4475, releases: 2 },
  { day: "2026-09-05", mergedPullRequests: 3, mergedLines: 3040, releases: 1 },
  { day: "2026-09-06", mergedPullRequests: 5, mergedLines: 6572, releases: 2 },
  { day: "2026-09-07", mergedPullRequests: 6, mergedLines: 3272, releases: 5 },
  { day: "2026-09-08", mergedPullRequests: 6, mergedLines: 7243, releases: 1 },
  { day: "2026-09-09", mergedPullRequests: 5, mergedLines: 5461, releases: 1 },
  { day: "2026-09-10", mergedPullRequests: 9, mergedLines: 3105, releases: 3 },
  { day: "2026-09-11", mergedPullRequests: 15, mergedLines: 9074, releases: 1 },
  { day: "2026-09-12", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-09-13", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-09-14", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-09-15", mergedPullRequests: 8, mergedLines: 3998, releases: 0 },
  { day: "2026-09-16", mergedPullRequests: 16, mergedLines: 12236, releases: 2 },
  { day: "2026-09-17", mergedPullRequests: 6, mergedLines: 3210, releases: 0 },
  { day: "2026-09-18", mergedPullRequests: 10, mergedLines: 9468, releases: 0 },
  { day: "2026-09-19", mergedPullRequests: 1, mergedLines: 1394, releases: 0 },
  { day: "2026-09-20", mergedPullRequests: 5, mergedLines: 15407, releases: 1 },
  { day: "2026-09-21", mergedPullRequests: 8, mergedLines: 21004, releases: 3 },
  { day: "2026-09-22", mergedPullRequests: 4, mergedLines: 3117, releases: 0 },
  { day: "2026-09-23", mergedPullRequests: 11, mergedLines: 2725, releases: 2 },
  { day: "2026-09-24", mergedPullRequests: 7, mergedLines: 497, releases: 0 },
  { day: "2026-09-25", mergedPullRequests: 11, mergedLines: 17638, releases: 1 },
  { day: "2026-09-26", mergedPullRequests: 1, mergedLines: 2301, releases: 0 },
  { day: "2026-09-27", mergedPullRequests: 1, mergedLines: 4234, releases: 0 },
  { day: "2026-09-28", mergedPullRequests: 15, mergedLines: 17091, releases: 2 },
  { day: "2026-09-29", mergedPullRequests: 3, mergedLines: 1634, releases: 1 },
  { day: "2026-09-30", mergedPullRequests: 6, mergedLines: 4213, releases: 3 },
  { day: "2026-10-01", mergedPullRequests: 10, mergedLines: 4483, releases: 5 },
  { day: "2026-10-02", mergedPullRequests: 8, mergedLines: 90172, releases: 5 },
  { day: "2026-10-03", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-10-04", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-10-05", mergedPullRequests: 3, mergedLines: 29532, releases: 3 },
  { day: "2026-10-06", mergedPullRequests: 7, mergedLines: 19283, releases: 6 },
  { day: "2026-10-07", mergedPullRequests: 11, mergedLines: 63294, releases: 1 },
  { day: "2026-10-08", mergedPullRequests: 7, mergedLines: 28633, releases: 2 },
  { day: "2026-10-09", mergedPullRequests: 2, mergedLines: 21597, releases: 0 },
].map((d) => ({ ...d, projects: [] }));

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [kitterm] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  // Both the lifetime (400d) and the toggle's own (7d/30d/90d) request hit
  // this one path; the real daemon filters by range, but nothing here reads
  // the narrow answer's `days`, so the full series answers every query.
  "/api/usage/daily": (query: URLSearchParams) => ({
    ok: true, timeZone: "UTC", from: query.get("from"), to: query.get("to"), refreshedAt: NOW, recordedSessions: usageDays.length,
    days: usageDays, totals: { costUSD: 0, apportionedUSD: 0, tokens: { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 }, sessions: 0, unbilledSessions: 0 },
    projects: [],
  }),
  "/api/yield": { ok: true, from: "2026-09-10", to: "2026-10-09", projects: [], totals: { checkouts: 0, counted: 0, mergedPullRequests: 0, mergedLines: 0, releases: 0 } },
  "/api/yield/daily": (query: URLSearchParams) => ({ ok: true, from: query.get("from"), to: query.get("to"), days: yieldDays }),
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

const valuePanel = () => page.root.querySelectorAll(".panel").find((p) => p.classList.contains("value"))!;
const blocks = () => valuePanel().querySelectorAll(".lifetime-chart-block");
const totalsBlock = () => blocks().find((b) => b.classList.contains("totals"))!;
const unitCostsBlock = () => blocks().find((b) => b.classList.contains("unit-costs"))!;
const lastTooltipRow = (block: FakeElement, label: string): string | undefined => {
  block.querySelector(".lifetime-hit")!.listeners.get("focus")?.[0]({});
  const line = block
    .querySelector(".lifetime-tooltip")!
    .querySelectorAll(".lifetime-tooltip-line")
    .find((l) => l.querySelector(".lifetime-tooltip-label")?.textContent === label);
  return line?.querySelector(".lifetime-tooltip-value")?.textContent;
};

async function chooseSpan(span: "7d" | "30d" | "90d"): Promise<number> {
  const before = page.requests.length;
  const toggle = page.root.querySelectorAll(".usage-toggle").find((b) => b.textContent === span)!;
  toggle.click();
  await page.settle();
  return page.requests.length - before;
}

describe("7d, from 3 Oct", () => {
  it("asks no lifetime route again, only the toggle's own narrower /api/usage/daily and /api/yield", async () => {
    const added = await chooseSpan("7d");
    const asked = page.requests.slice(-added);
    expect(asked.every((u) => u.startsWith("/api/usage/daily") || u.startsWith("/api/yield"))).toBe(true);
    expect(asked.some((u) => u.startsWith("/api/yield/daily"))).toBe(false);
  });

  it("TOTALS: growth since 3 Oct, ×1.13 spend, ×1.14 PRs, ×1.59 lines, ×1.21 releases", () => {
    expect(totalsBlock().querySelector(".lifetime-title")?.textContent).toContain("growth since 3 Oct, log scale");
    expect(lastTooltipRow(totalsBlock(), "spend")).toBe("$6.4k");
    expect(lastTooltipRow(totalsBlock(), "PRs")).toBe("244");
  });

  it("UNIT COSTS: $25.83/PR, $4.77/1k lines, $64.58/release, $38.38/hour, since 3 Oct", () => {
    expect(unitCostsBlock().querySelector(".lifetime-title")?.textContent).toContain("dollars, log scale, since 3 Oct");
    expect(lastTooltipRow(unitCostsBlock(), "$/PR")).toBe("$25.83");
    expect(lastTooltipRow(unitCostsBlock(), "$/1k lines")).toBe("$4.77");
    expect(lastTooltipRow(unitCostsBlock(), "$/release")).toBe("$64.58");
    expect(lastTooltipRow(unitCostsBlock(), "$/hour")).toBe("$38.38");
  });

  it("prints no note: the range never reaches before the base day", () => {
    expect(valuePanel().querySelector(".lifetime-note")).toBeNull();
  });
});

describe("30d, from 10 Sep", () => {
  it("asks no lifetime route again on the toggle click", async () => {
    const added = await chooseSpan("30d");
    const asked = page.requests.slice(-added);
    expect(asked.some((u) => u.startsWith("/api/yield/daily"))).toBe(false);
  });

  it("TOTALS: growth since 10 Sep, ×2.93 spend, ×3.59 PRs, ×8.75 lines, ×2.19 releases", () => {
    expect(totalsBlock().querySelector(".lifetime-title")?.textContent).toContain("growth since 10 Sep, log scale");
  });

  it("UNIT COSTS: $24.67/PR, $11.72/1k lines, $111/release, $51.15/hour, since 10 Sep", () => {
    expect(unitCostsBlock().querySelector(".lifetime-title")?.textContent).toContain("dollars, log scale, since 10 Sep");
    expect(lastTooltipRow(unitCostsBlock(), "$/PR")).toBe("$24.67");
    expect(lastTooltipRow(unitCostsBlock(), "$/1k lines")).toBe("$11.72");
    expect(lastTooltipRow(unitCostsBlock(), "$/release")).toBe("$111");
    expect(lastTooltipRow(unitCostsBlock(), "$/hour")).toBe("$51.15");
  });

  it("prints no note: 10 Sep still sits after the base day, 3 Sep", () => {
    expect(valuePanel().querySelector(".lifetime-note")).toBeNull();
  });
});

describe("90d, which reaches before the base day", () => {
  it("asks no lifetime route again on the toggle click", async () => {
    const added = await chooseSpan("90d");
    const asked = page.requests.slice(-added);
    expect(asked.some((u) => u.startsWith("/api/yield/daily"))).toBe(false);
  });

  it("TOTALS clamps to the base day, 3 Sep — the lifetime reading: ×8.81 spend, ×9.04 PRs, ×26.20 lines, ×4.12 releases", () => {
    expect(totalsBlock().querySelector(".lifetime-title")?.textContent).toContain("growth since 3 Sep, log scale");
  });

  it("prints the note: 90 days back from 9 Oct (12 Jul) reaches well before 3 Sep", () => {
    expect(valuePanel().querySelector(".lifetime-note")?.textContent).toBe(LIFETIME_NOTE);
  });
});
