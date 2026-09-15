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

export type Kind = "human" | "crew";

export type Filter = {
  states?: MergedState[];
  /** Project ids; "" selects the rows outside every project. */
  projects?: string[];
  crews?: string[];
  kind?: Kind;
  query?: string;
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

/** Case-insensitive substring match over the name, the cwd, and the last
 * command. An empty or blank query matches every row. */
function matchesQuery(row: ModelRow, query: string): boolean {
  const needle = query.trim().toLowerCase();
  if (needle === "") return true;
  const haystack = [row.name ?? "", row.cwd, row.lastCommand ?? ""];
  return haystack.some((text) => text.toLowerCase().includes(needle));
}

/** Keep the rows that pass every set criterion. An empty list or an absent
 * field does not restrict. `kind` reads `orchestrated`: a crew row is one a
 * program made; a human row is one a person opened. */
export function filter<R extends ModelRow>(rows: R[], criteria: Filter): R[] {
  const states = criteria.states ?? [];
  const projects = criteria.projects ?? [];
  const crews = criteria.crews ?? [];
  return rows.filter((row) => {
    if (states.length > 0 && !states.includes(stateOf(row))) return false;
    if (projects.length > 0 && !projects.includes(row.project?.id ?? NO_PROJECT)) return false;
    if (crews.length > 0) {
      const crew = crewOf(row);
      if (crew === null || !crews.includes(crew)) return false;
    }
    if (criteria.kind === "crew" && !row.orchestrated) return false;
    if (criteria.kind === "human" && row.orchestrated) return false;
    if (!matchesQuery(row, criteria.query ?? "")) return false;
    return true;
  });
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

/**
 * One attention item per goal whose `STATE.md` counts proposals waiting on
 * the human, in the order given (one entry per goal of each project, the
 * route's order), less the ones in `dismissed` (keys from `dismissKey`).
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

/** The state's name as the chips and the tallies print it. */
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

/** Where a shell is, once: the path under the project root, else the
 * folder; null at the root itself, which the card above already names. */
function whereOf(row: ModelRow): string | null {
  const root = (row.project?.root ?? "").replace(/\/+$/, "");
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
 * only for a named row away from the project root, because an unnamed row
 * carries the path as its name and the card names the root.
 */
export function rowLine(row: ModelRow, now: number): RowLine {
  const command = row.lastCommand ? `$ ${row.lastCommand}` : null;
  return {
    name: rowName(row),
    state: stateLabel(row),
    place: row.name ? whereOf(row) : null,
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
