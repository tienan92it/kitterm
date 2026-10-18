import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import { installFakePage, type FakePage } from "./fake-page";
import { type ProjectSummary } from "./sessions-model";

/**
 * `pulls.changed` on the event feed (`sessions-workflow` round 8, option 3
 * of `corpus/03-faster-pull-sync.md`): the page, which holds `/api/events`
 * open, asks the named project's pulls at once, with the ETag it holds,
 * and no other project's; the 10 s poll (`PULLS_REFRESH_MS`) stays the
 * fallback for both.
 */

const BASE = "https://github.com/tienan92it/kitterm/pull/";
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: "/Users/an/Workspace/kitterm", registered: true, knowledge: "docs/goals", pullRequestBase: BASE };
const cafe: ProjectSummary = { id: "lume-cafe", name: "lume-cafe", root: "/Users/an/Sites/lume-cafe", registered: true, knowledge: "docs/goals", pullRequestBase: "https://github.com/tienan92it/lume-cafe/pull/" };

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [kitterm, cafe] },
  "/api/projects/kitterm/pulls": { ok: true, project: "kitterm", pulls: [{ number: 196, title: "r8", state: "open", draft: true, headRefName: "goal/sessions-workflow", url: `${BASE}196`, additions: 1, deletions: 0 }] },
  "/api/projects/lume-cafe/pulls": { ok: true, project: "lume-cafe", pulls: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;
/** The headers of every pulls request, in order, by URL. */
const pullsHeaders: Array<{ url: string; ifNoneMatch: string | null }> = [];
let releaseEvents: (events: unknown[]) => void = () => {};
const pullsRequests = (id: string): number => page.requests.filter((u) => u === `/api/projects/${id}/pulls`).length;
const realNow = Date.now;

beforeAll(async () => {
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  const answer = globalThis.fetch;
  let eventsAnswered = 0;
  vi.stubGlobal("fetch", async (input: string | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.startsWith("/api/events")) {
      // The first watch parks until the test releases it with a batch; the
      // next one parks for good, so one batch is all the page hears.
      eventsAnswered += 1;
      if (eventsAnswered > 1) return new Promise<Response>(() => {});
      const events = await new Promise<unknown[]>((resolve) => { releaseEvents = resolve; });
      return new Response(JSON.stringify({ ok: true, epoch: "e", next: 7, events }), { status: 200 });
    }
    if (url.endsWith("/pulls")) {
      const headers = (init?.headers ?? {}) as Record<string, string>;
      pullsHeaders.push({ url, ifNoneMatch: headers["if-none-match"] ?? null });
    }
    return answer(input, init);
  });
  await import("./sessions");
  await page.settle();
  await page.poll();
});

afterAll(() => {
  Date.now = realNow;
});

describe("pulls.changed on the event feed", () => {
  it("the page asked each GitHub project's pulls once on load, and not again inside 10 s", () => {
    expect(pullsRequests("kitterm")).toBe(1);
    expect(pullsRequests("lume-cafe")).toBe(1);
    expect(pullsHeaders[0].ifNoneMatch).toBeNull();
  });

  it("asks the named project's pulls at once, with If-None-Match, and not the other's", async () => {
    releaseEvents([{ type: "pulls.changed", data: { project: "kitterm" } }]);
    await page.settle();
    expect(pullsRequests("kitterm")).toBe(2);
    expect(pullsRequests("lume-cafe")).toBe(1);
    const again = pullsHeaders.filter((h) => h.url === "/api/projects/kitterm/pulls");
    expect(again[0].ifNoneMatch).toBeNull();
    expect(again[1].ifNoneMatch).not.toBeNull();
  });

  it("a poll inside 10 s asks neither again", async () => {
    await page.poll();
    expect(pullsRequests("kitterm")).toBe(2);
    expect(pullsRequests("lume-cafe")).toBe(1);
  });

  it("keeps the 10 s poll as the fallback for both", async () => {
    const start = realNow();
    Date.now = () => start + 10_001;
    await page.poll();
    expect(pullsRequests("kitterm")).toBe(3);
    expect(pullsRequests("lume-cafe")).toBe(2);
  });
});
