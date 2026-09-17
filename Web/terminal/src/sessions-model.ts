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
};

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
};

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
 * What the strip lists, in order: every pending approval (with its row when
 * the session is still listed), then the rows that need input, then the
 * failed rows. The two row lists take `sortInGroup`'s order.
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

/** The first word of a proposed strip item: how many wait. */
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
 * round, so the strip does not carry them; the goal's own line does
 * (`lineProposals`). A `waiting` goal is open: it waits for the human's
 * direction, and its proposals are what the human decides on. A summary
 * with no status word is open too, so a daemon that sends none loses
 * nothing. */
export function isClosed(summary: KnowledgeSummary): boolean {
  const word = statusWord(summary.status);
  return word === "done" || word === "stopped";
}

/**
 * One attention item per open goal whose `STATE.md` counts proposals
 * waiting on the human, in the order given (one entry per goal of each
 * project, the route's order), less the ones in `dismissed` (keys from
 * `dismissKey`) and less every closed goal (`isClosed`): the strip holds
 * only what still needs the human, and a done or stopped goal has no round
 * for a proposal to block. Its count stands on the goal's own line instead
 * (`lineProposals`).
 *
 * The count is the trigger, because `STATE.md` is the foreman's source of
 * truth: it writes a proposal there at close, and the record's decision
 * line does not always carry it (`foreman-harness` round 4 reads `done`
 * with its proposal in `STATE.md` alone). A decision that starts with
 * `propose` is only the item's one-line text, and a goal with no proposals
 * in `STATE.md` yields nothing whatever the decision says, so a proposal
 * the human pruned leaves the strip on the next poll.
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
 * The strip's order: the attention items with the proposed ones inserted
 * before the first failed row. A proposal counts as "needs you" and a
 * failed row does not, so the order agrees with the count.
 */
export function withProposed<R extends ModelRow>(
  items: AttentionItem<R>[],
  proposed: ProposedItem[],
): (AttentionItem<R> | ProposedItem)[] {
  const at = items.findIndex((item) => item.kind === "failed");
  if (at < 0) return [...items, ...proposed];
  return [...items.slice(0, at), ...proposed, ...items.slice(at)];
}

/** The ids of the sessions the strip shows: the row of every approval
 * that still has one, and every needs-input and failed row. */
export function stripIds<R extends ModelRow>(items: (AttentionItem<R> | ProposedItem)[]): Set<string> {
  const ids = new Set<string>();
  for (const item of items) {
    if (item.kind === "proposed") continue;
    if (item.row) ids.add(item.row.id);
  }
  return ids;
}

/**
 * The rows the cards list: every row the strip does not show, in the order
 * given. A session that needs a person, or failed, is in the strip with
 * its project's name, so its card does not print it again; the card's
 * count is over these rows, and a project whose every session is in the
 * strip lists nothing and counts nothing.
 */
export function cardRows<R extends ModelRow>(rows: R[], items: (AttentionItem<R> | ProposedItem)[]): R[] {
  const shown = stripIds(items);
  return rows.filter((row) => !shown.has(row.id));
}

/**
 * The record a goal's card links, or null when the strip already links it:
 * a proposal in the strip carries the record it comes from, so the card
 * keeps only the title and the status until the human dismisses it, and
 * the link then returns to the card.
 */
export function cardRecord(projectId: string, summary: KnowledgeSummary, proposed: ProposedItem[]): string | null {
  const path = recordPath(summary);
  if (path === null) return null;
  const inStrip = proposed.some(
    (item) => item.project.id === projectId && item.summary.slug === summary.slug && item.record === path,
  );
  return inStrip ? null : path;
}

/** What a goal's own line says about its proposals when the strip does
 * not: how many `STATE.md` lists, and the `STATE.md` they wait in. */
export type LineProposals = { count: number; path: string };

/**
 * The proposals a goal's own line carries: the count and the `STATE.md`
 * path when `STATE.md` lists any and the strip does not show them, because
 * the goal is closed (`isClosed`) or the human dismissed the item. Null
 * when the goal lists none or the strip carries them: a proposal appears
 * in the strip or on the goal's line, never in both places. The count is
 * `STATE.md`'s bullet count whole; the page has no per-proposal state, so
 * a proposal stands until the human prunes its bullet.
 */
export function lineProposals(projectId: string, summary: KnowledgeSummary, proposed: ProposedItem[]): LineProposals | null {
  const count = summary.proposals ?? 0;
  if (count <= 0) return null;
  const inStrip = proposed.some((item) => item.project.id === projectId && item.summary.slug === summary.slug);
  return inStrip ? null : { count, path: statePath(summary) };
}

