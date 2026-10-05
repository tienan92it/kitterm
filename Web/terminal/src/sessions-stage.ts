/**
 * The stage of a goal line and of a task line (`sessions-workflow`,
 * capability 4): pure functions, no DOM. Each line takes one stage from
 * `plan`, `build`, `review`, `blocked`, `done` by the table of
 * `docs/goals/sessions-workflow/corpus/00-request.md` and the three rules
 * of `corpus/01-approved-design.md`. The inputs are the goal's summary of
 * `GET /api/projects/<id>/knowledge`, the session rows the project owns,
 * and the pull requests of `GET /api/projects/<id>/pulls`.
 *
 * Missing pull request data: `readPulls` answers null when the page holds
 * no answer of the pulls route (a watch token, a 404) or when no read has
 * succeeded yet (`not read yet`, no `gh`, no login, no GitHub remote).
 * Every function then decides from `STATE.md` and the sessions alone: the
 * CI row and the review row cannot hold, a pull request number still
 * comes from the summary, a label or a record, and no state word prints.
 */

import { goalOf, prOf, roundOf, spanLabel, stateOf, taskOf, type KnowledgeSummary, type MarkFamily, type ModelRow, type TaskSummary } from "./sessions-model";

export type Stage = "plan" | "build" | "review" | "blocked" | "done";

/** Why a line is blocked: a person must act (`?`, the warning colour) or
 * something failed (`!`, the danger colour). */
export type BlockCause = "person" | "failure";

/** The stage of one line. `cause` and `reason` are set for `blocked`
 * alone. `since` is the epoch millisecond the wait began, for `blocked`
 * and `review`, and is absent when no source dates the wait. */
export type LineStage = { stage: Stage; cause?: BlockCause; reason?: string; since?: number };

/** The order of lines in a list (rule 3 of the `Sessions components`
 * frame): the line that waits on the human first. */
export const STAGE_ORDER: readonly Stage[] = ["blocked", "review", "build", "plan", "done"];

/** The CI of a pull request as the daemon reduces it (`PullRequestStatus.ciWord`). */
export type PullCi = "passing" | "failing" | "pending";

/** One pull request of `GET /api/projects/<id>/pulls`. */
export type PullRequest = {
  number: number;
  title?: string;
  state: "open" | "closed" | "merged";
  draft: boolean;
  headRefName: string;
  mergedAt?: string;
  url?: string;
  /** Absent for a pull request with no checks. */
  ci?: PullCi;
  additions?: number;
  deletions?: number;
};

/** What `GET /api/projects/<id>/pulls` answers. `readAt` is absent before
 * the first good read; `reason` says why the latest read gave no list. */
export type PullsAnswer = {
  ok: boolean;
  project?: string;
  readAt?: number;
  ageSeconds?: number;
  reason?: string;
  pulls: PullRequest[];
};

/** A goal summary with the two fields the knowledge route gained in
 * rounds 3 and 4 of `sessions-workflow`. */
export type StagedSummary = KnowledgeSummary & {
  /** `origin/main`, `origin/goal/<slug>` or `working tree`. */
  source?: string;
  sourceReason?: string;
  /** The open pull request of the goal branch the summary was read from. */
  pullRequest?: number;
};

/** The pull requests the stage reads, or null for missing data. A failed
 * read after a good one keeps the last good list, and that list is read. */
export function readPulls(answer: PullsAnswer | null | undefined): PullRequest[] | null {
  if (!answer || typeof answer.readAt !== "number") return null;
  return answer.pulls;
}

/** How the goal's pull request was found. */
export type PullSource = "branch" | "summary" | "label" | "record";

/** The pull request of a goal: its number, how the number was found, and
 * its state when the pulls list holds it (null with missing data, and for
 * a number past the 50 the daemon reads). */
export type GoalPull = { number: number; by: PullSource; pull: PullRequest | null };

const PULL_RANK: Record<PullRequest["state"], number> = { open: 0, merged: 1, closed: 2 };

/**
 * The pull request of a goal. The head branch `goal/<slug>` decides
 * first: an open pull request wins over a merged one and a merged one
 * over a closed one, then the highest number, because a goal with a
 * second budget opens a new pull request on the same branch name. With no
 * such head, the number comes from the summary's `pullRequest`, then a
 * `pr:` label of a session under the goal, then the latest round record
 * that names one, then the first task line that names one.
 */
