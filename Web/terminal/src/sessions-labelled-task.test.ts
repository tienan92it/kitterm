import { describe, expect, it } from "vitest";

import { rollup } from "./range-fixture";
import { prOf, taskLines, type KnowledgeSummary, type ModelRow, type ProjectSummary } from "./sessions-model";
import { NO_FACT, tree, type TreeLine } from "./sessions-tree";

/**
 * The task line a running round draws from its labels (`foreman-flow`,
 * capability 2). The daemon reads `STATE.md` from the main checkout, and a
 * round's queue line lives on its branch until the pull request merges, so
 * the fleet view showed no task and no PR for a running round. Now a live
 * session that carries `goal:<slug>`, `task:<slug>` and `pr:<N>` for a slug
 * `STATE.md` does not list is a task line of its own: the working mark,
 * `[working]`, the dash in the cost column (no record yet) and `PR #N` as a
 * link through the project's `pullRequestBase`. A listed task whose line
 * names no PR takes the label's; one with its own keeps it. The fixture is
 * this goal as it stood in round 2: `STATE.md` on `main` lists round 1 done
 * and two queued items, and the round's own item is on the branch.
 */
const NOW = Date.now();
const ROOT = "/w/kitterm";
const BASE = "https://github.com/tienan92it/kitterm/pull/";
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: ROOT, registered: true, knowledge: "docs/goals", pullRequestBase: BASE };
const ref = { id: kitterm.id, name: kitterm.name, root: ROOT, registered: true };
const quarter = { from: "2026-01-01", to: "2026-12-31" };

const foremanFlow: KnowledgeSummary = {
  project: "kitterm",
  slug: "foreman-flow",
  status: "active",
  round: 1,
  budget: 3,
  tasks: [
    { slug: "the-ci-is-the-second-floor", state: "pending" },
    { slug: "the-bookkeeping-is-a-command", state: "pending", pr: 180 },
    { slug: "the-pr-opens-first", state: "done", round: 1, pr: 176 },
  ],
  rounds: [{ number: 1, started: "2026-09-29", costUSD: 5.23, pr: 176, correction: false }],
};

function row(id: string, labels: Record<string, string>, extra: Partial<ModelRow> = {}): ModelRow {
  return { id, name: id, cwd: `${ROOT}/.claude/worktrees/foreman-flow`, state: "running", mergedState: "working", marks: 0, project: ref, labels, lastOutputAt: NOW - 60_000, ...extra } as ModelRow;
}

const crew = row("crew", { crew: "foreman-flow", goal: "foreman-flow", round: "2", task: "the-dashboard-shows-the-open-pr", pr: "176" });

describe("prOf", () => {
  it("reads the pr: label as a whole number and nothing else", () => {
    expect(prOf(crew)).toBe(176);
    expect(prOf(row("none", {}))).toBeNull();
    expect(prOf(row("word", { pr: "#176" }))).toBeNull();
    expect(prOf(row("blank", { pr: "" }))).toBeNull();
  });
});

