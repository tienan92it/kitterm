import { describe, expect, it } from "vitest";

import type { ModelRow, TaskSummary } from "./sessions-model";
import {
  PULL_WORDS,
  REVIEW_NONE,
  STAGE_ORDER,
  byStage,
  draftsLabel,
  goalPull,
  goalStage,
  pullStateWord,
  pullStateWords,
  readPulls,
  reviewHead,
  reviewLine,
  sortByStage,
  stageMark,
  stageTag,
  taskStage,
  waitLabel,
  type PullRequest,
  type PullsAnswer,
  type Stage,
  type StagedSummary,
} from "./sessions-stage";

/**
 * The stage table of `docs/goals/sessions-workflow/corpus/00-request.md`
 * with the three rules of `corpus/01-approved-design.md`: one case per row
 * and per level (`sessions-workflow`, capability 4).
 */
const ROOT = "/Users/antran/Workspace/kitterm";
const project = { id: "kitterm", name: "kitterm", root: ROOT, registered: true };
const NOW = new Date(2026, 9, 5, 18, 0).getTime();
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;

function goal(extra: Partial<StagedSummary> = {}): StagedSummary {
  return { project: "kitterm", slug: "sessions-workflow", status: "active", ...extra };
}

function row(id: string, labels: Record<string, string>, extra: Partial<ModelRow> = {}): ModelRow {
  return { id, cwd: `${ROOT}/.claude/worktrees/${id}`, project, mergedState: "working", labels, ...extra };
}

function crew(extra: Partial<ModelRow> = {}, labels: Record<string, string> = {}): ModelRow {
  return row("crew", { goal: "sessions-workflow", ...labels }, extra);
}

function pull(extra: Partial<PullRequest> = {}): PullRequest {
  return {
    number: 185,
    state: "open",
    draft: true,
    headRefName: "goal/sessions-workflow",
    url: "https://github.com/tienan92it/kitterm/pull/185",
    ...extra,
  };
}

describe("goalStage: one case per row of the table", () => {
  it("blocked on a person: a session under it is needs-input", () => {
    const stage = goalStage(goal(), [crew({ mergedState: "needs-input" })], [pull()]);
    expect(stage).toMatchObject({ stage: "blocked", cause: "person", reason: "its session needs you" });
  });

  it("blocked on a person: a session under it is needs-approval", () => {
    expect(goalStage(goal(), [crew({ mergedState: "needs-approval" })], [])).toMatchObject({ stage: "blocked", cause: "person" });
  });

  it("blocked by a failure: a session under it is failed", () => {
    const stage = goalStage(goal(), [crew({ mergedState: "failed" })], []);
    expect(stage).toMatchObject({ stage: "blocked", cause: "failure", reason: "its session failed" });
  });

  it("blocked on a person: its status is waiting, or stopped", () => {
    expect(goalStage(goal({ status: "waiting" }), [], [])).toMatchObject({ stage: "blocked", cause: "person", reason: "its status is waiting" });
    expect(goalStage(goal({ status: "stopped" }), [], [])).toMatchObject({ stage: "blocked", cause: "person", reason: "its status is stopped" });
  });

  it("blocked on a person: a proposal waits on the human", () => {
    expect(goalStage(goal({ proposals: 20 }), [], [])).toMatchObject({ stage: "blocked", cause: "person", reason: "20 proposals wait on you" });
    expect(goalStage(goal({ proposals: 1 }), [], []).reason).toBe("1 proposal waits on you");
  });

  it("blocked by a failure: its pull request's CI fails, ready or draft", () => {
    expect(goalStage(goal(), [], [pull({ draft: false, ci: "failing" })])).toMatchObject({ stage: "blocked", cause: "failure", reason: "CI fails on PR #185" });
    expect(goalStage(goal(), [crew()], [pull({ draft: true, ci: "failing" })])).toMatchObject({ stage: "blocked", cause: "failure" });
  });

  it("review: its pull request is open and not a draft", () => {
    expect(goalStage(goal(), [], [pull({ draft: false, ci: "passing" })]).stage).toBe("review");
    expect(goalStage(goal(), [], [pull({ draft: false, ci: "pending" })]).stage).toBe("review");
    expect(goalStage(goal(), [], [pull({ draft: false })]).stage).toBe("review");
  });

  it("review wins over build: a crew still works under a ready pull request", () => {
    expect(goalStage(goal(), [crew()], [pull({ draft: false })]).stage).toBe("review");
  });

  it("build: a live crew session carries its goal: label", () => {
    expect(goalStage(goal(), [crew()], [pull()])).toEqual({ stage: "build" });
    expect(goalStage(goal(), [crew({ mergedState: "completed" })], [pull()]).stage).toBe("build");
  });

  it("build needs a live session of this goal: an exited one, or another goal's, is none", () => {
    expect(goalStage(goal(), [crew({ mergedState: "exited" })], []).stage).toBe("plan");
    expect(goalStage(goal(), [row("other", { goal: "cost-per-round" })], []).stage).toBe("plan");
    expect(goalStage(goal(), [row("foreman", { crew: "foreman" }, { mergedState: "needs-input" })], []).stage).toBe("plan");
  });

  it("done: its status is done", () => {
    expect(goalStage(goal({ status: "done" }), [], [])).toEqual({ stage: "done" });
  });

  it("done: its pull request is merged", () => {
    expect(goalStage(goal(), [], [pull({ state: "merged", draft: false })])).toEqual({ stage: "done" });
  });

  it("plan: any other active goal, with queued work, no live crew and no ready pull request", () => {
    expect(goalStage(goal({ tasks: [{ slug: "line-stage", state: "pending" }] }), [], [pull()])).toEqual({ stage: "plan" });
    expect(goalStage(goal(), [], [])).toEqual({ stage: "plan" });
  });
});

