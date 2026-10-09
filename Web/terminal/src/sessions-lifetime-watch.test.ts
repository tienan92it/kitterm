import { beforeAll, describe, expect, it, vi } from "vitest";

import { fakeStatus, installFakePage, type FakePage } from "./fake-page";
import { dayKey } from "./sessions-model";

/**
 * A watch client never asks either lifetime route (`goal.md` condition 5;
 * `value-lifetime`, capability 4): `fetchLifetime` waits for `gradeKnown`
 * and then checks `watchOnly`, the same 403 the profiles route gives any
 * other grade-gated route this page reads (the pulls route, the cost
 * routes). The two charts stay off the VALUE panel, as the rest of its
 * numbers already do.
 */

const NOW = new Date(2026, 9, 9, 12, 0, 0).getTime();
const LIFETIME_DAYS = 400;

/** `/api/usage/daily` is also asked for the `USAGE`/`VALUE` toggle's own
 * narrower range, which this page's existing behaviour already asks for
 * any grade (the daemon's own 403 refuses it); this picks out only the
 * lifetime route's distinct 400-day range, which a watch client must never
 * ask for at all. */
function lifetimeRange(now: number): { from: string; to: string } {
  const to = new Date(now);
  const from = new Date(to.getFullYear(), to.getMonth(), to.getDate() - (LIFETIME_DAYS - 1), 12);
  return { from: dayKey(from.getTime()), to: dayKey(now) };
}

const kitterm = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, knowledge: "docs/goals" };

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [kitterm] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  // A watch token's grade: the profiles route 403s.
  "/api/profiles": fakeStatus(403),
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;

beforeAll(async () => {
  vi.spyOn(Date, "now").mockReturnValue(NOW);
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  await import("./sessions");
  await page.settle();
  await page.poll();
});

describe("a watch client", () => {
  it("asks neither lifetime route, at load or ten minutes later", async () => {
    const { from, to } = lifetimeRange(NOW);
    expect(page.requests.some((u) => u.startsWith("/api/yield/daily"))).toBe(false);
    expect(page.requests.some((u) => u.includes(`from=${from}&to=${to}`))).toBe(false);
    vi.spyOn(Date, "now").mockReturnValue(NOW + 10 * 60_000);
    await page.poll();
    expect(page.requests.some((u) => u.startsWith("/api/yield/daily"))).toBe(false);
    const later = lifetimeRange(NOW + 10 * 60_000);
    expect(page.requests.some((u) => u.includes(`from=${later.from}&to=${later.to}`))).toBe(false);
  });

  it("paints no VALUE panel at all, so no lifetime chart can appear", () => {
    const value = page.root.querySelectorAll(".panel").find((p) => p.classList.contains("value"));
    expect(value?.hidden ?? true).toBe(true);
  });
});