export function goalPull(summary: StagedSummary, rows: readonly ModelRow[], pulls: readonly PullRequest[] | null): GoalPull | null {
  const slug = summary.slug;
  if (slug !== undefined && pulls !== null) {
    const head = `goal/${slug}`;
    let best: PullRequest | null = null;
    for (const pull of pulls) {
      if (pull.headRefName !== head) continue;
      if (best === null || PULL_RANK[pull.state] < PULL_RANK[best.state] || (pull.state === best.state && pull.number > best.number)) best = pull;
    }
    if (best !== null) return { number: best.number, by: "branch", pull: best };
  }
  const named = namedPull(summary, rows);
  if (named === null) return null;
  return { ...named, pull: pulls?.find((pull) => pull.number === named.number) ?? null };
}

function namedPull(summary: StagedSummary, rows: readonly ModelRow[]): { number: number; by: PullSource } | null {
  if (typeof summary.pullRequest === "number") return { number: summary.pullRequest, by: "summary" };
  for (const row of goalRows(summary, rows)) {
    const pr = prOf(row);
    if (pr !== null) return { number: pr, by: "label" };
  }
  const records = [...(summary.rounds ?? [])].sort((a, b) => b.number - a.number);
  for (const record of records) {
    if (typeof record.pr === "number") return { number: record.pr, by: "record" };
  }
  for (const task of summary.tasks ?? []) {
    if (typeof task.pr === "number") return { number: task.pr, by: "record" };
  }
  return null;
}

/** The rows that carry the goal's slug in a `goal:` label. */
function goalRows<R extends ModelRow>(summary: StagedSummary, rows: readonly R[]): R[] {
  const slug = summary.slug;
  return slug === undefined ? [] : rows.filter((row) => goalOf(row) === slug);
}

function isFailed(row: ModelRow): boolean {
  return stateOf(row) === "failed";
}

function needsPerson(row: ModelRow): boolean {
  const state = stateOf(row);
  return state === "needs-input" || state === "needs-approval";
}

/** A live session: one whose shell has not exited. */
function isLive(row: ModelRow): boolean {
  return stateOf(row) !== "exited";
}

/** The oldest `lastOutputAt` among `rows`: the longest wait. */
function oldestOutput(rows: readonly ModelRow[]): number | undefined {
  let since: number | undefined;
  for (const row of rows) {
    if (typeof row.lastOutputAt === "number" && (since === undefined || row.lastOutputAt < since)) since = row.lastOutputAt;
  }
  return since;
}

/** The newest `lastOutputAt` among `rows`: when the last session went quiet. */
function newestOutput(rows: readonly ModelRow[]): number | undefined {
  let since: number | undefined;
  for (const row of rows) {
    if (typeof row.lastOutputAt === "number" && (since === undefined || row.lastOutputAt > since)) since = row.lastOutputAt;
  }
  return since;
}

/** The local midnight that ends the day `YYYY-MM-DD`. A round record
 * names only its start day, so the wait counts from the end of that day:
 * a lower bound, never more than the line has waited. */
function endOfDay(day: string | undefined): number | undefined {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day ?? "");
  if (!match) return undefined;
  return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]) + 1).getTime();
}

/** When a wait with no blocking session began: when the last session
 * under the line went quiet, else the end of the start day of `round`
 * (the latest round with no number given). */
function quietSince(summary: StagedSummary, rows: readonly ModelRow[], round?: number): number | undefined {
  const quiet = newestOutput(rows);
  if (quiet !== undefined) return quiet;
  const records = summary.rounds ?? [];
  const record = round === undefined ? [...records].sort((a, b) => b.number - a.number)[0] : records.find((r) => r.number === round);
  return endOfDay(record?.started);
}

function blocked(cause: BlockCause, reason: string, since: number | undefined): LineStage {
  return since === undefined ? { stage: "blocked", cause, reason } : { stage: "blocked", cause, reason, since };
}

function review(since: number | undefined): LineStage {
  return since === undefined ? { stage: "review" } : { stage: "review", since };
}

function proposalsReason(count: number): string {
  return count === 1 ? "1 proposal waits on you" : `${count} proposals wait on you`;
}

