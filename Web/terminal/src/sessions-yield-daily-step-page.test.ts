import { beforeAll, describe, expect, it, vi } from "vitest";

import { type GatedPage, installGatedPage, NOW, paintFirstRoutes } from "./paint-first-fixture";

/**
 * The slower step of the daily yield (`fleet-first-paint`, round 3; the gap
 * of round 2). While `/api/yield/daily` says `pending` and the charts have
 * figures, the page asks the route again every 10 s, not on each 2 s poll:
 * the body for the whole record is hundreds of kilobytes. With no figures
 * each poll asks (`sessions-yield-pending-page.test.ts`). The steps run in
 * order on one page.
 */

const routes = paintFirstRoutes();
const figures = routes["/api/yield/daily"] as (query: URLSearchParams) => Record<string, unknown>;
const daily = (state: Record<string, unknown>) => (query: URLSearchParams): unknown => ({ ...figures(query), ...state });

let gated: GatedPage;
const dailyAsks = (): number => gated.page.requests.filter((url) => url.startsWith("/api/yield/daily")).length;
const charts = (): number => gated.panel("value").querySelectorAll(".lifetime-chart-block").length;
const at = (ms: number): void => void vi.spyOn(Date, "now").mockReturnValue(NOW + ms);

beforeAll(async () => {
  routes["/api/yield/daily"] = daily({ pending: true, unread: 0, ageSeconds: 400 });
  gated = installGatedPage(routes);
  await import("./sessions");
  await gated.page.settle();
  for (const gate of ["archives", "usage", "yield", "bills", "lifetime"] as const) await gated.open(gate);
});

describe("the daily yield says pending and its figures are on the page", () => {
  it("paints the charts from the kept figures", () => {
    expect(charts()).toBe(2);
    expect(dailyAsks()).toBe(1);
  });

  it("does not ask again on a 2 s poll", async () => {
    for (const ms of [2000, 4000, 6000, 8000]) {
      at(ms);
      await gated.page.poll();
    }
    expect(dailyAsks()).toBe(1);
  });

  it("asks again 10 s after the last ask, and then waits 10 s more", async () => {
    at(10_000);
    await gated.page.poll();
    expect(dailyAsks()).toBe(2);
    at(18_000);
    await gated.page.poll();
    expect(dailyAsks()).toBe(2);
  });

  it("stops when the body no longer says pending", async () => {
    routes["/api/yield/daily"] = daily({ pending: false, unread: 0, ageSeconds: 0 });
    at(20_000);
    await gated.page.poll();
    expect(dailyAsks()).toBe(3);
    at(40_000);
    await gated.page.poll();
    expect(dailyAsks()).toBe(3);
    expect(charts()).toBe(2);
  });
});
