import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { rollup } from "./range-fixture";
import { type DayRange, type KnowledgeSummary, type ModelRow, type ProjectSummary } from "./sessions-model";

/**
 * The page paints the task line a running round draws from its labels
 * (`foreman-flow`, capability 2; the pure rule is in
 * `sessions-labelled-task.test.ts`): under its goal, the same `.line-task`
 * as a listed task, `[working]`, the dash in the cost column, `PR #N` as
 * the `pullRequestLink` anchor under the project's `pullRequestBase`, and
 * the crew's row under it. A project with no base prints the number as
 * plain text, the same way `sessions-pr-links.test.ts` pins it for a
 * listed task.
 */
const NOW = Date.now();
const W = "/w";
const BASE = "https://github.com/tienan92it/kitterm/pull/";
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true, knowledge: "docs/goals", pullRequestBase: BASE };
const mdp: ProjectSummary = { id: "mdp", name: "market-data-pipeline", root: `${W}/market-data-pipeline`, registered: true, knowledge: "docs/goals" };
const ref = (p: ProjectSummary) => ({ id: p.id, name: p.name, root: p.root, registered: p.registered });
const rangeOf = (query: URLSearchParams): DayRange => ({ from: query.get("from") ?? "", to: query.get("to") ?? "" });

function crewOf(p: ProjectSummary, id: string, goal: string, task: string, pr: string): ModelRow {
  return {
    id, name: id, cwd: `${p.root}/.claude/worktrees/${goal}`, state: "running", mergedState: "working", marks: 0, project: ref(p),
    labels: { crew: goal, goal, round: "2", task, pr }, lastOutputAt: NOW - 60_000,
  } as ModelRow;
}

const foremanFlow: KnowledgeSummary = {
  project: "kitterm", slug: "foreman-flow", status: "active", round: 1, budget: 3,
  tasks: [{ slug: "the-ci-is-the-second-floor", state: "pending" }, { slug: "the-pr-opens-first", state: "done", round: 1, pr: 176 }],
  rounds: [{ number: 1, started: "2026-09-29", costUSD: 5.23, pr: 176, correction: false }],
};
const onboarding: KnowledgeSummary = { project: "mdp", slug: "symbol-onboarding", status: "active", round: 3, budget: 3, tasks: [] };

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [crewOf(kitterm, "crew-kitterm", "foreman-flow", "the-dashboard-shows-the-open-pr", "176"), crewOf(mdp, "crew-mdp", "symbol-onboarding", "map-the-path", "41")] },
  "/api/projects": { projects: [kitterm, mdp] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [foremanFlow] },
  "/api/projects/mdp/knowledge": { ok: true, project: "mdp", goals: [onboarding] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/daily": (query: URLSearchParams) => rollup(rangeOf(query), NOW),
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;

beforeAll(async () => {
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  await import("./sessions");
  await page.settle();
});

const cellsOf = (line: FakeElement) =>
  line.querySelector(".main")!.children.filter((c): c is FakeElement => typeof c !== "string").map((c) => `${c.className}=${c.textContent}${c.hasAttribute("data-col") ? `@${c.getAttribute("data-col")}` : ""}${c.hasAttribute("data-narrow") ? "!" : ""}`);
const linkIn = (cell: FakeElement | undefined) => {
  const a = cell?.querySelector("a") ?? null;
  if (a === null) return null;
  const el = a as unknown as { className: string; href: string; target: string; rel: string; textContent: string };
  return [el.className, el.href, el.target, el.rel, a.querySelector(".mark")?.className, el.textContent];
};
const goalNamed = (name: string) => page.root.querySelectorAll(".goal-line").find((g) => g.querySelector(".line-name")?.textContent === name)!;
const taskNamed = (name: string) => page.root.querySelectorAll(".line-task").find((t) => t.querySelector(".line-name")?.textContent === name)!;

describe("the painted labelled task", () => {
  it("is a task line under its goal with the working mark, [working], the dash and PR #N as a link, the crew under it", () => {
    const task = taskNamed("the-dashboard-shows-the-open-pr");
    expect(task).toBeDefined();
    // Chartered in round 6 of `sessions-workflow` (`goal.md` condition 2; the frame
    // `Sessions components`, "Task line": a task prints a pull request
    // number only when the number is not its goal's): the word is
    // `[build]`, and the label's `PR #176` is the goal's, so the link is
    // on the goal's line.
    expect(cellsOf(task)).toEqual(["line-name=the-dashboard-shows-the-open-pr", "state running=[build]", "cost=–@2!"]);
    expect(task.querySelector(".mark")?.className).toBe("mark running");
    expect(task.querySelector(".line-name")?.title).toBe("round 2 · PR #176");
    expect(linkIn(goalNamed("foreman-flow").querySelector(".pr") ?? undefined)).toEqual(["pr-link", `${BASE}176`, "_blank", "noopener", "mark link wide", "PR #176"]);
    // The lines of the goal, in order: the labelled task first, its crew
    // under it, then the listed tasks as the package lists them.
    const goalLines = page.root.querySelectorAll(".line").filter((l) => l.classList.contains("line-task") || l.classList.contains("row-line"));
    expect(goalLines.map((l) => [l.className.split(" ").find((c) => c === "line-task" || c === "row-line"), l.querySelector(".line-name")?.textContent])).toEqual([
      ["line-task", "the-dashboard-shows-the-open-pr"],
      ["row-line", "crew-kitterm"],
      ["line-task", "the-ci-is-the-second-floor"],
      ["line-task", "the-pr-opens-first"],
      ["line-task", "map-the-path"],
      ["row-line", "crew-mdp"],
    ]);
  });

  it("prints the PR as plain text for a project with no pullRequestBase", () => {
    const task = taskNamed("map-the-path");
    // Chartered in round 6 of `sessions-workflow`: the number is on the goal's line,
    // as plain text.
    expect(cellsOf(task)).toEqual(["line-name=map-the-path", "state running=[build]", "cost=–@2!"]);
    expect(goalNamed("symbol-onboarding").querySelector(".pr")?.textContent).toBe("PR #41");
    expect(linkIn(goalNamed("symbol-onboarding").querySelector(".pr") ?? undefined)).toBeNull();
  });
});