describe("goalStage: the three approved rules", () => {
  it("rule 1: done wins over a waiting proposal and over the status rows", () => {
    expect(goalStage(goal({ status: "done", proposals: 3 }), [crew({ mergedState: "needs-input" })], []).stage).toBe("done");
    expect(goalStage(goal({ status: "waiting", proposals: 3 }), [], [pull({ state: "merged" })]).stage).toBe("done");
  });

  it("rule 2: a person blocks with the warning mark, a failure with the danger mark, one word", () => {
    const person = goalStage(goal({ proposals: 1 }), [], []);
    const failure = goalStage(goal(), [], [pull({ ci: "failing" })]);
    expect(stageMark(person)).toBe("attention");
    expect(stageMark(failure)).toBe("failed");
    expect(stageTag(person.stage)).toBe("[blocked]");
    expect(stageTag(failure.stage)).toBe("[blocked]");
  });

  it("rule 2: a failure wins over a person when both block", () => {
    const rows = [crew({ mergedState: "needs-input" }), row("review", { goal: "sessions-workflow" }, { mergedState: "failed" })];
    expect(goalStage(goal({ proposals: 2 }), rows, []).cause).toBe("failure");
    expect(goalStage(goal({ proposals: 2 }), [], [pull({ ci: "failing" })]).cause).toBe("failure");
  });

  it("blocked wins over review: a ready pull request with a waiting proposal", () => {
    expect(goalStage(goal({ proposals: 20 }), [], [pull({ draft: false, ci: "passing" })])).toMatchObject({ stage: "blocked", cause: "person" });
  });

  it("the marks of the other stages", () => {
    expect(stageMark({ stage: "plan" })).toBe("pending");
    expect(stageMark({ stage: "build" })).toBe("running");
    expect(stageMark({ stage: "review" })).toBe("attention");
    expect(stageMark({ stage: "done" })).toBe("done");
  });
});

