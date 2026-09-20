/**
 * The fleet view's model: pure functions over the rows of `GET /api/sessions`
 * and the projects of `GET /api/projects`. No DOM, so every function has a
 * test. `sessions.ts` composes them and paints the result.
 */

export type MergedState =
  | "working"
  | "needs-approval"
  | "needs-input"
  | "completed"
  | "failed"
  | "idle"
  | "exited"
  | "unknown";

/** The `project` field of a session or archive row. */
export type ProjectRef = {
  id: string;
  name: string;
  root?: string;
  registered: boolean;
};

/** One entry of `GET /api/projects`: the identity plus the knowledge
 * directory. The page counts what it shows from the rows. */
export type ProjectSummary = ProjectRef & {
  knowledge?: string;
  /** `https://github.com/owner/repo/pull/`, from the checkout's `origin`
   * remote when it is on GitHub; absent otherwise, and the page then
   * prints a pull request as plain text (round 15). */
  pullRequestBase?: string;
};

/** The link of pull request `n` under `base`, or null with no base. */
export function pullRequestHref(base: string | undefined, n: number): string | null {
  return base ? `${base}${n}` : null;
}

/** The subset of a session row the model reads. The page's row type extends it. */
export type ModelRow = {
  id: string;
  cwd: string;
  name?: string;
  lastCommand?: string;
  state?: "running" | "idle" | "unknown";
  mergedState?: MergedState;
  lastExit?: number;
  labels?: Record<string, string>;
  orchestrated?: boolean;
  project?: ProjectRef;
  lastOutputAt?: number;
  /** Free-text status note set by a program or a person (`post_note`). */
  note?: string;
  /** The session's latest Claude Code hook report; the row reads the message. */
  agent?: { message?: string };
  /** The model id the session's transcript last answered with, as Claude
   * Code wrote it; absent until the session has an assistant turn. */
  agentModel?: string;
  /** The name the daemon derives from `agentModel` by the naming rule of
   * `design-foundation.md`: `Fable 5.1`, `Opus 5 · 1M`, or the id unchanged. */
  agentModelName?: string;
  /** The Claude Code transcript the session's hooks named, as the daemon
   * stored it; the page reads its bill from `GET /api/sessions/<id>/cost`
   * only for a row that carries one. */
  agentTranscript?: string;
};

/** What the page keeps of `GET /api/sessions/<id>/cost`: whether the
 * transcript ends in a bill, its dollars and when the session began.
 * `hasBill` is false for a running session, whose transcript has no
 * `cost-state` line yet; the route then prices its turns so far under
 * `estimate` (round 16), which the page prints as `~$4.20`. */
export type SessionBill = {
  hasBill: boolean;
  totalCostUSD?: number;
  /** Epoch milliseconds, the bill's `startTime`; absent on an old line. */
  startTime?: number;
  /** The running session's turns priced, when there is no bill. */
  estimate?: SessionEstimate;
};

/** The estimate the cost route answers for a running session, with when
 * the page fetched it, for the tooltip's `updated 12s ago`. */
export type SessionEstimate = {
  costUSD: number;
  /** API requests counted. */
  turns: number;
  /** Epoch milliseconds of the first counted turn; absent on a line with
   * no timestamp. */
  startTime?: number;
  /** Epoch milliseconds: when the page last fetched the estimate. */
  updatedAt: number;
};

export type Approval = {
  id: string;
  tool: string;
  input: string;
  session?: string;
  waitingMs: number;
};

/** Rows that share one `crew:` label inside a project. `crew` is null for the
 * rows without the label, and for the only section when the labels agree. */
export type CrewSection<R extends ModelRow> = { crew: string | null; rows: R[] };

export type Group<R extends ModelRow> = {
  /** The project id, or "" for the rows outside every project. */
  key: string;
  project: ProjectRef | null;
  rows: R[];
  sections: CrewSection<R>[];
};

export type AttentionItem<R extends ModelRow> =
  | { kind: "approval"; approval: Approval; row: R | null }
  | { kind: "needs-input"; row: R }
  | { kind: "failed"; row: R };

/** What `GET /api/projects/<id>/knowledge` answers: one summary per goal
 * folder under the knowledge directory, `active` first, then `waiting`,
 * `stopped`, `done`, the rest, and by slug; empty for a package with no
 * goal folder. */
export type KnowledgeAnswer = {
  ok: boolean;
  project: string;
  goals: KnowledgeSummary[];
};

/** The summary of one goal folder of a project's knowledge package, one
 * entry of `KnowledgeAnswer.goals`, with the project's id added by the
 * page. Every field but `project` is absent when the file or the line
 * behind it is missing. */
export type KnowledgeSummary = {
  project: string;
  /** The goal folder's name; what a `goal:` label names. */
  slug?: string;
  goal?: string;
  status?: string;
  round?: number;
  budget?: number;
  lastFloor?: string;
  nextAction?: string;
  proposals?: number;
  lastRound?: number;
  /** The latest record's path under the knowledge directory by its real
   * file name, `<slug>/rounds/7.md` included. Absent from a daemon before
   * v0.24. */
  lastRecord?: string;
  /** The first line of the latest round record's `## Decision` section. */
  lastDecision?: string;
  /** The sum of the goal's records' `- Cost:` lines, dollars at the full
   * API rate; absent when no record carries one. From a daemon since
   * capability 5 of `workspace-ledger`. */
  costUSD?: number;
  /** The summed `in` tokens of those lines: input, cache creation and
   * cache read together. */
  inTokens?: number;
  /** The cache-read part of `inTokens`. */
  cacheReadTokens?: number;
  /** The goal's tasks from `STATE.md`: one per slug under `## Queue`
   * (pending), `## Failures` (failed) and `## Done` (done), in that order,
   * each slug once. Absent from a daemon before capability 3 of
   * `agent-dashboard`, and for a `STATE.md` with none of the three
   * headings; empty for one whose headings list nothing. */
  tasks?: TaskSummary[];
  /** One entry per `rounds/<N>.md`, by number, from a daemon since
   * capability 7 of `agent-dashboard`; absent for a goal with no record.
   * The `WHERE` panel groups by goal and by task from these. */
  rounds?: RoundRecord[];
};

/** One round record on the wire: `KnowledgeSummary.rounds[]`. Every field
 * but the number and the flag is absent when the record has no line for
 * it, so a round with no `- Cost:` line prices at nothing, never at
 * zero. */
export type RoundRecord = {
  number: number;
  /** The queue item after `# Round NNN:`. */
  task?: string;
  /** `YYYY-MM-DD` from the `- Started:` line. */
  started?: string;
  /** The sum of the record's `- Cost:` lines. */
  costUSD?: number;
  /** The summed `Hh Mm` of those lines, in milliseconds. */
  durationMs?: number;
  /** The `PR #N` the `- Result:` line names. */
  pr?: number;
  /** The record carries a `## Correction` section. */
  correction: boolean;
};

/** One task on the wire: `KnowledgeSummary.tasks[]`. `working` never comes
 * from the daemon; the page joins it from a live `task:` label
 * (`taskLines`). */
export type TaskSummary = {
  slug: string;
  state: "pending" | "done" | "failed";
  /** The round the line names, `round 2`, when it does. */
  round?: number;
  /** The pull request the line names, `PR #126`, when it does. */
  pr?: number;
};

/** The four states a task line prints (`design-foundation.md`, Hierarchy). */
export type TaskState = "working" | "pending" | "done" | "failed";

/** One task under its goal, the fourth level: the slug, its state, the
 * bracketed word the state reads as, the facts after it, and the listed
 * rows that carry its label, the crew's row under a working task. */
export type TaskLine<R extends ModelRow> = {
  slug: string;
  state: TaskState;
  /** `[working]`, `[pending]`, `[done]`, `[failed]` (`taskTag`). */
  tag: string;
  /** `round 1`, `PR #118`; empty for a task whose line names neither. */
  facts: string[];
  /** The numbers behind the facts, for the tree's columns. */
  round?: number;
  pr?: number;
  rows: R[];
};

/** What a goal prints under its line: its tasks, then the rows no task
 * claimed, which stay under the goal as before the level existed. */
export type TaskLines<R extends ModelRow> = { tasks: TaskLine<R>[]; rest: R[] };

/** One goal that is not done, as its project prints it on one line: the
 * title, the status word when the goal is not active, the round counter,
 * and the first line of the next action. `unwritten` is a goal whose files
 * still hold the template's placeholders; it prints "not written yet" in
 * place of them. */
export type GoalLine = {
  summary: KnowledgeSummary;
  title: string;
  unwritten: boolean;
  status: string | null;
  round: string | null;
  next: string | null;
};

/** What a project prints for its goals: one line per goal that is not
 * done, then the done goals behind one folded line. */
export type GoalLines = { open: GoalLine[]; done: KnowledgeSummary[] };

/** A goal whose `STATE.md` lists proposals waiting on the human: the human
 * has to decide before the goal's next round. */
export type ProposedItem = {
  kind: "proposed";
  project: ProjectRef;
  summary: KnowledgeSummary;
  /** The round the proposals belong to: the latest record's, else the
   * `STATE.md` counter, else 0; part of the Dismiss key. */
  round: number;
  /** How many proposals `STATE.md` lists. */
  count: number;
  /** The latest record's path when there is one, `recordPath`. */
  record: string | null;
  /** What the item links: the record, else the goal's `STATE.md`. */
  path: string;
  /** The latest record's decision line when it proposes; null when the
   * proposals live in `STATE.md` alone. */
  decision: string | null;
};

/** The key of the group for rows outside every project. */
export const NO_PROJECT = "";

/** The label value that marks the foreman's own pane (LOOP.md, Labels). */
export const FOREMAN_CREW = "foreman";

/** The merged crew state, or one synthesized for a daemon too old to send it. */
export function stateOf(row: ModelRow): MergedState {
  if (row.mergedState) return row.mergedState;
  if (row.state === "running") return "working";
  if (typeof row.lastExit === "number" && row.lastExit !== 0) return "failed";
  if (row.state === "idle") return "idle";
  return "unknown";
}

export function crewOf(row: ModelRow): string | null {
  const crew = row.labels?.crew;
  return crew ? crew : null;
}

/** Split the foreman's pane from the rows a card lists. The first row whose
 * `crew` label is `foreman` is the foreman; a second one stays in its card. */
export function pickForeman<R extends ModelRow>(rows: R[]): { foreman: R | null; rest: R[] } {
  const index = rows.findIndex((row) => crewOf(row) === FOREMAN_CREW);
  if (index < 0) return { foreman: null, rest: rows };
  return { foreman: rows[index], rest: rows.filter((_, i) => i !== index) };
}

/**
 * The rank of a row inside its project: what the human is asked to act on
 * first, then the foreman, then the rows by state. The state comes before
 * the recency because a returning reader asks "what is still working", and
 * a working row that went quiet three hours ago, which is the one that
 * stalled, is what the reader must see before an idle shell that printed a
 * prompt a minute ago. Recency then answers which of the working rows
 * stalled. Recency alone would also reorder the rows on every poll, as the
 * working rows' last output ticks.
 */
function rank(row: ModelRow): number {
  const state = stateOf(row);
  switch (state) {
    case "needs-approval":
      return 0;
    case "needs-input":
      return 1;
    case "failed":
      return 2;
  }
  // The foreman is the first row of its project, ahead of the rows it
  // supervises, whatever its own state: `done` with a note is its usual one.
  if (crewOf(row) === FOREMAN_CREW) return 3;
  switch (state) {
    case "working":
      return 4;
    case "completed":
      return 5;
    case "idle":
      return 6;
    case "exited":
      return 7;
    default:
      return 8;
  }
}

/** Attention first (needs-approval, needs-input, failed), then the foreman,
 * then by state (working, done, idle, exited, no integration), then the
 * most recent output first. Stable: equal rows keep their input order. */
export function sortInGroup<R extends ModelRow>(rows: R[]): R[] {
  return rows
    .map((row, index) => ({ row, index }))
    .sort((a, b) => {
      const byRank = rank(a.row) - rank(b.row);
      if (byRank !== 0) return byRank;
      const byOutput = (b.row.lastOutputAt ?? 0) - (a.row.lastOutputAt ?? 0);
      if (byOutput !== 0) return byOutput;
      return a.index - b.index;
    })
    .map((entry) => entry.row);
}

function compareProjects(a: ProjectRef, b: ProjectRef): number {
  const byName = a.name.toLowerCase().localeCompare(b.name.toLowerCase());
  return byName !== 0 ? byName : a.id.localeCompare(b.id);
}

/** Crew sections inside one project: the rows without a `crew:` label first,
 * then one section per crew value in name order. One section, with `crew`
 * null, when every row carries the same label or none does. */
export function crewSections<R extends ModelRow>(rows: R[]): CrewSection<R>[] {
  const byCrew = new Map<string | null, R[]>();
  for (const row of rows) {
    const crew = crewOf(row);
    const list = byCrew.get(crew) ?? [];
    list.push(row);
    byCrew.set(crew, list);
  }
  if (byCrew.size <= 1) return [{ crew: null, rows: sortInGroup(rows) }];
  const crews = [...byCrew.keys()]
    .filter((crew): crew is string => crew !== null)
    .sort((a, b) => a.localeCompare(b));
  const result: CrewSection<R>[] = [];
  const unlabelled = byCrew.get(null);
  if (unlabelled) result.push({ crew: null, rows: sortInGroup(unlabelled) });
  for (const crew of crews) result.push({ crew, rows: sortInGroup(byCrew.get(crew) ?? []) });
  return result;
}