describe("taskLines with a labelled task STATE.md does not list", () => {
  it("draws the task first, working, with the label's PR and round, and its session under it", () => {
    const { tasks, rest } = taskLines(foremanFlow, [crew], [crew]);
    expect(tasks.map((t) => [t.slug, t.state, t.tag, t.pr ?? null, t.round ?? null, t.facts])).toEqual([
      ["the-dashboard-shows-the-open-pr", "working", "[working]", 176, 2, ["round 2", "PR #176"]],
      ["the-ci-is-the-second-floor", "pending", "[pending]", null, null, []],
      ["the-bookkeeping-is-a-command", "pending", "[pending]", 180, null, ["PR #180"]],
      ["the-pr-opens-first", "done", "[done]", 176, 1, ["round 1", "PR #176"]],
    ]);
    expect(tasks[0].rows.map((r) => r.id)).toEqual(["crew"]);
    expect(rest).toEqual([]);
  });

  it("draws one line per slug when two sessions carry it, and holds the task from a session the page does not list", () => {
    const helper = row("helper", { crew: "helper", goal: "foreman-flow", round: "2", task: "the-dashboard-shows-the-open-pr", pr: "176" }, { mergedState: "idle" });
    const { tasks } = taskLines(foremanFlow, [helper, crew], [helper, crew]);
    expect(tasks.filter((t) => t.slug === "the-dashboard-shows-the-open-pr")).toHaveLength(1);
    expect(tasks[0].rows.map((r) => r.id)).toEqual(["crew", "helper"]);
    const unlisted = taskLines(foremanFlow, [], [crew]);
    expect(unlisted.tasks[0]).toMatchObject({ slug: "the-dashboard-shows-the-open-pr", state: "working", pr: 176, rows: [] });
  });

  it("omits the round when the session carries no round: label", () => {
    const noRound = row("crew", { goal: "foreman-flow", task: "the-dashboard-shows-the-open-pr", pr: "176" });
    const { tasks } = taskLines(foremanFlow, [noRound], [noRound]);
    expect(tasks[0]).not.toHaveProperty("round");
    expect(tasks[0].facts).toEqual(["PR #176"]);
  });

  it("gives a listed task without a PR the label's, and keeps a listed task's own", () => {
    const ci = row("ci", { goal: "foreman-flow", task: "the-ci-is-the-second-floor", pr: "177" });
    const books = row("books", { goal: "foreman-flow", task: "the-bookkeeping-is-a-command", pr: "999" });
    const { tasks } = taskLines(foremanFlow, [ci, books], [ci, books]);
    expect(tasks.map((t) => [t.slug, t.state, t.pr ?? null, t.facts])).toEqual([
      ["the-ci-is-the-second-floor", "working", 177, ["PR #177"]],
      ["the-bookkeeping-is-a-command", "working", 180, ["PR #180"]],
      ["the-pr-opens-first", "done", 176, ["round 1", "PR #176"]],
    ]);
    expect(tasks[0].rows.map((r) => r.id)).toEqual(["ci"]);
  });

  it("adds nothing for a session with pr: and no task:, or task: and no pr:, or under another goal", () => {
    const prOnly = row("pr-only", { goal: "foreman-flow", round: "2", pr: "176" });
    const taskOnly = row("task-only", { goal: "foreman-flow", task: "the-dashboard-shows-the-open-pr" });
    const otherGoal = row("other", { goal: "agent-dashboard", task: "a-task", pr: "5" });
    const { tasks, rest } = taskLines(foremanFlow, [prOnly, taskOnly, otherGoal], [prOnly, taskOnly, otherGoal]);
    expect(tasks.map((t) => t.slug)).toEqual(["the-ci-is-the-second-floor", "the-bookkeeping-is-a-command", "the-pr-opens-first"]);
    expect(tasks.every((t) => t.state !== "working" && t.rows.length === 0)).toBe(true);
    expect(rest.map((r) => r.id)).toEqual(["pr-only", "task-only", "other"]);
  });

  it("prints no line for a goal with no tasks key when the labels name one, so a package before capability 3 is unchanged", () => {
    // A summary with no `tasks` prints no task and changes nothing
    // (`sessions-tasks.test.ts`); the label alone does not open the level.
    const { tasks, rest } = taskLines({ project: "kitterm", slug: "foreman-flow", status: "active" }, [crew], [crew]);
    expect(tasks.map((t) => t.slug)).toEqual(["the-dashboard-shows-the-open-pr"]);
    expect(rest).toEqual([]);
  });
});

describe("the tree", () => {
  const lines = (projects: ProjectSummary[]): TreeLine<ModelRow>[] =>
    tree({ rows: [crew], projects, goalsOf: () => [foremanFlow], approvals: [], proposed: [], usage: rollup(quarter, NOW), now: NOW }).sections[0].lines;

  it("draws the labelled task under its goal with the working mark, the dash for its cost and PR #N as a link, the session under it", () => {
    const all = lines([kitterm]);
    expect(all.map((l) => [l.kind, l.depth, l.name, l.state?.tag ?? null])).toEqual([
      ["project", 0, "kitterm", null],
      ["goal", 1, "foreman-flow", "[working]"],
      ["task", 2, "the-dashboard-shows-the-open-pr", "[working]"],
      ["session", 3, "crew", "[working]"],
      ["task", 2, "the-ci-is-the-second-floor", "[pending]"],
      ["task", 2, "the-bookkeeping-is-a-command", "[pending]"],
      ["task", 2, "the-pr-opens-first", "[done]"],
    ]);
    const task = all[2];
    expect(task.kind === "task" && task.mark).toBe("running");
    expect(task.title).toBe("round 2 · PR #176");
    expect(task.facts.map((f) => [f.kind, f.text, f.column, f.href ?? null])).toEqual([
      ["cost", NO_FACT, 2, null],
      ["pr", "PR #176", 3, `${BASE}176`],
    ]);
    // The listed done task keeps its record's cost beside the same link.
    expect(all[6].facts.map((f) => [f.kind, f.text, f.href ?? null])).toEqual([["cost", "$5.23", null], ["pr", "PR #176", `${BASE}176`]]);
  });

  it("prints the PR as plain text when the project has no pullRequestBase", () => {
    const task = lines([{ ...kitterm, pullRequestBase: undefined }])[2];
    expect(task.facts.map((f) => [f.kind, f.text, f.href ?? null])).toEqual([["cost", NO_FACT, null], ["pr", "PR #176", null]]);
  });
});
