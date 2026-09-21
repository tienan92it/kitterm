/**
 * What the spend bought (`agent-dashboard`, capability 7; the wording and
 * the columns of the frames `Dashboard 1200` and `Dashboard 390`, round
 * 10): the pure model behind the `USAGE` headline, the `VALUE`, `WHERE`,
 * `MODELS` and `LEAKS` panels. No DOM, no clock; `sessions.ts` paints what
 * these return. The numbers and the refusals come from
 * `corpus/valuemaxxing.md`: a merged line and a merged pull request are
 * proxies for value, a row with no source prints a dash and never a zero,
 * the unattributed remainder is a row and not a footnote, and nothing here
 * knows or invents what an hour of the human's time is worth. No quality
 * rate and no rework rate either: every round on record says `done`, and
 * two fix commits are noise.
 */

import {
  countdown,
  dollars,
  projectUsage,
  roundsInRange,
  tokenCount,
  totalTokens,
  wholeDollars,
  type DayRange,
  type KnowledgeSummary,
  type ProjectRef,
  type ProjectSummary,
  type RoundRecord,
  type UsageBucket,
  type UsageChoice,
  pullRequestHref,
  type UsageDaily,
  type UsageMode,
  type UsageSpan,
} from "./sessions-model";

/** What a row prints for a value it has no source for. Never `0`. */
export const DASH = "–";

/** One merged pull request of `GET /api/yield`: its number and the lines
 * it added, so a goal's lines can be priced from the `PR #N` its records
 * name. Absent from a daemon before round 10. */
export type YieldPullRequest = { number: number; lines: number };

/** What `GET /api/yield` answers for one project: whether its root is a
 * git checkout, whether it has a remote, and what the range delivered
 * there. A count is absent, never zero, for a root with no history to
 * read it from: no checkout, or no remote for a pull request. */
export type RepositoryYield = {
  checkout: boolean;
  remote: boolean;
  branch?: string;
  mergedPullRequests?: number;
  mergedLines?: number;
  releases?: number;
  pullRequests?: YieldPullRequest[];
};

export type ProjectYield = { id: string; name: string; root: string; registered: boolean; yield: RepositoryYield };

/** The route's answer: every project the daemon lists, and the counts
 * summed over the ones that have them. */
export type YieldReport = {
  ok: boolean;
  from: string;
  to: string;
  projects: ProjectYield[];
  totals: { checkouts: number; counted: number; mergedPullRequests: number; mergedLines: number; releases: number };
};

