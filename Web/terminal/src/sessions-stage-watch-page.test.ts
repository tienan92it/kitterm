import { beforeAll, describe, expect, it, vi } from "vitest";

import { installFakePage, type FakePage } from "./fake-page";
import { type ProjectSummary } from "./sessions-model";

/**
 * A watch-only token (`sessions-workflow`, capability 5): the pulls route
 * is full grade, so a watch page asks no pulls route, prints no pull
 * request state, no `REVIEW` line and no reason for either, as it hides
 * the costs. The stage still comes from `STATE.md` and the sessions.
 */

const BASE = "https://github.com/tienan92it/kitterm/pull/";
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: "/Users/an/Workspace/kitterm", registered: true, knowledge: "docs/goals", pullRequestBase: BASE };
const local: ProjectSummary = { id: "fnb", name: "fnb-design", root: "/Users/an/Sites/fnb-design", registered: true, knowledge: "docs/goals" };

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [kitterm, local] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [{ slug: "demo-backend", goal: "the demo trades", status: "waiting", round: 2, budget: 3, pullRequest: 2888, tasks: [{ slug: "replica-reclaim", state: "pending" }] }] },
  "/api/projects/fnb/knowledge": { ok: true, project: "fnb", goals: [{ slug: "menu-board", status: "active", tasks: [{ slug: "print", state: "pending" }] }] },
  // What the route would say to a full token; a watch page never asks.
  "/api/projects/kitterm/pulls": { ok: true, project: "kitterm", readAt: Date.now(), pulls: [{ number: 2888, state: "open", draft: false, headRefName: "goal/demo-backend", ci: "passing" }] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;

beforeAll(async () => {
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  // The daemon answers 403 on the profiles route for a watch token.
  const answer = globalThis.fetch;
  vi.stubGlobal("fetch", async (input: string | URL) => (String(input).startsWith("/api/profiles") ? new Response("forbidden", { status: 403 }) : answer(input)));
  await import("./sessions");
  await page.settle();
  await page.poll();
  await page.poll();
});

describe("a watch page", () => {
  it("asks no pulls route", () => {
    expect(page.requests.filter((u) => u.includes("/pulls"))).toEqual([]);
  });

  it("prints no REVIEW line and no pull request state", () => {
    expect(page.root.querySelector(".review")?.hidden).toBe(true);
    expect(page.root.querySelector(".review-label")?.hidden).toBe(true);
    expect(page.root.querySelectorAll(".pr-words")).toEqual([]);
    expect(page.root.querySelectorAll(".pr-word")).toEqual([]);
  });

  it("keeps the stage word and the pull request number, and gives no reason for the missing state", () => {
    const goal = page.root.querySelectorAll(".goal-line").find((g) => g.querySelector(".line-name")?.textContent === "demo-backend")!;
    expect(goal.querySelector(".state")?.textContent).toBe("[blocked]");
    expect(goal.querySelector(".pr")?.textContent).toBe("PR #2888");
    expect(page.root.textContent).not.toContain("pull request states are not read");
    expect(page.root.textContent).not.toContain("Pull request states are not read");
  });
});
