import { describe, expect, it } from "vitest";

import {
  taskFacts,
  taskLines,
  taskMark,
  taskOf,
  taskTag,
  type KnowledgeSummary,
  type ModelRow,
  type TaskState,
} from "./sessions-model";

/**
 * The fourth level of the fleet view (`agent-dashboard`, capability 3): a
 * goal's tasks from `STATE.md`, joined with the live `task:` label
 * `LOOP.md` gives a crew session. The fixture is this repository's own
 * `agent-dashboard` goal as it stood on 2026-09-18: five queued, two done.
 */
const ROOT = "/Users/antran/Workspace/kitterm";
const project = { id: "kitterm", name: "kitterm", root: ROOT, registered: true };

const dashboard: KnowledgeSummary = {
  project: "kitterm",
  slug: "agent-dashboard",
  status: "active",
  round: 2,
  budget: 3,
  tasks: [
    { slug: "a-task-is-the-fourth-level", state: "pending" },
    { slug: "the-band-replaces-the-strip", state: "pending" },
    { slug: "every-line-is-one-line", state: "pending" },
    { slug: "the-foundation-in-the-stylesheet", state: "done", round: 2, pr: 126 },
    { slug: "no-input-on-the-page", state: "done", round: 1, pr: 125 },
  ],
};

function row(id: string, labels: Record<string, string>, extra: Partial<ModelRow> = {}): ModelRow {
  return { id, cwd: `${ROOT}/.claude/worktrees/${id}`, project, mergedState: "working", labels, ...extra };
}

const crew = row("crew", { crew: "agent-dashboard", goal: "agent-dashboard", round: "3", task: "a-task-is-the-fourth-level" });
const helper = row("helper", { crew: "helper", goal: "agent-dashboard", round: "3", task: "a-task-is-the-fourth-level" }, { mergedState: "idle" });
const shell = row("shell", {}, { mergedState: "idle" });

describe("taskLines", () => {
  it("joins a live task: label under the same goal: label and carries its row", () => {
    const { tasks, rest } = taskLines(dashboard, [crew, shell], [crew, shell]);
    expect(tasks.map((t) => [t.slug, t.state])).toEqual([
      ["a-task-is-the-fourth-level", "working"],
      ["the-band-replaces-the-strip", "pending"],
      ["every-line-is-one-line", "pending"],
      ["the-foundation-in-the-stylesheet", "done"],
      ["no-input-on-the-page", "done"],
    ]);
    expect(tasks[0].rows.map((r) => r.id)).toEqual(["crew"]);
    expect(tasks[0].tag).toBe("[working]");
    expect(rest.map((r) => r.id), "the shell has no task and stays under the goal").toEqual(["shell"]);
  });

  it("keeps the daemon's order: queue, then failures, then done", () => {
    const failed: KnowledgeSummary = {
      ...dashboard,
      tasks: [
        { slug: "two", state: "pending" },
        { slug: "three", state: "failed", round: 3 },
        { slug: "one", state: "done", round: 1 },
      ],
    };
    const { tasks } = taskLines(failed, [], []);
    expect(tasks.map((t) => `${t.slug} ${t.tag}`)).toEqual(["two [pending]", "three [failed]", "one [done]"]);
    expect(tasks[1].facts).toEqual(["round 3"]);
  });

  it("holds a task at working from a session the page does not list, with no row under it", () => {
    // A crew in the attention strip is owned by the project but not listed
    // in its section (`cardRows`); its task is still the one running.
    const { tasks, rest } = taskLines(dashboard, [shell], [crew, shell]);
    expect(tasks[0].state).toBe("working");
    expect(tasks[0].rows).toEqual([]);
    expect(rest.map((r) => r.id)).toEqual(["shell"]);
  });

  it("nests every listed row with the label, the crew's helper included, in the group order", () => {
    const { tasks } = taskLines(dashboard, [helper, crew], [helper, crew]);
    expect(tasks[0].rows.map((r) => r.id)).toEqual(["crew", "helper"]);
  });

  it("leaves a task: label under another goal, or one that names no slug, out of the join", () => {
    const otherGoal = row("other", { goal: "workspace-ledger", task: "a-task-is-the-fourth-level" });
    const stray = row("stray", { goal: "agent-dashboard", task: "nowhere" });
    const noGoal = row("no-goal", { task: "a-task-is-the-fourth-level" });
    const { tasks, rest } = taskLines(dashboard, [otherGoal, stray, noGoal], [otherGoal, stray, noGoal]);
    expect(tasks.every((t) => t.state !== "working")).toBe(true);
    expect(tasks.every((t) => t.rows.length === 0)).toBe(true);
    expect(rest.map((r) => r.id)).toEqual(["other", "stray", "no-goal"]);
  });

  it("marks a task working when a live session runs it again after a failure", () => {
    const retried: KnowledgeSummary = { ...dashboard, tasks: [{ slug: "a-task-is-the-fourth-level", state: "failed", round: 2 }] };
    const { tasks } = taskLines(retried, [crew], [crew]);
    expect(tasks[0].state).toBe("working");
    expect(tasks[0].facts, "the round the failure names stays as a fact").toEqual(["round 2"]);
  });

  it("prints no task for a goal with none, and changes nothing under it", () => {
    const noSection: KnowledgeSummary = { project: "kitterm", slug: "agent-push", status: "done" };
    expect(taskLines(noSection, [crew, shell], [crew, shell])).toEqual({ tasks: [], rest: [crew, shell] });
    const emptyQueue: KnowledgeSummary = { ...noSection, tasks: [] };
    expect(taskLines(emptyQueue, [shell], [shell])).toEqual({ tasks: [], rest: [shell] });
    const noSlug: KnowledgeSummary = { project: "kitterm", tasks: [{ slug: "x", state: "pending" }] };
    const { tasks, rest } = taskLines(noSlug, [crew], [crew]);
    expect(tasks.map((t) => [t.state, t.rows])).toEqual([["pending", []]]);
    expect(rest).toEqual([crew]);
  });
});

describe("the task vocabulary", () => {
  it("reads every state as a bracketed word beside its mark, never a bare one", () => {
    const states: TaskState[] = ["working", "pending", "done", "failed"];
    expect(states.map(taskTag)).toEqual(["[working]", "[pending]", "[done]", "[failed]"]);
    expect(states.map(taskMark)).toEqual(["running", "pending", "done", "failed"]);
  });

  it("prints the round and the PR as facts, in that order, and nothing for neither", () => {
    expect(taskFacts({ slug: "x", state: "done", round: 1, pr: 118 })).toEqual(["round 1", "PR #118"]);
    expect(taskFacts({ slug: "x", state: "done", pr: 118 })).toEqual(["PR #118"]);
    expect(taskFacts({ slug: "x", state: "pending" })).toEqual([]);
  });

  it("reads the task: label and nothing else", () => {
    expect(taskOf(crew)).toBe("a-task-is-the-fourth-level");
    expect(taskOf(shell)).toBeNull();
    expect(taskOf(row("blank", { task: "" }))).toBeNull();
  });
});
