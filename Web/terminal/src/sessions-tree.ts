/**
 * The tree as flat lines (`agent-dashboard`, round 10; the frames
 * `Dashboard 1200` and `Dashboard 390` in `design/dashboard.pen`). No DOM,
 * no clock beyond the `now` it is handed; `sessions.ts` paints what this
 * returns, one `.line` per entry.
 *
 * Every line has the same cells: a mark at the far left of the page, an
 * indent per level, a name, then four right-aligned fact columns of fixed
 * width — the state word, the cost in the range (round 15: at every level
 * and nothing else; a workspace's and a project's from the rollup, a
 * goal's from its round records, a task's from its round's `Cost:` line,
 * a session's from its transcript bill, a dash where the level has none),
 * a pull request (a task's `PR #124`, a link when the project has a
 * `pullRequestBase`) or a session's model, and a trailing fact (a time,
 * `1 agent`). `round 6` and a goal's `r6/3` are the name's tooltip. On a
 * phone the columns give way to the state word and the cost (`narrow`).
 *
 * A project shows its sessions under no goal, its working and pending
 * goals with their tasks, then its most recently finished goal open with
 * its last two done tasks (`latestDoneGoal`, `shownTasks`), and the other
 * done goals behind one `N done` fold at the goal's indent. A live session
 * whose `goal:` label names a done goal nests under that goal, which is
 * then shown open too. Idle shells are not lines of the tree: they are
 * returned apart, for the `N idle shells` fold at the page's foot.
 *
 * A workspace wears no mark. A project and a goal wear the disclosure
 * triangle alone, never a state (round 11, the Components frame):
 * `children` says whether there is anything under the line to fold, and
 * `visibleLines` hides what sits under a closed one. A done goal inside
 * the `N done` fold is the same line shape and opens to all its tasks;
 * it starts closed (`closed`), and a goal with no task wears no mark
 * (round 14, rule A).
 *
 * Since `sessions-workflow` capability 5 (the frames `Sessions 1200`,
 * `Sessions 390` and `Sessions components` of `design/sessions.pen`) a
 * goal line and a task line carry their stage (`sessions-stage.ts`): the
 * state word is `[plan]`, `[build]`, `[review]`, `[blocked]` or `[done]`,
 * and its mark sits beside it in one status cell. A goal line prints its
 * slug, its purpose or the reason it is blocked (`detail`), its pull
 * request with the state words, and `waits 2d` or `r1/3` in the last
 * column. A task prints a pull request only when the number is not its
 * goal's. Goals and tasks sort blocked, review, build, plan, done. A
 * scope line prints its path and its goals counted by stage. A goal with
 * no open task and a project with every goal done and no live session
 * start closed. `joins` gives each line the hairlines that tie it to its
 * parent.
 */

import {
  agentsLabel,
  approvalsOf,
  costLabel,
  doneLabel,
  goalCost,
  goalOf,
  goalTitle,
  isIdleShell,
  knowledgeUrl,
  latestDoneGoal,
  levels,
  markFamily,
  NO_PROJECT,
  NO_PROJECT_NAME,
  nextLine,
  orphanApprovals,
  projectUsage,
  pullRequestHref,
  recordPath,
  roundCounter,
  rowLine,
  rowModel,
  rowName,
  rowNeeds,
  BILL_TITLE,
  runningEstimate,
  sessionCost,
  sessionCostTitle,
  shownTasks,
  statePath,
  stateOf,
  stateTag,
  taskCost,
  taskLines,
  workspaceHome,
  workspaceUsage,
  type TaskSummary,
  type Approval,
  type GoalLine,
  type KnowledgeSummary,
  type MarkFamily,
  type ModelRow,
  type ProjectRef,
  type ProjectSection,
  type ProjectSummary,
  type ProposedItem,
  type SessionBill,
  type UsageDaily,
  type VocabularyEntry,
  type WorkspaceSection,
} from "./sessions-model";
import {
  goalPull,
  goalStage,
  projectPullsReason,
  pullHref,
  pullStateWord,
  pullStateWords,
  readPulls,
  sortByStage,
  STAGE_ORDER,
  stageCounts,
  stageMark,
  stageTag,
  taskStage,
  waitLabel,
  type GoalPull,
  type LineStage,
  type PullRequest,
  type PullsAnswer,
  type Stage,
} from "./sessions-stage";

