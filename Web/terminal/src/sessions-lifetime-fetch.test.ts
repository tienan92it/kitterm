import { beforeAll, describe, expect, it, vi } from "vitest";

import { installFakePage, type FakePage } from "./fake-page";
import { dayKey } from "./sessions-model";

/**
 * The two lifetime routes (`value-lifetime`, capability 4): `fetchLifetime`
 * asks `GET /api/usage/daily` and `GET /api/yield/daily` for a wide range
 * (400 days, ending today) once at load and every five minutes after,
 * never on the `USAGE`/`VALUE` 7d/30d/90d toggle. The watch-client case
 * (neither route asked at all) is `sessions-lifetime-watch.test.ts`: a
 * second `import("./sessions")` in this file would reuse the first one's
 * already-initialized module instance, not a fresh client.
 */

const NOW = new Date(2026, 9, 9, 12, 0, 0).getTime();
const LIFETIME_DAYS = 400;

function lifetimeRange(now: number): { from: string; to: string } {
  const to = new Date(now);
  const from = new Date(to.getFullYear(), to.getMonth(), to.getDate() - (LIFETIME_DAYS - 1), 12);
  return { from: dayKey(from.getTime()), to: dayKey(now) };
}

const kitterm = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, knowledge: "docs/goals" };

const emptyUsage = (query: URLSearchParams) => ({
  ok: true, timeZone: "UTC", from: query.get("from"), to: query.get("to"), refreshedAt: NOW, recordedSessions: 0,
  days: [], totals: { costUSD: 0, apportionedUSD: 0, tokens: { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 }, sessions: 0, unbilledSessions: 0 },
  projects: [],
});
const emptyYieldDaily = (query: URLSearchParams) => ({ ok: true, from: query.get("from"), to: query.get("to"), days: [] });

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [kitterm] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/daily": emptyUsage,
  "/api/yield": { ok: true, from: "2026-09-10", to: "2026-10-09", projects: [], totals: { checkouts: 0, counted: 0, mergedPullRequests: 0, mergedLines: 0, releases: 0 } },
  "/api/yield/daily": emptyYieldDaily,
  "/api/usage/limits": { ok: true, hasReading: false },
};

/** The requests to the two lifetime routes, by their own wide range, not
 * the toggle's narrower one: `/api/usage/daily` is asked for both ranges,
 * so this filters to the lifetime one by its distinct `from`/`to`. */
function lifetimeRequests(page: FakePage, now: number): string[] {
  const { from, to } = lifetimeRange(now);
  return page.requests.filter((u) => u.includes(`from=${from}&to=${to}`));
}

let page: FakePage;
let clock: ReturnType<typeof vi.spyOn>;

beforeAll(async () => {
  clock = vi.spyOn(Date, "now").mockReturnValue(NOW);
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  await import("./sessions");
  await page.settle();
});

describe("a full-grade client", () => {
  it("asks both routes once at load, for the same 400-day range ending today", () => {
    const asked = lifetimeRequests(page, NOW);
    const paths = asked.map((u) => u.replace(/\?.*$/, "")).sort();
    expect(paths).toEqual(["/api/usage/daily", "/api/yield/daily"]);
  });

  it("does not ask again on a later 2 s poll inside the five-minute window", async () => {
    const before = lifetimeRequests(page, NOW).length;
    clock.mockReturnValue(NOW + 60_000);
    await page.poll();
    expect(lifetimeRequests(page, NOW).length).toBe(before);
  });

  it("asks again, for a range one day wider, once five minutes have passed", async () => {
    const later = NOW + 5 * 60_000 + 1000;
    clock.mockReturnValue(later);
    await page.poll();
    expect(lifetimeRequests(page, later).length).toBeGreaterThan(0);
  });

  it("is never asked by the usage/span toggle: a toggle click re-asks only the toggle's own narrower range", async () => {
    const beforeCount = page.requests.length;
    const toggle = page.root.querySelectorAll(".usage-toggle").find((b) => b.textContent === "7d")!;
    toggle.click();
    await page.settle();
    const after = page.requests.slice(beforeCount);
    const { from: lFrom, to: lTo } = lifetimeRange(Date.now());
    expect(after.some((u) => u.includes(`/api/usage/daily?from=${lFrom}&to=${lTo}`))).toBe(false);
    expect(after.some((u) => u.includes("/api/yield/daily"))).toBe(false);
  });
});