// --- a session row -----------------------------------------------------------

/** What one row prints, in order: the name, the state word, where the shell
 * is when the name does not say, what it is doing, and how long. A null
 * field is not printed. */
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
  const state = stateOf(row);
  const word = stateName(state);
  if (state !== "failed" && state !== "exited") return word;
  const code = row.lastExit;
  return typeof code === "number" && code !== 0 ? `${word} (${code})` : word;
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
    state: stateLabel(row),
    place: row.name ? whereOf(row, base) : null,
    what: row.agent?.message ?? row.note ?? command,
    since: typeof row.lastOutputAt === "number" ? spanLabel(now - row.lastOutputAt) : null,
  };
}

/**
 * The project word beside a strip item's name, or null when the name says
 * it already. A row named after its folder, `NgheNhanTrading` in
 * `/w/NgheNhanTrading`, would otherwise print the word twice; a row with no
 * project is named by its folder, so there is nothing else to say.
 */
export function stripWhere(row: ModelRow): string | null {
  const project = row.project?.name;
  if (!project || project === rowName(row)) return null;
  return project;
}

/** The states the fleet line counts, in the order it prints them. These
 * are the states the strip does not hold. */
const FLEET_STATES: MergedState[] = ["working", "completed", "idle", "exited", "unknown"];

/**
 * The one line above the projects: how many sessions are working, and how
 * many are done, idle, exited or without integration. `working` prints
 * even at zero, because "0 working" is the answer a returning reader came
 * for; the other counts print only when they are not zero. The rows are
 * the ones the projects list, so a session in the strip is counted there
 * and not here again.
 */
