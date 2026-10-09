import { beforeAll, describe, expect, it, vi } from "vitest";

import { fakeStatus, fakeThrow, installFakePage, type FakePage } from "./fake-page";
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

/** Ten days of real spend and yield, the same shape `sessions-lifetime-page.test.ts`
 * uses: enough for a seven-day run (`baseDayOf`) and real end-label text,
 * so a test can tell "kept the last good chart" from "lost it" by reading
 * the DOM, not just by counting requests. */
function lifetimeDays(): { usage: unknown[]; yield: unknown[] } {
  const usage: unknown[] = [];
  const yieldDays: unknown[] = [];
  for (let i = 1; i <= 10; i += 1) {
    const day = `2026-09-${String(i).padStart(2, "0")}`;
    usage.push({ day, costUSD: 10, apportionedUSD: 0, tokens: { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 }, sessions: 1, unbilledSessions: 0, apiMs: 3_600_000, measuredUSD: 10, projects: [] });
    yieldDays.push({ day, mergedPullRequests: i, mergedLines: i * 100, releases: 1, projects: [] });
  }
  return { usage, yield: yieldDays };
}
const fixture = lifetimeDays();

/** Whole days between two `YYYY-MM-DD` query bounds, to tell the lifetime
 * route's 400-day request apart from the `USAGE`/`VALUE` toggle's own
 * narrower one on the one path, `/api/usage/daily`, they share. */
function daySpan(query: URLSearchParams): number {
  const from = new Date(query.get("from") ?? "");
  const to = new Date(query.get("to") ?? "");
  return Math.round((to.getTime() - from.getTime()) / 86_400_000);
}

/** What the lifetime routes answer on their next request: a good answer
 * with the fixture, a non-ok status, or a thrown (network) failure. The
 * toggle's own `/api/usage/daily` request always gets a good, empty
 * answer — only the lifetime-range request reads this. */
let lifetimeBehavior: "ok" | "fail" | "throw" = "ok";

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [kitterm] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/daily": (query: URLSearchParams) => {
    const good = {
      ok: true, timeZone: "UTC", from: query.get("from"), to: query.get("to"), refreshedAt: NOW, recordedSessions: daySpan(query) > 100 ? 10 : 0,
      days: daySpan(query) > 100 ? fixture.usage : [],
      totals: { costUSD: 0, apportionedUSD: 0, tokens: { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 }, sessions: 0, unbilledSessions: 0 },
      projects: [],
    };
    if (daySpan(query) <= 100) return good; // the toggle's own range: always a good, empty answer
    if (lifetimeBehavior === "fail") return fakeStatus(500);
    if (lifetimeBehavior === "throw") return fakeThrow();
    return good;
  },
  "/api/yield": { ok: true, from: "2026-09-10", to: "2026-10-09", projects: [], totals: { checkouts: 0, counted: 0, mergedPullRequests: 0, mergedLines: 0, releases: 0 } },
  "/api/yield/daily": (query: URLSearchParams) => {
    if (lifetimeBehavior === "fail") return fakeStatus(500);
    if (lifetimeBehavior === "throw") return fakeThrow();
    return { ok: true, from: query.get("from"), to: query.get("to"), days: fixture.yield };
  },
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

/** The chart's end-label text: a stand-in for "the lifetime charts show
 * the last good answer", since this fixture's labels are only present once
 * a good answer has landed. */
const lifetimeLabels = () => page.root.querySelectorAll(".lifetime-label").map((l) => l.textContent);

describe("a non-ok answer or a thrown request", () => {
  it("keeps the last good charts on a non-ok answer, and waits the full five minutes before asking again", async () => {
    // The previous describe block already landed a good answer; the chart
    // carries real labels, not nothing.
    const goodLabels = lifetimeLabels();
    expect(goodLabels.length).toBeGreaterThan(0);

    lifetimeBehavior = "fail";
    const failAt = Date.now() + 5 * 60_000 + 1000;
    const before = lifetimeRequests(page, failAt).length;
    clock.mockReturnValue(failAt);
    await page.poll();
    // The failing request was made (the cadence allowed it)...
    expect(lifetimeRequests(page, failAt).length).toBe(before + 2); // usage + yield/daily
    // ...but the charts still show the last good answer, not nothing.
    expect(lifetimeLabels()).toEqual(goodLabels);

    // Inside five minutes of the failed attempt, no retry: the count of
    // lifetime-range requests does not move on a later 2 s poll.
    const afterFail = lifetimeRequests(page, failAt).length;
    clock.mockReturnValue(failAt + 60_000);
    await page.poll();
    expect(lifetimeRequests(page, failAt).length).toBe(afterFail);

    lifetimeBehavior = "ok";
  });

  it("does not retry before five minutes after a thrown request, then recovers", async () => {
    const goodLabels = lifetimeLabels();
    lifetimeBehavior = "throw";
    const throwAt = Date.now() + 5 * 60_000 + 1000;
    const before = lifetimeRequests(page, throwAt).length;
    clock.mockReturnValue(throwAt);
    await page.poll();
    // Both fetches were attempted (`Promise.all` starts them together);
    // the thrown one does not stop the other's `requests` entry.
    expect(lifetimeRequests(page, throwAt).length).toBe(before + 2);
    expect(lifetimeLabels()).toEqual(goodLabels); // kept, not reset

    // Inside five minutes: no retry.
    const afterThrow = lifetimeRequests(page, throwAt).length;
    clock.mockReturnValue(throwAt + 60_000);
    await page.poll();
    expect(lifetimeRequests(page, throwAt).length).toBe(afterThrow);

    // Past five minutes: retries, and a good answer repaints the charts.
    lifetimeBehavior = "ok";
    const recoverAt = throwAt + 5 * 60_000 + 1000;
    clock.mockReturnValue(recoverAt);
    await page.poll();
    expect(lifetimeRequests(page, recoverAt).length).toBe(afterThrow + 2);
    expect(lifetimeLabels()).toEqual(goodLabels);
  });
});