/** What a fact is, which is also its class on the page. */
export type TreeFactKind = "cost" | "pr" | "model" | "since" | "agents" | "wait" | "counter";

/** What a line prints in a column it has no source for. Never `0`. */
export const NO_FACT = "–";

/** One fact of a line: its text, its column (2 the cost, 3 the pull
 * request or the model, 4 the trailing fact; the state word is column 1;
 * the page draws column 3 before column 2, as the `Sessions 1200` frame
 * does), and, on a pull request whose project is on GitHub, the link it
 * opens. A goal's pull request carries its state words: `words` for 768 px
 * and up (`draft`, `CI …`), `word` the one a phone prints. `narrow` was
 * the one fact a phone kept before `sessions-workflow`; a phone now keeps
 * the pull request cell and nothing else, by its kind, and no rule reads
 * `narrow`. */
export type TreeFact = { kind: TreeFactKind; text: string; column: 2 | 3 | 4; narrow: boolean; title?: string; href?: string; words?: string[]; word?: string };

/** The cells every line shares. `state` is the bracketed word and the
 * family that colours its mark; null on a heading line, which has no
 * state. `title` is the name's tooltip. */
export type TreeLineBase = {
  key: string;
  /** Indent levels below the top of the page. */
  depth: number;
  name: string;
  title: string | null;
  /** The grey text after the name: a scope's path and stage counts, a
   * goal's purpose, the reason a line is blocked; null with none. */
  detail: string | null;
  state: VocabularyEntry | null;
  facts: TreeFact[];
};

export type TreeLine<R extends ModelRow> =
  | (TreeLineBase & { kind: "workspace"; path: string; children: boolean })
  /** `children` is whether anything sits under the line, which is what
   * the disclosure triangle folds; a project with nothing under it wears
   * a blank mark. The reason a project lists no goal is on the name's
   * tooltip. */
  | (TreeLineBase & { kind: "project"; project: ProjectRef | null; children: boolean; closed?: true })
  /** `href` opens the latest record, else `STATE.md`. `proposed` is the
   * item whose `N proposals` ride on the name's tooltip. `closed` is set
   * on a goal inside the `N done` fold and on a goal with no open task,
   * which start closed; a key in `visibleLines`'s set flips the line's
   * default either way. `stage` is what decided the state word. */
  | (TreeLineBase & {
      kind: "goal";
      project: ProjectRef;
      summary: KnowledgeSummary;
      children: boolean;
      href: string;
      proposed: ProposedItem | null;
      closed?: true;
      stage: LineStage;
    })
  /** `children` is whether a session sits under the task. */
  | (TreeLineBase & { kind: "task"; mark: MarkFamily; stage: LineStage; children: boolean })
  /** A session: the mark is its state's, the approvals are the lines
   * under it, `needs` marks a row the band's cell can land on. */
  | (TreeLineBase & { kind: "session"; row: R; mark: MarkFamily; needs: boolean; approvals: Approval[] })
  /** An approval whose session is gone: a line of its own. */
  | (TreeLineBase & { kind: "approval"; approval: Approval })
  /** The done goals behind one line, `N done`, at the goal's indent. */
  | (TreeLineBase & { kind: "fold"; lines: TreeLine<R>[] });

/** One top-level section: a workspace with its projects, or a lone
 * project. The page draws a hairline between sections. */
export type TreeSection<R extends ModelRow> = { key: string; label: string; lines: TreeLine<R>[] };

export type Tree<R extends ModelRow> = {
  sections: TreeSection<R>[];
  /** The idle shells, in `sortInGroup`'s order across the fleet, for
   * the fold at the page's foot. */
  idle: R[];
};

export type TreeInput<R extends ModelRow> = {
  rows: R[];
  projects: ProjectSummary[];
  goalsOf: (projectId: string) => KnowledgeSummary[] | null | undefined;
  approvals: Approval[];
  proposed: ProposedItem[];
  /** The rollup for the toggles' range: a project's and a workspace's
   * cost come from its buckets, and a goal's cost sums the round records
   * that started inside its `from` and `to` (round 13); no rollup, no
   * cost on any line. */
  usage: UsageDaily | null | undefined;
  /** The bill of a session by id (`GET /api/sessions/<id>/cost`), for its
   * cost column; undefined for one not fetched yet. */
  billOf?: (sessionId: string) => SessionBill | null | undefined;
  /** What `GET /api/projects/<id>/pulls` last answered for a project;
   * absent on a watch page, which reads no pull request state and prints
   * no reason for it. */
  pullsOf?: (projectId: string) => PullsAnswer | null | undefined;
  now: number;
};