/**
 * The stage of a goal line. The first row that holds wins:
 *
 * 1. `done`: its status is `done`, or its pull request is merged, even
 *    when a proposal still waits (approved rule 1). A merged pull request
 *    found only by a round record or a task line does not decide: under
 *    the earlier flow each task had its own pull request, and a merged
 *    one there says the task is done, not the goal.
 * 2. `blocked` by a failure: a session under it is `failed`, or the CI of
 *    its open pull request fails. A failure wins over a person when both
 *    hold, because the danger mark is the stronger one.
 * 3. `blocked` by a person: a session under it is `needs-input` or
 *    `needs-approval`, a proposal waits, or its status is `waiting` or
 *    `stopped`.
 * 4. `review`: its pull request is open and not a draft.
 * 5. `build`: a live session carries its `goal:` label.
 * 6. `plan`: any other goal.
 *
 * `rows` is every session the project owns. `pulls` is `readPulls`'s
 * answer; with null, rows 2 and 4 read no pull request and row 1 reads
 * the status alone.
 */
export function goalStage(summary: StagedSummary, rows: readonly ModelRow[], pulls: readonly PullRequest[] | null): LineStage {
  const mine = goalRows(summary, rows);
  const found = goalPull(summary, rows, pulls);
  const pull = found?.pull ?? null;
  const status = (summary.status ?? "").trim().toLowerCase();
  if (status === "done" || (pull?.state === "merged" && found?.by !== "record")) return { stage: "done" };

  const failed = mine.filter(isFailed);
  if (failed.length > 0) return blocked("failure", "its session failed", oldestOutput(failed));
  if (pull?.state === "open" && pull.ci === "failing") return blocked("failure", `CI fails on PR #${pull.number}`, quietSince(summary, mine));

  const asking = mine.filter(needsPerson);
  if (asking.length > 0) return blocked("person", "its session needs you", oldestOutput(asking));
  const proposals = summary.proposals ?? 0;
  if (proposals > 0) return blocked("person", proposalsReason(proposals), quietSince(summary, mine));
  if (status === "waiting" || status === "stopped") return blocked("person", `its status is ${status}`, quietSince(summary, mine));

  if (pull?.state === "open" && !pull.draft) return review(quietSince(summary, mine));
  if (mine.some(isLive)) return { stage: "build" };
  return { stage: "plan" };
}

/** The round a task belongs to: the one its `STATE.md` line names, else
 * the `round:` label of a session under it, else the latest record whose
 * heading names the slug. */
function taskRound(summary: StagedSummary, task: TaskSummary, under: readonly ModelRow[]): number | null {
  if (typeof task.round === "number") return task.round;
  for (const row of under) {
    const round = roundOf(row);
    if (round !== null) return round;
  }
  let latest: number | null = null;
  for (const record of summary.rounds ?? []) {
    if (record.task === task.slug && (latest === null || record.number > latest)) latest = record.number;
  }
  return latest;
}

/**
 * The pull request of a task's round, or null. A task with no round has
 * no round's pull request: a queued line that names the goal's pull
 * request before any round ran stays in `plan` when that pull request
 * goes ready. The number is the line's own, else a `pr:` label under the
 * task, else the round record's.
 */
function taskPull(summary: StagedSummary, task: TaskSummary, under: readonly ModelRow[], pulls: readonly PullRequest[] | null): { round: number; pull: PullRequest | null } | null {
  const round = taskRound(summary, task, under);
  if (round === null) return null;
  let number: number | null = typeof task.pr === "number" ? task.pr : null;
  for (const row of under) {
    if (number === null) number = prOf(row);
  }
  if (number === null) number = summary.rounds?.find((r) => r.number === round)?.pr ?? null;
  return { round, pull: number === null ? null : (pulls?.find((p) => p.number === number) ?? null) };
}

/**
 * The stage of a task line. The first row that holds wins:
 *
 * 1. `blocked` by a failure: the task is under `## Failures`, or a
 *    session under it is `failed`.
 * 2. `blocked` by a person: a session under it is `needs-input` or
 *    `needs-approval`.
 * 3. `review`: its round's pull request is open and not a draft, and no
 *    session under it is `working`.
 * 4. `build`: a live session carries its `task:` label.
 * 5. `done`: the task is under `## Done`.
 * 6. `plan`: any other task.
 *
 * `task` is one entry of the summary's `tasks`, or the entry `taskLines`
 * makes for a labelled task `STATE.md` does not list yet. A session is
 * under the task when it carries `task:<slug>` and `goal:<the goal's slug>`.
 */
