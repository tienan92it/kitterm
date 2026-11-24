import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { type ModelRow, type ProjectSummary } from "./sessions-model";

/**
 * The page prints the count of a done row's own running jobs as visible
 * text, in the `.line-detail` every line uses, so a touch device shows it;
 * a tooltip alone does not. A count that changes repaints the row.
 */
const NOW = Date.now();
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, knowledge: "docs/goals" };
const project = { id: kitterm.id, name: kitterm.name, root: kitterm.root, registered: true };

function crew(id: string, ownJobs?: number): ModelRow {
  return {
    id, name: id, cwd: kitterm.root, state: "running", mergedState: "completed", marks: 0, project,
    agent: { status: "completed", at: NOW - 60_000, ...(ownJobs === undefined ? {} : { ownJobs }) },
    lastOutputAt: NOW - 60_000,
  } as ModelRow;
}

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [crew("with-job", 1), crew("no-job")] },
  "/api/projects": { projects: [kitterm] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [] },
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
});

const rowNamed = (name: string): FakeElement =>
  page.root.querySelectorAll(".row-line").find((r) => r.querySelector(".line-name")?.textContent === name)!;

describe("the painted row whose turn ended with a job of its own running", () => {
  it("prints the count as visible text beside the name, with the word done", () => {
    const row = rowNamed("with-job");
    expect(row.querySelector(".line-detail")?.textContent).toBe("1 job running");
    expect(row.querySelector(".state")?.textContent).toBe("[done]");
  });

  it("prints no detail on a done row with no job", () => {
    expect(rowNamed("no-job").querySelector(".line-detail")).toBeNull();
  });

  it("repaints when the count changes", async () => {
    routes["/api/sessions"] = { ok: true, sessions: [crew("with-job", 2), crew("no-job")] };
    await page.poll();
    expect(rowNamed("with-job").querySelector(".line-detail")?.textContent).toBe("2 jobs running");
  });
});
