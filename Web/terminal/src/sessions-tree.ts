/**
 * The tree as flat lines (`agent-dashboard`, round 10; the frames
 * `Dashboard 1200` and `Dashboard 390` in `corpus/dashboard.pen`). No DOM,
 * no clock beyond the `now` it is handed; `sessions.ts` paints what this
 * returns, one `.line` per entry.
 *
 * Every line has the same cells: a mark at the far left of the page, an
 * indent per level, a name, then four right-aligned fact columns of fixed
 * width — the state word, a number (a cost, a model, `round 6`, or a
 * goal's `r0/3` when it has no cost), a pull request (or the counter of a
 * goal that has a cost), and a trailing fact (a time, `1 agent`). On a
 * phone the columns give way to the state word and one fact per level:
 * a project's cost, a goal's cost or counter, a task's round, a session's
 * time (`narrow`).
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
 * `visibleLines` hides what sits under a closed one.
 */

import {
  agentsLabel,
  approvalsOf,
  costLabel,
  doneLabel,
  goalCost,
  goalOf,
  goalTag,
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
  recordPath,
  roundCounter,
  rowLine,
  rowModel,
  rowName,
  rowNeeds,
  shownTasks,
  statePath,
  stateOf,
  stateTag,
  taskLines,
  taskMark,
  workspaceHome,
  workspaceUsage,
  type Approval,
  type GoalLine,
  type KnowledgeSummary,
  type MarkFamily,
  type ModelRow,
  type ProjectRef,
  type ProjectSection,
  type ProjectSummary,
  type ProposedItem,
  type UsageDaily,
  type VocabularyEntry,
  type WorkspaceSection,
} from "./sessions-model";

/** What a fact is, which is also its class on the page. */
export type TreeFactKind = "cost" | "counter" | "round" | "pr" | "model" | "since" | "agents";

/** One fact of a line: its text, the column it sits in at 768 px and up
 * (2, 3 or 4; the state word is column 1), and whether it is the one fact
 * the line keeps on a phone. */
export type TreeFact = { kind: TreeFactKind; text: string; column: 2 | 3 | 4; narrow: boolean; title?: string };

/** The cells every line shares. `state` is the bracketed word and the
 * family that colours its mark; null on a heading line, which has no
 * state. `title` is the name's tooltip. */
export type TreeLineBase = {
  key: string;
  /** Indent levels below the top of the page. */
  depth: number;
  name: string;
  title: string | null;
  state: VocabularyEntry | null;
  facts: TreeFact[];
};

export type TreeLine<R extends ModelRow> =
  | (TreeLineBase & { kind: "workspace"; path: string })
  /** `children` is whether anything sits under the line, which is what
   * the disclosure triangle folds; a project with nothing under it wears
   * a blank mark. The reason a project lists no goal is on the name's
   * tooltip. */
  | (TreeLineBase & { kind: "project"; project: ProjectRef | null; children: boolean })
  /** `href` opens the latest record, else `STATE.md`. `proposed` is the
   * item whose `N proposals` ride on the name's tooltip. */
  | (TreeLineBase & {
      kind: "goal";
      project: ProjectRef;
      summary: KnowledgeSummary;
      children: boolean;
      href: string;
      proposed: ProposedItem | null;
    })
  | (TreeLineBase & { kind: "task"; mark: MarkFamily })
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
  now: number;
};

const fact = (kind: TreeFactKind, text: string, column: 2 | 3 | 4, narrow = false, title?: string): TreeFact =>
  title === undefined ? { kind, text, column, narrow } : { kind, text, column, narrow, title };

/** The facts of a goal's line: the cost in column 2 and the counter in
 * column 4 when it has both, as the frame draws `workspace-ledger [done]
 * $75.11 r6/3`; the counter alone in column 2, `agent-dashboard [waiting]
 * r0/3`. The phone keeps the cost, else the counter. */
export function goalFactColumns(cost: string | null, counter: string | null): TreeFact[] {
  const facts: TreeFact[] = [];
  if (cost !== null) facts.push(fact("cost", cost, 2, true, "the sum of the Cost lines of this goal's round records started in the range, at the full API rate"));
  if (counter !== null) facts.push(fact("counter", counter, cost !== null ? 4 : 2, cost === null));
  return facts;
}

