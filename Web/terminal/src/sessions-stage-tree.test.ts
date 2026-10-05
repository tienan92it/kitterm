import { describe, expect, it } from "vitest";

import { type KnowledgeSummary, type ModelRow, type ProjectSummary } from "./sessions-model";
import { projectPullsReason, pullsNotice, SESSION_LEGEND, STAGE_LEGEND, stageCounts, type PullRequest, type PullsAnswer, type StagedSummary } from "./sessions-stage";
import { homePath, isOpen, joins, tree, visibleLines, type TreeLine } from "./sessions-tree";

/**
 * The tree with the stages wired in (`sessions-workflow`, capability 5; the
 * frames `Sessions 1200`, `Sessions 390` and `Sessions components` of
 * `design/sessions.pen`, and the three rules of
 * `corpus/01-approved-design.md`). The pure model only: what each line
 * prints, in what order, what starts closed, and the hairline joins.
 * `sessions-stage.test.ts` pins the table that decides a stage; this file
 * pins what the tree does with it.
 */

const NOW = Date.parse("2026-10-05T12:00:00Z");
const BASE = "https://github.com/tienan92it/kitterm/pull/";
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: "/Users/an/Workspace/kitterm", registered: true, knowledge: "docs/goals", pullRequestBase: BASE };
const ref = (p: ProjectSummary) => ({ id: p.id, name: p.name, root: p.root, registered: p.registered });

const pull = (number: number, head: string, extra: Partial<PullRequest> = {}): PullRequest => ({
  number, headRefName: head, state: "open", draft: false, url: `${BASE}${number}`, ...extra,
});
const goal = (slug: string, extra: Partial<StagedSummary> = {}): StagedSummary => ({ project: "kitterm", slug, goal: `the purpose of ${slug}`, status: "active", round: 1, budget: 3, ...extra });

const goals: StagedSummary[] = [
  goal("command-failed-event", { round: 0 }),
  goal("sessions-workflow", {
    tasks: [{ slug: "stage-tree", state: "pending", pr: 185 }, { slug: "line-stage", state: "done", round: 5, pr: 185 }],
  }),
  goal("foreman-scope", { tasks: [{ slug: "scope-in-the-texts", state: "done", round: 1 }] }),
  goal("green-ci-again", { tasks: [{ slug: "one-more-run", state: "pending" }, { slug: "twenty-green-runs", state: "failed", round: 2 }, { slug: "first-run", state: "done", round: 1 }] }),
  goal("demo-backend", { proposals: 20, round: 2 }),
  goal("cost-per-round", {
    status: "done", round: 4, budget: 4,
    tasks: [{ slug: "the-join-checks-its-pane", state: "done", round: 4, pr: 182 }, { slug: "the-ledger-prints-api-time", state: "done", round: 3, pr: 160 }],
    rounds: [{ number: 4, started: "2026-09-13", pr: 182, correction: false }],
  }),
];
const pulls: PullRequest[] = [
  pull(2888, "goal/demo-backend", { ci: "passing" }),
  pull(185, "goal/sessions-workflow", { draft: true, ci: "pending" }),
  pull(182, "fix/the-join", { state: "merged" }),
  pull(180, "goal/foreman-scope", { ci: "passing" }),
  pull(156, "goal/green-ci-again", { ci: "failing" }),
];
const answer: PullsAnswer = { ok: true, project: "kitterm", readAt: NOW - 30_000, pulls };

const crew: ModelRow = {
  id: "s-crew", name: "sessions-workflow round 6", cwd: `${kitterm.root}/.claude/worktrees/x`, mergedState: "working", project: ref(kitterm),
  labels: { goal: "sessions-workflow", task: "stage-tree", round: "6", pr: "185" }, lastOutputAt: NOW - 5_000,
};
/** A finished review session under `foreman-scope`: it dates the wait. */
const reviewer: ModelRow = { id: "s-rev", name: "review", cwd: kitterm.root!, mergedState: "completed", project: ref(kitterm), labels: { goal: "foreman-scope" }, lastOutputAt: NOW - 40 * 60_000 };
const foreman: ModelRow = { id: "s-foreman", name: "foreman", cwd: kitterm.root!, mergedState: "needs-input", project: ref(kitterm), labels: { crew: "foreman" }, lastOutputAt: NOW - 4 * 60_000 };