describe("taskStage: one case per row of the table", () => {
  const done: TaskSummary = { slug: "pull-request-state", state: "done", round: 2, pr: 185 };
  const queued: TaskSummary = { slug: "line-stage", state: "pending" };
  const under = (extra: Partial<ModelRow> = {}, task = "line-stage"): ModelRow => crew(extra, { task, round: "5", pr: "185" });

  it("blocked by a failure: the task is under ## Failures", () => {
    const failed: TaskSummary = { slug: "twenty-green-runs", state: "failed" };
    expect(taskStage(goal(), failed, [], [])).toEqual({ stage: "blocked", cause: "failure", reason: "under ## Failures" });
  });

  it("blocked by a failure: a session under it is failed", () => {
    expect(taskStage(goal(), queued, [under({ mergedState: "failed" })], [])).toMatchObject({ stage: "blocked", cause: "failure", reason: "its session failed" });
  });

  it("blocked on a person: a session under it is needs-input or needs-approval", () => {
    expect(taskStage(goal(), queued, [under({ mergedState: "needs-input" })], [])).toMatchObject({ stage: "blocked", cause: "person", reason: "its session needs you" });
    expect(taskStage(goal(), queued, [under({ mergedState: "needs-approval" })], [])).toMatchObject({ stage: "blocked", cause: "person" });
  });

  it("a session of another task, or of another goal, does not block it", () => {
    const rows = [under({ mergedState: "failed" }, "stage-tree"), row("x", { goal: "cost-per-round", task: "line-stage" }, { mergedState: "failed" })];
    expect(taskStage(goal(), queued, rows, []).stage).toBe("plan");
  });

  it("review: its round's pull request is open and not a draft, and no crew session works on it", () => {
    expect(taskStage(goal(), done, [], [pull({ draft: false })]).stage).toBe("review");
    expect(taskStage(goal(), queued, [under({ mergedState: "completed" })], [pull({ draft: false })]).stage).toBe("review");
  });

  it("not review while a crew session works on it: build", () => {
    expect(taskStage(goal(), queued, [under()], [pull({ draft: false })])).toEqual({ stage: "build" });
  });

  it("not review under a draft: a done task stays done", () => {
    expect(taskStage(goal(), done, [], [pull()])).toEqual({ stage: "done" });
  });

  it("the round's pull request comes from the round record when the line names none", () => {
    const summary = goal({ rounds: [{ number: 2, task: "pull-request-state", pr: 185, correction: false }] });
    expect(taskStage(summary, { slug: "pull-request-state", state: "done" }, [], [pull({ draft: false })]).stage).toBe("review");
  });

  it("a queued task with no round has no round's pull request: plan under a ready one", () => {
    expect(taskStage(goal(), { slug: "line-stage", state: "pending", pr: 185 }, [], [pull({ draft: false })])).toEqual({ stage: "plan" });
  });

  it("build: a live crew session carries its task: label", () => {
    expect(taskStage(goal(), queued, [under()], [pull()])).toEqual({ stage: "build" });
    expect(taskStage(goal(), done, [under({}, "pull-request-state")], [pull()])).toEqual({ stage: "build" });
  });

  it("done: the task is under ## Done", () => {
    expect(taskStage(goal(), done, [], [])).toEqual({ stage: "done" });
    expect(taskStage(goal(), done, [], [pull({ state: "merged" })])).toEqual({ stage: "done" });
  });

  it("plan: the task is under ## Queue and no session carries it", () => {
    expect(taskStage(goal(), queued, [], [pull()])).toEqual({ stage: "plan" });
    expect(taskStage(goal(), queued, [under({ mergedState: "exited" })], [pull()])).toEqual({ stage: "plan" });
  });
});

describe("pullStateWords", () => {
  it("prints each state word of the frames", () => {
    expect(pullStateWords(pull())).toEqual(["draft"]);
    expect(pullStateWords(pull({ draft: false }))).toEqual(["ready"]);
    expect(pullStateWords(pull({ ci: "passing" }))).toEqual(["draft", "CI ✓"]);
    expect(pullStateWords(pull({ ci: "failing" }))).toEqual(["draft", "CI ✗"]);
    expect(pullStateWords(pull({ draft: false, ci: "pending" }))).toEqual(["ready", "CI …"]);
    expect(pullStateWords(pull({ state: "merged", draft: false, ci: "passing" }))).toEqual(["merged"]);
    expect(Object.values(PULL_WORDS)).toEqual(["draft", "ready", "CI ✓", "CI ✗", "CI …", "merged"]);
  });

  it("prints no word for a closed pull request and for missing data", () => {
    expect(pullStateWords(pull({ state: "closed" }))).toEqual([]);
    expect(pullStateWords(null)).toEqual([]);
  });

  it("a phone prints one word", () => {
    expect(pullStateWord(pull({ ci: "passing" }))).toBe("draft");
    expect(pullStateWord(pull({ draft: false, ci: "failing" }))).toBe("CI ✗");
    expect(pullStateWord(pull({ draft: false }))).toBe("ready");
    expect(pullStateWord(pull({ state: "merged" }))).toBe("merged");
    expect(pullStateWord(null)).toBeNull();
  });
});

