import { beforeAll, describe, expect, it, vi } from "vitest";

import { fakeStatus } from "./fake-page";
import { type GatedPage, installGatedPage, paintFirstRoutes } from "./paint-first-fixture";

/**
 * The archive list and an answer that is not ok (`fleet-first-paint`,
 * round 3, correction 2). A 500 keeps the list and its tag on the page,
 * and the next poll asks again. A 404 is a daemon with no archive route:
 * the page has no list and does not ask again. The steps run in order on
 * one page.
 */

const routes = paintFirstRoutes();
let gated: GatedPage;
/** What each `/api/archives` request sent and got, in order. */
const asks: Array<{ ifNoneMatch: string | null; status: number }> = [];

const foldNames = (): string[] =>
  gated.page.root.querySelector(".folds")!.querySelectorAll(".line-name").map((n) => n.textContent);

async function feed(next: number): Promise<void> {
  routes["/api/events"] = { next, epoch: "e1", events: [{ type: "session.archived", session: "a-new" }] };
  await gated.release("events");
}

beforeAll(async () => {
  gated = installGatedPage(routes);
  const answer = globalThis.fetch;
  vi.stubGlobal("fetch", async (input: string | URL, init?: RequestInit) => {
    const res = await answer(input, init);
    if (String(input) !== "/api/archives") return res;
    const ifNoneMatch = ((init?.headers ?? {}) as Record<string, string>)["if-none-match"] ?? null;
    asks.push({ ifNoneMatch, status: res.status });
    return res;
  });
  await import("./sessions");
  await gated.page.settle();
  for (const gate of ["archives", "usage", "yield", "bills", "lifetime"] as const) await gated.open(gate);
});

describe("the archive list and an answer that is not ok", () => {
  it("paints the list of the first 200", () => {
    expect(asks).toEqual([{ ifNoneMatch: null, status: 200 }]);
    expect(foldNames()).toEqual(["Archived (2)"]);
  });

  it("keeps the list on a 500", async () => {
    routes["/api/archives"] = fakeStatus(500, { ok: false });
    await feed(1);
    expect(asks.length).toBeGreaterThanOrEqual(2);
    expect(asks[1].status).toBe(500);
    expect(foldNames()).toEqual(["Archived (2)"]);
  });

  it("asks again in the next poll with the tag it kept, and paints the list of the 200", async () => {
    routes["/api/archives"] = { archives: [{ id: "arch-2", name: "older", cwd: "/w/kitterm" }] };
    const before = asks.length;
    await gated.page.poll();
    expect(asks).toHaveLength(before + 1);
    expect(asks[before].status).toBe(200);
    expect(asks[before].ifNoneMatch).toMatch(/^".+"$/);
    expect(foldNames()).toEqual(["Archived (1)"]);
  });

  it("does not ask in a poll after the 200", async () => {
    const before = asks.length;
    await gated.page.poll();
    expect(asks).toHaveLength(before);
  });

  it("has no list after a 404 and does not ask again", async () => {
    routes["/api/archives"] = fakeStatus(404, { ok: false });
    await feed(2);
    const after = asks.length;
    expect(asks[after - 1].status).toBe(404);
    expect(foldNames()).toEqual([]);
    for (let i = 0; i < 2; i += 1) await gated.page.poll();
    expect(asks).toHaveLength(after);
  });
});