const build = (over: { rows?: ModelRow[]; projects?: ProjectSummary[]; goalsOf?: (id: string) => KnowledgeSummary[] | null; pullsOf?: ((id: string) => PullsAnswer | null | undefined) | null } = {}) =>
  tree({
    rows: over.rows ?? [crew, reviewer, foreman],
    projects: over.projects ?? [kitterm],
    goalsOf: over.goalsOf ?? (() => goals),
    approvals: [], proposed: [], usage: null,
    ...(over.pullsOf === null ? {} : { pullsOf: over.pullsOf ?? (() => answer) }),
    now: NOW,
  });
const linesOf = (built = build()): TreeLine<ModelRow>[] => built.sections[0].lines;
const named = (lines: TreeLine<ModelRow>[], name: string) => lines.find((l) => l.name === name)!;
const factsOf = (line: TreeLine<ModelRow>) => line.facts.map((f) => `${f.kind}:${f.text}@${f.column}`);

describe("a goal line", () => {
  const lines = linesOf();
  const goalLines = lines.filter((l) => l.kind === "goal");

  it("prints exactly one stage word, with the mark of its stage, in the order blocked, review, build, plan, done", () => {
    expect(goalLines.map((l) => [l.name, l.state?.tag, l.state?.family])).toEqual([
      ["green-ci-again", "[blocked]", "failed"],
      ["demo-backend", "[blocked]", "attention"],
      ["foreman-scope", "[review]", "attention"],
      ["sessions-workflow", "[build]", "running"],
      ["command-failed-event", "[plan]", "pending"],
      ["cost-per-round", "[done]", "done"],
    ]);
  });

  it("is named by its slug, with its purpose after it, or the reason when it is blocked", () => {
    expect(goalLines.map((l) => l.detail)).toEqual([
      "CI fails on PR #156",
      "20 proposals wait on you",
      "the purpose of foreman-scope",
      "the purpose of sessions-workflow",
      "the purpose of command-failed-event",
      "the purpose of cost-per-round",
    ]);
    // A goal whose title is its slug prints no second copy of it.
    const same = linesOf(build({ goalsOf: () => [goal("alpha", { goal: "alpha" })] }));
    expect(named(same, "alpha").detail).toBeNull();
  });

  it("prints its pull request as a link to the pull request's page, with the state words and the one word a phone keeps", () => {
    const pr = (name: string) => named(lines, name).facts.find((f) => f.kind === "pr");
    expect(["green-ci-again", "demo-backend", "foreman-scope", "sessions-workflow", "cost-per-round"].map((name) => [pr(name)?.text, pr(name)?.href, pr(name)?.words, pr(name)?.word])).toEqual([
      ["PR #156", `${BASE}156`, ["ready", "CI ✗"], "CI ✗"],
      ["PR #2888", `${BASE}2888`, ["ready", "CI ✓"], "CI ✓"],
      ["PR #180", `${BASE}180`, ["ready", "CI ✓"], "CI ✓"],
      ["PR #185", `${BASE}185`, ["draft", "CI …"], "draft"],
      ["PR #182", `${BASE}182`, ["merged"], "merged"],
    ]);
    expect(pr("command-failed-event")).toBeUndefined();
    expect(pr("sessions-workflow")?.column).toBe(3);
  });

  it("prints how long a blocked or a review line waits in the last column, else the round counter, and nothing when it is done", () => {
    const last = (name: string) => named(lines, name).facts.filter((f) => f.column === 4).map((f) => `${f.kind}:${f.text}`);
    expect(last("foreman-scope")).toEqual(["wait:waits 40m"]);
    expect(last("sessions-workflow")).toEqual(["counter:r1/3"]);
    expect(last("command-failed-event")).toEqual(["counter:r0/3"]);
    expect(last("cost-per-round")).toEqual([]);
    // A blocked line with no dated wait keeps its counter.
    expect(last("demo-backend")).toEqual(["counter:r2/3"]);
  });
});