describe("goalPull: the mapping", () => {
  it("maps by the head branch goal/<slug>", () => {
    const pulls = [pull({ number: 186, headRefName: "goal/cost-per-round" }), pull()];
    expect(goalPull(goal({ pullRequest: 999 }), [], pulls)).toEqual({ number: 185, by: "branch", pull: pulls[1] });
  });

  it("on one branch name, an open pull request wins over a merged one, then the highest number", () => {
    const merged = pull({ number: 150, state: "merged" });
    const open = pull({ number: 185 });
    expect(goalPull(goal(), [], [merged, open])?.number).toBe(185);
    expect(goalPull(goal(), [], [merged, pull({ number: 120, state: "merged" })])?.number).toBe(150);
    expect(goalPull(goal(), [], [pull({ number: 190, state: "closed" }), merged])?.number).toBe(150);
  });

  it("maps by the number the summary names when no head matches", () => {
    const other = pull({ headRefName: "feat/sessions" });
    expect(goalPull(goal({ pullRequest: 185 }), [], [other])).toEqual({ number: 185, by: "summary", pull: other });
  });

  it("maps by a pr: label of a session under the goal", () => {
    const other = pull({ number: 616, headRefName: "feat/demo" });
    expect(goalPull(goal(), [crew({}, { pr: "616" })], [other])).toEqual({ number: 616, by: "label", pull: other });
    expect(goalPull(goal(), [row("x", { goal: "cost-per-round", pr: "616" })], [other])).toBeNull();
  });

  it("maps by the latest round record, then by a task line", () => {
    const rounds = [
      { number: 1, pr: 160, correction: false },
      { number: 2, pr: 182, correction: false },
    ];
    expect(goalPull(goal({ rounds }), [], [])).toEqual({ number: 182, by: "record", pull: null });
    expect(goalPull(goal({ tasks: [{ slug: "a", state: "done", pr: 126 }] }), [], [])).toEqual({ number: 126, by: "record", pull: null });
  });

  it("a goal that names no pull request has none", () => {
    expect(goalPull(goal(), [], [pull({ headRefName: "chore/readme" })])).toBeNull();
  });

  it("a merged pull request found only by a record does not make the goal done", () => {
    const summary = goal({ rounds: [{ number: 1, pr: 614, correction: false }], tasks: [{ slug: "next", state: "pending" }] });
    const merged = pull({ number: 614, state: "merged", headRefName: "feat/real-app-prune" });
    expect(goalStage(summary, [], [merged])).toEqual({ stage: "plan" });
    expect(pullStateWords(goalPull(summary, [], [merged])!.pull)).toEqual(["merged"]);
  });

  it("an open pull request found by a record still decides review and CI", () => {
    const summary = goal({ rounds: [{ number: 1, pr: 614, correction: false }] });
    expect(goalStage(summary, [], [pull({ number: 614, draft: false, headRefName: "feat/x" })]).stage).toBe("review");
    expect(goalStage(summary, [], [pull({ number: 614, ci: "failing", headRefName: "feat/x" })]).cause).toBe("failure");
  });
});

describe("missing pull request data", () => {
  const notRead: PullsAnswer = { ok: true, project: "kitterm", reason: "not read yet", pulls: [] };

  it("readPulls answers null with no answer and before the first good read", () => {
    expect(readPulls(null)).toBeNull();
    expect(readPulls(undefined)).toBeNull();
    expect(readPulls(notRead)).toBeNull();
    expect(readPulls({ ...notRead, reason: "gh is not on PATH" })).toBeNull();
  });

  it("readPulls keeps the last good list of a read that failed after it", () => {
    const stale: PullsAnswer = { ok: true, readAt: NOW - HOUR, reason: "gh pr list exited 1: HTTP 502", pulls: [pull()] };
    expect(readPulls(stale)).toEqual([pull()]);
  });

  it("the stage then comes from STATE.md and the sessions alone", () => {
    const pulls = readPulls(notRead);
    expect(goalStage(goal({ pullRequest: 185 }), [], pulls)).toEqual({ stage: "plan" });
    expect(goalStage(goal({ pullRequest: 185 }), [crew()], pulls)).toEqual({ stage: "build" });
    expect(goalStage(goal({ status: "done" }), [], pulls)).toEqual({ stage: "done" });
    expect(goalStage(goal({ proposals: 1 }), [], pulls)).toMatchObject({ stage: "blocked", cause: "person" });
    expect(taskStage(goal(), { slug: "a", state: "done", round: 2, pr: 185 }, [], pulls)).toEqual({ stage: "done" });
    expect(taskStage(goal(), { slug: "b", state: "failed" }, [], pulls)).toMatchObject({ stage: "blocked", cause: "failure" });
  });

  it("the number still prints, with no state word", () => {
    const found = goalPull(goal({ pullRequest: 185 }), [], readPulls(notRead));
    expect(found).toEqual({ number: 185, by: "summary", pull: null });
    expect(pullStateWords(found!.pull)).toEqual([]);
    expect(goalPull(goal(), [], null)).toBeNull();
  });
});

