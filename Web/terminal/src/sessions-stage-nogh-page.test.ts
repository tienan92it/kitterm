import { beforeAll, describe, expect, it, vi } from "vitest";

import { installFakePage, type FakePage } from "./fake-page";
import { type ProjectSummary } from "./sessions-model";

/**
 * A machine with no `gh`, then a `gh` with no login (`sessions-workflow`,
 * `goal.md` condition 6; the frame `Sessions components`, "No pull request
 * state"): the pull request numbers print as before, one line says why,
 * and no other part of the page changes.
 */

const BASE = "https://github.com/tienan92it/kitterm/pull/";
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: "/Users/an/Workspace/kitterm", registered: true, knowledge: "docs/goals", pullRequestBase: BASE };

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [kitterm] },
  "/api/projects/kitterm/knowledge": {
    ok: true, project: "kitterm",
    goals: [{ slug: "demo-backend", goal: "the demo trades", status: "active", round: 2, budget: 3, pullRequest: 2888, tasks: [{ slug: "replica-reclaim", state: "pending" }] }],
  },
  "/api/projects/kitterm/pulls": { ok: true, project: "kitterm", pulls: [], reason: "gh is not on PATH" },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;

beforeAll(async () => {
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  await import("./sessions");
  await page.settle();
  await page.poll();
});

describe("no gh on the machine", () => {
  it("says why on the REVIEW line, once", () => {
    const review = page.root.querySelector(".review")!;
    expect(review.hidden).toBe(false);
    expect(review.textContent).toBe("Pull request states are not read: gh is not installed.");
    expect(page.root.textContent.split("Pull request states are not read").length - 1).toBe(1);
  });

  it("prints the pull request number as a link, with no state word, and the stage from STATE.md", () => {
    const goal = page.root.querySelector(".goal-line")!;
    const cell = goal.querySelector(".pr")!;
    expect([cell.textContent, cell.querySelector("a")?.href, cell.querySelector(".pr-words"), cell.querySelector(".pr-word")]).toEqual(["PR #2888", `${BASE}2888`, null, null]);
    expect(goal.querySelector(".state")?.textContent).toBe("[plan]");
    // The project's line keeps its path and its counts.
    expect(page.root.querySelector(".line-project")?.querySelector(".line-detail")?.textContent).toBe("~/Workspace/kitterm · 1 plan");
  });

  it("names the command when gh has no login", async () => {
    routes["/api/projects/kitterm/pulls"] = { ok: true, project: "kitterm", pulls: [], reason: "gh is not logged in" };
    const later = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 60_000);
    await page.poll();
    later.mockRestore();
    const review = page.root.querySelector(".review")!;
    expect(review.textContent).toBe("Pull request states are not read: gh is not logged in. Run gh auth login");
    expect(review.querySelector(".note-command")?.textContent).toBe("gh auth login");
  });
});