describe("a task line", () => {
  const lines = linesOf();
  const tasksUnder = (name: string): TreeLine<ModelRow>[] => {
    const at = lines.findIndex((l) => l.name === name);
    const out: TreeLine<ModelRow>[] = [];
    for (const line of lines.slice(at + 1)) {
      if (line.depth <= lines[at].depth) break;
      if (line.kind === "task") out.push(line);
    }
    return out;
  };

  it("prints its stage word and mark, the blocked one first, with the reason after its name", () => {
    expect(tasksUnder("green-ci-again").map((l) => [l.name, l.state?.tag, l.kind === "task" && l.mark, l.detail])).toEqual([
      ["twenty-green-runs", "[blocked]", "failed", "under ## Failures"],
      ["one-more-run", "[plan]", "pending", null],
      ["first-run", "[done]", "done", null],
    ]);
    expect(tasksUnder("sessions-workflow").map((l) => [l.name, l.state?.tag])).toEqual([["stage-tree", "[build]"], ["line-stage", "[done]"]]);
  });

  it("prints a pull request number only when the number is not its goal's", () => {
    // PR #185 is the goal's, by its `goal/<slug>` head: the tasks print none.
    expect(tasksUnder("sessions-workflow").map(factsOf)).toEqual([[], []]);
    expect(tasksUnder("sessions-workflow").map((l) => l.title)).toEqual(["PR #185", "round 5 · PR #185"]);
    // The earlier flow gave each task its own pull request: the goal has
    // its number from a record, and each task keeps its own.
    expect(tasksUnder("cost-per-round").map(factsOf)).toEqual([["pr:PR #182@3"], ["pr:PR #160@3"]]);
  });

  it("wears a triangle when a session sits under it, and folds it", () => {
    const task = named(lines, "stage-tree");
    expect(task.kind === "task" && task.children).toBe(true);
    expect(named(lines, "line-stage").kind === "task" && (named(lines, "line-stage") as Extract<TreeLine<ModelRow>, { kind: "task" }>).children).toBe(false);
    const closed = visibleLines(lines, new Set([task.key])).map((l) => l.name);
    expect(closed).toContain("stage-tree");
    expect(closed).not.toContain("sessions-workflow round 6");
  });
});

describe("a session line", () => {
  it("keeps its own word, and prints the wait when it waits on a person", () => {
    const lines = linesOf();
    expect([named(lines, "foreman").state?.tag, factsOf(named(lines, "foreman"))]).toEqual(["[needs you]", ["since:waits 4m@4"]]);
    expect([named(lines, "sessions-workflow round 6").state?.tag, factsOf(named(lines, "sessions-workflow round 6"))]).toEqual(["[working]", ["since:now@4"]]);
  });
});

describe("the closed defaults (approved rule 3)", () => {
  it("starts a goal with no open task closed, and keeps one with an open task or a session open", () => {
    const lines = linesOf();
    const closed = (name: string) => { const l = named(lines, name); return l.kind === "goal" ? [l.children, l.closed ?? false, isOpen(l, new Set())] : null; };
    // Only a done task under it, and a session: open.
    expect(closed("foreman-scope")).toEqual([true, false, true]);
    // Only a done task under it: closed, and its task is not painted.
    const quiet = linesOf(build({ rows: [] }));
    const scope = named(quiet, "foreman-scope");
    expect(scope.kind === "goal" && [scope.children, scope.closed, isOpen(scope, new Set())]).toEqual([true, true, false]);
    expect(visibleLines(quiet, new Set()).map((l) => l.name)).not.toContain("scope-in-the-texts");
    expect(visibleLines(quiet, new Set([scope.key])).map((l) => l.name)).toContain("scope-in-the-texts");
    // A queued or a failed task, or a session: open.
    expect(closed("green-ci-again")).toEqual([true, false, true]);
    expect(closed("sessions-workflow")).toEqual([true, false, true]);
    // Nothing under it: no triangle to close.
    expect(closed("command-failed-event")).toEqual([false, false, true]);
    // The project's latest done goal shows open, as before.
    expect(closed("cost-per-round")).toEqual([true, false, true]);
  });

  it("starts a project with every goal done and no live session closed, with its count on its line", () => {
    const done = [goal("a", { status: "done" }), goal("b", { status: "done" })];
    const quiet = linesOf(build({ rows: [], goalsOf: () => done }));
    const head = quiet[0];
    expect(head.kind === "project" && [head.closed, head.detail, isOpen(head, new Set())]).toEqual([true, "~/Workspace/kitterm · 2 done", false]);
    expect(visibleLines(quiet, new Set()).map((l) => l.name)).toEqual(["kitterm"]);
    expect(visibleLines(quiet, new Set([head.key])).length).toBeGreaterThan(1);
    // A live session keeps it open.
    const live = linesOf(build({ rows: [foreman], goalsOf: () => done }))[0];
    expect(live.kind === "project" && live.closed).toBeUndefined();
    // So does a goal that is not done, and a project with no goal.
    expect((linesOf()[0] as Extract<TreeLine<ModelRow>, { kind: "project" }>).closed).toBeUndefined();
    expect((linesOf(build({ rows: [], goalsOf: () => [] }))[0] as Extract<TreeLine<ModelRow>, { kind: "project" }>).closed).toBeUndefined();
  });
});