export function taskStage(summary: StagedSummary, task: TaskSummary, rows: readonly ModelRow[], pulls: readonly PullRequest[] | null): LineStage {
  const under = goalRows(summary, rows).filter((row) => taskOf(row) === task.slug);
  const found = taskPull(summary, task, under, pulls);

  const failed = under.filter(isFailed);
  if (task.state === "failed") return blocked("failure", "under ## Failures", failed.length > 0 ? oldestOutput(failed) : quietSince(summary, under, found?.round));
  if (failed.length > 0) return blocked("failure", "its session failed", oldestOutput(failed));
  const asking = under.filter(needsPerson);
  if (asking.length > 0) return blocked("person", "its session needs you", oldestOutput(asking));

  const pull = found?.pull ?? null;
  if (pull?.state === "open" && !pull.draft && !under.some((row) => stateOf(row) === "working")) return review(quietSince(summary, under, found?.round));
  if (under.some(isLive)) return { stage: "build" };
  if (task.state === "done") return { stage: "done" };
  return { stage: "plan" };
}

/** The stage as the line prints it: `[blocked]`, whatever the cause. */
export function stageTag(stage: Stage): string {
  return `[${stage}]`;
}

/** The mark family of a stage (rule 2 of the `Sessions components`
 * frame): `•` plan, `◐` build, `?` review, `?` blocked on a person, `!`
 * blocked by a failure, `✓` done. */
export function stageMark(line: Pick<LineStage, "stage" | "cause">): MarkFamily {
  switch (line.stage) {
    case "plan":
      return "pending";
    case "build":
      return "running";
    case "review":
      return "attention";
    case "blocked":
      return line.cause === "failure" ? "failed" : "attention";
    case "done":
      return "done";
  }
}

/** A comparator for the order of lines in a list. */
export function byStage(a: Stage, b: Stage): number {
  return STAGE_ORDER.indexOf(a) - STAGE_ORDER.indexOf(b);
}

/** `items` in the order of `STAGE_ORDER`; two lines of one stage keep the
 * order they came in. */
export function sortByStage<T>(items: readonly T[], stageOf: (item: T) => Stage): T[] {
  return items
    .map((item, index) => ({ item, index, stage: stageOf(item) }))
    .sort((a, b) => byStage(a.stage, b.stage) || a.index - b.index)
    .map((entry) => entry.item);
}

/** The six state words a goal's pull request prints. */
export const PULL_WORDS = { draft: "draft", ready: "ready", passing: "CI ✓", failing: "CI ✗", pending: "CI …", merged: "merged" } as const;

export type PullWord = (typeof PULL_WORDS)[keyof typeof PULL_WORDS];

/** The CI word of a pull request, or null with no checks. */
export function ciWord(pull: Pick<PullRequest, "ci">): PullWord | null {
  return pull.ci === undefined ? null : PULL_WORDS[pull.ci];
}

/**
 * The state words after `PR #N` on a goal line: `merged` alone for a
 * merged pull request; `draft` or `ready`, then the CI word when the pull
 * request has checks, for an open one. A closed pull request that did not
 * merge prints no word, and so does missing data (`pull` null): the
 * frames give neither a word.
 */
export function pullStateWords(pull: PullRequest | null): PullWord[] {
  if (pull === null || pull.state === "closed") return [];
  if (pull.state === "merged") return [PULL_WORDS.merged];
  const words: PullWord[] = [pull.draft ? PULL_WORDS.draft : PULL_WORDS.ready];
  const ci = ciWord(pull);
  if (ci !== null) words.push(ci);
  return words;
}

/** The one state word a phone prints (rule 7 of the frame): `merged`,
 * `draft`, else the CI word, else `ready` for a pull request with no
 * checks; null where `pullStateWords` is empty. */
export function pullStateWord(pull: PullRequest | null): PullWord | null {
  const words = pullStateWords(pull);
  if (words.length === 0) return null;
  if (words[0] === PULL_WORDS.ready && words.length > 1) return words[1]!;
  return words[0]!;
}

