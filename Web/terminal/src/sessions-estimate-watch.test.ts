import { beforeAll, describe, expect, it } from "vitest";

import { installFakePage, type FakePage } from "./fake-page";
import { type ModelRow, type ProjectSummary } from "./sessions-model";

/**
 * A watch-only token and the running session's estimate (`agent-dashboard`,
 * round 16): the daemon refuses the rollup and the cost route to a watch
 * token, so the page has no rollup, prints no cost column on any line, and
 * never asks the cost route for the running session. The estimate changes
 * nothing here, as the request said.
 */

const NOW = Date.now();
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, knowledge: "docs/goals" };
const ref = { id: kitterm.id, name: kitterm.name, root: kitterm.root!, registered: true };
const running: ModelRow = {
  id: "s-running", name: "crew", cwd: kitterm.root!, state: "running", mergedState: "working", marks: 0, project: ref,
  agentModel: "claude-opus-5", agentModelName: "Opus 5", agentTranscript: "/t/running.jsonl", lastOutputAt: NOW - 12_000,
} as ModelRow;

// No `/api/usage/daily` and no cost route: what a watch token gets (403),
// which the page reads like the stub's 404.
const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [running] },
  "/api/projects": { projects: [kitterm] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;

beforeAll(async () => {
  page = installFakePage(routes);
  await import("./sessions");
  await page.settle();
  await page.poll();
});

describe("a watch client", () => {
  it("sees no cost on the running session's line, and the page never asks the cost route", () => {
    const line = page.root.querySelector(".tree")!.querySelector(".row-line")!;
    expect(line.querySelector(".line-name")?.textContent).toBe("crew");
    expect(line.querySelector(".cost")).toBeNull();
    expect(line.querySelector(".main")!.children.filter((c) => typeof c !== "string").map((c) => c.className)).toEqual(["folder line-name", "state running", "model", "since"]);
    expect(page.requests.filter((u) => u.includes("/cost"))).toEqual([]);
    expect(page.root.querySelector(".tree")!.querySelector(".line-project")!.querySelector(".line-name")?.title).toBe(`${kitterm.root}\nno goal folder`);
  });
});
