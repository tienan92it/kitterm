import { beforeAll, describe, expect, it, vi } from "vitest";

import { type GatedPage, installGatedPage, paintFirstRoutes } from "./paint-first-fixture";

/**
 * The page and the archive list's `ETag` (`fleet-first-paint`, round 3;
 * `goal.md` condition 4, the page half). The page sends the tag of the
 * list it holds as `If-None-Match`, keeps its list on a 304, and asks
 * again on an `archive.removed` event. The daemon here answers 304 when
 * the tag the page sent is the tag of the list. The steps run in order on
 * one page.
 */

const routes = paintFirstRoutes();
let gated: GatedPage;
/** What each `/api/archives` request sent and got, in order. */
const asks: Array<{ ifNoneMatch: string | null; status: number }> = [];

const foldNames = (): string[] =>
  gated.page.root.querySelector(".folds")!.querySelectorAll(".line-name").map((n) => n.textContent);

async function feed(next: number, type: string): Promise<void> {
  routes["/api/events"] = { next, epoch: "e1", events: [{ type, session: "a-gone" }] };
  await gated.release("events");
}

beforeAll(async () => {
  gated = installGatedPage(routes);
  const answer = globalThis.fetch;
  vi.stubGlobal("fetch", async (input: string | URL, init?: RequestInit) => {
    const res = await answer(input, init);
    if (String(input) !== "/api/archives") return res;
    const ifNoneMatch = ((init?.headers ?? {}) as Record<string, string>)["if-none-match"] ?? null;
    const same = ifNoneMatch !== null && ifNoneMatch === res.headers.get("etag");
    asks.push({ ifNoneMatch, status: same ? 304 : res.status });
    return same ? new Response(null, { status: 304, headers: { etag: ifNoneMatch } }) : res;
  });
  await import("./sessions");
  await gated.page.settle();
  for (const gate of ["archives", "usage", "yield", "bills", "lifetime"] as const) await gated.open(gate);
});

describe("the archive list and its ETag", () => {
  it("asks first with no If-None-Match and paints the list", () => {
    expect(asks).toEqual([{ ifNoneMatch: null, status: 200 }]);
    expect(foldNames()).toEqual(["Archived (2)"]);
  });

  it("sends the tag on the next ask and keeps its list on a 304", async () => {
    await feed(1, "session.archived");
    expect(asks).toHaveLength(2);
    expect(asks[1].ifNoneMatch).toMatch(/^".+"$/);
    expect(asks[1].status).toBe(304);
    expect(foldNames()).toEqual(["Archived (2)"]);
  });

  it("asks again on archive.removed, and paints the shorter list of a 200", async () => {
    routes["/api/archives"] = { archives: [{ id: "arch-2", name: "older", cwd: "/w/kitterm" }] };
    await feed(2, "archive.removed");
    expect(asks).toHaveLength(3);
    expect(asks[2]).toEqual({ ifNoneMatch: asks[1].ifNoneMatch, status: 200 });
    expect(foldNames()).toEqual(["Archived (1)"]);
  });

  it("sends the tag of the new list after that", async () => {
    await feed(3, "archive.removed");
    expect(asks).toHaveLength(4);
    expect(asks[3].status).toBe(304);
    expect(asks[3].ifNoneMatch).not.toBe(asks[2].ifNoneMatch);
    expect(foldNames()).toEqual(["Archived (1)"]);
  });

  it("does not ask in a poll", async () => {
    for (let i = 0; i < 3; i += 1) await gated.page.poll();
    expect(asks).toHaveLength(4);
  });
});
