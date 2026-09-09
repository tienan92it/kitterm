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

/** Rows whose `goal:` label names the project's own goal slug. */
export type GoalGroup<R extends ModelRow> = { slug: string; rows: R[] };

/** A round record whose decision is `propose`: the human has to decide
 * before the goal's next round. */
export type ProposedItem = {
  kind: "proposed";
  project: ProjectRef;
  summary: KnowledgeSummary;
  round: number;
  /** The record's path under the knowledge directory, `recordPath`. */
  path: string;
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

/** Attention rank: what the human is asked to act on, loudest first. Rows
 * with no rank sort after every ranked row. */
function rank(row: ModelRow): number {
  switch (stateOf(row)) {
    case "needs-approval":
      return 0;
    case "needs-input":
      return 1;
    case "failed":
      return 2;
    default:
      return 3;
  }
}

/** Attention first (needs-approval, needs-input, failed), then the most
 * recent output first. Stable: equal rows keep their input order. */
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

/** What a record link shows: the record's file name without `rounds/` and
 * `.md`, so `rounds/005.md` reads `005` and `rounds/7.md` reads `7`. The
 * word "record" tells it from the `round N of M` counter beside it. */
export function recordLabel(path: string): string {
  return path.replace(/^rounds\//, "").replace(/\.md$/, "");
}

/** The accessible name of a record link: what it opens and whose. */
export function recordName(path: string, project: string): string {
  return `Open round record ${recordLabel(path)} of ${project}`;
}

/** The accessible name of the proposals chip, a link to `STATE.md`. */
export function proposalsName(count: number, project: string): string {
  const noun = count === 1 ? "proposal" : "proposals";
  return `${count} ${noun} waiting on the human in STATE.md of ${project}`;
}

/** The accessible name of a proposal's Dismiss button: which round of
 * which project, so two Dismiss buttons read apart. */
export function dismissName(round: number, project: string): string {
  return `Dismiss the proposal of round ${round} of ${project}`;
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

/** The `round:` label as a whole number, or null when absent or not one. */
export function roundOf(row: ModelRow): number | null {
  const raw = row.labels?.round;
  if (!raw || !/^\d+$/.test(raw)) return null;
  return Number(raw);
}

/**
 * Split a card's rows into the goals' own crews and the rest: a row whose
 * `goal:` label equals a goal's slug goes under that slug, one group per
 * goal with rows in the goals' order; every other row, and every row when
 * no goal has a slug, stays in `rest` for the crew sections. Every group
 * keeps `sortInGroup`'s order.
 */
export function goalGroups<R extends ModelRow>(
  rows: R[],
  goals: KnowledgeSummary[] | null | undefined,
): { goals: GoalGroup<R>[]; rest: R[] } {
  const slugs = (goals ?? []).map((goal) => goal.slug).filter((slug): slug is string => !!slug);
  const groups: GoalGroup<R>[] = [];
  for (const slug of slugs) {
    const own = rows.filter((row) => goalOf(row) === slug);
    if (own.length > 0) groups.push({ slug, rows: sortInGroup(own) });
  }
  const rest = rows.filter((row) => !slugs.includes(goalOf(row) ?? ""));
  return { goals: groups, rest: sortInGroup(rest) };
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

/** What Dismiss stores for one proposal: the project and the round, so the
 * next round's proposal from the same project shows again. */
export function dismissKey(projectId: string, round: number): string {
  return `${projectId}:${round}`;
}

/**
 * One attention item per project whose latest round record's decision
 * starts with `propose`, in the order given, less the ones in `dismissed`
 * (keys from `dismissKey`). A summary with no round record or a decision of
 * `done` or `failed` yields nothing.
 */
export function proposedItems(
  entries: { project: ProjectRef; summary: KnowledgeSummary }[],
  dismissed: ReadonlySet<string> = new Set(),
): ProposedItem[] {
  const items: ProposedItem[] = [];
  for (const { project, summary } of entries) {
    const round = summary.lastRound;
    const path = recordPath(summary);
    if (typeof round !== "number" || path === null) continue;
    if (!(summary.lastDecision ?? "").trim().toLowerCase().startsWith("propose")) continue;
    if (dismissed.has(dismissKey(project.id, round))) continue;
    items.push({ kind: "proposed", project, summary, round, path });
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