describe("a scope line", () => {
  const W = "/Users/an/Workspace/NgheNhanTrading";
  const mono: ProjectSummary = { id: "mono", name: "nghenhan-monorepo", root: `${W}/nghenhan-monorepo`, registered: true, knowledge: "docs/goals", pullRequestBase: BASE };
  const mdp: ProjectSummary = { id: "mdp", name: "market-data-pipeline", root: `${W}/market-data-pipeline`, registered: true, knowledge: "docs/goals", pullRequestBase: BASE };
  const backend: ProjectSummary = { id: "backend", name: "backend", root: `${W}/backend`, registered: true, knowledge: "docs/goals", pullRequestBase: BASE };
  const of: Record<string, StagedSummary[]> = {
    mono: [{ project: "mono", slug: "demo-app", status: "active" }, { project: "mono", slug: "demo-frontend", status: "active", proposals: 3 }],
    mdp: [{ project: "mdp", slug: "bars", status: "done" }, { project: "mdp", slug: "ticks", status: "done" }],
    backend: [{ project: "backend", slug: "reset-index", status: "active" }],
  };
  const crewRow: ModelRow = { id: "s-m", name: "crew", cwd: mono.root!, mergedState: "working", project: ref(mono), labels: { goal: "demo-app" }, lastOutputAt: NOW };
  const lines = linesOf(build({ rows: [crewRow], projects: [backend, mdp, mono], goalsOf: (id) => of[id] ?? null, pullsOf: () => ({ ok: true, readAt: NOW, pulls: [] }) }));

  it("prints a lone project's path and its goals counted by stage, in the stage order", () => {
    expect(linesOf()[0].detail).toBe("~/Workspace/kitterm · 2 blocked · 1 review · 1 build · 1 plan · 1 done");
    expect(homePath("/home/an/x")).toBe("~/x");
    expect(homePath("/Users/an")).toBe("~");
    expect(homePath("/srv/x")).toBe("/srv/x");
  });

  it("prints a workspace's path, its projects and the counts of all their goals, and each project's own counts", () => {
    expect(lines.filter((l) => l.kind === "workspace" || l.kind === "project").map((l) => [l.kind, l.name, l.detail])).toEqual([
      ["workspace", "NgheNhanTrading", "~/Workspace/NgheNhanTrading · 3 projects · 1 blocked · 1 build · 1 plan · 2 done"],
      // The project whose goal waits on the human first, the done one last.
      ["project", "nghenhan-monorepo", "1 blocked · 1 build"],
      ["project", "backend", "1 plan"],
      ["project", "market-data-pipeline", "2 done"],
    ]);
  });

  it("gives the workspace a triangle that folds everything under it", () => {
    const head = lines[0];
    expect(head.kind === "workspace" && head.children).toBe(true);
    expect(visibleLines(lines, new Set([head.key])).map((l) => l.name)).toEqual(["NgheNhanTrading"]);
  });
});