const fact = (kind: TreeFactKind, text: string, column: 2 | 3 | 4, narrow = false, title?: string): TreeFact =>
  title === undefined ? { kind, text, column, narrow } : { kind, text, column, narrow, title };

/** The cost column of a goal, a task or a session: the figure, or the dash
 * when the level has none; nothing at all with no rollup, where every cost
 * is off the page (a watch client). */
function costColumn(cost: string | null, title: string): TreeFact[] {
  return [fact("cost", cost ?? NO_FACT, 2, true, title)];
}

/** The facts of a goal's line: its cost in column 2, as the frame draws
 * `workspace-ledger [done] $75.11`, the dash with none. The counter,
 * `r6/3`, is on the name's tooltip (`goalTooltip`), not in a column. */
export function goalFactColumns(cost: string | null): TreeFact[] {
  return costColumn(cost, "the Cost line of this goal's round records started in the range, summed, at the full API rate");
}

/** The name's tooltip of a goal: the counter and the next action, `r6/3 ·
 * next: Round 7, …`; either alone; null with neither. */
export function goalTooltip(counter: string | null, next: string | null): string | null {
  const parts = [counter, next === null ? null : `next: ${next}`].filter((t): t is string => t !== null);
  return parts.length === 0 ? null : parts.join(" · ");
}

/** The facts of a task's line: its round's cost in column 2 (the dash
 * with none; no column with no rollup, `undefined`), `PR #124` in column
 * 3, a link under `base` when the project has one. The round is on the
 * name's tooltip (`taskTooltip`). */
export function taskFactColumns(cost: string | null | undefined, pr: number | undefined, base: string | undefined): TreeFact[] {
  const facts: TreeFact[] = cost === undefined ? [] : costColumn(cost, "the Cost line of the round this task names, when it started in the range");
  if (typeof pr === "number") {
    const link = fact("pr", `PR #${pr}`, 3);
    const href = pullRequestHref(base, pr);
    if (href !== null) link.href = href;
    facts.push(link);
  }
  return facts;
}

/** The name's tooltip of a task: `round 6 · PR #124`, either alone, null
 * with neither. */
export function taskTooltip(round: number | undefined, pr: number | undefined): string | null {
  const parts = [typeof round === "number" ? `round ${round}` : null, typeof pr === "number" ? `PR #${pr}` : null].filter((t): t is string => t !== null);
  return parts.length === 0 ? null : parts.join(" · ");
}

/** The facts of a session's line: its bill in column 2 (a running
 * session's estimate, `~$4.20`, with `title` saying so; round 16), its
 * model in column 3, how long since its last output in column 4. The
 * phone keeps the cost; with no rollup (`cost` undefined) the column is
 * empty and the phone keeps the time. */
export function sessionFactColumns(cost: string | null | undefined, model: string | null, modelId: string | undefined, since: string | null, title: string = BILL_TITLE): TreeFact[] {
  const facts: TreeFact[] = cost === undefined ? [] : costColumn(cost, title);
  if (model !== null) facts.push(fact("model", model, 3, false, modelId));
  if (since !== null) facts.push(fact("since", since, 4, cost === undefined));
  return facts;
}

/** The facts of a heading's line: the range's cost in column 2, the
 * working sessions in column 4. The phone keeps the cost. */
export function headingFactColumns(cost: string | null, agents: string | null, name: string): TreeFact[] {
  const facts: TreeFact[] = [];
  if (cost !== null) facts.push(fact("cost", cost, 2, true, `${name}: what the range cost here, at the full API rate`));
  if (agents !== null) facts.push(fact("agents", agents, 4));
  return facts;
}

/** How many of `rows` hold the tty. */
function working(rows: readonly ModelRow[]): number {
  return rows.filter((row) => stateOf(row) === "working").length;
}

/** A path under the reader's home as `~/…`, the way the frame prints a
 * scope's directory; any other path unchanged. */
export function homePath(path: string): string {
  return path.replace(/^\/(?:Users|home)\/[^/]+(?=\/|$)/, "~");
}