/** `1,234`: thousands grouped, no decimals. */
export function count(n: number): string {
  return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

/** A unit cost: two decimals from a dollar up, three under it, so a line
 * at 1.7 cents reads `$0.017` and not `$0.02`. */
export function unitCost(usd: number): string {
  return usd >= 1 ? dollars(usd) : `$${usd.toFixed(3)}`;
}

/** Hours from milliseconds, one decimal under a hundred: `20.9`, `312`. */
export function hours(ms: number): string {
  const h = ms / 3_600_000;
  return h >= 100 ? String(Math.round(h)) : h.toFixed(1);
}

function plural(n: number, one: string, many: string): string {
  return `${count(n)} ${n === 1 ? one : many}`;
}

// --- the scope the repositories count in ------------------------------------

/** The checkouts the range's counts and unit costs are read over, and
 * what they cost: the projects whose root is a git checkout, each with
 * the rollup's bucket at its root. `label` names the scope the way the
 * frame does: the project itself when one checkout is counted, else
 * `2 repositories`; null with no checkout. */
export type Scope = { label: string | null; spendUSD: number; checkouts: ProjectYield[] };

export function scopeOf(report: UsageDaily, yieldReport: YieldReport | null | undefined): Scope {
  const checkouts = yieldReport?.ok ? yieldReport.projects.filter((p) => p.yield.checkout) : [];
  const spendUSD = checkouts.reduce((sum, p) => sum + (projectUsage(report, p.root)?.costUSD ?? 0), 0);
  const label = checkouts.length === 0 ? null : checkouts.length === 1 ? checkouts[0].name : `${checkouts.length} repositories`;
  return { label, spendUSD, checkouts };
}

// --- USAGE -------------------------------------------------------------------

/** The headline row of the `USAGE` panel: the amount at the headline size,
 * the facts beside it in the muted grey (`4.43B tokens`, `20.9 h model
 * time`), and the span the phone prints in their place (`30 days`).
 * `title` is what the amount is, for its tooltip. */
export type UsageHead = { amount: string; facts: string[]; span: string; title: string };

/** The amount is the range's dollars in cost mode and its tokens in
 * tokens mode; the facts are the other of the two and the model hours,
 * which are left out when the daemon sends none. Null without a rollup. */
export function usageHead(report: UsageDaily | null | undefined, choice: UsageChoice): UsageHead | null {
  if (!report || !report.ok) return null;
  const totals = report.totals;
  const cost = dollars(totals?.costUSD ?? 0);
  const tokens = `${tokenCount(totals ? totalTokens(totals.tokens) : 0)} tokens`;
  const apiMs = totals?.apiMs ?? 0;
  const facts = [choice.mode === "cost" ? tokens : cost];
  if (apiMs > 0) facts.push(`${hours(apiMs)} h model time`);
  return {
    amount: choice.mode === "cost" ? cost : tokens.replace(/ tokens$/, ""),
    facts,
    span: `${choice.span} days`,
    title: choice.mode === "cost" ? "if billed at full API rate" : "tokens, every kind, input and output and cache",
  };
}

/** The one note under the chart: `$1,446.00 apportioned across midnight`,
 * the part of the total that was split by token share rather than
 * measured (`design-foundation.md`, "The panels"). Null when nothing was
 * apportioned, and in tokens mode, where every token is counted. */
export function apportionedNote(totals: UsageBucket | null | undefined, mode: UsageMode): string | null {
  if (mode !== "cost" || !totals || totals.apportionedUSD <= 0) return null;
  return `${dollars(totals.apportionedUSD)} apportioned across midnight`;
}

// --- VALUE -----------------------------------------------------------------

export type ValueTileKey = "prs" | "lines" | "releases" | "hours";

/** One tile: the count, its noun in the long form the desktop prints and
 * the short one the phone prints, and what one unit cost. `count` and
 * `rate` are `DASH` when the range has no source for them. */
export type ValueTile = { key: ValueTileKey; count: string; noun: string; shortNoun: string; rate: string; title: string };

/** The four tiles and the note under them, in its long form (`kitterm, 30
 * days. Proxies for value, not value.`) and its short one (`kitterm, 30
 * days`). */
export type ValuePanel = { tiles: ValueTile[]; note: string; shortNote: string; command?: string };

/** The note when no project is registered, and the command that fills
 * the panel (round 20, the frame `Dashboard 1200 · first run`). */
export const VALUE_REGISTER_NOTE = "Register a repository to count what it shipped:";
export const VALUE_REGISTER_COMMAND = "kitterm project add <path>";
export const WHERE_REGISTER_NOTE = "Spend groups by project once one is registered; goals and tasks follow docs/goals/:";
export const WHERE_REGISTER_COMMAND = "kitterm project init <path>";

/** Is no project registered: the yield answered and lists no project
 * (`GET /api/projects` is empty) or counts no checkout among them. A
 * yield not yet read decides nothing. */
export function noProjectRegistered(yieldReport: YieldReport | null | undefined): boolean {
  if (!yieldReport?.ok) return false;
  return yieldReport.projects.length === 0 || yieldReport.totals.checkouts === 0;
}

/** The caveat the note ends with. */
export const VALUE_NOTE = "Proxies for value, not value.";

/**
 * The four tiles, or null when the page has no rollup to price anything
 * with. The three repository counts come from `GET /api/yield`, summed
 * over the projects whose root is a checkout with a remote; a fleet with
 * none prints a dash. The hours are the bills' API duration over the
 * range, from the same rollup as the spend.
 *
 * A repository's unit cost divides the spend of the checkouts counted, the
 * rollup's bucket at each counted root summed, by the count: the number
 * `corpus/valuemaxxing.md` reports ($11.77 a PR is kitterm's own spend
 * over kitterm's own pull requests), and not the fleet's spend, which
 * holds sessions in directories with no history. The note names the
 * scope and the span. The hour's cost divides only the dollars of the
 * sessions the hours belong to (`measuredUSD`), so a record read before
 * the rollup kept its duration prices no hour, and prints in whole
 * dollars, `$47 an hour`, as the frame draws it.
 */
export function valuePanel(report: UsageDaily | null | undefined, yieldReport: YieldReport | null | undefined, span: UsageSpan): ValuePanel | null {
  if (!report || !report.ok) return null;
  const counted = yieldReport?.ok ? yieldReport.totals : null;
  const scope = scopeOf(report, yieldReport);
  const tile = (key: ValueTileKey, n: number | null, noun: string, shortNoun: string, rate: (usd: number) => string, source: string, base = scope.spendUSD): ValueTile => ({
    key,
    count: n === null ? DASH : count(n),
    noun,
    shortNoun,
    rate: n !== null && n > 0 && base > 0 ? rate(base / n) : DASH,
    title: source,
  });
  const each = (usd: number): string => `${unitCost(usd)} each`;
  const repos = counted && counted.counted > 0 ? counted : null;
  const apiMs = report.totals?.apiMs ?? 0;
  const tiles = [
    tile("prs", repos ? repos.mergedPullRequests : null, "merged pull requests", "merged PRs", each,
      "First-parent commits on the remote's branch in the range whose subject ends in (#N) or starts with Merge pull request, over every registered or discovered checkout with a remote. The unit cost is the range's spend over the count."),
    tile("lines", repos ? repos.mergedLines : null, "merged lines added", "merged lines", each,
      "The insertions of those merged commits, against the first parent."),
    tile("releases", counted && counted.checkouts > 0 ? counted.releases : null, "releases", "releases", each,
      "Tags created in the range, over every checkout."),
    tile("hours", apiMs > 0 ? apiMs / 3_600_000 : null, "hours of model time", "model hours", (usd) => `${wholeDollars(usd)} an hour`,
      "The bills' API duration over the range, each session's share by the day's token share. The unit cost divides the dollars of the sessions that carry a duration.",
      report.totals?.measuredUSD ?? 0),
  ].map((t) => (t.key === "hours" && t.count !== DASH ? { ...t, count: hours(apiMs) } : t));
  if (noProjectRegistered(yieldReport)) {
    // The first run: the three repository tiles have no source, and the
    // note names the command that gives them one.
    return { tiles, note: VALUE_REGISTER_NOTE, shortNote: VALUE_REGISTER_NOTE, command: VALUE_REGISTER_COMMAND };
  }
  const shortNote = [scope.label, `${span} days`].filter((part): part is string => part !== null).join(", ");
  return { tiles, note: `${shortNote}. ${VALUE_NOTE}`, shortNote };
}

// --- WHERE -----------------------------------------------------------------

export type WhereGrouping = "project" | "goal" | "task" | "role";
export const WHERE_GROUPINGS: readonly WhereGrouping[] = ["project", "goal", "task", "role"];
export const WHERE_DEFAULT: WhereGrouping = "goal";

/** The grouping read back from storage; the default for anything else. */
export function readWhereGrouping(raw: string | null | undefined): WhereGrouping {
  return WHERE_GROUPINGS.find((g) => g === raw) ?? WHERE_DEFAULT;
}

/** One row: a name, a bar, then four columns — the spend, a count (`10
 * goals`, `6 tasks`; a task's working time, `45m`, `1h 2m`; a role's
 * share of the range and the remainder's, `86%`, the same arithmetic), the pull requests (`83 PRs`,
 * `4 PRs`, `PR #124`; a role's API hours, `34.0 h`), and a unit cost
 * (`$11.17/PR`, `$0.018/line`, `$61/API hour`: the noun after a slash, no
 * article), each as the Components frame draws `WHERE` at that filter. `fill` is the
 * bar's share of the panel's longest, 0 to 1. `remainder` marks the
 * unattributed row, whose name, bar and spend wear the amber and whose
 * bar is the longest at the goal grouping. A column with no source is
 * `DASH`. */
export type WhereRow = {
  key: string;
  name: string;
  remainder: boolean;
  fill: number;
  spend: string;
  count: string;
  units: string;
  /** The link of a task row's one `PR #N`, when its project has a
   * `pullRequestBase` (round 15); absent, and the text is plain. */
  unitsHref?: string;
  rate: string;
  title: string;
};

export type WhereToggle = { label: WhereGrouping; checked: boolean; name: string };

export type WherePanel = {
  grouping: WhereGrouping;
  rows: WhereRow[];
  note: string;
  /** The command the note ends with, in the text colour: only on the
   * first run, when no project is registered. */
  command?: string;
  toggles: WhereToggle[];
  /** The line at the selector's right: what the counted checkouts cost
   * and delivered, `$976.74 in kitterm · 83 merged PRs · 58,853 lines ·
   * 24 releases`; null without a yield answer. */
  summary: string | null;
};

/** What the panel groups over. `goals` is every goal summary the page
 * holds, each with its project; `range` is the days the rollup answered. */
export type WhereInput = {
  report: UsageDaily | null | undefined;
  yield: YieldReport | null | undefined;
  projects: readonly ProjectSummary[];
  goals: readonly { project: ProjectRef; summary: KnowledgeSummary }[];
  range: DayRange;
};

/** A row before it is formatted: the numbers, or null for no source. */
type Raw = {
  key: string;
  name: string;
  spendUSD: number | null;
  /** The count column, already worded; null for no source. */
  count: string | null;
  /** The pull requests column, already worded; null for no source. */
  units: string | null;
  /** The link of the one pull request the column names, when known. */
  unitsHref?: string;
  /** The unit the rate divides the spend by — the pull requests merged,
   * the lines merged, an API hour — as `/PR`, `/line`, `/API hour`, and
   * whether the rate prints whole dollars (an API hour does, as the frame
   * draws `$61/API hour`); null for no source. */
  per: { n: number; unit: "/PR" | "/line" | "/API hour" } | null;
  title: string;
  remainder?: boolean;
  /** The folded dash row, which sorts after the named rows. */
  folded?: boolean;
};

/** The rounds of a goal that started inside the range: the one filter
 * every figure read from a round record goes through (`sessions-model`). */
export { roundsInRange };

const nameOf = (project: ProjectRef, summary: KnowledgeSummary): string => summary.slug ?? summary.goal ?? project.name;

/** The lines the pull requests `numbers` added in `project`'s history, or
 * null when the yield names no lines for one of them: a daemon before
 * round 10, a pull request merged outside the range, or none at all. */
export function linesOf(yieldReport: YieldReport | null | undefined, projectId: string, numbers: readonly number[]): number | null {
  if (!yieldReport?.ok || numbers.length === 0) return null;
  const list = yieldReport.projects.find((p) => p.id === projectId)?.yield.pullRequests;
  if (!list) return null;
  let sum = 0;
  for (const n of numbers) {
    const pr = list.find((p) => p.number === n);
    if (!pr) return null;
    sum += pr.lines;
  }
  return sum;
}

function format(raw: Raw, max: number): WhereRow {
  const spend = raw.spendUSD;
  let rate = DASH;
  if (spend !== null && spend > 0 && raw.per && raw.per.n > 0) {
    const each = spend / raw.per.n;
    rate = `${raw.per.unit === "/API hour" ? wholeDollars(each) : unitCost(each)}${raw.per.unit}`;
  }
  return {
    key: raw.key,
    name: raw.name,
    remainder: raw.remainder === true,
    fill: spend !== null && max > 0 ? Math.max(0, Math.min(1, spend / max)) : 0,
    spend: spend === null ? DASH : dollars(spend),
    count: raw.count ?? DASH,
    units: raw.units ?? DASH,
    ...(raw.unitsHref === undefined ? {} : { unitsHref: raw.unitsHref }),
    rate,
    title: raw.title,
  };
}

/** Sort: the rows with a spend, dearest first; then the rows without, by
 * name; then the folded row; the remainder last. */
function order(rows: Raw[]): Raw[] {
  const rank = (r: Raw): number => (r.remainder ? 2 : r.folded ? 1 : 0);
  return [...rows].sort((a, b) => {
    if (rank(a) !== rank(b)) return rank(a) - rank(b);
    const sa = a.spendUSD ?? -1;
    const sb = b.spendUSD ?? -1;
    if (sa !== sb) return sb - sa;
    return a.name.localeCompare(b.name);
  });
}

/**
 * The panel at `grouping`, or null when the page has no rollup. Each
 * grouping is a level the tree already has (`design-foundation.md`, "The
 * VALUE panel groups by the same levels as the tree"):
 *
 * - **project**: one row per project the daemon lists; its spend is the
 *   rollup's bucket at its root, its count the goals the knowledge route
 *   lists for it (`10 goals`; none is a dash, and the sessions sit in the
 *   tooltip), its pull requests and lines its history's. The dollars the
 *   rollup keys on no listed project are the `no project` remainder.
 * - **goal**: one row per goal folder; its spend is the sum of the `Cost:`
 *   lines of its rounds that started in the range, its tasks those
 *   rounds, its pull requests the ones those records name, and its lines
 *   theirs (`linesOf`). The dollars no round record claims are the `no
 *   round record` remainder: at this grouping the largest bar, which is
 *   the finding the panel exists to show.
 * - **task**: one row per task named by the round records started in the
 *   range (a record with no task is its own row, `round N`); the sum of
 *   its rounds' `Cost:` lines, its working time (the rounds' wall time
 *   from their `Cost:` lines summed, `45m`, `1h 2m`, as `countdown`
 *   prints it; a dash when no round carries one), the pull request its
 *   `Result:` names (`PR #122`, or `2 PRs` when its rounds name two), and
 *   those pull requests' lines.
 * - **role**: `root` and `crew`, from the rollup's split by the
 *   transcript's directory, with the role's share of the range's spend
 *   (`86%`, the remainder's arithmetic), its API hours (`34.0 h`) and
 *   dollars an API hour.
 *
 * The goal grouping lists every goal (round 13, the human's word): a goal
 * with neither a spend nor a pull request in the range is a dash row of
 * its own, after the priced rows and before the remainder. At the task
 * grouping the rounds with neither fold into one dash row that says how
 * many there are, so a fleet with fifty rounds does not print fifty
 * dashes. The remainder's count column is its share of the range, `85%`.
 */
export function wherePanel(grouping: WhereGrouping, input: WhereInput): WherePanel | null {
  const { report } = input;
  if (!report || !report.ok) return null;
  const total = report.totals?.costUSD ?? 0;
  const empty = (report.totals?.sessions ?? 0) === 0;
  let raws: Raw[] = [];
  let note = "";
  const share = (rest: number): string | null => (total > 0 ? `${Math.round((rest / total) * 100)}%` : null);
  /** The link of pull request `n` in a project, or null off GitHub. */
  const linkOf = (projectId: string, n: number): string | null =>
    pullRequestHref(input.projects.find((p) => p.id === projectId)?.pullRequestBase, n);

  if (grouping === "project") {
    let attributed = 0;
    for (const p of input.projects) {
      const bucket = projectUsage(report, p.root);
      const y = input.yield?.ok ? (input.yield.projects.find((e) => e.id === p.id)?.yield ?? null) : null;
      const prs = typeof y?.mergedPullRequests === "number" ? y.mergedPullRequests : null;
      const goalCount = input.goals.filter((g) => g.project.id === p.id).length;
      if (bucket) attributed += bucket.costUSD;
      raws.push({
        key: `project:${p.id}`,
        name: p.name,
        spendUSD: bucket ? bucket.costUSD : null,
        // The goals the knowledge route lists for the project; `0 goals`
        // is no source, so it prints a dash.
        count: goalCount > 0 ? plural(goalCount, "goal", "goals") : null,
        // A remote with no merged pull request is a dash, never `0 PRs`.
        units: prs === null || prs === 0 ? null : plural(prs, "PR", "PRs"),
        // What one merged pull request cost here, `$11.17/PR`.
        per: prs !== null && prs > 0 ? { n: prs, unit: "/PR" } : null,
        title: [
          bucket ? `${p.name}: ${plural(bucket.sessions, "session", "sessions")} in the range` : `${p.name}: no session in the range`,
          !y ? "no yield read yet" : !y.checkout ? `${p.root} is not a git checkout, so nothing is counted` : !y.remote ? "no remote, so no pull request to count" : `merged on ${y.branch ?? "HEAD"}, ${count(y.mergedLines ?? 0)} lines, ${count(y.releases ?? 0)} releases`,
        ].join("; "),
      });
    }
    const rest = total - attributed;
    if (rest > 0.005) {
      raws.push({ key: "remainder", name: "no project", spendUSD: rest, count: share(rest), units: null, per: null, remainder: true, title: "Spend the rollup keys on a directory no listed project holds." });
    }
    note = empty ? "No usage recorded in the range" : "What each repository cost and shipped";
  } else if (grouping === "goal" || grouping === "task") {
    let attributed = 0;
    const folded: string[] = [];
    for (const { project, summary } of input.goals) {
      const rounds = roundsInRange(summary, input.range);
      if (grouping === "goal") {
        const priced = rounds.filter((r) => typeof r.costUSD === "number");
        const spend = priced.length > 0 ? priced.reduce((sum, r) => sum + (r.costUSD ?? 0), 0) : null;
        const prs = [...new Set(rounds.flatMap((r) => (typeof r.pr === "number" ? [r.pr] : [])))];
        const name = nameOf(project, summary);
        attributed += spend ?? 0;
        const lines = linesOf(input.yield, project.id, prs);
        raws.push({
          key: `goal:${project.id}:${name}`,
          name,
          spendUSD: spend,
          count: rounds.length > 0 ? plural(rounds.length, "task", "tasks") : null,
          units: prs.length === 0 ? null : plural(prs.length, "PR", "PRs"),
          per: lines !== null && lines > 0 ? { n: lines, unit: "/line" } : null,
          title: `${name} in ${project.name}: ${plural(rounds.length, "round", "rounds")} started in the range, ${priced.length} with a Cost line${lines !== null ? `, ${count(lines)} lines merged` : ""}`,
        });
      } else {
        // A task is the rounds that name it; a record with no task name
        // stands alone as `round N`.
        const tasks = new Map<string, RoundRecord[]>();
        for (const r of rounds) {
          const name = r.task ?? `round ${r.number}`;
          tasks.set(name, [...(tasks.get(name) ?? []), r]);
        }
        for (const [name, own] of tasks) {
          const priced = own.filter((r) => typeof r.costUSD === "number");
          const spend = priced.length > 0 ? priced.reduce((sum, r) => sum + (r.costUSD ?? 0), 0) : null;
          const prs = [...new Set(own.flatMap((r) => (typeof r.pr === "number" ? [r.pr] : [])))];
          if (spend === null && prs.length === 0) {
            folded.push(...own.map(() => name));
            continue;
          }
          attributed += spend ?? 0;
          const lines = linesOf(input.yield, project.id, prs);
          // The task's working time: its rounds' wall time summed, from
          // the records that carry one; none is a dash.
          const timed = own.filter((r) => typeof r.durationMs === "number" && r.durationMs > 0);
          const durationMs = timed.reduce((sum, r) => sum + (r.durationMs ?? 0), 0);
          raws.push({
            key: `task:${project.id}:${summary.slug ?? ""}:${name}`,
            name,
            spendUSD: spend,
            count: timed.length > 0 ? countdown(durationMs) : null,
            units: prs.length === 0 ? null : prs.length === 1 ? `PR #${prs[0]}` : plural(prs.length, "PR", "PRs"),
            ...(prs.length === 1 && linkOf(project.id, prs[0]) !== null ? { unitsHref: linkOf(project.id, prs[0])! } : {}),
            per: lines !== null && lines > 0 ? { n: lines, unit: "/line" } : null,
            title: `${own.map((r) => `round ${r.number}`).join(", ")} of ${nameOf(project, summary)} in ${project.name}, started ${own.map((r) => r.started ?? "on no recorded day").join(", ")}`,
          });
        }
      }
    }
    if (folded.length > 0) {
      raws.push({
        key: "folded",
        name: `${plural(folded.length, "more round", "more rounds")}`,
        spendUSD: null,
        count: null,
        units: null,
        per: null,
        folded: true,
        title: `Rounds with no Cost line and no pull request in the range: ${[...new Set(folded)].join(", ")}`,
      });
    }
    const rest = total - attributed;
    if (rest > 0.005) {
      raws.push({ key: "remainder", name: "no round record", spendUSD: rest, count: share(rest), units: null, per: null, remainder: true, title: "Spend that no round record's Cost line claims: root sessions, and rounds recorded before the line existed." });
    }
    if (empty) note = "No usage recorded in the range";
    else if (rest > 0.005 && total > 0) note = `${Math.round((rest / total) * 100)}% names no round, so it cannot be valued`;
    else note = grouping === "goal" ? "A goal's spend sums the Cost line of its round records" : "One task is one round, and usually one pull request";
  } else {
    const roles = report.roles ?? [];
    const rates: Partial<Record<"root" | "crew", number>> = {};
    for (const role of roles) {
      const h = role.apiMs / 3_600_000;
      if (h > 0 && role.measuredUSD > 0) rates[role.role] = role.measuredUSD / h;
      raws.push({
        key: `role:${role.role}`,
        name: role.role === "crew" ? "crew, worktree" : "root session",
        spendUSD: role.sessions > 0 ? role.costUSD : null,
        // The role's share of the range, `86%`: the remainder's arithmetic.
        count: role.sessions > 0 ? share(role.costUSD) : null,
        units: h > 0 ? `${hours(role.apiMs)} h` : null,
        // The rate divides the measured dollars, not the whole spend.
        per: h > 0 && role.measuredUSD > 0 ? { n: h * (role.costUSD / role.measuredUSD), unit: "/API hour" } : null,
        title: `${plural(role.sessions, "session", "sessions")}, ${count(role.linesAdded)} lines added; the role is the transcript's directory, a crew being one under .claude/worktrees`,
      });
    }
    if (roles.length === 0) note = "This daemon sends no role split";
    else if (empty) note = "No usage recorded in the range";
    else if (rates.root && rates.crew) {
      const pct = Math.round((1 - rates.crew / rates.root) * 100);
      note = pct > 0 ? `A crew is ${pct}% cheaper an API hour` : pct < 0 ? `A crew is ${-pct}% dearer an API hour` : "A crew and a root session cost the same an API hour";
    } else note = "A crew starts with a context sized to one item";
  }

  raws = order(raws);
  const max = Math.max(0, ...raws.map((r) => r.spendUSD ?? 0));
  // The first run: no project is registered, so the rows are the one
  // remainder and the note names the command that starts a grouping
  // (round 20). The role split needs no project and keeps its note.
  const firstRun = grouping !== "role" && (input.projects.length === 0 || noProjectRegistered(input.yield));
  return {
    grouping,
    summary: whereSummary(report, input.yield),
    rows: raws.map((r) => format(r, max)),
    note: firstRun ? WHERE_REGISTER_NOTE : note,
    ...(firstRun ? { command: WHERE_REGISTER_COMMAND } : {}),
    toggles: WHERE_GROUPINGS.map((g) => ({ label: g, checked: g === grouping, name: `Group by ${g}` })),
  };
}

/** `$976.74 in kitterm · 83 merged PRs · 58,853 lines · 24 releases`: what
 * the counted checkouts cost and delivered; null without a yield answer
 * or a checkout. */
export function whereSummary(report: UsageDaily, yieldReport: YieldReport | null | undefined): string | null {
  const scope = scopeOf(report, yieldReport);
  if (!yieldReport?.ok || scope.label === null) return null;
  const t = yieldReport.totals;
  return `${dollars(scope.spendUSD)} in ${scope.label} · ${plural(t.mergedPullRequests, "merged PR", "merged PRs")} · ${plural(t.mergedLines, "line", "lines")} · ${plural(t.releases, "release", "releases")}`;
}

// --- MODELS ----------------------------------------------------------------

/** One row: the name, the bar, the spend to the cent, the spend in whole
 * dollars for a phone (`$1,283`), and the session count. */
export type ModelRow = { key: string; name: string; fill: number; spend: string; short: string; sessions: string; title: string };

export type ModelsPanel = {
  rows: ModelRow[];
  note: string | null;
};

/** How many models the panel names. The rest sum into one row, `Others`,
 * unless the rest is one model: a summary of one hides a name for the
 * height of the row it replaces, so exactly four models print four
 * rows. */
export const MODELS_NAMED = 3;

/**
 * The top `MODELS_NAMED` models by cost over the range, from the split
 * `GET /api/usage/daily` answers (`models`), then one summed row for the
 * rest, always last: the name, a bar, the spend and the session count on
 * every row. The summed row's spend is the range's split total less the
 * named rows, its session count the sum of its models' counts, and its
 * title is the only place that names them: the row reads `Others`,
 * because a count of models a reader cannot name is not a fact they can
 * act on (round 9), and it sits after the top three whatever its sum
 * (the human's word, round 10: "top 3 by cost, sum the others as one row
 * more"). Every bar is scaled to the longest row, the summed row
 * included, so a tail that sums past the leader is the longest bar and
 * still the last row. Null when the page has no rollup, the daemon
 * sends no split, or no model appears: a model with no reading prints
 * nothing rather than a guess. The note names the dollars of records
 * read before the rollup kept the map, which are in the total and in no
 * row, when there are any.
 */
export function modelsPanel(report: UsageDaily | null | undefined): ModelsPanel | null {
  if (!report || !report.ok || !report.models || report.models.length === 0) return null;
  const byCost = [...report.models].sort((a, b) => b.costUSD - a.costUSD);
  const unsplit = report.totals?.unsplitUSD ?? 0;
  const named = byCost.length > MODELS_NAMED + 1 ? byCost.slice(0, MODELS_NAMED) : byCost;
  const rest = byCost.slice(named.length);
  const raws = named.map((m) => ({
    key: m.model,
    name: m.name,
    costUSD: m.costUSD,
    sessions: m.sessions,
    title: `${m.model}: ${dollars(m.costUSD)} over ${plural(m.sessions, "session", "sessions")}`,
  }));
  if (rest.length > 0) {
    const costUSD = rest.reduce((sum, m) => sum + m.costUSD, 0);
    const sessions = rest.reduce((sum, m) => sum + m.sessions, 0);
    raws.push({
      key: "more",
      name: "Others",
      costUSD,
      sessions,
      title: `${dollars(costUSD)} over ${plural(sessions, "session", "sessions")}: ${rest.map((m) => `${m.name} ${dollars(m.costUSD)}`).join(", ")}`,
    });
  }
  const max = Math.max(0, ...raws.map((r) => r.costUSD));
  return {
    rows: raws.map((r) => ({
      key: r.key,
      name: r.name,
      fill: max > 0 ? Math.max(0, Math.min(1, r.costUSD / max)) : 0,
      spend: dollars(r.costUSD),
      short: wholeDollars(r.costUSD),
      sessions: plural(r.sessions, "session", "sessions"),
      title: r.title,
    })),
    note: unsplit > 0.005 ? `${dollars(unsplit)} is from records read before the rollup kept the per-model map, in the total and in no row` : null,
  };
}

// --- LEAKS -----------------------------------------------------------------

export type LeakKey = "unpriced" | "rest";

/** One marked line. The first wears `?` in the amber when rounds carry no
 * `Cost:` line and the faint `·` when none does; the second, the
 * corrections and the cache exceptions joined with ` · `, always wears the
 * faint `·`. */
export type LeakLine = { key: LeakKey; mark: "attention" | "pending"; text: string; title: string };

/**
 * The leaks `corpus/valuemaxxing.md` names, on two lines as the frame
 * draws them: `37 of 51 rounds carry no Cost line`, then `3 corrections
 * in 51 rounds · 3 sessions under 95% cached, $33.54`. The round counts
 * take the round records that started in the range (round 13: the same
 * `roundsInRange` the `WHERE` panel and the tree read; before it, every
 * record the page held). The cache exceptions are the rollup's own list
 * over the range, sessions over $5, the floor the research measured
 * with. A fact whose source the page does not have is left out rather
 * than printed as a zero; a line with no fact is left out whole.
 */
export function leakLines(
  report: UsageDaily | null | undefined,
  goals: readonly { summary: KnowledgeSummary }[],
  range: DayRange,
): LeakLine[] {
  const lines: LeakLine[] = [];
  const rounds = goals.flatMap(({ summary }) => roundsInRange(summary, range));
  const rest: string[] = [];
  const titles: string[] = [];
  if (rounds.length > 0) {
    const unpriced = rounds.filter((r) => typeof r.costUSD !== "number").length;
    lines.push({
      key: "unpriced",
      mark: unpriced > 0 ? "attention" : "pending",
      text: `${count(unpriced)} of ${plural(rounds.length, "round carries", "rounds carry")} no Cost line`,
      title: "A round with no Cost line prices at nothing: its spend sits in the no-round-record remainder. LOOP.md writes the line at collect.",
    });
    const corrections = rounds.filter((r) => r.correction).length;
    rest.push(`${plural(corrections, "correction", "corrections")} in ${plural(rounds.length, "round", "rounds")}`);
    titles.push("Corrections: records that carry a Correction section. The record template has no field for one, so this counts the records that wrote the heading.");
  }
  if (report?.ok && report.lowCache) {
    const low = report.lowCache;
    const sum = low.reduce((s, l) => s + l.costUSD, 0);
    rest.push(low.length > 0 ? `${plural(low.length, "session", "sessions")} under 95% cached, ${dollars(sum)}` : "no session under 95% cached");
    titles.push(low.length > 0
      ? `Under 95% cached, over $5: ${low.map((l) => `${l.project}: ${dollars(l.costUSD)} at ${Math.round(l.cacheShare * 100)}%`).join("; ")}`
      : "Every billed session over $5 in the range read 95% or more of its input from cache.");
  }
  if (rest.length > 0) lines.push({ key: "rest", mark: "pending", text: rest.join(" · "), title: titles.join(" ") });
  return lines;
}