describe("no pull request state (goal.md, condition 6)", () => {
  it("prints the numbers as before and no state word when the page holds no answer", () => {
    for (const pullsOf of [(): null => null, (): PullsAnswer => ({ ok: true, pulls: [], reason: "not read yet" }), (): PullsAnswer => ({ ok: true, pulls: [], reason: "gh is not on PATH" })]) {
      const lines = linesOf(build({ pullsOf }));
      const pr = named(lines, "sessions-workflow").facts.find((f) => f.kind === "pr");
      // The number comes from the session's `pr:` label; the link from the base.
      expect([pr?.text, pr?.href, pr?.words, pr?.word]).toEqual(["PR #185", `${BASE}185`, undefined, undefined]);
      expect(named(lines, "sessions-workflow").state?.tag).toBe("[build]");
      // The machine-wide reasons are the REVIEW line's; the project says nothing.
      expect(lines[0].detail?.startsWith("~/Workspace/kitterm · ")).toBe(true);
    }
  });

  it("says on the project's line why its pull requests carry no state: no GitHub remote, or the failure of gh", () => {
    const bare = linesOf(build({ projects: [{ ...kitterm, pullRequestBase: undefined }], pullsOf: () => undefined }));
    expect(bare[0].detail).toBe("no GitHub remote: pull request states are not read");
    // Plain text with no base.
    expect(named(bare, "sessions-workflow").facts.find((f) => f.kind === "pr")?.href).toBeUndefined();
    const failed = linesOf(build({ pullsOf: () => ({ ok: true, readAt: NOW - 14 * 60_000, pulls, reason: "gh pr list exited 1: HTTP 502" }) }));
    expect(failed[0].detail).toBe("gh failed: HTTP 502 · read 14m ago");
    // A project with no goal has no pull request to explain.
    expect(linesOf(build({ projects: [{ ...kitterm, pullRequestBase: undefined }], goalsOf: () => [], pullsOf: () => undefined }))[0].detail).toBe("~/Workspace/kitterm");
  });

  it("says nothing at all on a page that reads no pull request state (a watch page)", () => {
    const lines = linesOf(build({ projects: [{ ...kitterm, pullRequestBase: undefined }], pullsOf: null }));
    expect(lines[0].detail?.includes("pull request")).toBe(false);
    expect(named(lines, "sessions-workflow").facts.find((f) => f.kind === "pr")?.words).toBeUndefined();
  });

  it("words each reason", () => {
    expect(pullsNotice([null, { ok: true, pulls: [], reason: "gh is not on PATH" }])).toEqual({ text: "Pull request states are not read: gh is not installed." });
    expect(pullsNotice([{ ok: true, pulls: [], reason: "gh is not logged in" }])).toEqual({ text: "Pull request states are not read: gh is not logged in. Run", command: "gh auth login" });
    expect(pullsNotice([answer, undefined, { ok: true, pulls: [], reason: "not read yet" }])).toBeNull();
    const base = { pullRequestBase: BASE };
    expect(projectPullsReason(base, answer, NOW)).toBeNull();
    expect(projectPullsReason(base, null, NOW)).toBeNull();
    expect(projectPullsReason(base, { ok: true, pulls: [], reason: "not read yet" }, NOW)).toBeNull();
    expect(projectPullsReason(base, { ok: true, pulls: [], reason: "gh is not logged in" }, NOW)).toBeNull();
    expect(projectPullsReason(base, { ok: true, pulls: [], reason: "no GitHub remote" }, NOW)).toBe("no GitHub remote: pull request states are not read");
    expect(projectPullsReason(base, { ok: true, pulls: [], reason: "gh pr list timed out after 20 s" }, NOW)).toBe("gh failed: timed out after 20 s");
    expect(projectPullsReason(base, { ok: true, pulls: [], readAt: NOW - 5_000, reason: "gh pr list printed no JSON list" }, NOW)).toBe("gh failed: printed no JSON list · read just now");
  });
});

describe("the legend and the counts", () => {
  it("lists the five stages, [blocked] with its two marks, then the words a session keeps", () => {
    expect(STAGE_LEGEND.map((e) => [e.tag, ...e.families])).toEqual([
      ["[plan]", "pending"], ["[build]", "running"], ["[review]", "attention"], ["[blocked]", "attention", "failed"], ["[done]", "done"],
    ]);
    expect(SESSION_LEGEND.map((e) => [e.tag, ...e.families])).toEqual([["[working]", "running"], ["[needs you]", "attention"], ["[idle]", "idle"]]);
  });

  it("counts the goals of a scope by stage, in the stage order, and says nothing for none", () => {
    expect(stageCounts(["done", "build", "blocked", "done", "blocked"])).toBe("2 blocked · 1 build · 2 done");
    expect(stageCounts(["done"])).toBe("1 done");
    expect(stageCounts([])).toBeNull();
  });
});

describe("the hairline joins (rule 4)", () => {
  const at = (...depths: number[]) => joins(depths.map((depth) => ({ depth }))).map((cells) => cells.join(" "));

  it("gives a top-level line no cell and each line below it one cell per level", () => {
    expect(at(0)).toEqual([""]);
    expect(at(0, 1, 1)).toEqual(["", "tee", "end"]);
  });

  it("runs a parent's line by its children while a sibling follows, and stops at the last child", () => {
    //            ws  foreman  project  goal         task   session  task   goal   project
    expect(at(0, 1, 1, 2, 3, 4, 3, 2, 1)).toEqual([
      "",
      "tee",
      "tee",
      "pass tee",
      "pass pass tee",
      "pass pass pass end",
      "pass pass end",
      "pass end",
      "end",
    ]);
    // Under a last child nothing runs by at its level.
    expect(at(0, 1, 2, 2)).toEqual(["", "end", "none tee", "none end"]);
  });

  it("keeps the fold's own cells above the lines inside it", () => {
    // The lines inside `N done` at depth 1 under a workspace's project at
    // depth 2: the levels above come from the fold's line.
    expect(joins([{ depth: 2 }, { depth: 3 }, { depth: 2 }], ["pass", "end"]).map((cells) => cells.join(" "))).toEqual(["pass tee", "pass pass end", "pass end"]);
  });

  it("ties every painted line of the tree to its parent", () => {
    const lines = visibleLines(linesOf(), new Set());
    const cells = joins(lines);
    expect(cells.map((c) => c.length)).toEqual(lines.map((l) => l.depth));
    // The last line of the section is a last child at its level.
    expect(cells[cells.length - 1].at(-1)).toBe("end");
  });
});