/** The parts of a scope line's grey text, joined by ` · `; null with none. */
function detailOf(parts: readonly (string | null | undefined)[]): string | null {
  const kept = parts.filter((part): part is string => typeof part === "string" && part !== "");
  return kept.length === 0 ? null : kept.join(" · ");
}

/** The pull request fact of a goal line: `PR #185` in column 3, a link to
 * the pull request's own page when that sits under the project's `base`,
 * else to `base` and the number (`pullHref`), plain text with no base,
 * with the state words when the pulls route gave the pull request. */
export function pullFactColumn(found: GoalPull, base: string | undefined): TreeFact {
  const link = fact("pr", `PR #${found.number}`, 3);
  const href = pullHref(found.pull?.url, base, found.number);
  if (href) link.href = href;
  const words = pullStateWords(found.pull);
  if (words.length > 0) {
    link.words = words;
    link.word = pullStateWord(found.pull) ?? undefined;
  }
  return link;
}

/** The last column of a session's line: `waits 4m` for one that waits on
 * a person, as the `Sessions components` frame draws it, else how long
 * since its output. */
function sessionSince(row: ModelRow, since: string | null, now: number): string | null {
  const state = stateOf(row);
  if (since === null || (state !== "needs-input" && state !== "needs-approval")) return since;
  return waitLabel({ stage: "blocked", since: row.lastOutputAt }, now) ?? since;
}

/** Where a scope with no goal sorts: after every stage. */
const NO_STAGE_RANK = STAGE_ORDER.length;