export function fleetLine(rows: ModelRow[]): string {
  const counts = tally(rows);
  const parts: string[] = [];
  for (const state of FLEET_STATES) {
    const n = counts[state] ?? 0;
    if (n === 0 && state !== "working") continue;
    parts.push(`${n} ${stateName(state)}`);
  }
  return parts.join(" · ");
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
/** `.card .head { gap }` and `.card .spawn { gap }`. */
const HEAD_GAP_PX = 10;
const SPAWN_GAP_PX = 6;
/** `[new]`: five cells and 2 px of padding each side. */
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
  /** Every session the project owns, the strip's included; 0 prints
   * "no live session" on the heading. */
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
 * stopped. `owned` is every session the project owns, so a crew that sits
 * in the strip still holds its goal at working; `listed` is what the
 * section prints, so the crew's row nests under the goal only when the
 * strip does not carry it.
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
 * `listed` is what the sections print; `owned` is every session, so a
 * project whose sessions are all in the strip still counts them and a
 * crew in the strip still holds its goal at working. `goalsOf` answers a
 * project's knowledge, null or undefined when the page has none.
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

/** How many cells a bar has. Twenty is 5% a cell, and the number beside
 * the bar carries the rest; at 12 px it leaves room for the label and the
 * countdown on one 390 px line. */
export const QUOTA_CELLS = 20;

/** The windows in the order the page lists them; any other key follows,
 * by name, with its key as its label. */
const QUOTA_ORDER = ["five_hour", "seven_day", "spend_limit"];
const QUOTA_LABELS: Record<string, string> = {
  five_hour: "Session (5h)",
  seven_day: "Weekly",
  spend_limit: "Spend limit",
};

export type QuotaState = "fresh" | "stale" | "reset";

/** One bar: the label, the cells, the number, and the countdown, each a
 * string the page prints as is. `filled` is how many of `QUOTA_CELLS` are
 * full, so the page can colour the fill apart from the track. */
export type QuotaBar = {
  key: string;
  label: string;
  filled: number;
  /** `#####···············`, `QUOTA_CELLS` long, without the brackets. */
  cells: string;
  /** `24%`, or `reset` once `resets_at` has passed. */
  percent: string;
  /** `resets 49m`, or `12m ago` once the window has reset. */
  reset: string;
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

/** The cells for a percentage, rounded to the nearest cell and clamped to
 * the bar: `#` for a full cell, `·` for an empty one. */
export function quotaCells(percent: number, cells: number = QUOTA_CELLS): { filled: number; cells: string } {
  const clamped = Math.min(100, Math.max(0, Number.isFinite(percent) ? percent : 0));
  const filled = Math.round((clamped / 100) * cells);
  return { filled, cells: "#".repeat(filled) + "·".repeat(cells - filled) };
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

/** The reading's age as the note prints it: `read just now` under a
 * minute, then `read 4m ago`, `read 3h ago`, `read 2d ago`. */
export function quotaAge(receivedAt: number, now: number): string {
  const span = spanLabel(now - receivedAt);
  return span === "now" ? "read just now" : `read ${span} ago`;
}

/**
 * The quota panel, read at `now`, or null when the page has nothing to
 * draw: no answer from the route (a daemon too old to have it, or a watch
 * token, which the daemon refuses).
 *
 * A daemon never given a reading says so in words, and names the command
 * that teaches the statusline to post one. A reading with no window says
 * that too: Claude Code gives an API-key account none, and a session none
 * before its first response. A window whose `resets_at` has passed draws
 * an empty bar and says `reset`, because the number it carried is about a
 * window that no longer exists; the statusline drops such a window on its
 * next render, and the bar goes with it. A stale reading keeps its bars,
 * and the note says how old they are, because a bar from three hours ago
 * is still the account's last known state while the note stands beside it.
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
    if (resetAt <= now) {
      return {
        key,
        label: quotaLabel(key),
        filled: 0,
        cells: "·".repeat(QUOTA_CELLS),
        percent: "reset",
        reset: `${countdown(now - resetAt)} ago`,
        state: "reset",
      };
    }
    const percent = Math.round(Math.min(999, Math.max(0, window.used_percentage)));
    return {
      key,
      label: quotaLabel(key),
      ...quotaCells(window.used_percentage),
      percent: `${percent}%`,
      reset: `resets ${countdown(resetAt - now)}`,
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
  tokens: UsageTokens;
  sessions: number;
  unbilledSessions: number;
};

export type UsageProject = UsageBucket & { id: string; name: string; root: string; registered: boolean };

export type UsageDay = UsageBucket & { day: string; projects: UsageProject[] };

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
  projects: UsageProject[];
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

/** The cache-read share of the input, 0 to 1; null when nothing was read,
 * so a heading with no tokens prints no share rather than `0%`. */
export function cacheShare(cacheRead: number, input: number): number | null {
  return input > 0 ? cacheRead / input : null;
}

/** `91% cached`, or null for no share. */
export function cachedLabel(share: number | null): string | null {
  return share === null ? null : `${Math.round(share * 100)}% cached`;
}

/** What a heading prints after its name: the dollars, then the cache share
 * when there is one, `$850.51 · 91% cached`. `$0.00` for a heading the
 * report priced at nothing, because "nothing" is an answer and an absent
 * number would read as "not loaded". */
export function costLabel(bucket: UsageBucket | null): string {
  if (bucket === null) return dollars(0);
  const cached = cachedLabel(cacheShare(bucket.tokens.cacheRead, inTokens(bucket.tokens)));
  return cached === null ? dollars(bucket.costUSD) : `${dollars(bucket.costUSD)} · ${cached}`;
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

/** What a goal prints beside its round: the sum of its records' `Cost:`
 * lines with the cache share, `$12.34 · 88% cached`, from the fields the
 * knowledge route adds; null for a goal whose records carry no line, which
 * is a goal that predates the bill, not a free one. */
export function goalCost(summary: Pick<KnowledgeSummary, "costUSD" | "inTokens" | "cacheReadTokens">): string | null {
  if (typeof summary.costUSD !== "number") return null;
  const cached = cachedLabel(cacheShare(summary.cacheReadTokens ?? 0, summary.inTokens ?? 0));
  return cached === null ? dollars(summary.costUSD) : `${dollars(summary.costUSD)} · ${cached}`;
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

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

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

/** The note under the chart, so the numbers say what they are made of. */
export function usageNote(totals: UsageBucket, mode: UsageMode): string {
  const parts: string[] = [];
  if (mode === "cost" && totals.apportionedUSD > 0) {
    parts.push(`${dollars(totals.apportionedUSD)} of it is apportioned across midnight by token share, not measured`);
  }
  if (totals.unbilledSessions > 0) {
    parts.push(
      mode === "cost"
        ? `${plural(totals.unbilledSessions, "session has", "sessions have")} no bill yet, so their tokens are in and their dollars are not`
        : `${plural(totals.unbilledSessions, "session has", "sessions have")} no bill yet; their tokens are counted`,
    );
  }
  if (parts.length === 0) {
    return mode === "cost"
      ? "Every dollar is a session's own bill on the day it ran."
      : "Every session in the range has its bill.";
  }
  return parts.join("; ") + ".";
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