/** The facts of a task's line: `round 6` in column 2, `PR #124` in column
 * 3. The phone keeps the round. */
export function taskFactColumns(round: number | undefined, pr: number | undefined): TreeFact[] {
  const facts: TreeFact[] = [];
  if (typeof round === "number") facts.push(fact("round", `round ${round}`, 2, true));
  if (typeof pr === "number") facts.push(fact("pr", `PR #${pr}`, 3));
  return facts;
}

/** The facts of a session's line: its model in column 2, how long since
 * its last output in column 4. The phone keeps the time. */
export function sessionFactColumns(model: string | null, modelId: string | undefined, since: string | null): TreeFact[] {
  const facts: TreeFact[] = [];
  if (model !== null) facts.push(fact("model", model, 2, false, modelId));
  if (since !== null) facts.push(fact("since", since, 4, true));
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

export function tree<R extends ModelRow>(input: TreeInput<R>): Tree<R> {
  const { rows, projects, goalsOf, approvals, proposed, usage, now } = input;
  const idle = rows.filter(isIdleShell);
  const listed = rows.filter((row) => !isIdleShell(row));
  const sections = levels(listed, rows, projects, goalsOf);
  const headed = sections.flatMap((s) => (s.heading?.path ? [s.heading.path] : []));

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
      state: { family: markFamily(state), tag: stateTag(row) },
      facts: sessionFactColumns(rowModel(row), row.agentModel, line.since),
      row,
      mark: markFamily(state),
      needs: rowNeeds(row),
      approvals: approvalsOf(row, approvals),
    };
  };

  const goalLines = (
    line: GoalLine,
    goalRows: R[],
    project: ProjectRef,
    owned: R[],
    depth: number,
    bucket: "working" | "pending",
  ): TreeLine<R>[] => {
    const summary = line.summary;
    const item = proposed.find((p) => p.project.id === project.id && p.summary.slug === summary.slug) ?? null;
    const word = goalTag(bucket, line.status, item !== null);
    const { tasks, rest } = taskLines(summary, goalRows, owned);
    const shown = shownTasks(tasks);
    const children: TreeLine<R>[] = [];
    for (const task of shown) {
      children.push({
        kind: "task",
        key: `task:${project.id}:${summary.slug ?? ""}:${task.slug}`,
        depth: depth + 1,
        name: task.slug,
        title: null,
        state: { family: taskMark(task.state), tag: task.tag },
        facts: taskFactColumns(task.round, task.pr),
        mark: taskMark(task.state),
      });
      for (const row of task.rows) children.push(sessionLine(row, depth + 2));
    }
    for (const row of rest) children.push(sessionLine(row, depth + 1));
    const next = line.unwritten ? "not written yet" : nextLine(summary.nextAction);
    const head: TreeLine<R> = {
      kind: "goal",
      key: `goal:${project.id}:${summary.slug ?? goalTitle(summary)}`,
      depth,
      name: line.unwritten ? line.title : goalTitle(summary),
      title: next,
      state: line.unwritten ? null : word,
      facts: line.unwritten ? [] : goalFactColumns(usage ? goalCost(summary, usage) : null, roundCounter(summary)),
      project,
      summary,
      children: children.length > 0,
      href: knowledgeUrl(project.id, item?.path ?? recordPath(summary) ?? statePath(summary)),
      proposed: item,
    };
    return [head, ...children];
  };

  const projectLines = (p: ProjectSection<R>, depth: number): TreeLine<R>[] => {
    const owned = ownedBy(p.key);
    const bucket = usage && p.project ? projectUsage(usage, p.project.root) : null;
    const lines: TreeLine<R>[] = [
      {
        kind: "project",
        key: `project:${p.key}`,
        depth,
        name: p.heading.name,
        title: [p.heading.path, p.noGoals].filter((t): t is string => t !== null).join("\n") || null,
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
      return lines;
    }
    const { working: live, pending, done } = p.goals;
    // A session whose label names a done goal sits under that goal.
    const doneSlugs = new Set(done.map((g) => g.slug).filter((s): s is string => s !== undefined));
    const underDone = p.rows.filter((row) => {
      const goal = goalOf(row);
      return goal !== null && doneSlugs.has(goal);
    });
    for (const row of p.rows) if (!underDone.includes(row)) lines.push(sessionLine(row, depth + 1));
    for (const entry of live) lines.push(...goalLines(entry.line, entry.rows, p.project, owned, depth + 1, "working"));
    for (const line of pending) lines.push(...goalLines(line, [], p.project, owned, depth + 1, "pending"));
    const latest = latestDoneGoal(done);
    const open = done.filter((g) => g === latest || underDone.some((row) => goalOf(row) === g.slug));
    const folded = done.filter((g) => !open.includes(g));
    for (const goal of open) {
      const goalRows = underDone.filter((row) => goalOf(row) === goal.slug);
      lines.push(...goalLines(doneGoalLine(goal), goalRows, p.project, owned, depth + 1, "pending"));
    }
    if (folded.length > 0) {
      lines.push({
        kind: "fold",
        key: `fold:done:${p.key}`,
        depth: depth + 1,
        name: doneLabel(folded.length),
        title: null,
        state: null,
        facts: [],
        lines: folded.map((goal) => goalLines(doneGoalLine(goal), [], p.project!, owned, depth + 1, "pending")[0]),
      });
    }
    head.children = lines.length > 1;
    return lines;
  };

  const workspaceLines = (s: WorkspaceSection<R>): TreeLine<R>[] => {
    const heading = s.heading!;
    const inside = rows.filter((row) => workspaceHome(row.project?.root ?? row.cwd, [heading.path!]) === heading.path);
    const lines: TreeLine<R>[] = [
      {
        kind: "workspace",
        key: `workspace:${heading.path}`,
        depth: 0,
        name: heading.name,
        title: heading.path,
        state: null,
        facts: headingFactColumns(usage ? costLabel(workspaceUsage(usage, heading.path, headed)) : null, agentsLabel(working(inside)), heading.name),
        path: heading.path!,
      },
    ];
    for (const row of s.rows) lines.push(sessionLine(row, 1));
    for (const p of s.projects) lines.push(...projectLines(p, 1));
    return lines;
  };

  const out: TreeSection<R>[] = [];
  let none: TreeSection<R> | null = null;
  for (const s of sections) {
    if (s.heading === null) {
      const p = s.projects[0];
      const section = { key: p.key, label: p.heading.name, lines: projectLines(p, 0) };
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
        lines: [{ kind: "project", key: `project:${NO_PROJECT}`, depth: 0, name: NO_PROJECT_NAME, title: null, state: null, facts: [], project: null, children: true }],
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
        state: null,
        facts: [],
        approval,
      });
    }
  }
  return { sections: out, idle };
}

/** A done goal as a line: `[done]` in grey, its cost and its counter. */
function doneGoalLine(summary: KnowledgeSummary): GoalLine {
  return { summary, title: goalTitle(summary), unwritten: false, status: "done", round: null, next: nextLine(summary.nextAction) };
}

/**
 * The lines a section paints: every line, less what sits under a project
 * or a goal in `closed` (by `key`). A line is under another when it
 * follows it at a greater depth, until the next line at the same depth or
 * less, so a closed goal hides its tasks and their sessions, and a closed
 * project hides everything down to its `N done` fold. A workspace is
 * always open and a closed key of any other kind changes nothing.
 */
export function visibleLines<R extends ModelRow>(lines: readonly TreeLine<R>[], closed: ReadonlySet<string>): TreeLine<R>[] {
  const out: TreeLine<R>[] = [];
  let hideBelow: number | null = null;
  for (const line of lines) {
    if (hideBelow !== null && line.depth > hideBelow) continue;
    hideBelow = null;
    out.push(line);
    if ((line.kind === "project" || line.kind === "goal") && closed.has(line.key)) hideBelow = line.depth;
  }
  return out;
}