export function tree<R extends ModelRow>(input: TreeInput<R>): Tree<R> {
  const { rows, projects, goalsOf, approvals, proposed, usage, billOf, pullsOf, now } = input;
  const idle = rows.filter(isIdleShell);
  const listed = rows.filter((row) => !isIdleShell(row));
  const sections = levels(listed, rows, projects, goalsOf);
  const headed = sections.flatMap((s) => (s.heading?.path ? [s.heading.path] : []));
  // Every cost follows the rollup's range (round 13); no rollup, no cost.
  const range = usage ? { from: usage.from, to: usage.to } : null;
  const summaryOf = (projectId: string): ProjectSummary | undefined => projects.find((p) => p.id === projectId);

  const ownedBy = (key: string): R[] => rows.filter((row) => (row.project?.id ?? NO_PROJECT) === key);

  const sessionLine = (row: R, depth: number): TreeLine<R> => {
    const line = rowLine(row, now);
    const state = stateOf(row);
    const title = [line.what, row.cwd].filter((t): t is string => t !== null && t !== "").join("\n");
    return {
      kind: "session",
      key: `session:${row.id}`,
      depth,
      name: rowName(row),
      title: title === "" ? null : title,
      detail: null,
      state: { family: markFamily(state), tag: stateTag(row) },
      facts: sessionFactColumns(range ? sessionCost(billOf?.(row.id), range) : undefined, rowModel(row), row.agentModel, sessionSince(row, line.since, now), sessionCostTitle(billOf?.(row.id), now)),
      row,
      mark: markFamily(state),
      needs: rowNeeds(row),
      approvals: approvalsOf(row, approvals),
    };
  };

  /** One goal and what sits under it. `keepOpen` is a done goal the
   * project shows open (its latest, or one a live session labels);
   * `folded` is a goal inside the `N done` fold. */
  const goalLines = (
    line: GoalLine,
    goalRows: R[],
    project: ProjectRef,
    owned: R[],
    depth: number,
    staged: LineStage,
    pulls: readonly PullRequest[] | null,
    mode: "open" | "keepOpen" | "folded" = "open",
  ): TreeLine<R>[] => {
    const summary = line.summary;
    const folded = mode === "folded";
    const base = summaryOf(project.id)?.pullRequestBase;
    const item = proposed.find((p) => p.project.id === project.id && p.summary.slug === summary.slug) ?? null;
    const found = goalPull(summary, owned, pulls);
    const { tasks, rest } = taskLines(summary, goalRows, owned);
    // A goal inside the `N done` fold opens to all its tasks; one outside
    // it shows its first two done ones. The order is the stage's.
    const staging = (folded ? tasks : shownTasks(tasks)).map((task) => {
      const listedTask: TaskSummary = summary.tasks?.find((t) => t.slug === task.slug) ?? { slug: task.slug, state: "pending", round: task.round, pr: task.pr };
      return { task, stage: taskStage(summary, listedTask, owned, pulls) };
    });
    const shown = sortByStage(staging, (entry) => entry.stage.stage);
    const children: TreeLine<R>[] = [];
    for (const { task, stage } of shown) {
      // A task prints a pull request only when the number is not its
      // goal's. A number the goal has only from a record is a task's own.
      const own = found !== null && found.by !== "record" && found.number === task.pr ? undefined : task.pr;
      const facts = taskFactColumns(range ? taskCost(summary, task.round, range) : undefined, own, base);
      const wait = waitLabel(stage, now);
      if (wait !== null) facts.push(fact("wait", wait, 4));
      const family = stageMark(stage);
      children.push({
        kind: "task",
        key: `task:${project.id}:${summary.slug ?? ""}:${task.slug}`,
        depth: depth + 1,
        name: task.slug,
        title: taskTooltip(task.round, task.pr),
        detail: stage.reason ?? null,
        state: { family, tag: stageTag(stage.stage) },
        facts,
        mark: family,
        stage,
        children: task.rows.length > 0,
      });
      for (const row of task.rows) children.push(sessionLine(row, depth + 2));
    }
    for (const row of rest) children.push(sessionLine(row, depth + 1));
    const name = line.unwritten ? line.title : (summary.slug ?? goalTitle(summary));
    const purpose = line.unwritten || goalTitle(summary) === name ? null : goalTitle(summary);
    const facts = line.unwritten || range === null ? [] : goalFactColumns(goalCost(summary, range));
    if (found !== null) facts.push(pullFactColumn(found, base));
    const wait = waitLabel(staged, now);
    const counter = line.unwritten || staged.stage === "done" ? null : roundCounter(summary);
    if (wait !== null) facts.push(fact("wait", wait, 4));
    else if (counter !== null) facts.push(fact("counter", counter, 4));
    const head: TreeLine<R> = {
      kind: "goal",
      key: `goal:${project.id}:${summary.slug ?? goalTitle(summary)}`,
      depth,
      name,
      title: line.unwritten ? "not written yet" : goalTooltip(roundCounter(summary), nextLine(summary.nextAction)),
      detail: staged.reason ?? purpose,
      state: { family: stageMark(staged), tag: stageTag(staged.stage) },
      facts,
      project,
      summary,
      children: children.length > 0,
      href: knowledgeUrl(project.id, item?.path ?? recordPath(summary) ?? statePath(summary)),
      proposed: item,
      stage: staged,
    };
    // A goal with no open task starts closed (approved rule 3): nothing
    // under it but done tasks, and no session.
    const nothingOpen = children.length > 0 && goalRows.length === 0 && shown.every((entry) => entry.stage.stage === "done");
    if (folded || (mode === "open" && nothingOpen)) head.closed = true;
    return [head, ...children];
  };

  /** A project's lines and the stage of each of its goals, for the
   * counts of the scope above it. */
  const projectLines = (p: ProjectSection<R>, depth: number): { lines: TreeLine<R>[]; stages: Stage[] } => {
    const owned = ownedBy(p.key);
    const bucket = usage && p.project ? projectUsage(usage, p.project.root) : null;
    const answer = p.project ? pullsOf?.(p.project.id) : undefined;
    const pulls = readPulls(answer);
    const { working: live, pending, done } = p.goals;
    const stageOf = new Map<KnowledgeSummary, LineStage>();
    for (const summary of [...live.map((entry) => entry.line.summary), ...pending.map((line) => line.summary), ...done]) {
      stageOf.set(summary, goalStage(summary, owned, pulls));
    }
    const stages = [...stageOf.values()].map((staged) => staged.stage);
    // The one line that says why the pull requests carry no state takes
    // the place of the counts; a page that reads none says nothing.
    const reason = pullsOf && p.project && stages.length > 0 ? projectPullsReason(summaryOf(p.project.id) ?? {}, answer, now) : null;
    const lines: TreeLine<R>[] = [
      {
        kind: "project",
        key: `project:${p.key}`,
        depth,
        name: p.heading.name,
        // A running session's estimate is on its own line and on no
        // figure above it, because the rollup counts a session once its
        // transcript is billed; the project's tooltip says what is coming.
        title: [p.heading.path, p.noGoals, billOf ? runningEstimate(owned, billOf) : null].filter((t): t is string => t !== null && t !== undefined).join("\n") || null,
        // A lone project is its own scope and prints its path; one under
        // a workspace prints its counts alone.
        detail: reason ?? detailOf([depth === 0 && p.heading.path ? homePath(p.heading.path) : null, stageCounts(stages)]),
        state: null,
        facts: headingFactColumns(usage && p.project ? costLabel(bucket) : null, agentsLabel(working(owned)), p.heading.name),
        project: p.project,
        children: false,
      },
    ];
    const head = lines[0] as Extract<TreeLine<R>, { kind: "project" }>;
    if (!p.project) {
      for (const row of p.rows) lines.push(sessionLine(row, depth + 1));
      head.children = lines.length > 1;
      return { lines, stages };
    }
    // A session whose label names a done goal sits under that goal.
    const doneSlugs = new Set(done.map((g) => g.slug).filter((s): s is string => s !== undefined));
    const underDone = p.rows.filter((row) => {
      const goal = goalOf(row);
      return goal !== null && doneSlugs.has(goal);
    });
    for (const row of p.rows) if (!underDone.includes(row)) lines.push(sessionLine(row, depth + 1));
    // The goals that are not done by status, the line that waits on the
    // human first (rule 3 of the `Sessions components` frame).
    const open = sortByStage(
      [...live.map((entry) => ({ line: entry.line, rows: entry.rows })), ...pending.map((line) => ({ line, rows: [] as R[] }))],
      (entry) => stageOf.get(entry.line.summary)!.stage,
    );
    for (const entry of open) lines.push(...goalLines(entry.line, entry.rows, p.project, owned, depth + 1, stageOf.get(entry.line.summary)!, pulls));
    const latest = latestDoneGoal(done);
    const shownDone = done.filter((g) => g === latest || underDone.some((row) => goalOf(row) === g.slug));
    const folded = done.filter((g) => !shownDone.includes(g));
    for (const goal of shownDone) {
      const goalRows = underDone.filter((row) => goalOf(row) === goal.slug);
      lines.push(...goalLines(doneGoalLine(goal), goalRows, p.project, owned, depth + 1, stageOf.get(goal)!, pulls, "keepOpen"));
    }
    if (folded.length > 0) {
      lines.push({
        kind: "fold",
        key: `fold:done:${p.key}`,
        depth: depth + 1,
        name: doneLabel(folded.length),
        title: null,
        detail: null,
        state: null,
        facts: [],
        lines: folded.flatMap((goal) => goalLines(doneGoalLine(goal), [], p.project!, owned, depth + 1, stageOf.get(goal)!, pulls, "folded")),
      });
    }
    head.children = lines.length > 1;
    // A project with every goal done and no live session starts closed,
    // with its count on its line (approved rule 3).
    if (stages.length > 0 && stages.every((stage) => stage === "done") && !lines.some((line) => line.kind === "session")) head.closed = true;
    return { lines, stages };
  };

  const workspaceLines = (s: WorkspaceSection<R>): TreeLine<R>[] => {
    const heading = s.heading!;
    const inside = rows.filter((row) => workspaceHome(row.project?.root ?? row.cwd, [heading.path!]) === heading.path);
    // The projects in the order of their most urgent goal; a project with
    // no goal is last.
    const built = s.projects
      .map((p, index) => ({ ...projectLines(p, 1), index }))
      .map((entry) => ({ ...entry, rank: Math.min(NO_STAGE_RANK, ...entry.stages.map((stage) => STAGE_ORDER.indexOf(stage))) }))
      .sort((a, b) => a.rank - b.rank || a.index - b.index);
    const count = s.projects.length;
    const lines: TreeLine<R>[] = [
      {
        kind: "workspace",
        key: `workspace:${heading.path}`,
        depth: 0,
        name: heading.name,
        title: heading.path,
        detail: detailOf([homePath(heading.path!), `${count} ${count === 1 ? "project" : "projects"}`, stageCounts(built.flatMap((entry) => entry.stages))]),
        state: null,
        facts: headingFactColumns(usage ? costLabel(workspaceUsage(usage, heading.path, headed)) : null, agentsLabel(working(inside)), heading.name),
        path: heading.path!,
        children: s.rows.length > 0 || built.length > 0,
      },
    ];
    for (const row of s.rows) lines.push(sessionLine(row, 1));
    for (const entry of built) lines.push(...entry.lines);
    return lines;
  };

  const out: TreeSection<R>[] = [];
  let none: TreeSection<R> | null = null;
  for (const s of sections) {
    if (s.heading === null) {
      const p = s.projects[0];
      const section = { key: p.key, label: p.heading.name, lines: projectLines(p, 0).lines };
      if (p.key === NO_PROJECT) none = section;
      out.push(section);
      continue;
    }
    out.push({ key: `workspace:${s.heading.path}`, label: s.heading.name, lines: workspaceLines(s) });
  }
  // An approval whose session is gone is a line under "No project", which
  // the page makes for it when no loose shell would.
  const orphans = orphanApprovals(approvals, rows);
  if (orphans.length > 0) {
    if (none === null) {
      none = {
        key: NO_PROJECT,
        label: NO_PROJECT_NAME,
        lines: [{ kind: "project", key: `project:${NO_PROJECT}`, depth: 0, name: NO_PROJECT_NAME, title: null, detail: null, state: null, facts: [], project: null, children: true }],
      };
      out.push(none);
    }
    for (const approval of orphans) {
      none.lines.push({
        kind: "approval",
        key: `approval:${approval.id}`,
        depth: 1,
        name: `approve ${approval.tool}`,
        title: null,
        detail: null,
        state: null,
        facts: [],
        approval,
      });
    }
  }
  return { sections: out, idle };
}