/**
 * One group per project, in name order: every project the daemon lists
 * (registered or discovered), plus any project a row names that the list
 * lacks. The rows outside every project form a last group with key "" when
 * there are any. Rows inside a group are sorted with `sortInGroup`.
 */
export function group<R extends ModelRow>(rows: R[], projects: ProjectSummary[]): Group<R>[] {
  const known = new Map<string, ProjectRef>();
  for (const project of projects) {
    known.set(project.id, {
      id: project.id,
      name: project.name,
      root: project.root,
      registered: project.registered,
    });
  }
  const members = new Map<string, R[]>();
  const loose: R[] = [];
  for (const row of rows) {
    if (!row.project) {
      loose.push(row);
      continue;
    }
    if (!known.has(row.project.id)) known.set(row.project.id, row.project);
    const list = members.get(row.project.id) ?? [];
    list.push(row);
    members.set(row.project.id, list);
  }
  const groups: Group<R>[] = [...known.values()].sort(compareProjects).map((project) => {
    const list = members.get(project.id) ?? [];
    return { key: project.id, project, rows: sortInGroup(list), sections: crewSections(list) };
  });
  if (loose.length > 0) {
    groups.push({
      key: NO_PROJECT,
      project: null,
      rows: sortInGroup(loose),
      sections: crewSections(loose),
    });
  }
  return groups;
}

/**
 * What needs a person, in order: every pending approval (with its row when
 * the session is still listed), then the rows that need input, then the
 * failed rows. The two row lists take `sortInGroup`'s order. The band
 * counts these items (`band`); the tree marks each one on the line it
 * belongs to, so no item is listed twice.
 */
export function attention<R extends ModelRow>(rows: R[], approvals: Approval[]): AttentionItem<R>[] {
  const byId = new Map(rows.map((row) => [row.id, row] as const));
  const items: AttentionItem<R>[] = approvals.map((approval) => ({
    kind: "approval",
    approval,
    row: approval.session ? (byId.get(approval.session) ?? null) : null,
  }));
  const sorted = sortInGroup(rows);
  for (const row of sorted) if (stateOf(row) === "needs-input") items.push({ kind: "needs-input", row });
  for (const row of sorted) if (stateOf(row) === "failed") items.push({ kind: "failed", row });
  return items;
}

/** Counts by merged state, for a card's tallies. Only non-zero states appear. */
export function tally(rows: ModelRow[]): Partial<Record<MergedState, number>> {
  const counts: Partial<Record<MergedState, number>> = {};
  for (const row of rows) {
    const state = stateOf(row);
    counts[state] = (counts[state] ?? 0) + 1;
  }
  return counts;
}

/** The accessible name of one row action, so a button list does not read
 * "Kill, Kill, Kill": the verb and the row's headline. */
export function actionName(action: "Rename" | "Name" | "Archive" | "Kill" | "Actions for", headline: string): string {
  return `${action} ${headline}`;
}

/** The accessible name of one approval answer: the verb, the tool, and the
 * session it runs in, so two Allow buttons read apart. */
export function approvalName(decision: "Allow" | "Deny", tool: string, who: string): string {
  return who ? `${decision} ${tool} in ${who}` : `${decision} ${tool}`;
}

/** What a record link shows: the record's file name without the goal
 * folder, `rounds/` and `.md`, so `goal-folders/rounds/005.md` reads `005`
 * and `rounds/7.md` reads `7`. The word "record" tells it from the
 * `round N of M` counter beside it. */
