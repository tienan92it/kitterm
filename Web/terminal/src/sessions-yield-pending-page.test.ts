import { beforeAll, describe, expect, it } from "vitest";

import { type GatedPage, installGatedPage, paintFirstRoutes } from "./paint-first-fixture";

/**
 * The page and a yield route that never waits (`fleet-first-paint`, round
 * 2; `goal.md` condition 3, the page half). The daemon answers at once
 * and says `pending` while `git` runs. With roots still `unread` the page
 * keeps its waiting line and asks the yield route alone on the next poll.
 * With kept figures it paints at once and asks again while the refresh
 * runs. The steps run in order on one page.
 */

const routes = paintFirstRoutes();
const totals = { checkouts: 1, counted: 1, mergedPullRequests: 3, mergedLines: 1200, releases: 1 };
const project = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true };
const counted = { checkout: true, remote: true, branch: "origin/main", mergedPullRequests: 3, mergedLines: 1200, releases: 1 };
const report = (state: Record<string, unknown>, figures: boolean): unknown => ({
  ok: true, from: "2026-09-01", to: "2026-09-10",
  projects: [figures ? { ...project, yield: counted } : { ...project, pending: true, yield: { checkout: false, remote: false } }],
  totals: figures ? totals : { checkouts: 0, counted: 0, mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  ...state,
});
const dailyFigures = routes["/api/yield/daily"] as (query: URLSearchParams) => Record<string, unknown>;
const daily = (state: Record<string, unknown>, figures: boolean) => (query: URLSearchParams): unknown =>
  ({ ...dailyFigures(query), ...(figures ? {} : { days: [] }), ...state });

let gated: GatedPage;
const tiles = (): number => gated.panel("value").querySelectorAll(".yield-tile").length;
const charts = (): number => gated.panel("value").querySelectorAll(".lifetime-chart-block").length;

beforeAll(async () => {
  routes["/api/yield"] = report({ pending: true, unread: 1 }, false);
  routes["/api/yield/daily"] = daily({ pending: true, unread: 1 }, false);
  gated = installGatedPage(routes);
  await import("./sessions");
  await gated.page.settle();
  for (const gate of ["archives", "usage", "yield", "bills", "lifetime"] as const) await gated.open(gate);
});

describe("the yield answers at once and says pending, with no figures", () => {
  it("keeps the waiting line of VALUE and WHERE, and paints no tile", () => {
    expect(tiles()).toBe(0);
    expect(gated.panel("value").querySelector(".section-waiting")?.textContent).toBe("Reading the repositories…");
    expect(gated.panel("where").querySelector(".panel-summary")?.textContent).toBe("Reading the repositories…");
  });

  it("asks the yield route alone again on each poll, and never the usage", async () => {
    expect([gated.asked("yield"), gated.asked("usage")]).toEqual([1, 1]);
    await gated.page.poll();
    await gated.page.poll();
    expect([gated.asked("yield"), gated.asked("usage")]).toEqual([3, 1]);
    expect(tiles()).toBe(0);
    expect(gated.panel("value").querySelector(".section-waiting")?.textContent).toBe("Reading the repositories…");
  });

  it("paints the figures by itself when the read ended, and stops asking", async () => {
    routes["/api/yield"] = report({ pending: false, unread: 0, ageSeconds: 0 }, true);
    await gated.page.poll();
    expect(tiles()).toBe(4);
    expect(gated.panel("where").querySelector(".section-waiting")).toBeNull();
    const asked = gated.asked("yield");
    await gated.page.poll();
    await gated.page.poll();
    expect(gated.asked("yield")).toBe(asked);
  });
});

describe("the lifetime's daily yield says pending, with no figures", () => {
  it("keeps the lifetime waiting line and asks the daily yield alone again", async () => {
    expect(charts()).toBe(0);
    expect(gated.waiting()).toEqual(["Reading the lifetime totals…"]);
    const asked = gated.asked("lifetime");
    await gated.page.poll();
    expect(gated.asked("lifetime")).toBe(asked + 1);
    expect(gated.waiting()).toEqual(["Reading the lifetime totals…"]);
  });

  it("paints the two charts when the read ended, and stops asking", async () => {
    routes["/api/yield/daily"] = daily({ pending: false, unread: 0 }, true);
    await gated.page.poll();
    expect(charts()).toBe(2);
    expect(gated.waiting()).toEqual([]);
    const asked = gated.asked("lifetime");
    await gated.page.poll();
    expect(gated.asked("lifetime")).toBe(asked);
  });
});

describe("a kept answer whose refresh runs", () => {
  it("paints the kept figures at once and asks again while the body says pending", async () => {
    // A new range is a new ask: the 7-day toggle. The daemon serves the
    // kept figures with `pending` while one refresh runs.
    routes["/api/yield"] = report({ pending: true, unread: 0, ageSeconds: 400 }, true);
    const seven = gated.panel("usage").querySelectorAll("button").find((b) => b.textContent === "7d")!;
    seven.click();
    await gated.page.settle();
    expect(tiles()).toBe(4);
    expect(gated.panel("value").querySelector(".section-waiting")).toBeNull();
    const asked = gated.asked("yield");
    await gated.page.poll();
    expect(gated.asked("yield")).toBe(asked + 1);
    expect(tiles()).toBe(4);
    routes["/api/yield"] = report({ pending: false, unread: 0, ageSeconds: 0 }, true);
    await gated.page.poll();
    await gated.page.poll();
    expect(gated.asked("yield")).toBe(asked + 2);
  });
});