/** A done goal as a line: `[done]`, its cost and its counter. */
function doneGoalLine(summary: KnowledgeSummary): GoalLine {
  return { summary, title: goalTitle(summary), unwritten: false, status: "done", round: null, next: nextLine(summary.nextAction) };
}

/** Whether a line that folds is open: every line starts open but a goal
 * or a project marked `closed`, and a key in `toggled` flips its line's
 * default. */
export function isOpen<R extends ModelRow>(line: TreeLine<R>, toggled: ReadonlySet<string>): boolean {
  const closedByDefault = (line.kind === "goal" || line.kind === "project") && line.closed === true;
  return closedByDefault === toggled.has(line.key);
}

/**
 * The lines a section paints: every line, less what sits under a
 * workspace, a project, a goal or a task that is not open (`isOpen`;
 * `toggled` holds the keys the reader clicked). A line is under another
 * when it follows it at a greater depth, until the next line at the same
 * depth or less, so a closed goal hides its tasks and their sessions, and
 * a closed project hides everything down to its `N done` fold. A key of
 * any other kind changes nothing.
 */
export function visibleLines<R extends ModelRow>(lines: readonly TreeLine<R>[], toggled: ReadonlySet<string>): TreeLine<R>[] {
  const out: TreeLine<R>[] = [];
  let hideBelow: number | null = null;
  for (const line of lines) {
    if (hideBelow !== null && line.depth > hideBelow) continue;
    hideBelow = null;
    out.push(line);
    const folds = line.kind === "workspace" || line.kind === "project" || line.kind === "goal" || line.kind === "task";
    if (folds && !isOpen(line, toggled)) hideBelow = line.depth;
  }
  return out;
}