/** What the REVIEW line reads of one project. */
export type ReviewProject = {
  project: { id: string; name: string };
  goals: readonly StagedSummary[];
  rows: readonly ModelRow[];
  pulls: PullsAnswer | null | undefined;
};

/** One pull request on the REVIEW line. */
export type ReviewPull = {
  number: number;
  /** The pull request's page on GitHub, from the pulls route. */
  href: string | null;
  /** `CI ✓`, `CI ✗`, `CI …`, or null with no checks. */
  ci: PullWord | null;
  project: { id: string; name: string };
  /** The slug of the goal the pull request maps to, or null for none. */
  goal: string | null;
  /** What the line prints after the project: the goal's slug, else the
   * kind and the slug of the head (`chore readme` for `chore/readme`),
   * else the head branch name. */
  label: string;
};

/** The REVIEW line under the SESSIONS header: the open pull requests
 * that are not drafts, then the drafts. */
export type ReviewLine = { ready: ReviewPull[]; drafts: ReviewPull[] };

/** A head of the shape `<kind>/<slug>`: `chore/readme`, `fix/enter-key`. */
const KIND_HEAD = /^([a-z][a-z0-9-]*)\/([A-Za-z0-9][A-Za-z0-9._-]*)$/;

/** What a pull request of no goal prints: `chore readme` for the head
 * `chore/readme`, else the head branch name unchanged. */
function headLabel(head: string): string {
  const match = KIND_HEAD.exec(head);
  return match ? `${match[1]} ${match[2]}` : head;
}

/**
 * The REVIEW line's data: every open pull request of each project, in
 * the order of the projects and then the order the pulls route gives.
 * The ones that are not drafts go in `ready`, whatever their CI says,
 * and the drafts in `drafts`. The human merges a chore's pull request
 * too, so a pull request needs no goal to be listed. Each carries its
 * goal when `goalPull` maps one to it (the head `goal/<slug>`, or a
 * number the summary, a `pr:` label or a record names; the first goal
 * wins a number two goals name), else the label of its head. A project
 * with missing pull request data adds nothing.
 */
export function reviewLine(projects: readonly ReviewProject[]): ReviewLine {
  const line: ReviewLine = { ready: [], drafts: [] };
  for (const entry of projects) {
    const pulls = readPulls(entry.pulls);
    if (pulls === null) continue;
    const goalOfPull = new Map<number, string>();
    for (const goal of entry.goals) {
      const found = goalPull(goal, entry.rows, pulls);
      if (found && goal.slug !== undefined && !goalOfPull.has(found.number)) goalOfPull.set(found.number, goal.slug);
    }
    for (const pull of pulls) {
      if (pull.state !== "open") continue;
      const goal = goalOfPull.get(pull.number) ?? null;
      const item: ReviewPull = { number: pull.number, href: pull.url ?? null, ci: ciWord(pull), project: entry.project, goal, label: goal ?? headLabel(pull.headRefName) };
      (pull.draft ? line.drafts : line.ready).push(item);
    }
  }
  return line;
}

/** The sentence that says there is nothing to review. */
export const REVIEW_NONE = "No pull request is ready for review.";

/** What the REVIEW line says first: `2 ready for review`, else the
 * sentence that says there is none. */
export function reviewHead(line: ReviewLine): string {
  return line.ready.length === 0 ? REVIEW_NONE : `${line.ready.length} ready for review`;
}

/** The count before the drafts: `1 draft`, `2 drafts`; null with none. */
export function draftsLabel(line: ReviewLine): string | null {
  const count = line.drafts.length;
  if (count === 0) return null;
  return count === 1 ? "1 draft" : `${count} drafts`;
}

/** The last column of a blocked or a review line: `waits 2d`, `waits 3h`,
 * `waits 40m`, `waits <1m`, in one unit rounded down. Null for any other
 * stage, and for a wait no source dates or whose start is after `now`
 * (a round that started today names only its day). */
export function waitLabel(line: LineStage, now: number): string | null {
  if (line.stage !== "blocked" && line.stage !== "review") return null;
  if (line.since === undefined || line.since > now) return null;
  return now - line.since < 60_000 ? "waits <1m" : `waits ${spanLabel(now - line.since)}`;
}
