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
function sections<R extends ModelRow>(rows: R[]): CrewSection<R>[] {
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
    return { key: project.id, project, rows: sortInGroup(list), sections: sections(list) };
  });
  if (loose.length > 0) {
    groups.push({
      key: NO_PROJECT,
      project: null,
      rows: sortInGroup(loose),
      sections: sections(loose),
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

/** The distinct crew label values across the rows, in name order. */
export function crews(rows: ModelRow[]): string[] {
  const set = new Set<string>();
  for (const row of rows) {
    const crew = crewOf(row);
    if (crew !== null) set.add(crew);
  }
  return [...set].sort((a, b) => a.localeCompare(b));
}