/** One cell of the hairlines at a line's left, one per level above it:
 * `pass` a parent's line running by, `none` nothing, and for the line's
 * own level `tee` (a child with a sibling after it) or `end` (the last
 * child). */
export type Join = "pass" | "none" | "tee" | "end";

/**
 * The hairline joins of each of `lines`, the lines a section paints in
 * order (rule 4 of the `Sessions components` frame): a line at depth `d`
 * gets `d` cells, a top-level line none. A level's line runs by while a
 * later line sits at that level before the list climbs above it. `outer`
 * is the cells of the levels above the list's own shallowest line, for
 * the lines inside a fold: the fold's own cells less its last.
 */
export function joins(lines: readonly { depth: number }[], outer: readonly Join[] = []): Join[][] {
  const top = lines.reduce((min, line) => Math.min(min, line.depth), Number.POSITIVE_INFINITY);
  return lines.map((line, i) => {
    const cells: Join[] = [];
    for (let level = 1; level <= line.depth; level++) {
      if (level < top) {
        cells.push(outer[level - 1] ?? "none");
        continue;
      }
      let later = false;
      for (let j = i + 1; j < lines.length; j++) {
        if (lines[j]!.depth < level) break;
        if (lines[j]!.depth === level) {
          later = true;
          break;
        }
      }
      cells.push(level === line.depth ? (later ? "tee" : "end") : later ? "pass" : "none");
    }
    return cells;
  });
}