export function recordLabel(path: string): string {
  return path.replace(/^(?:[^/]+\/)?rounds\//, "").replace(/\.md$/, "");
}

/** Whose a thing is, for a name: the goal and the project when the goal is
 * given, else the project alone. */
function whose(project: string, goal?: string): string {
  return goal ? `${goal} in ${project}` : project;
}

/** The accessible name of a record link: what it opens and whose, the goal
 * and the project, so two `record 002` links on one card read apart. */
export function recordName(path: string, project: string, goal?: string): string {
  return `Open round record ${recordLabel(path)} of ${whose(project, goal)}`;
}

/** The accessible name of a proposed item's link to the goal's `STATE.md`,
 * for a goal whose proposals have no round record to open. */
export function proposalsName(count: number, project: string, goal?: string): string {
  const noun = count === 1 ? "proposal" : "proposals";
  return `${count} ${noun} waiting on the human in STATE.md of ${whose(project, goal)}`;
}

/** What a goal's line says about its proposals: how many wait. */
export function proposedLabel(count: number): string {
  return count === 1 ? "1 proposal" : `${count} proposals`;
}

/** The accessible name of a proposal's Dismiss button: which round of
 * which goal and project, so two Dismiss buttons read apart. */
export function dismissName(round: number, project: string, goal?: string): string {
  return `Dismiss the proposal of round ${round} of ${whose(project, goal)}`;
}

/** The `data-focus` key of a control, so `paint` can give focus back to it
 * after a repaint: the kind, then what it acts on, joined with `:`. Every
 * link and button the page builds carries one. */
export function focusKey(kind: string, ...parts: string[]): string {
  return [kind, ...parts].join(":");
}

/** What the polite live region says when the count of items that need the
 * human changes. */
export function needsYouMessage(count: number): string {
  if (count === 0) return "Nothing needs you";
  return count === 1 ? "1 item needs you" : `${count} items need you`;
}

/** The distinct crew label values across the rows, in name order. */
export function crews(rows: ModelRow[]): string[] {
  const set = new Set<string>();
  for (const row of rows) {
    const crew = crewOf(row);
    if (crew !== null) set.add(crew);
  }
  return [...set].sort((a, b) => a.localeCompare(b));
}

export function goalOf(row: ModelRow): string | null {
  const goal = row.labels?.goal;
  return goal ? goal : null;
}

/** The `task:` label, the queue item slug `LOOP.md` gives a crew session;
 * null when absent or empty. */
export function taskOf(row: ModelRow): string | null {
  const task = row.labels?.task;
  return task ? task : null;
}

/** A whole number from a label or an event value, or null when the value is
 * absent or carries something else. */
function wholeNumber(raw: string | undefined): number | null {
  if (raw === undefined || !/^\d+$/.test(raw)) return null;
  return Number(raw);
}

/** The `round:` label as a whole number, or null when absent or not one. */
export function roundOf(row: ModelRow): number | null {
  return wholeNumber(row.labels?.round);
}

function statusWord(status: string | undefined): string {
  return (status ?? "").trim().toLowerCase();
}

/**
 * The placeholders `examples/goals/goal/` ships in `goal.md` and `STATE.md`.
 * A goal whose summary still carries one is not written yet: `kitterm goal
 * new` copied the template and nobody filled it in. The list names the
 * template's own tokens rather than any `<…>`, because a written next
 * action says `GET /api/sessions/<id>/cost` and means it.
 */
const TEMPLATE_PLACEHOLDERS = [
  "<one line that names the outcome>",
  "<goal slug>",
  "<item>",
  "<test or screenshot>",
  "<check>",
  "<ISO date>",
];

/** Do the goal's files still hold the template's placeholders? Reads the
 * three fields the template fills with them: the title, the next action
 * and the last floor. */
export function isUnwritten(summary: KnowledgeSummary): boolean {
  const texts = [summary.goal, summary.nextAction, summary.lastFloor];
  return texts.some((text) => text !== undefined && TEMPLATE_PLACEHOLDERS.some((token) => text.includes(token)));
}

/** The round counter as one word group: `round 2 of 3`, `round 2` from a
 * daemon that sends no budget, null without a round. */
export function roundLabel(summary: KnowledgeSummary): string | null {
  if (typeof summary.round !== "number") return null;
  return typeof summary.budget === "number" ? `round ${summary.round} of ${summary.budget}` : `round ${summary.round}`;
}

/** The round counter as the tree prints it: `r2/3`, `r2` from a daemon
 * that sends no budget, null without a round (`design-foundation.md`'s
 * frame draws `r2/3`; `roundLabel` is the long form). */
export function roundCounter(summary: KnowledgeSummary): string | null {
  if (typeof summary.round !== "number") return null;
  return typeof summary.budget === "number" ? `r${summary.round}/${summary.budget}` : `r${summary.round}`;
}

/** The first line of the next action, trimmed; null when there is none.
 * The page shows one line and cuts it with an ellipsis, so the text past
 * the first line break would never be read. */
export function nextLine(nextAction: string | undefined): string | null {
  const first = (nextAction ?? "").split("\n")[0].trim();
  return first === "" ? null : first;
}

/**
 * One goal as its project prints it. An unwritten goal is named by its
 * slug and carries nothing else: the placeholders are not a status, a
 * round or a next action. The status word prints only when the goal is
 * not `active`, because a line that is open is active by default; the
 * floor word and the slug do not print, because neither is something the
 * returning reader acts on.
 */
export function goalLine(summary: KnowledgeSummary): GoalLine {
  if (isUnwritten(summary)) {
    return { summary, title: summary.slug ?? "goal", unwritten: true, status: null, round: null, next: null };
  }
  const word = statusWord(summary.status);
  return {
    summary,
    title: goalTitle(summary),
    unwritten: false,
    status: word === "" || word === "active" ? null : word,
    round: roundLabel(summary),
    next: nextLine(summary.nextAction),
  };
}

/**
 * What a project prints for its goals: every summary that carries a
 * field, in the route's order (`active`, `waiting`, `stopped`, `done`).
 * A goal that is not done is one line; the done goals go behind one
 * folded line, because they are history and a returning reader scrolls
 * past history to reach the next project.
 */
export function goalLines(goals: KnowledgeSummary[] | null | undefined): GoalLines {
  const open: GoalLine[] = [];
  const done: KnowledgeSummary[] = [];
  for (const summary of (goals ?? []).filter(hasKnowledge)) {
    if (statusWord(summary.status) === "done") done.push(summary);
    else open.push(goalLine(summary));
  }
  return { open, done };
}

/** The folded line over the done goals: `1 done`, `7 done`. */
export function doneLabel(count: number): string {
  return `${count} done`;
}

/** What a goal is called on the page and in a name: its title, else its
 * slug, else the word "goal". */
export function goalTitle(summary: KnowledgeSummary): string {
  return summary.goal ?? summary.slug ?? "goal";
}

/** The path of the goal's `STATE.md` under the knowledge directory, where
 * its proposals wait: under the goal's folder, or at the root for a
 * summary from a daemon that sends no slug. */
export function statePath(summary: KnowledgeSummary): string {
  return summary.slug ? `${summary.slug}/STATE.md` : "STATE.md";
}

/** `rounds/NNN.md` for round `n`: three digits, more when needed. */
export function roundPath(n: number): string {
  return `rounds/${String(n).padStart(3, "0")}.md`;
}

/** Does the summary carry anything the card can show? False for a package
 * whose files the daemon found but could not read a field from, so the
 * card skips the block instead of printing the word "goal" alone. */
export function hasKnowledge(summary: KnowledgeSummary): boolean {
  // The known fields, not every key: the wire object carries `ok` too.
  const fields: (keyof KnowledgeSummary)[] = [
    "slug", "goal", "status", "round", "budget", "lastFloor",
    "nextAction", "proposals", "lastRound", "lastRecord", "lastDecision",
  ];
  return fields.some((field) => summary[field] !== undefined);
}

/** The path of the latest round record: the name the daemon read, else the
 * three-digit name for the round number from a daemon that sends only the
 * number; null without a record. */
export function recordPath(summary: KnowledgeSummary): string | null {
  if (summary.lastRecord) return summary.lastRecord;
  return typeof summary.lastRound === "number" ? roundPath(summary.lastRound) : null;
}

/** The knowledge route for one file of a project's package. */
export function knowledgeUrl(projectId: string, path: string): string {
  const encoded = path.split("/").map(encodeURIComponent).join("/");
  return `/api/projects/${encodeURIComponent(projectId)}/knowledge/${encoded}`;
}

/** What Dismiss stores for one proposal: the project, the goal's slug and
 * the round, so the next round's proposal from the same goal, and another
 * goal's proposal of the same round number, show again. The slug is ""
 * for a summary from a daemon that sends none. */
export function dismissKey(projectId: string, slug: string, round: number): string {
  return `${projectId}:${slug}:${round}`;
}

/** Is the goal closed: its status is `done` or `stopped`, the two words
 * `LOOP.md` never schedules again. A closed goal's proposals block no
 * round, so they need no person: the goal's line carries the count
 * unmarked (`lineProposals`). A `waiting` goal is open: it waits for the
 * human's direction, and its proposals are what the human decides on. A
 * summary with no status word is open too, so a daemon that sends none
 * loses nothing. */
export function isClosed(summary: KnowledgeSummary): boolean {
  const word = statusWord(summary.status);
  return word === "done" || word === "stopped";
}

/**
 * One item per open goal whose `STATE.md` counts proposals waiting on the
 * human, in the order given (one entry per goal of each project, the
 * route's order), less the ones in `dismissed` (keys from `dismissKey`)
 * and less every closed goal (`isClosed`): the band counts only what
 * still needs the human, and a done or stopped goal has no round for a
 * proposal to block. A proposed item marks its goal's own line in the
 * tree, with the count, the record and Dismiss; a closed or dismissed
 * goal's count stands on the line unmarked (`lineProposals`).
 *
 * The count is the trigger, because `STATE.md` is the foreman's source of
 * truth: it writes a proposal there at close, and the record's decision
 * line does not always carry it (`foreman-harness` round 4 reads `done`
 * with its proposal in `STATE.md` alone). A decision that starts with
 * `propose` is only the item's one-line text, and a goal with no proposals
 * in `STATE.md` yields nothing whatever the decision says, so a proposal
 * the human pruned leaves the count on the next poll.
 */
export function proposedItems(
  entries: { project: ProjectRef; summary: KnowledgeSummary }[],
  dismissed: ReadonlySet<string> = new Set(),
): ProposedItem[] {
  const items: ProposedItem[] = [];
  for (const { project, summary } of entries) {
    const count = summary.proposals ?? 0;
    if (count <= 0) continue;
    if (isClosed(summary)) continue;
    const round = summary.lastRound ?? summary.round ?? 0;
    if (dismissed.has(dismissKey(project.id, summary.slug ?? "", round))) continue;
    const record = recordPath(summary);
    const line = (summary.lastDecision ?? "").trim();
    const decision = line.toLowerCase().startsWith("propose") ? line : null;
    items.push({
      kind: "proposed", project, summary, round, count, record, path: record ?? statePath(summary), decision,
    });
  }
  return items;
}

/**
 * Everything that needs a person, as one list: the attention items with
 * the proposed ones inserted before the first failed row, so what waits
 * on a decision comes before what broke. The band's "need you" count is
 * this list's length (`band`).
 */
export function withProposed<R extends ModelRow>(
  items: AttentionItem<R>[],
  proposed: ProposedItem[],
): (AttentionItem<R> | ProposedItem)[] {
  const at = items.findIndex((item) => item.kind === "failed");
  if (at < 0) return [...items, ...proposed];
  return [...items.slice(0, at), ...proposed, ...items.slice(at)];
}

/**
 * The record a done goal's fold links, or null when a proposed item links
 * it already: a proposed item on the goal's own line carries the record it
 * comes from, so the fold keeps only the title until the human dismisses
 * it, and the link then returns to the fold.
 */
export function cardRecord(projectId: string, summary: KnowledgeSummary, proposed: ProposedItem[]): string | null {
  const path = recordPath(summary);
  if (path === null) return null;
  const inStrip = proposed.some(
    (item) => item.project.id === projectId && item.summary.slug === summary.slug && item.record === path,
  );
  return inStrip ? null : path;
}

/** What a goal's own line says about its proposals when no proposed item
 * marks it: how many `STATE.md` lists, and the `STATE.md` they wait in. */
export type LineProposals = { count: number; path: string };

/**
 * The unmarked count a goal's line carries: the count and the `STATE.md`
 * path when `STATE.md` lists proposals and no proposed item marks the
 * line, because the goal is closed (`isClosed`) or the human dismissed
 * the item. Null when the goal lists none or a proposed item marks it: a
 * proposal is a marked item or an unmarked count, never both. The count
 * is `STATE.md`'s bullet count whole; the page has no per-proposal state,
 * so a proposal stands until the human prunes its bullet.
 */
export function lineProposals(projectId: string, summary: KnowledgeSummary, proposed: ProposedItem[]): LineProposals | null {
  const count = summary.proposals ?? 0;
  if (count <= 0) return null;
  const inStrip = proposed.some((item) => item.project.id === projectId && item.summary.slug === summary.slug);
  return inStrip ? null : { count, path: statePath(summary) };
}

// --- a session row -----------------------------------------------------------

/** What one row prints, in order: the name, the state as a bracketed word
 * (`stateTag`), where the shell is when the name does not say, what it is
 * doing, and how long. A null field is not printed. The name is the only
 * cell that truncates; `place`, `what` and the model are facts the line
 * drops, in `ROW_DROP_ORDER`, when it is too narrow for them. */
export type RowLine = {
  name: string;
  state: string;
  place: string | null;
  what: string | null;
  since: string | null;
};

/** The last segment of a path: the folder a shell sits in. */
export function folderOf(cwd: string): string {
  const trimmed = cwd.replace(/\/+$/, "");
  const base = trimmed.slice(trimmed.lastIndexOf("/") + 1);
  return base || cwd;
}

/** The state's name as the fleet line prints it. */
export function stateName(state: MergedState): string {
  switch (state) {
    case "needs-approval":
      return "needs approval";
    case "needs-input":
      return "needs input";
    case "completed":
      return "done";
    case "unknown":
      return "no integration";
    default:
      return state;
  }
}

/** The state word of a row: the name, with the exit code in brackets when
 * the last command failed or the shell exited with one, so `failed (1)`
 * says the number once and `exit 0` is never printed. */
export function stateLabel(row: ModelRow): string {
  return stateName(stateOf(row)) + exitSuffix(row);
}

/** ` (1)` after a failed or exited state whose code is not zero; nothing
 * otherwise, so `exit 0` is never printed. */
function exitSuffix(row: ModelRow): string {
  const state = stateOf(row);
  if (state !== "failed" && state !== "exited") return "";
  const code = row.lastExit;
  return typeof code === "number" && code !== 0 ? ` (${code})` : "";
}

/** The vocabulary word of a row's state (`design-foundation.md`,
 * Hierarchy): `needs you` for an agent waiting on a person, whether its
 * hook report or a pending approval says so; `stateName` for the rest. */
export function stateWord(state: MergedState): string {
  return state === "needs-approval" || state === "needs-input" ? "needs you" : stateName(state);
}

/** The state of a row as its line prints it: the vocabulary word in
 * brackets, never bare, with the exit code inside them when the last
 * command failed or the shell exited with one: `[working]`, `[needs you]`,
 * `[failed (1)]`. The brackets are what make a state unmistakable in a
 * column of names that are also lower-case and hyphenated. */
export function stateTag(row: ModelRow): string {
  return `[${stateWord(stateOf(row))}${exitSuffix(row)}]`;
}

/** Where a shell is, once: the path under `base`, the directory the heading
 * above names (the project root unless given), else the folder; null at
 * `base` itself, which the heading already names. */
function whereOf(row: ModelRow, base: string | undefined = row.project?.root): string | null {
  const root = (base ?? "").replace(/\/+$/, "");
  const cwd = row.cwd.replace(/\/+$/, "");
  if (root && cwd === root) return null;
  if (root && cwd.startsWith(root + "/")) return cwd.slice(root.length + 1);
  return folderOf(cwd);
}

/** What a row is called: its name, else where it is (`docs/postman` under
 * the project root, the folder otherwise). The same text names the row's
 * buttons, so a list of Kill buttons reads apart. */
export function rowName(row: ModelRow): string {
  return row.name || whereOf(row) || folderOf(row.cwd);
}

/** A span in one unit, for a reader who wants the magnitude: `now` under a
 * minute, then minutes, hours, and days, each rounded down. No seconds, so
 * a row that is alive repaints once a minute at most. */
export function spanLabel(ms: number): string {
  const minutes = Math.floor(Math.max(0, ms) / 60_000);
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

/**
 * The one line a session row prints, read at `now`.
 *
 * `what` is the agent's message, else the note a program or a person set,
 * else the last command, else nothing. `since` measures from the last
 * output, because that is when the row's state began: the prompt that
 * waits, the command that failed, the shell that went quiet; a working row
 * reads `now` while it is alive and grows when it stalls. `place` shows
 * only for a named row away from `base`, the directory the heading above
 * names: the project root, or the workspace directory for a row outside
 * every project that a workspace lists; an unnamed row carries the path
 * as its name and the heading names the base.
 */
export function rowLine(row: ModelRow, now: number, base: string | undefined = row.project?.root): RowLine {
  const command = row.lastCommand ? `$ ${row.lastCommand}` : null;
  return {
    name: rowName(row),
    state: stateTag(row),
    place: row.name ? whereOf(row, base) : null,
    what: row.agent?.message ?? row.note ?? command,
    since: typeof row.lastOutputAt === "number" ? spanLabel(now - row.lastOutputAt) : null,
  };
}

/**
 * The model fact of a session row: the name the daemon derived, printed
 * beside the row's other facts before the time (`design-foundation.md`,
 * "The model"). The id unchanged when the daemon sent one with no name,
 * which is the rule's own last step. Null for a session with no assistant
 * turn yet and for one that never ran `claude`: nothing, never a guess.
 */
export function rowModel(row: ModelRow): string | null {
  const name = row.agentModelName?.trim() || row.agentModel?.trim();
  return name ? name : null;
}

// --- the line ---------------------------------------------------------------
//
// Every level of the tree is one line (`design-foundation.md`, "The line, in
// detail"): a mark, the indent, a name, its facts, its time, its actions.
// The name is the only cell that grows and the only one that truncates. A
// fact that does not fit is dropped, not wrapped, and the facts drop in a
// fixed order as the line narrows. The model here names the mark, the word
// and the drop order of each level; `sessions.ts` measures the line and
// hides the facts that do not fit, in that order (`keptFacts`).

/** The families a gutter mark can wear: the class beside `mark`, which is
 * what colours it. `running` is the accent, `attention` the amber,
 * `failed` the red; the other four are grey, because a finished, waiting
 * or unknown thing needs nothing from the reader. */
export type MarkFamily = "running" | "attention" | "failed" | "done" | "idle" | "pending" | "unknown";

/** The mark's family for a row's merged state. A pending approval and a
 * hook report that waits on a person wear the same amber. */
export function markFamily(state: MergedState): MarkFamily {
  switch (state) {
    case "working":
      return "running";
    case "needs-approval":
    case "needs-input":
      return "attention";
    case "completed":
      return "done";
    case "failed":
      return "failed";
    case "idle":
      return "idle";
    default:
      return "unknown";
  }
}

/** The one character a mark prints (`design-foundation.md`, Hierarchy):
 * `?` for what waits on a person, `!` for what failed, `✓` for what is
 * done, `•` for what is pending, `–` for what is idle or unknown, and `◐`
 * for what is working: the quadrant the mark rests on, which the page
 * turns through the cycle in `spinner.ts`. */
export function markGlyph(family: MarkFamily): string {
  switch (family) {
    case "running":
      return "◐";
    case "attention":
      return "?";
    case "failed":
      return "!";
    case "done":
      return "✓";
    case "pending":
      return "•";
    default:
      return "–";
  }
}

/** One entry of the vocabulary the tree's header prints: the mark and the
 * bracketed word it always appears beside. */
export type VocabularyEntry = { family: MarkFamily; tag: string };

/** The whole vocabulary, in the foundation's order, so a reader never has
 * to infer a mark. */
export const VOCABULARY: readonly VocabularyEntry[] = [
  { family: "running", tag: "[working]" },
  { family: "attention", tag: "[needs you]" },
  { family: "pending", tag: "[pending]" },
  { family: "done", tag: "[done]" },
  { family: "failed", tag: "[failed]" },
  { family: "idle", tag: "[idle]" },
];

/** The word and the mark of a goal's line. `[needs you]` with the amber
 * mark when its proposals wait on the human, because that is what the
 * band counts and the reader opens; `[waiting]`, also amber, for a goal
 * whose budget is spent; `[stopped]`, or any other status word, in grey;
 * else the bucket's own word, `[working]` on the accent or `[pending]` on
 * the faint dot. One state per line: the mark carries the colour, the
 * word carries the meaning. */
export function goalTag(bucket: "working" | "pending", status: string | null, marked: boolean): VocabularyEntry {
  if (marked) return { family: "attention", tag: "[needs you]" };
  if (status === "waiting") return { family: "attention", tag: "[waiting]" };
  if (status !== null) return { family: "idle", tag: `[${status}]` };
  return bucket === "working" ? { family: "running", tag: "[working]" } : { family: "pending", tag: "[pending]" };
}

/** The facts of a goal's line after its state word, in the order they
 * stand and the reverse of the order they drop: the cost, the round
 * counter, then the first line of the next action, which goes first. */
export function goalFacts(line: GoalLine, cost: string | null): string[] {
  const facts: string[] = [];
  if (cost !== null) facts.push(cost);
  if (line.round) facts.push(line.round);
  if (line.next) facts.push(line.next);
  return facts;
}

/** The cells of a row's line that drop, first to last, when the line is
 * too narrow: what it is doing, then where it is, then the model. The
 * state word never drops. The DOM keeps the model beside the time, which
 * is where the foundation puts it, so the drop order is a list here rather
 * than the cells' order. */
export const ROW_DROP_ORDER: readonly ("what" | "place" | "model")[] = ["what", "place", "model"];

/** The facts of a heading that drop, first to last: the count ("no live
 * session"), then the cost. The name stays whole until nothing else can
 * give way. */
export const HEADING_DROP_ORDER: readonly ("tally" | "cost")[] = ["tally", "cost"];

/**
 * How many of a line's facts stay when the line is `need` px too narrow
 * for all of them. `widths` are the facts' widths in the order they drop,
 * each with one `gap` before it; the facts drop from the front of that
 * order until the room they free covers the need. Zero need keeps every
 * fact; a need no fact can cover drops them all, and the name truncates.
 * Never a partial fact: a fact is shown whole or not at all.
 */
export function keptFacts(widths: readonly number[], need: number, gap: number): number {
  let freed = 0;
  let dropped = 0;
  while (freed < need && dropped < widths.length) {
    freed += widths[dropped] + gap;
    dropped += 1;
  }
  return widths.length - dropped;
}

/** A goal's tasks split for a phone: the ones a reader may act on stay
 * open, the done ones fold behind one line, the way a project's done
 * goals do. Every state but `done` stays open, `failed` included, because
 * a failed task needs a person. */
export function foldDoneTasks<R extends ModelRow>(tasks: readonly TaskLine<R>[]): { open: TaskLine<R>[]; done: TaskLine<R>[] } {
  return { open: tasks.filter((t) => t.state !== "done"), done: tasks.filter((t) => t.state === "done") };
}

/** How many of a goal's done tasks its line shows: the most recent two,
 * as the frame draws them; the older ones are history the record link
 * holds. `STATE.md` lists `## Done` newest first, so the first two are
 * the most recent. */
export const DONE_TASKS_SHOWN = 2;

/** The tasks a goal's line shows: every task that is not done, in the
 * daemon's order, and the first `DONE_TASKS_SHOWN` done ones. */
export function shownTasks<R extends ModelRow>(tasks: readonly TaskLine<R>[]): TaskLine<R>[] {
  let done = 0;
  return tasks.filter((t) => {
    if (t.state !== "done") return true;
    done += 1;
    return done <= DONE_TASKS_SHOWN;
  });
}

/** The project's most recently finished goal, the one the tree shows open
 * with its last done tasks while the rest fold behind `N done`: the done
 * goal whose latest round started last, by the `started` day of its
 * records; the first in the route's order when no record carries a day.
 * Null for no done goal. */
export function latestDoneGoal(done: readonly KnowledgeSummary[]): KnowledgeSummary | null {
  let best: KnowledgeSummary | null = null;
  let bestDay = "";
  for (const goal of done) {
    const day = (goal.rounds ?? []).reduce((max, r) => (typeof r.started === "string" && r.started > max ? r.started : max), "");
    if (best === null || day > bestDay) {
      best = goal;
      bestDay = day;
    }
  }
  return best;
}

// --- the restart line -------------------------------------------------------

/**
 * One `daemon.started` event: the feed's epoch and the event's data. The
 * daemon puts the previous run's summary on this event (round 2 of
 * `daemon-last-words`), so the page never reads `~/.kitterm/last-run.json`
 * itself.
 *
 * Three keys of `data` matter here. `previous` is `unrecorded`, `clean` or
 * `takeover`, and is absent when the daemon found no record of a previous
 * run. `previousAliveAt` is epoch milliseconds; `previousSessions` is a
 * count. Both arrive as strings, because every event value is a string.
 */
export type DaemonStarted = { epoch: string; data: Record<string, string> };

/** The line above the cards, and the key its Dismiss button stores. */
export type RestartNotice = { text: string; key: string };

/** How the page prints one past moment: the time alone, or the date and the
 * time. `sessions.ts` owns the locale; the model picks the format only. */
export type StampFormat = "time" | "date-and-time";

/** Do the two moments fall on the same day of the reader's own calendar? */
function sameLocalDay(a: number, b: number): boolean {
  const first = new Date(a);
  const second = new Date(b);
  return (
    first.getFullYear() === second.getFullYear() &&
    first.getMonth() === second.getMonth() &&
    first.getDate() === second.getDate()
  );
}

/**
 * The format a past moment needs, read at `now`: the time alone while the
 * moment falls on today, the date and the time on every other day.
 *
 * The rule is the calendar day, not an elapsed span, because a bare "10:35
 * PM" is unambiguous only while the moment and the read carry the same date:
 * a daemon that died at 23:50 and a page opened at 00:10 are 80 minutes apart
 * on two dates, and a reader who returns on Monday must not take Friday's
 * time for this morning's. The short format holds the line to one line at
 * 390 px on the common case, the restart the reader just watched.
 */
export function stampFormat(epochMs: number, now: number): StampFormat {
  return sameLocalDay(epochMs, now) ? "time" : "date-and-time";
}

/** What Dismiss stores for the restart line: the current run's epoch. A
 * restart gives the feed a new epoch, so the next death shows a new line,
 * and a live upgrade keeps the epoch, which is right because it loses
 * nothing and shows no line at all. */
export function restartDismissKey(epoch: string): string {
  return `epoch:${epoch}`;
}

/** The accessible name of the restart line's Dismiss button, so it reads
 * apart from the notice line's and a proposal's Dismiss. */
export function restartDismissName(): string {
  return "Dismiss the restart notice";
}

/**
 * The one line the fleet view shows above the cards, or null for silence.
 *
 * Only `previous: unrecorded` speaks: that run died without writing an
 * ending, so every session it held is gone. `clean` says nothing, because
 * the run ended on purpose. `takeover` says nothing, because a live upgrade
 * keeps every session. An absent `previous` says nothing, because there was
 * no previous run to lose. A dismissed epoch says nothing until the next
 * restart, which is a new epoch and a new key.
 *
 * `stamp` prints epoch milliseconds in the format `stampFormat` picks against
 * `now`, the moment the page reads the event; the page passes its own
 * formatter, so this function stays free of the locale and the DOM.
 */
export function restartNotice(
  started: DaemonStarted | null | undefined,
  dismissed: ReadonlySet<string>,
  stamp: (epochMs: number, format: StampFormat) => string,
  now: number,
): RestartNotice | null {
  if (!started) return null;
  if (started.data.previous !== "unrecorded") return null;
  const key = restartDismissKey(started.epoch);
  if (dismissed.has(key)) return null;
  const aliveAt = wholeNumber(started.data.previousAliveAt);
  const sessions = wholeNumber(started.data.previousSessions);
  // Both facts are the line's claim; a half-line would say less than nothing.
  if (aliveAt === null || sessions === null) return null;
  const lost = sessions === 1 ? "1 session" : `${sessions} sessions`;
  const when = stamp(aliveAt, stampFormat(aliveAt, now));
  return {
    text: `The daemon restarted. The previous run was last alive at ${when} and lost ${lost}.`,
    key,
  };
}

// --- the push toggle ---------------------------------------------------------

/** Whether this page can subscribe at all, read once at load. `insecure`
 * is an http origin, where no service worker registers; `old-daemon` is a
 * daemon that answers 404 to `GET /api/push/vapid`. */
export type PushSupport = "ok" | "unsupported" | "insecure" | "old-daemon";

/** `Notification.permission`. The browser asks once; after `denied` it
 * never asks again, and only the browser's own site settings can undo it. */
export type PushPermission = "default" | "granted" | "denied";

/** What the page knows about push right now. */
export type PushFacts = {
  /** The token is watch-only: the feature is hidden, not refused. */
  watchOnly: boolean;
  support: PushSupport;
  permission: PushPermission;
  /** The browser holds a subscription and the daemon has accepted it. */
  subscribed: boolean;
  /** A subscribe or an unsubscribe is in flight. */
  busy: boolean;
  /** The last step that failed, in the words the page will print. */
  error: string | null;
};

/** The switch the page paints: `checked` is the subscription, `enabled`
 * is whether pressing it can change anything, and `detail` is the line
 * beside it that says why it cannot, or what went wrong. */
export type PushToggle = {
  label: string;
  checked: boolean;
  enabled: boolean;
  detail: string | null;
  /** The `data-focus` key of the switch. */
  key: string;
};

/** The label of the switch. The same words in every state, so a reader who
 * finds it again knows it is the same control. */
export const PUSH_LABEL = "Notify this device";

/**
 * The toggle for the facts, or null for a watch client, which `goal.md`
 * excludes from push entirely: a watch token exists to withhold the answer,
 * so it does not get the question, and the daemon answers its subscribe
 * with 403. Hidden rather than disabled, so the page does not offer what
 * it would refuse.
 *
 * The switch is disabled, with a line that says why, wherever pressing it
 * could not work: no push in this browser, no secure context, a daemon
 * with no key, and `denied`, where the browser will not ask again and only
 * its site settings can turn the answer around. A disabled switch beside
 * the reason reads as a decision; a missing one reads as a page that broke.
 */
export function pushToggle(facts: PushFacts): PushToggle | null {
  if (facts.watchOnly) return null;
  const key = focusKey("push");
  const off = (detail: string): PushToggle => ({ label: PUSH_LABEL, checked: false, enabled: false, detail, key });
  switch (facts.support) {
    case "unsupported":
      return off("This browser does not support push notifications. On iOS, add the page to the Home Screen and open it from there.");
    case "insecure":
      return off("Notifications need an HTTPS origin. Open the page over HTTPS.");
    case "old-daemon":
      return off("This daemon does not send notifications. Upgrade kitterm.");
    case "ok":
      break;
  }
  if (facts.permission === "denied") {
    return off("Notifications are blocked for this site. Allow them in the browser's site settings, then reload.");
  }
  if (facts.busy) {
    return {
      label: PUSH_LABEL,
      checked: facts.subscribed,
      enabled: false,
      detail: facts.subscribed ? "Turning off…" : "Turning on…",
      key,
    };
  }
  return { label: PUSH_LABEL, checked: facts.subscribed, enabled: true, detail: facts.error, key };
}

/** The `applicationServerKey` bytes from the daemon's base64url public key
 * (`GET /api/push/vapid`). A `Uint8Array`, because every browser takes one
 * and older Safari takes nothing else. */
export function applicationServerKey(base64url: string): Uint8Array<ArrayBuffer> {
  const padded = base64url.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (base64url.length % 4)) % 4);
  const raw = atob(padded);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

/** Whether the subscription the browser holds was made with `key`, so the
 * page can tell a subscription bound to a daemon whose `vapid.json` was
 * replaced, which the push service would answer 403 for, from one that is
 * still good. `held` is `PushSubscription.options.applicationServerKey`. */
export function sameServerKey(held: ArrayBuffer | null | undefined, key: Uint8Array<ArrayBuffer>): boolean {
  if (!held) return false;
  const bytes = new Uint8Array(held);
  if (bytes.length !== key.length) return false;
  for (let i = 0; i < key.length; i++) if (bytes[i] !== key[i]) return false;
  return true;
}

// --- the card heading ---------------------------------------------------------

/**
 * The heading line of a project card on a phone: the name, "no live
 * session" when the card lists no row, the profile select, and `[new]`.
 * The four do not fit one 390 px line beside a real name and a real
 * profile: whole, they leave 47 px for the name, six characters, and every
 * registered project is longer. So the line gives way, in this order:
 *
 * 1. The count drops. The rows under the heading say what is live and the
 *    fleet line above the cards says the total; a count cut to "no live …"
 *    says less than nothing, so it goes whole or not at all.
 * 2. The select shrinks to `PROFILE_SHORT_CELLS`. Its label is a hint of
 *    the pick; the aria-label and the opened list carry every label whole.
 *    Five cells show every bundled profile name (`box`, `zbox`, `ubash`)
 *    and the first word of "local shell".
 * 3. The select drops. `[new]` still starts a local shell; a profile pick
 *    waits for a wider screen.
 * 4. The name and `[new]` stay. The name never shrinks and never clips. A
 *    name wider than the line less `[new]`, 36 characters, breaks inside
 *    its own box and `[new]` wraps under it; `fits` is false then.
 *
 * The widths are arithmetic over the sheet's sizes, not a measurement: a
 * mono cell is 0.6 em (Menlo, SF Mono, Monaco and Courier New agree within
 * 1%), the name is 13 px and the rest 12 px, and the line is 390 px less
 * the page's 16 px gutters and the head's 12 px padding, with 4 px of
 * slack for a wider face. `sessions.css` applies the result under its
 * phone media query; a wider screen holds everything.
 */
export type HeadingInput = {
  name: string;
  /** "no live session" when the card lists no row; null otherwise. */
  tally: string | null;
  /** The select's option labels, the default first; `[]` when the daemon
   * has no profiles, so the line holds `[new]` alone; null for a client
   * that may not spawn. */
  profiles: string[] | null;
  /** What the line loses to its level: `NESTED_INDENT_PX` for a project
   * under a workspace heading, 0 or absent at the top level. */
  indent?: number;
};

/** The select at its natural width, capped at `PROFILE_WHOLE_CELLS`, or at
 * `PROFILE_SHORT_CELLS`. */
export type ProfileWidth = "whole" | "short";

export type HeadingLine = {
  /** The project's name, whole. */
  name: string;
  /** The count, whole, or null when it gives way. */
  tally: string | null;
  /** The select's width, or null when it gives way or the line has none. */
  profile: ProfileWidth | null;
  /** The line's width by the arithmetic above, in px. */
  px: number;
  /** False only when the name and `[new]` alone are wider than the line. */
  fits: boolean;
};

/** 390 less the page's 16 px gutters and the head's 12 px padding. */
export const HEADING_LINE_PX = 334;
/** What a project under a workspace heading is set in from the workspace's
 * edge: `.workspace .nested` in the sheet. Two mono cells at 13 px. */
export const NESTED_INDENT_PX = 16;
const HEADING_SLACK_PX = 4;
/** A mono cell, as a fraction of the font size. */
const CELL_EM = 0.6;
const NAME_FONT_PX = 13;
const TEXT_FONT_PX = 12;
/** An upper bound of `.card .head { gap }` and `.card .spawn { gap }`, which
 * the sheet sets at --space-2 and --space-1. The model counts the wider
 * gaps it was measured with, so it gives the count and the select away a
 * few px early rather than late. */
const HEAD_GAP_PX = 10;
const SPAWN_GAP_PX = 6;
/** `[new]`: five cells, plus the 4 px of padding the sheet no longer adds,
 * kept as slack for the same reason. */
const NEW_PX = 5 * TEXT_FONT_PX * CELL_EM + 4;
/** The select's padding, border and arrow: `--profile-chrome` in the sheet. */
export const PROFILE_CHROME_PX = 30;
/** The select's cap, the width of "local shell". */
export const PROFILE_WHOLE_CELLS = 11;
export const PROFILE_SHORT_CELLS = 5;

export function headingLine(input: HeadingInput): HeadingLine {
  const { name, tally, profiles } = input;
  const indent = input.indent ?? 0;
  const canSpawn = profiles !== null;
  const wholeCells = Math.min(PROFILE_WHOLE_CELLS, Math.max(0, ...(profiles ?? []).map((p) => p.length)));
  const shortCells = Math.min(PROFILE_SHORT_CELLS, wholeCells);
  const cells = (n: number, font: number): number => n * font * CELL_EM;

  const width = (count: string | null, profile: ProfileWidth | null): number => {
    let px = indent + cells(name.length, NAME_FONT_PX);
    if (count) px += HEAD_GAP_PX + cells(count.length, TEXT_FONT_PX);
    if (canSpawn) {
      px += HEAD_GAP_PX + NEW_PX;
      if (profile) px += cells(profile === "whole" ? wholeCells : shortCells, TEXT_FONT_PX) + PROFILE_CHROME_PX + SPAWN_GAP_PX;
    }
    return px;
  };

  // The shapes in the order they are preferred; the first that fits wins.
  const shapes: Array<[string | null, ProfileWidth | null]> = [];
  const withSelect: Array<ProfileWidth | null> = wholeCells > 0 ? ["whole", "short", null] : [null];
  if (tally) shapes.push([tally, withSelect[0]]);
  for (const profile of withSelect) shapes.push([null, profile]);

  for (const [count, profile] of shapes) {
    const px = width(count, profile);
    if (px <= HEADING_LINE_PX - HEADING_SLACK_PX) return { name, tally: count, profile, px, fits: true };
  }
  return { name, tally: null, profile: null, px: width(null, null), fits: false };
}

// --- the three levels ---------------------------------------------------------

/**
 * A heading on the page: a workspace or a project. `name` is what the line
 * prints. `path` is the directory the heading stands for, the workspace
 * directory or the project root, and null for the rows outside every
 * project. A later capability keys a cost and a cache share on `path` and
 * adds them as fields beside `name`; the painter prints them after the name
 * on the same line, and a goal's own number sits on its `GoalLine` beside
 * `round`.
 */
export type Heading = { name: string; path: string | null };

/** The three buckets a project's goals sort into. */
export type GoalState = "working" | "pending" | "done";

/** One goal being worked: its line, then the listed rows that carry its
 * `goal:` label, in `sortInGroup`'s order. */
export type GoalEntry<R extends ModelRow> = { line: GoalLine; rows: R[] };

/** A project's goals by state, each bucket in the route's order. */
export type GoalBuckets<R extends ModelRow> = {
  working: GoalEntry<R>[];
  pending: GoalLine[];
  done: KnowledgeSummary[];
};

/** The line a project prints in place of its goals when it has none to
 * sort, or null when it has goals or the page cannot know. */
export type NoGoals = "no goal folder" | "not registered" | null;

export type ProjectSection<R extends ModelRow> = {
  /** The group's key: the project id, or `NO_PROJECT`. */
  key: string;
  heading: Heading;
  project: ProjectRef | null;
  /** The listed rows under no goal, in `sortInGroup`'s order. */
  rows: R[];
  /** Every session the project owns; 0 prints "no live session" on the
   * heading. */
  owned: number;
  goals: GoalBuckets<R>;
  noGoals: NoGoals;
};

export type WorkspaceSection<R extends ModelRow> = {
  /** The workspace's heading, or null when it holds one project, which then
   * stands at the top level with no heading over it. */
  heading: Heading | null;
  /** The listed rows outside every project whose shell sits in the
   * workspace directory, under the heading and above the projects; empty
   * without a heading. */
  rows: R[];
  projects: ProjectSection<R>[];
};

/** The workspace a project root sits in: its parent directory. Null for a
 * project with no root, or a root with no parent. */
export function workspaceOf(root: string | undefined): string | null {
  const trimmed = (root ?? "").replace(/\/+$/, "");
  const cut = trimmed.lastIndexOf("/");
  if (cut <= 0) return null;
  return trimmed.slice(0, cut);
}

/**
 * The headed workspace a shell outside every project belongs to: the one of
 * `headed` whose directory is the cwd or holds it; the deepest when two do.
 * Null when none does, which sends the row to the "No project" section.
 */
export function workspaceHome(cwd: string, headed: readonly string[]): string | null {
  const path = cwd.replace(/\/+$/, "");
  let home: string | null = null;
  for (const dir of headed) {
    if (path !== dir && !path.startsWith(dir + "/")) continue;
    if (home === null || dir.length > home.length) home = dir;
  }
  return home;
}

/**
 * The goals of one project in three buckets. A goal is working when a live
 * session of the project carries its slug in a `goal:` label, whatever its
 * status word says: `active` only means runnable, and a goal can be active
 * with no round open. Done is `status: done`, and wins over a lingering
 * label, because the status word is the human's and the loop never opens a
 * round on a done goal. Pending is the rest: active with no crew, waiting,
 * stopped. `owned` is every session the project owns and decides the
 * state; `listed` is what the section prints and nests under the goal.
 * The page passes the same rows as both; a caller that lists a subset
 * still holds the goal at working.
 */
export function goalBuckets<R extends ModelRow>(
  goals: KnowledgeSummary[] | null | undefined,
  listed: R[],
  owned: R[],
): GoalBuckets<R> {
  const live = new Set<string>();
  for (const row of owned) {
    const goal = goalOf(row);
    if (goal !== null) live.add(goal);
  }
  const lines = goalLines(goals);
  const working: GoalEntry<R>[] = [];
  const pending: GoalLine[] = [];
  for (const line of lines.open) {
    const slug = line.summary.slug;
    if (slug !== undefined && live.has(slug)) {
      working.push({ line, rows: sortInGroup(listed.filter((row) => goalOf(row) === slug)) });
    } else {
      pending.push(line);
    }
  }
  return { working, pending, done: lines.done };
}

/** The label over a bucket: `1 working`, `2 pending`, `10 done`. */
export function bucketLabel(state: GoalState, count: number): string {
  return `${count} ${state}`;
}

// --- the fourth level -------------------------------------------------------

/** The state as the line prints it: a bracketed word, never a bare one,
 * so it is unmistakable in a column of names that are also lower-case
 * and hyphenated (`design-foundation.md`, Hierarchy). */
export function taskTag(state: TaskState): string {
  return `[${state}]`;
}

/** The gutter mark's family for a task state: the working mark is the
 * accent glyph a working row wears (the turning mark is capability 5's),
 * failed is the danger glyph, done and pending are grey. */
export function taskMark(state: TaskState): "running" | "pending" | "done" | "failed" {
  return state === "working" ? "running" : state;
}

/** The facts a task line prints after its state word, in the order the
 * foundation's frame shows them: the round, then the pull request. */
export function taskFacts(task: TaskSummary): string[] {
  const facts: string[] = [];
  if (typeof task.round === "number") facts.push(`round ${task.round}`);
  if (typeof task.pr === "number") facts.push(`PR #${task.pr}`);
  return facts;
}

/**
 * The tasks of one goal, in the daemon's order (queue, failures, done),
 * joined with the live sessions. A task is `working` when a session in
 * `owned` carries `task:<slug>` under `goal:<the goal's slug>`, whatever
 * `STATE.md` says: the session is what the reader can open, and a task
 * that runs again is being retried. The listed rows with that label nest
 * under the task; `rest` is every other listed row, which stays under the
 * goal's line as before. A row whose `task:` names no listed slug stays in
 * `rest` too, because a line the reader cannot find in `STATE.md` would
 * be a fifth kind of state. A summary with no `tasks` prints no task and
 * changes nothing: eleven of the thirteen goals on the machine this was
 * built on have an empty queue, and their lines must read as they did.
 */
export function taskLines<R extends ModelRow>(summary: KnowledgeSummary, listed: R[], owned: R[]): TaskLines<R> {
  const goal = summary.slug;
  const tasks: TaskLine<R>[] = [];
  const claimed = new Set<string>();
  for (const task of summary.tasks ?? []) {
    const under = (row: R): boolean => goalOf(row) === goal && taskOf(row) === task.slug;
    const live = goal !== undefined && owned.some(under);
    const rows = goal === undefined ? [] : sortInGroup(listed.filter(under));
    for (const row of rows) claimed.add(row.id);
    const state: TaskState = live ? "working" : task.state;
    const line: TaskLine<R> = { slug: task.slug, state, tag: taskTag(state), facts: taskFacts(task), rows };
    if (typeof task.round === "number") line.round = task.round;
    if (typeof task.pr === "number") line.pr = task.pr;
    tasks.push(line);
  }
  return { tasks, rest: listed.filter((row) => !claimed.has(row.id)) };
}

/**
 * What a project prints in place of its goal buckets when it has none.
 * "no goal folder" for a registered project whose package holds no goal:
 * the foreman skips it, and `kitterm goal new` is the remedy. "not
 * registered" for a discovered checkout: the page cannot read its goals
 * because `GET /api/projects/<id>/knowledge` answers 404 for it, and
 * `kitterm project add` is the remedy. The two absences differ in what the
 * reader does next, so they print apart. Null while the goals are unknown,
 * for a registered package the daemon has not answered yet, and for the
 * rows outside every project.
 */
export function noGoalsLine(project: ProjectRef | null, goals: KnowledgeSummary[] | null | undefined): NoGoals {
  if (project === null) return null;
  if (!project.registered) return "not registered";
  return goals?.length === 0 ? "no goal folder" : null;
}

/** The name of the section for the rows outside every project. */
export const NO_PROJECT_NAME = "No project";

function projectSection<R extends ModelRow>(
  g: Group<R>,
  owned: R[],
  goals: KnowledgeSummary[] | null | undefined,
): ProjectSection<R> {
  const buckets = goalBuckets(goals, g.rows, owned);
  const nested = new Set(buckets.working.flatMap((entry) => entry.rows.map((row) => row.id)));
  return {
    key: g.key,
    heading: { name: g.project?.name ?? NO_PROJECT_NAME, path: g.project?.root ?? null },
    project: g.project,
    rows: g.rows.filter((row) => !nested.has(row.id)),
    owned: owned.length,
    goals: buckets,
    noGoals: noGoalsLine(g.project, goals),
  };
}

/**
 * The page's three levels over `group`'s projects: a workspace, its
 * projects, and each project's goals by state.
 *
 * A workspace is the parent directory of a project root, named by that
 * directory's own name, because it is the one name the human gave it. A
 * workspace that holds one project shows no heading, because a heading
 * over a single child says nothing the child's name does not, and the
 * degenerate case would print "Workspace" over `kitterm`; that project
 * stands at the top level. Workspaces and lone projects share one name
 * order, and the projects inside a workspace keep `group`'s.
 *
 * A row outside every project goes where its shell sits: under the heading
 * of the workspace whose directory is or holds its cwd, above that
 * workspace's projects, because the foreman for a workspace runs in the
 * workspace directory and a reader looks for it there. Every other one
 * goes to a last "No project" section, which is a lone project section
 * with no `project`, and which exists only when it has a row to list.
 *
 * `listed` is what the sections print; `owned` is every session and
 * decides the counts and the goal states. The page passes the same rows
 * as both, so every session is a line once. `goalsOf` answers a project's
 * knowledge, null or undefined when the page has none.
 */
export function levels<R extends ModelRow>(
  listed: R[],
  owned: R[],
  projects: ProjectSummary[],
  goalsOf: (projectId: string) => KnowledgeSummary[] | null | undefined,
): WorkspaceSection<R>[] {
  const shown = group(listed, projects);
  const ownedBy = new Map(group(owned, projects).map((g) => [g.key, g.rows] as const));
  const byWorkspace = new Map<string, Group<R>[]>();
  const lone: Group<R>[] = [];
  let loose: Group<R> | null = null;
  for (const g of shown) {
    if (g.project === null) {
      loose = g;
      continue;
    }
    const dir = workspaceOf(g.project.root);
    if (dir === null) {
      lone.push(g);
      continue;
    }
    const list = byWorkspace.get(dir) ?? [];
    list.push(g);
    byWorkspace.set(dir, list);
  }
  const headed = [...byWorkspace].filter(([, list]) => list.length > 1).map(([dir]) => dir);
  const homes = new Map<string, R[]>(headed.map((dir) => [dir, []]));
  const noProject: R[] = [];
  for (const row of loose?.rows ?? []) {
    const home = workspaceHome(row.cwd, headed);
    if (home === null) noProject.push(row);
    else homes.get(home)!.push(row);
  }
  const ownedLoose = (ownedBy.get(NO_PROJECT) ?? []).filter((row) => workspaceHome(row.cwd, headed) === null);

  const section = (g: Group<R>): ProjectSection<R> =>
    projectSection(g, ownedBy.get(g.key) ?? [], g.project ? goalsOf(g.project.id) : null);
  const sections: WorkspaceSection<R>[] = [];
  for (const [dir, list] of byWorkspace) {
    if (list.length > 1) {
      sections.push({
        heading: { name: folderOf(dir), path: dir },
        rows: sortInGroup(homes.get(dir) ?? []),
        projects: list.map(section),
      });
    } else {
      sections.push({ heading: null, rows: [], projects: [section(list[0])] });
    }
  }
  for (const g of lone) sections.push({ heading: null, rows: [], projects: [section(g)] });
  const nameOf = (s: WorkspaceSection<R>): string => (s.heading ?? s.projects[0].heading).name.toLowerCase();
  sections.sort((a, b) => nameOf(a).localeCompare(nameOf(b)));
  if (loose !== null && noProject.length > 0) {
    const none = projectSection({ ...loose, rows: sortInGroup(noProject) }, ownedLoose, null);
    sections.push({ heading: null, rows: [], projects: [none] });
  }
  return sections;
}

// --- the quota bars ----------------------------------------------------------

/** One window as `GET /api/usage/limits` serves it, with the statusline's
 * own field names: `used_percentage` of the window spent, `resets_at` in
 * epoch seconds. */
export type LimitWindow = { used_percentage: number; resets_at: number };

/** The route's answer. `rateLimits` and the age fields are present only
 * with a reading; `stale` is the daemon's call, past an hour. */
export type UsageLimits = {
  ok: boolean;
  hasReading: boolean;
  receivedAt?: number;
  ageSeconds?: number;
  stale?: boolean;
  rateLimits?: Record<string, LimitWindow>;
};

/** The share of a window at which its bar and its number turn caution
 * (`corpus/dashboard.pen`, the Components frame): 80 % and over. */
export const QUOTA_CAUTION_PERCENT = 80;

/** The windows in the order the page lists them; any other key follows,
 * by name, with its key as its label. */
const QUOTA_ORDER = ["five_hour", "seven_day", "spend_limit"];
const QUOTA_LABELS: Record<string, string> = {
  five_hour: "Session (5h)",
  seven_day: "Weekly",
  spend_limit: "Spend limit",
};

export type QuotaState = "fresh" | "stale" | "reset";

/** The colour a bar's fill and its number wear: the accent under
 * `QUOTA_CAUTION_PERCENT`, the caution at and over it. */
export type QuotaLevel = "accent" | "caution";

/** One bar: the label, the fill, the number, and the reset time, each a
 * string the page prints as is. `fill` is the window's share of the bar,
 * 0 to 1, clamped; `level` is the colour the fill and the number wear. */
export type QuotaBar = {
  key: string;
  label: string;
  /** The share of the bar that is full, 0 to 1. */
  fill: number;
  level: QuotaLevel;
  /** `24%`; a window past its reset keeps its last number. */
  percent: string;
  /** `resets today 20:20`, `resets tomorrow 04:00`, `resets Sep 25,
   * 04:00` (`quotaResetTime`), or `reset · read 1d 19h ago` once the
   * window has reset: the word and the reading's age, never a countdown
   * that ran out. */
  reset: string;
  /** `reset` once `resets_at` has passed: the page draws the bar and the
   * number in the faint grey, at the last value. */
  state: QuotaState;
};

/** What the panel shows: the bars, and one line under them. The line
 * says how old the reading is, or why there is no bar. */
export type QuotaPanel = { bars: QuotaBar[]; note: string };

/** The label for a window key: the three the statusline sends by name,
 * any other by its key with the underscores opened. */
export function quotaLabel(key: string): string {
  return QUOTA_LABELS[key] ?? key.replace(/_/g, " ");
}

/** The fill for a percentage, clamped to the bar, and the colour it
 * wears: the accent under 80 %, the caution from 80 % (`quotaLevel`). */
export function quotaFill(percent: number): { fill: number; level: QuotaLevel } {
  const clamped = Math.min(100, Math.max(0, Number.isFinite(percent) ? percent : 0));
  return { fill: clamped / 100, level: quotaLevel(percent) };
}

/** The colour a window's fill and number wear: `caution` at and over
 * `QUOTA_CAUTION_PERCENT`, `accent` under it. The label and the reset
 * never change colour. */
export function quotaLevel(percent: number): QuotaLevel {
  return Number.isFinite(percent) && percent >= QUOTA_CAUTION_PERCENT ? "caution" : "accent";
}

/** A span ahead in its two largest units: `49m`, `3h 12m`, `1d 14h`; under
 * a minute reads `<1m`. Rounded down, so the countdown never promises a
 * reset that has not come. */
export function countdown(ms: number): string {
  const minutes = Math.floor(Math.max(0, ms) / 60_000);
  if (minutes < 1) return "<1m";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return minutes % 60 === 0 ? `${hours}h` : `${hours}h ${minutes % 60}m`;
  const days = Math.floor(hours / 24);
  return hours % 24 === 0 ? `${days}d` : `${days}d ${hours % 24}h`;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const DAY = 24 * 60 * 60_000;

/** The local midnight that starts the day `at` falls in, epoch millis. */
function localMidnight(at: number): number {
  const d = new Date(at);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

/** A reset as a clock time in the viewer's zone, 24-hour (round 17, the
 * human's word): `today 20:20` on the day `now` falls in, `tomorrow
 * 04:00` on the next, `Sep 25, 04:00` later in the year and `Jan 2 2027,
 * 04:00` in another. The days are counted between local midnights, so
 * five minutes before midnight a reset ten minutes ahead is `tomorrow`;
 * the count is rounded because a day across a DST change is 23 or 25
 * hours. Never a countdown: the band keeps that. */
export function quotaResetTime(resetAt: number, now: number): string {
  const at = new Date(resetAt);
  const pad = (n: number): string => String(n).padStart(2, "0");
  const clock = `${pad(at.getHours())}:${pad(at.getMinutes())}`;
  const days = Math.round((localMidnight(resetAt) - localMidnight(now)) / DAY);
  if (days === 0) return `today ${clock}`;
  if (days === 1) return `tomorrow ${clock}`;
  const date = `${MONTHS[at.getMonth()]} ${at.getDate()}`;
  const year = at.getFullYear() === new Date(now).getFullYear() ? "" : ` ${at.getFullYear()}`;
  return `${date}${year}, ${clock}`;
}

/** The reading's age as the note prints it: `read just now` under a
 * minute, then `read 4m ago`, `read 3h ago`, `read 2d ago`. */
export function quotaAge(receivedAt: number, now: number): string {
  const span = spanLabel(now - receivedAt);
  return span === "now" ? "read just now" : `read ${span} ago`;
}

/** The reading's age as a window past its reset prints it, from the
 * daemon's own `ageSeconds` (else from `receivedAt`), in the countdown's
 * two units: `read 1d 19h ago`; `read just now` under a minute. */
export function quotaReadAge(limits: Pick<UsageLimits, "ageSeconds" | "receivedAt">, now: number): string {
  const ms = typeof limits.ageSeconds === "number" ? limits.ageSeconds * 1000 : now - (limits.receivedAt ?? now);
  return ms < 60_000 ? "read just now" : `read ${countdown(ms)} ago`;
}

/**
 * The quota panel, read at `now`, or null when the page has nothing to
 * draw: no answer from the route (a daemon too old to have it, or a watch
 * token, which the daemon refuses).
 *
 * A daemon never given a reading says so in words, and names the command
 * that teaches the statusline to post one. A reading with no window says
 * that too: Claude Code gives an API-key account none, and a session none
 * before its first response. A window whose `resets_at` has passed keeps
 * its last number and its bar, both in the faint grey, and its reset cell
 * says `reset · read 1d 19h ago`: the window is over and this is how old
 * the word is. Never `resets … ago` (round 14, the human's word). A
 * window ahead prints its reset as a clock time in the viewer's zone,
 * `resets today 20:20` (`quotaResetTime`, round 17); the band alone
 * keeps the countdown. The
 * statusline drops such a window on its next render, and the bar goes
 * with it. A stale reading keeps its bars, and the note says how old they
 * are, because a bar from three hours ago is still the account's last
 * known state while the note stands beside it.
 */
export function quotaPanel(limits: UsageLimits | null | undefined, now: number): QuotaPanel | null {
  if (!limits || !limits.ok) return null;
  if (!limits.hasReading || typeof limits.receivedAt !== "number") {
    return {
      bars: [],
      note: "No quota reading yet. Run kitterm statusline install, then open a Claude Code session; its statusline posts one.",
    };
  }
  const age = quotaAge(limits.receivedAt, now);
  const windows = Object.entries(limits.rateLimits ?? {});
  if (windows.length === 0) {
    return {
      bars: [],
      note: `The last reading, ${age.replace(/^read /, "")}, carried no quota window: an API-key account, or a session before its first response.`,
    };
  }
  const rank = (key: string): number => {
    const at = QUOTA_ORDER.indexOf(key);
    return at === -1 ? QUOTA_ORDER.length : at;
  };
  windows.sort(([a], [b]) => rank(a) - rank(b) || a.localeCompare(b));
  const stale = limits.stale === true;
  const bars = windows.map(([key, window]): QuotaBar => {
    const resetAt = window.resets_at * 1000;
    const percent = Math.round(Math.min(999, Math.max(0, window.used_percentage)));
    if (resetAt <= now) {
      return {
        key,
        label: quotaLabel(key),
        fill: quotaFill(window.used_percentage).fill,
        level: "accent",
        percent: `${percent}%`,
        reset: `reset · ${quotaReadAge(limits, now)}`,
        state: "reset",
      };
    }
    return {
      key,
      label: quotaLabel(key),
      ...quotaFill(window.used_percentage),
      percent: `${percent}%`,
      reset: `resets ${quotaResetTime(resetAt, now)}`,
      state: stale ? "stale" : "fresh",
    };
  });
  const note = stale ? `${age}; open a Claude Code session to refresh it.` : age;
  return { bars, note };
}

// --- the numbers on the page --------------------------------------------------

/** The token counts of `GET /api/usage/daily`, per day, per project and
 * over the range: the four kinds Claude Code bills, and the requests. */
export type UsageTokens = {
  input: number;
  output: number;
  cacheCreation: number;
  cacheRead: number;
  requests: number;
};

/** Cost and tokens for one day or one project. `costUSD` is the dollars
 * attributed; `apportionedUSD` is the part of it that came from a session
 * spanning midnight and was split by token share. `unbilledSessions` had
 * turns and no bill yet. */
export type UsageBucket = {
  costUSD: number;
  apportionedUSD: number;
  /** The part of `costUSD` from a record the rollup read before it kept
   * the per-model map, whose transcript is gone: in the total, in no
   * model's row. Absent from a daemon before `agent-dashboard` round 5. */
  unsplitUSD?: number;
  tokens: UsageTokens;
  sessions: number;
  unbilledSessions: number;
  /** The bills' API milliseconds, each session's share by the day's token
   * share: the hours of model time. Absent from a daemon before
   * `agent-dashboard` round 6. */
  apiMs?: number;
  /** The dollars of the sessions whose record carries a duration, so a
   * rate an hour divides the dollars the hours belong to. */
  measuredUSD?: number;
};

/** One role's part of the range: a session in a checkout's root, or a
 * crew in a worktree, by the transcript's own directory. */
export type UsageRole = {
  role: "root" | "crew";
  costUSD: number;
  apportionedUSD: number;
  sessions: number;
  apiMs: number;
  measuredUSD: number;
  linesAdded: number;
};

/** A billed session over $5 in the range under 95% cached: the `LEAKS`
 * exception line, the only place the cache share appears. */
export type LowCacheSession = { sessionId?: string; project: string; costUSD: number; cacheShare: number };

/** One model's part of a day or of the range: the bill's own field names,
 * and the name the daemon derived by the naming rule. The `MODELS` panel
 * (capability 7) reads these; this round serves them. */
export type UsageModel = {
  model: string;
  name: string;
  costUSD: number;
  apportionedUSD: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadInputTokens: number;
  cacheCreationInputTokens: number;
  sessions: number;
};

export type UsageProject = UsageBucket & { id: string; name: string; root: string; registered: boolean };

export type UsageDay = UsageBucket & { day: string; models?: UsageModel[]; projects: UsageProject[] };

/** The route's answer: one entry per day in the range, zero-filled, the
 * totals, and the totals per project over the range. */
export type UsageDaily = {
  ok: boolean;
  timeZone: string;
  from: string;
  to: string;
  /** Epoch milliseconds of the rollup's last refresh; 0 before the first. */
  refreshedAt: number;
  recordedSessions: number;
  days: UsageDay[];
  totals: UsageBucket;
  /** The range's split per model, dearest first; its dollars sum to
   * `totals.costUSD` less `totals.unsplitUSD`. */
  models?: UsageModel[];
  projects: UsageProject[];
  /** The range per role, `root` then `crew`; absent from a daemon before
   * `agent-dashboard` round 6. */
  roles?: UsageRole[];
  /** The sessions over $5 under 95% cached, dearest first; absent from an
   * older daemon. */
  lowCache?: LowCacheSession[];
};

/** What the panel plots: dollars, or tokens of every kind. */
export type UsageMode = "cost" | "tokens";
/** The ranges the panel offers, in days, today included. */
export type UsageSpan = 7 | 30 | 90;
export const USAGE_SPANS: readonly UsageSpan[] = [7, 30, 90];
export const USAGE_MODES: readonly UsageMode[] = ["cost", "tokens"];

/** The reader's choice of mode and span, kept in `localStorage`. */
export type UsageChoice = { mode: UsageMode; span: UsageSpan };
export const USAGE_DEFAULT: UsageChoice = { mode: "cost", span: 30 };

/** The choice read back from storage: the default for anything that is not
 * one of the offered values, so a stale or hand-edited entry cannot ask the
 * route for a range it refuses. */
export function readUsageChoice(raw: string | null | undefined): UsageChoice {
  if (!raw) return USAGE_DEFAULT;
  try {
    const parsed = JSON.parse(raw) as Partial<Record<keyof UsageChoice, unknown>>;
    const mode = USAGE_MODES.find((m) => m === parsed.mode) ?? USAGE_DEFAULT.mode;
    const span = USAGE_SPANS.find((s) => s === parsed.span) ?? USAGE_DEFAULT.span;
    return { mode, span };
  } catch {
    return USAGE_DEFAULT;
  }
}

/** `YYYY-MM-DD` of an epoch in the browser's own zone. The rollup's day is
 * the daemon's zone; a phone in another zone asks for a range a day off,
 * and the panel prints the days the route answered, not the ones asked. */
export function dayKey(epochMs: number): string {
  const d = new Date(epochMs);
  const pad = (n: number): string => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** The inclusive range for a span ending today: 7 is today and the six
 * days before it. Stepped in local noon-to-noon days, so a daylight-saving
 * change inside the span does not lose a day. */
export function usageRange(span: UsageSpan, now: number): { from: string; to: string } {
  const to = new Date(now);
  const from = new Date(to.getFullYear(), to.getMonth(), to.getDate() - (span - 1), 12);
  return { from: dayKey(from.getTime()), to: dayKey(now) };
}

/** `$1,084.03`: two decimals, thousands grouped, never rounded to a whole
 * dollar, because a goal's round can cost cents. */
export function dollars(usd: number): string {
  const fixed = Math.abs(usd).toFixed(2);
  const [whole, cents] = fixed.split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${usd < 0 ? "-" : ""}$${grouped}.${cents}`;
}

/** `$2,316` for $2,316.83: the dollars with the cents cut, thousands
 * grouped, for the band and a phone's `MODELS` row, where the cents are
 * noise beside the number. Cut, not rounded, as the frame prints it. */
export function wholeDollars(usd: number): string {
  const whole = String(Math.floor(Math.abs(usd))).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${usd < 0 ? "-" : ""}$${whole}`;
}

/** Whole units under a thousand, one decimal of `k` under a million, two
 * decimals of `M` under a billion, two of `B` above: `0`, `17.7k`,
 * `1.10M`, `2.31B`. The shape `kitterm goal cost` prints. */
export function tokenCount(count: number): string {
  if (count >= 1_000_000_000) return `${(count / 1_000_000_000).toFixed(2)}B`;
  if (count >= 1_000_000) return `${(count / 1_000_000).toFixed(2)}M`;
  if (count >= 1000) return `${(count / 1000).toFixed(1)}k`;
  return String(Math.round(count));
}

/** Every kind, the number the tokens series plots. */
export function totalTokens(t: UsageTokens): number {
  return t.input + t.output + t.cacheCreation + t.cacheRead;
}

/** Input, cache creation and cache read together: the `in` of the ledger,
 * the tokens the model was given. */
export function inTokens(t: UsageTokens): number {
  return t.input + t.cacheCreation + t.cacheRead;
}

/** The cache-read share of the input, 0 to 1; null when nothing was read.
 * No heading prints it since `agent-dashboard` round 6; the daemon's
 * `lowCache` list is the exception line's source. Kept, with `cachedLabel`,
 * for the share's own arithmetic and its tests. */
export function cacheShare(cacheRead: number, input: number): number | null {
  return input > 0 ? cacheRead / input : null;
}

/** `91% cached`, or null for no share. */
export function cachedLabel(share: number | null): string | null {
  return share === null ? null : `${Math.round(share * 100)}% cached`;
}

/** What a heading prints after its name: the dollars, `$850.51`, and
 * nothing else. `$0.00` for a heading the report priced at nothing,
 * because "nothing" is an answer and an absent number would read as "not
 * loaded". The cache share is not here: `corpus/valuemaxxing.md` measured
 * it at 95–99% on every session over $5 but three, a constant that
 * carries no information, so it left every heading and appears only as
 * the `LEAKS` exception line (`leakLines`). */
export function costLabel(bucket: UsageBucket | null): string {
  return dollars(bucket === null ? 0 : bucket.costUSD);
}

const ZERO_TOKENS: UsageTokens = { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 };

function addBuckets(a: UsageBucket, b: UsageBucket): UsageBucket {
  return {
    costUSD: a.costUSD + b.costUSD,
    apportionedUSD: a.apportionedUSD + b.apportionedUSD,
    tokens: {
      input: a.tokens.input + b.tokens.input,
      output: a.tokens.output + b.tokens.output,
      cacheCreation: a.tokens.cacheCreation + b.tokens.cacheCreation,
      cacheRead: a.tokens.cacheRead + b.tokens.cacheRead,
      requests: a.tokens.requests + b.tokens.requests,
    },
    // A session on two projects is not a thing, so the counts add.
    sessions: a.sessions + b.sessions,
    unbilledSessions: a.unbilledSessions + b.unbilledSessions,
  };
}

/** The range's bucket for one project root, or null when the report names
 * none: the rollup keys a session on the root its cwd resolved to, which is
 * the registered root or the checkout, the same `root` the page's project
 * carries, so the match is by root. */
export function projectUsage(report: UsageDaily | null | undefined, root: string | null | undefined): UsageBucket | null {
  if (!report || !root) return null;
  const trimmed = root.replace(/\/+$/, "");
  return report.projects.find((p) => p.root.replace(/\/+$/, "") === trimmed) ?? null;
}

/**
 * The range's bucket for a workspace directory: every project bucket whose
 * root the directory is or holds, by the rule that homes a loose shell
 * (`workspaceHome`, the deepest of `headed`), summed. That takes in the
 * projects on the page, a checkout under the directory the page does not
 * list, and the sessions that ran in the directory itself, which is where
 * the workspace's foreman sits. Null when the report names nothing there.
 */
export function workspaceUsage(
  report: UsageDaily | null | undefined,
  dir: string | null | undefined,
  headed: readonly string[],
): UsageBucket | null {
  if (!report || !dir) return null;
  let sum: UsageBucket | null = null;
  for (const p of report.projects) {
    if (workspaceHome(p.root, headed) !== dir) continue;
    sum = sum === null ? { ...p, tokens: { ...p.tokens } } : addBuckets(sum, p);
  }
  return sum;
}

/** Two inclusive day keys, `YYYY-MM-DD`: the range the rollup answered
 * for the toggles' span, which every figure on the page follows. */
export type DayRange = { from: string; to: string };

/** The rounds of a goal that started inside the range. A record with no
 * start day cannot be placed and is left out, which is never a guess. */
export function roundsInRange(summary: Pick<KnowledgeSummary, "rounds">, range: DayRange): RoundRecord[] {
  return (summary.rounds ?? []).filter((r) => typeof r.started === "string" && r.started >= range.from && r.started <= range.to);
}

/** What a goal prints beside its round: the sum of the `Cost:` lines of
 * its records that started in the range, `$12.34` (round 13: the same
 * rounds the `WHERE` panel sums, never the route's all-time `costUSD`);
 * null for a goal whose rounds in the range carry no line, which is a
 * goal that predates the bill, not a free one. The cache share left the
 * line with the headings' (`costLabel`). */
export function goalCost(summary: Pick<KnowledgeSummary, "rounds">, range: DayRange): string | null {
  const priced = roundsInRange(summary, range).filter((r) => typeof r.costUSD === "number");
  return priced.length > 0 ? dollars(priced.reduce((sum, r) => sum + (r.costUSD ?? 0), 0)) : null;
}

/** What a task prints in the cost column (round 15): the `Cost:` line of
 * the round its `STATE.md` line names, `round 6`, when that record started
 * in the range; null for a task that names no round, a round with no
 * record or no line, or one outside the range. */
export function taskCost(summary: Pick<KnowledgeSummary, "rounds">, round: number | undefined, range: DayRange): string | null {
  if (typeof round !== "number") return null;
  const record = roundsInRange(summary, range).find((r) => r.number === round);
  return record && typeof record.costUSD === "number" ? dollars(record.costUSD) : null;
}

/** What a session prints in the cost column (round 15): its transcript's
 * bill, `$12.85`, when the session began inside the range (`startTime`,
 * in this browser's zone; a bill with no start is counted); for a running
 * session with no bill yet, its estimate as `~$4.20` (round 16), placed
 * in the range by its first turn the same way; null for a session with
 * neither, or none fetched. */
export function sessionCost(bill: SessionBill | null | undefined, range: DayRange): string | null {
  if (bill?.hasBill && typeof bill.totalCostUSD === "number") {
    return inRange(bill.startTime, range) ? dollars(bill.totalCostUSD) : null;
  }
  const estimate = bill?.estimate;
  if (!estimate || typeof estimate.costUSD !== "number") return null;
  return inRange(estimate.startTime, range) ? `~${dollars(estimate.costUSD)}` : null;
}

/** Whether a start moment falls inside the range; one with no moment is
 * counted. */
function inRange(startTime: number | undefined, range: DayRange): boolean {
  if (typeof startTime !== "number") return true;
  const day = dayKey(startTime);
  return day >= range.from && day <= range.to;
}

/** The cost cell's tooltip of a session line: what the figure is. A bill
 * is the transcript's; an estimate says how many turns it prices and how
 * old it is, `estimated from 12 turns · updated 12s ago` (round 16). */
export function sessionCostTitle(bill: SessionBill | null | undefined, now: number): string {
  const estimate = bill?.estimate;
  if (bill?.hasBill || !estimate) return BILL_TITLE;
  return `estimated from ${plural(estimate.turns, "turn", "turns")} · updated ${secondsAgo(now - estimate.updatedAt)}`;
}

/** The tooltip of a session's bill in the cost column. */
export const BILL_TITLE = "the bill of this session's transcript, when it began in the range";

/** `12s ago` under a minute, then the span's two-unit label, `4m ago`. */
export function secondsAgo(ms: number): string {
  const seconds = Math.floor(Math.max(0, ms) / 1000);
  return seconds < 60 ? `${seconds}s ago` : `${spanLabel(ms)} ago`;
}

/** What a project's sessions are estimated to have cost so far, summed,
 * as its name's tooltip prints it, `+ ~$4.20 running` (round 16): the
 * rollup counts a session only once its transcript is billed, so a
 * running session's estimate is on its own line and on no figure above
 * it. Null with no estimated session under the project. */
export function runningEstimate(rows: readonly Pick<ModelRow, "id">[], billOf: (id: string) => SessionBill | null | undefined): string | null {
  let sum = 0;
  let any = false;
  for (const row of rows) {
    const bill = billOf(row.id);
    if (bill?.hasBill || typeof bill?.estimate?.costUSD !== "number") continue;
    sum += bill.estimate.costUSD;
    any = true;
  }
  return any ? `+ ~${dollars(sum)} running` : null;
}

/** One toggle of the panel: what it prints, whether it is the choice, and
 * the name a screen reader gets. */
export type UsageToggle = { label: string; checked: boolean; name: string };

/** The usage panel as the page prints it. `series` is one number per day
 * in the route's order, dollars or tokens by `mode`; `days` the matching
 * day keys; `peak` the largest, for the chart's scale and its caption. */
export type UsagePanel = {
  mode: UsageMode;
  span: UsageSpan;
  /** `Usage · last 30 days`. */
  title: string;
  /** `$1,084.03`, or `312.4M` in tokens mode. */
  headline: string;
  /** What the headline is: the full API rate, or tokens of every kind. */
  qualifier: string;
  /** `17 Aug to 16 Sep`, the days the route answered. */
  range: string;
  series: number[];
  days: string[];
  peak: { day: string; value: number } | null;
  /** True when the range holds no session: the chart is an empty axis. */
  empty: boolean;
  /** What the numbers are made of: the apportioned part and the sessions
   * without a bill, or that neither applies. */
  note: string;
  /** How old the rollup is, `rollup refreshed 4m ago`, or that it has not. */
  age: string;
  modes: UsageToggle[];
  spans: UsageToggle[];
};

/** `16 Sep` from `2026-09-16`; the key itself when it is not a day. */
export function dayLabel(key: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(key);
  if (!m) return key;
  return `${Number(m[3])} ${MONTHS[Number(m[2]) - 1] ?? m[2]}`;
}

/** The chart's value for one day: dollars or every token. */
export function usageValue(bucket: UsageBucket, mode: UsageMode): number {
  return mode === "cost" ? bucket.costUSD : totalTokens(bucket.tokens);
}

/** The value as the chart's caption prints it: `$99.95` or `48.2M`. */
export function usageAmount(value: number, mode: UsageMode): string {
  return mode === "cost" ? dollars(value) : tokenCount(value);
}

function plural(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`;
}

/**
 * The note under the chart: one line that names a fact
 * (`design-foundation.md`, "The panels"). In cost mode, the part of the
 * total that is apportioned across midnight by token share rather than
 * measured, and the sessions that have turns and no bill yet, whose tokens
 * are in and whose dollars are not; in tokens mode only the unbilled
 * count, because every token is counted. Under 46 characters, which is
 * what one line holds at 390 px; the page's title on the note carries the
 * long form.
 */
export function usageNote(totals: UsageBucket, mode: UsageMode): string {
  const unbilled = totals.unbilledSessions > 0 ? `${plural(totals.unbilledSessions, "session", "sessions")} unbilled` : null;
  if (mode === "tokens") return unbilled ? `${unbilled}: tokens counted` : "every session billed";
  const apportioned = totals.apportionedUSD > 0 ? dollars(totals.apportionedUSD) : null;
  if (apportioned && unbilled) return `${apportioned} apportioned · ${unbilled}`;
  if (apportioned) return `${apportioned} apportioned across midnight`;
  if (unbilled) return `${unbilled}: tokens in, dollars not`;
  return "every dollar measured on its day";
}

/**
 * The usage panel from the route's answer, or null when the page has none
 * to draw: a watch token, which the daemon refuses, a daemon too old to
 * have the route, or one built without a rollup.
 *
 * The headline is the range's total, marked as the full API rate, because
 * `totalCostUSD` is priced at the pay-as-you-go rate whatever the plan;
 * on a subscription it is what the work would have cost, not what was
 * paid. The series is the route's days in its order, zero-filled, so a
 * silent day is a gap the reader sees. An empty range draws the axis and
 * says so. The note names the apportioned part and the unbilled sessions,
 * so nothing on the panel reads as a measurement that is not one.
 */
export function usagePanel(
  report: UsageDaily | null | undefined,
  choice: UsageChoice,
  now: number,
): UsagePanel | null {
  if (!report || !report.ok) return null;
  const { mode, span } = choice;
  const days = report.days.map((d) => d.day);
  const series = report.days.map((d) => usageValue(d, mode));
  let peak: UsagePanel["peak"] = null;
  series.forEach((value, i) => {
    if (value > 0 && (peak === null || value > peak.value)) peak = { day: days[i], value };
  });
  const totals = report.totals ?? { costUSD: 0, apportionedUSD: 0, tokens: ZERO_TOKENS, sessions: 0, unbilledSessions: 0 };
  const empty = totals.sessions === 0;
  const from = days[0] ?? report.from;
  const to = days[days.length - 1] ?? report.to;
  const range = from === to ? dayLabel(from) : `${dayLabel(from)} to ${dayLabel(to)}`;
  const age = report.refreshedAt > 0
    ? `rollup refreshed ${spanLabel(now - report.refreshedAt) === "now" ? "just now" : `${spanLabel(now - report.refreshedAt)} ago`}`
    : "the rollup has not refreshed yet";
  return {
    mode,
    span,
    title: `Usage · last ${span} days`,
    headline: mode === "cost" ? dollars(totals.costUSD) : tokenCount(totalTokens(totals.tokens)),
    qualifier: mode === "cost" ? "if billed at full API rate" : "tokens, every kind, input and output and cache",
    range,
    series,
    days,
    peak,
    empty,
    note: empty ? `No usage recorded from ${range}.` : usageNote(totals, mode),
    age,
    modes: USAGE_MODES.map((m) => ({ label: m, checked: m === mode, name: m === "cost" ? "Show cost" : "Show tokens" })),
    spans: USAGE_SPANS.map((s) => ({ label: `${s}d`, checked: s === span, name: `Show the last ${s} days` })),
  };
}

/** The chart's name for a screen reader: the range, the peak, the shape. */
export function usageChartName(panel: UsagePanel): string {
  if (panel.empty || panel.peak === null) return `No ${panel.mode === "cost" ? "cost" : "tokens"} per day, ${panel.range}.`;
  const unit = panel.mode === "cost" ? "Cost" : "Tokens";
  return `${unit} per day, ${panel.range}; the most on ${dayLabel(panel.peak.day)}, ${usageAmount(panel.peak.value, panel.mode)}.`;
}

// --- the band ------------------------------------------------------------------

/** The four cells, in the order they print (`design-foundation.md`, The
 * frame): agents working, items needing a person, spend over the range,
 * quota used. */
export type BandCellKey = "working" | "needs" | "spend" | "quota";

/** One cell: a count and its noun. The count is the text the eye reads;
 * the noun says what it counts; `title` is the sentence a tooltip gets. */
export type BandCell = {
  key: BandCellKey;
  /** `2`, `4`, `$2,316.45`, `19%`; `–` for a cell whose source the page
   * does not have, never a zero that would read as a measurement. */
  value: string;
  /** `working`, `need you`, `30d`, `quota · 3h 16m`. */
  noun: string;
  title: string;
  /** The colour the count wears: the accent on the working count, the
   * amber on the need-you count, none on the two numbers. The count is
   * the one glyph run in the band that carries a state, so it is a mark. */
  family?: "running" | "attention";
};

/** The band as the page prints it. Always four cells, whatever the fleet
 * is doing: the frame does not move (principle 2). */
export type Band = {
  cells: BandCell[];
  /** How many items need a person: the second cell's count. */
  needs: number;
  /** The id the "need you" cell links, the first marked line in the tree;
   * null when nothing needs a person, and the cell is a word, not a link. */
  target: string | null;
};

/** The id the page gives the first marked line, the "need you" cell's
 * link target. One id, so the link is a plain fragment and needs no
 * script to scroll. */
export const NEEDS_YOU_ID = "needs-you";

/** How many rows are working: a shell running a command or an agent
 * holding the tty, whatever else the fleet holds. */
export function workingCount(rows: ModelRow[]): number {
  return rows.filter((row) => stateOf(row) === "working").length;
}

/** What a workspace or a project prints for its working sessions at the
 * line's end: `1 agent`, `2 agents`; null for none, because a heading
 * with no agent prints nothing rather than a zero. */
export function agentsLabel(working: number): string | null {
  if (working <= 0) return null;
  return `${working} ${working === 1 ? "agent" : "agents"}`;
}

/** Is the row an idle shell: a session nobody is waiting on and no agent
 * holds, so it is not a line of the tree but one of the `N idle shells`
 * the page folds at its foot. `idle`, `exited` with a zero code, and a
 * shell with no integration; a `completed` agent at its prompt is not
 * one, because `claude` still holds its tty. */
export function isIdleShell(row: ModelRow): boolean {
  const state = stateOf(row);
  return state === "idle" || state === "exited" || state === "unknown";
}

/** The fold line over the idle shells: `1 idle shell`, `3 idle shells`. */
export function idleShellsLabel(count: number): string {
  return `${count} idle ${count === 1 ? "shell" : "shells"}`;
}

/** The noun of the "need you" cell: `needs you` for one item, `need you`
 * otherwise, zero included. */
export function needsNoun(count: number): string {
  return count === 1 ? "needs you" : "need you";
}

/** Does a row's own state need a person: it waits for input or it
 * failed. These are the rows `attention` counts; a pending approval is
 * counted from the approvals list and marks its own line under the row. */
export function rowNeeds(row: ModelRow): boolean {
  const state = stateOf(row);
  return state === "needs-input" || state === "failed";
}

/** The approvals that block one session: the row's own approval lines. */
export function approvalsOf(row: ModelRow, approvals: readonly Approval[]): Approval[] {
  return approvals.filter((approval) => approval.session === row.id);
}

/**
 * The approvals with no row on the page: one whose session the daemon no
 * longer lists (a hook can name a session id from before a restart,
 * `facts.md`), or one that names no session. Each is still an item that
 * needs a person, so it gets a line of its own under the "No project"
 * heading, which is where a thing with no place in the tree goes; the
 * page makes that section for them when no loose shell would.
 */
export function orphanApprovals(approvals: readonly Approval[], rows: readonly ModelRow[]): Approval[] {
  const ids = new Set(rows.map((row) => row.id));
  return approvals.filter((approval) => !approval.session || !ids.has(approval.session));
}

/** The noun of the quota cell: `quota · 3h 16m`, the word and the
 * countdown to the window's reset, as the frame draws it. */
export function bandQuotaNoun(reset: string): string {
  return `quota · ${reset}`;
}

/** The window the band's quota cell reads: the session window
 * (`five_hour`) while it has not reset, because it is the one that
 * decides whether more work can start now; else the most-used window
 * that has not reset. */
const BAND_QUOTA_WINDOW = "five_hour";

/**
 * The quota cell: the session window's share and its countdown, `19%`
 * with `quota · 3h 16m`, from the newest reading; the most-used window
 * that has not reset when the reading carries no session window. `–`
 * with the noun `quota` when the page has no reading, the reading
 * carries no window, or every window has reset; the quota panel below
 * says which in words.
 */
export function bandQuota(limits: UsageLimits | null | undefined, now: number): BandCell {
  const none: BandCell = { key: "quota", value: "–", noun: "quota", title: "No quota reading." };
  if (!limits || !limits.ok || !limits.hasReading) return none;
  const live = Object.entries(limits.rateLimits ?? {}).filter(([, window]) => window.resets_at * 1000 > now);
  let top: [string, LimitWindow] | null = live.find(([key]) => key === BAND_QUOTA_WINDOW) ?? null;
  if (top === null) {
    for (const entry of live) {
      if (top === null || entry[1].used_percentage > top[1].used_percentage) top = entry;
    }
  }
  if (top === null) return none;
  const [key, window] = top;
  const percent = Math.round(Math.min(999, Math.max(0, window.used_percentage)));
  const stale = limits.stale === true ? ", from a stale reading" : "";
  const reset = countdown(window.resets_at * 1000 - now);
  return {
    key: "quota",
    value: `${percent}%`,
    noun: bandQuotaNoun(reset),
    title: `${quotaLabel(key)}: ${percent}% used, resets in ${reset}${stale}.`,
  };
}

/** The spend cell: the range's total at the full API rate in whole
 * dollars, `$2,316`, with the span as its noun; `–` with the noun `spend`
 * when the page has no rollup (a watch token, or a daemon without the
 * route). The cents are on the `USAGE` headline under it. */
export function bandSpend(report: UsageDaily | null | undefined, choice: UsageChoice): BandCell {
  if (!report || !report.ok) return { key: "spend", value: "–", noun: "spend", title: "No usage rollup." };
  const total = report.totals?.costUSD ?? 0;
  return {
    key: "spend",
    value: wholeDollars(total),
    noun: `${choice.span}d`,
    title: `${dollars(total)}: what the last ${choice.span} days cost, if billed at full API rate.`,
  };
}

/**
 * The band: four cells, always, in one order. `items` is everything that
 * needs a person (`withProposed(attention(rows, approvals), proposed)`):
 * every pending approval, every session waiting for input, every failed
 * session, and every live goal's proposals. A failed session counts,
 * because no agent can move it and a returning reader must see it on
 * the first screen (`fleet-catch-up`, request 01). The count is the
 * number of marked lines the reader can walk to from the cell's link.
 */
export function band<R extends ModelRow>(
  rows: R[],
  items: readonly (AttentionItem<R> | ProposedItem)[],
  report: UsageDaily | null | undefined,
  choice: UsageChoice,
  limits: UsageLimits | null | undefined,
  now: number,
): Band {
  const working = workingCount(rows);
  const needs = items.length;
  return {
    cells: [
      {
        key: "working",
        value: String(working),
        noun: "working",
        title: `${working} ${working === 1 ? "session is" : "sessions are"} running a command or an agent.`,
        family: "running",
      },
      {
        key: "needs",
        value: String(needs),
        noun: needsNoun(needs),
        title: "Pending approvals, sessions waiting for input, failed sessions, and live goals' proposals.",
        family: "attention",
      },
      bandSpend(report, choice),
      bandQuota(limits, now),
    ],
    needs,
    target: needs > 0 ? NEEDS_YOU_ID : null,
  };
}