describe("reviewLine", () => {
  const answer = (pulls: PullRequest[]): PullsAnswer => ({ ok: true, readAt: NOW, pulls });
  const backend = { id: "backend", name: "backend" };
  const scope = goal({ slug: "foreman-scope" });
  const demo: StagedSummary = { project: "backend", slug: "demo-backend", status: "active" };

  it("lists the ready pull requests with their project and goal, then the drafts", () => {
    const line = reviewLine([
      {
        project,
        goals: [goal(), scope],
        rows: [],
        pulls: answer([pull(), pull({ number: 180, draft: false, ci: "passing", headRefName: "goal/foreman-scope", url: "https://github.com/tienan92it/kitterm/pull/180" })]),
      },
      { project: backend, goals: [demo], rows: [], pulls: answer([pull({ number: 2899, draft: false, ci: "pending", headRefName: "goal/demo-backend", url: undefined })]) },
    ]);
    expect(line.ready).toEqual([
      { number: 180, href: "https://github.com/tienan92it/kitterm/pull/180", ci: "CI ✓", project, goal: "foreman-scope" },
      { number: 2899, href: null, ci: "CI …", project: backend, goal: "demo-backend" },
    ]);
    expect(line.drafts).toEqual([{ number: 185, href: "https://github.com/tienan92it/kitterm/pull/185", ci: null, project, goal: "sessions-workflow" }]);
    expect(reviewHead(line)).toBe("2 ready for review");
    expect(draftsLabel(line)).toBe("1 draft");
  });

  it("with only drafts, says none is ready and lists the drafts", () => {
    const line = reviewLine([{ project, goals: [goal(), scope], rows: [], pulls: answer([pull({ ci: "pending" }), pull({ number: 180, headRefName: "goal/foreman-scope" })]) }]);
    expect(line.ready).toEqual([]);
    expect(line.drafts.map((p) => p.number)).toEqual([185, 180]);
    expect(reviewHead(line)).toBe(REVIEW_NONE);
    expect(draftsLabel(line)).toBe("2 drafts");
  });

  it("with none, says so", () => {
    const line = reviewLine([{ project, goals: [goal()], rows: [], pulls: answer([pull({ state: "merged" })]) }]);
    expect(line).toEqual({ ready: [], drafts: [] });
    expect(reviewHead(line)).toBe("No pull request is ready for review.");
    expect(draftsLabel(line)).toBeNull();
  });

  it("lists a ready pull request whose CI fails, and one found by a label", () => {
    const line = reviewLine([
      { project, goals: [goal()], rows: [crew({}, { pr: "616" })], pulls: answer([pull({ number: 616, draft: false, ci: "failing", headRefName: "feat/demo" })]) },
    ]);
    expect(line.ready.map((p) => [p.number, p.ci])).toEqual([[616, "CI ✗"]]);
  });

  it("skips a pull request of no goal, a number twice, and a project with missing data", () => {
    const twice = { rounds: [{ number: 1, pr: 185, correction: false }] };
    const line = reviewLine([
      { project, goals: [goal(), goal({ slug: "other", ...twice })], rows: [], pulls: answer([pull({ draft: false }), pull({ number: 190, draft: false, headRefName: "chore/readme" })]) },
      { project: backend, goals: [demo], rows: [], pulls: { ok: true, reason: "gh is not logged in", pulls: [] } },
      { project: backend, goals: [demo], rows: [], pulls: null },
    ]);
    expect(line.ready.map((p) => p.number)).toEqual([185]);
    expect(line.drafts).toEqual([]);
  });
});

