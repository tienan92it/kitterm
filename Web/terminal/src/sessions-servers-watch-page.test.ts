import { beforeAll, describe, expect, it, vi } from "vitest";

import { installFakePage, type FakePage } from "./fake-page";

/**
 * A watch-only token and the SERVERS section (`running-servers`,
 * `goal.md` condition 5): the servers route is full grade, so a watch page
 * asks it never, not before it knows its grade and not after, and shows
 * no SERVERS section, as it shows no cost.
 *
 * The page starts out of order here: the event feed answers and starts a
 * poll while the profiles route, which says the token is watch-only, has
 * not answered yet. No servers request may leave before the page knows.
 */

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [] },
  // What the route would say to a full token; a watch page never asks.
  "/api/servers": { ok: true, supported: true, readAt: Date.now(), servers: [{ port: 3000, addresses: ["0.0.0.0"], pid: 440, program: "node", http: true, session: { id: "s1", name: "web" } }] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;
let releaseProfiles: () => void = () => {};
let early = { polled: 0, servers: 0 };

beforeAll(async () => {
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  const answer = globalThis.fetch;
  let feedAnswered = false;
  vi.stubGlobal("fetch", async (input: string | URL) => {
    const url = String(input);
    if (url.startsWith("/api/profiles")) {
      await new Promise<void>((resolve) => { releaseProfiles = resolve; });
      return new Response("forbidden", { status: 403 });
    }
    if (url.startsWith("/api/events")) {
      if (feedAnswered) return new Promise<Response>(() => {});
      feedAnswered = true;
      return new Response(JSON.stringify({ ok: true, epoch: "e", next: 1, events: [{ type: "session.created" }] }), { status: 200 });
    }
    return answer(input);
  });
  await import("./sessions");
  await page.settle();
  early = { polled: page.requests.filter((u) => u.startsWith("/api/sessions")).length, servers: page.requests.filter((u) => u.startsWith("/api/servers")).length };
  releaseProfiles();
  await page.settle();
  await page.poll();
  await page.poll();
});

describe("a watch page", () => {
  it("polled the fleet before it knew its grade, and asked no servers route meanwhile", () => {
    expect(early.polled).toBeGreaterThan(0);
    expect(early.servers).toBe(0);
  });

  it("asks no servers route once it knows", () => {
    expect(page.requests.filter((u) => u.startsWith("/api/servers"))).toEqual([]);
  });

  it("shows no SERVERS section: no label, no header, no row", () => {
    const block = page.root.querySelector(".servers-head")!;
    expect(block.hidden).toBe(true);
    expect(block.querySelector(".servers")?.textContent).toBe("");
    expect(block.querySelectorAll(".line-server")).toEqual([]);
    expect(page.root.textContent).not.toContain("listening");
  });
});