describe("the wait time", () => {
  it("a line blocked by a session waits since that session's last output", () => {
    const stage = goalStage(goal(), [crew({ mergedState: "needs-input", lastOutputAt: NOW - 12 * MINUTE })], []);
    expect(waitLabel(stage, NOW)).toBe("waits 12m");
    const task = taskStage(goal(), { slug: "the-catch-up", state: "pending" }, [crew({ mergedState: "needs-approval", lastOutputAt: NOW - 3 * HOUR }, { task: "the-catch-up" })], []);
    expect(waitLabel(task, NOW)).toBe("waits 3h");
  });

  it("the longest wait of the blocking sessions prints, and under a minute reads <1m", () => {
    const rows = [crew({ mergedState: "failed", lastOutputAt: NOW - 30_000 }), row("b", { goal: "sessions-workflow" }, { mergedState: "failed", lastOutputAt: NOW - 40 * MINUTE })];
    expect(waitLabel(goalStage(goal(), rows, []), NOW)).toBe("waits 40m");
    expect(waitLabel(goalStage(goal(), [rows[0]!], []), NOW)).toBe("waits <1m");
  });

  it("a review line waits since its last session went quiet", () => {
    const rows = [crew({ mergedState: "completed", lastOutputAt: NOW - 40 * MINUTE }), row("b", { goal: "sessions-workflow" }, { mergedState: "completed", lastOutputAt: NOW - 2 * HOUR })];
    expect(waitLabel(goalStage(goal(), rows, [pull({ draft: false })]), NOW)).toBe("waits 40m");
  });

  it("with no session, the wait counts from the end of the latest round's start day", () => {
    const rounds = [
      { number: 1, started: "2026-09-20", correction: false },
      { number: 2, started: "2026-10-02", correction: false },
    ];
    // The day 2026-10-02 ends at local midnight; 18:00 on the 5th is 2 days and 18 hours later.
    expect(waitLabel(goalStage(goal({ proposals: 20, rounds }), [], []), NOW)).toBe("waits 2d");
    expect(waitLabel(goalStage(goal({ rounds }), [], [pull({ draft: false })]), NOW)).toBe("waits 2d");
    expect(waitLabel(taskStage(goal({ rounds }), { slug: "a", state: "failed", round: 1 }, [], []), NOW)).toBe("waits 14d");
  });

  it("a round that started today, or no dated source, prints no wait", () => {
    const today = [{ number: 5, started: "2026-10-05", correction: false }];
    expect(waitLabel(goalStage(goal({ proposals: 1, rounds: today }), [], []), NOW)).toBeNull();
    expect(waitLabel(goalStage(goal({ status: "waiting" }), [], []), NOW)).toBeNull();
  });

  it("only a blocked or a review line prints a wait", () => {
    expect(waitLabel({ stage: "build", since: NOW - HOUR }, NOW)).toBeNull();
    expect(waitLabel({ stage: "plan", since: NOW - HOUR }, NOW)).toBeNull();
    expect(waitLabel({ stage: "done", since: NOW - HOUR }, NOW)).toBeNull();
    expect(waitLabel({ stage: "review", since: NOW - HOUR }, NOW)).toBe("waits 1h");
  });
});

describe("the order of lines in a list", () => {
  it("is blocked, review, build, plan, done", () => {
    expect(STAGE_ORDER).toEqual(["blocked", "review", "build", "plan", "done"]);
    const stages: Stage[] = ["done", "plan", "build", "review", "blocked"];
    expect([...stages].sort(byStage)).toEqual(["blocked", "review", "build", "plan", "done"]);
  });

  it("keeps the order of two lines of one stage", () => {
    const lines: { name: string; stage: Stage }[] = [
      { name: "a", stage: "plan" },
      { name: "b", stage: "done" },
      { name: "c", stage: "blocked" },
      { name: "d", stage: "plan" },
      { name: "e", stage: "blocked" },
      { name: "f", stage: "review" },
    ];
    expect(sortByStage(lines, (l) => l.stage).map((l) => l.name)).toEqual(["c", "e", "f", "a", "d", "b"]);
    expect(lines[0]!.name).toBe("a");
  });
});
