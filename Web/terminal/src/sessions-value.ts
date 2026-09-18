/**
 * What the spend bought (`agent-dashboard`, capability 7): the pure model
 * behind the `VALUE`, `WHERE`, `MODELS` and `LEAKS` panels. No DOM, no
 * clock; `sessions.ts` paints what these return. The numbers and the
 * refusals come from `corpus/valuemaxxing.md`: a merged line and a merged
 * pull request are proxies for value, a row with no source prints a dash
 * and never a zero, the unattributed remainder is a row and not a
 * footnote, and nothing here knows or invents what an hour of the human's
 * time is worth. No quality rate and no rework rate either: every round
 * on record says `done`, and two fix commits are noise.
 */

import {
  dollars,
  projectUsage,
  type KnowledgeSummary,
  type ProjectRef,
  type ProjectSummary,
  type RoundRecord,
  type UsageDaily,
} from "./sessions-model";

/** What a row prints for a value it has no source for. Never `0`. */
export const DASH = "–";

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

// --- VALUE -----------------------------------------------------------------

export type ValueTileKey = "prs" | "lines" | "releases" | "hours";

/** One tile: the count, its noun, and what one unit cost. `count` and
 * `rate` are `DASH` when the range has no source for them. */
export type ValueTile = { key: ValueTileKey; count: string; noun: string; rate: string; title: string };

export type ValuePanel = { tiles: ValueTile[]; note: string };

/** The first sentence of the note under the tiles. */
export const VALUE_NOTE = "A merged line and a merged PR are proxies for value, not value.";

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
 * holds sessions in directories with no history. The note says which. The
 * hour's cost divides only the dollars of the sessions the hours belong
 * to (`measuredUSD`), so a record read before the rollup kept its
 * duration prices no hour.
 */
export function valuePanel(report: UsageDaily | null | undefined, yieldReport: YieldReport | null | undefined): ValuePanel | null {
  if (!report || !report.ok) return null;
  const counted = yieldReport?.ok ? yieldReport.totals : null;
  const checkouts = yieldReport?.ok ? yieldReport.projects.filter((p) => p.yield.checkout) : [];
  const spend = checkouts.reduce((sum, p) => sum + (projectUsage(report, p.root)?.costUSD ?? 0), 0);
  const tile = (key: ValueTileKey, n: number | null, noun: string, unit: string, source: string, base = spend): ValueTile => ({
    key,
    count: n === null ? DASH : count(n),
    noun,
    rate: n !== null && n > 0 && base > 0 ? `${unitCost(base / n)} ${unit}` : DASH,
    title: source,
  });
  const repos = counted && counted.counted > 0 ? counted : null;
  const apiMs = report.totals?.apiMs ?? 0;
  return {
    tiles: [
      tile("prs", repos ? repos.mergedPullRequests : null, "merged PRs", "a PR",
        "First-parent commits on the remote's branch in the range whose subject ends in (#N) or starts with Merge pull request, over every registered or discovered checkout with a remote. The unit cost is the range's spend over the count."),
      tile("lines", repos ? repos.mergedLines : null, "merged lines", "a line",
        "The insertions of those merged commits, against the first parent."),
      tile("releases", counted && counted.checkouts > 0 ? counted.releases : null, "releases", "a release",
        "Tags created in the range, over every checkout."),
      tile("hours", apiMs > 0 ? apiMs / 3_600_000 : null, "model hours", "an hour",
        "The bills' API duration over the range, each session's share by the day's token share. The unit cost divides the dollars of the sessions that carry a duration.",
        report.totals?.measuredUSD ?? 0),
    ].map((t) => (t.key === "hours" && t.count !== DASH ? { ...t, count: hours(apiMs) } : t)),
    note: checkouts.length > 0
      ? `${VALUE_NOTE} A unit cost divides the ${dollars(spend)} spent in ${plural(checkouts.length, "repository", "repositories")} counted; the hour divides the fleet's.`
      : VALUE_NOTE,
  };
}

// --- WHERE -----------------------------------------------------------------

export type WhereGrouping = "project" | "goal" | "task" | "role";
export const WHERE_GROUPINGS: readonly WhereGrouping[] = ["project", "goal", "task", "role"];
export const WHERE_DEFAULT: WhereGrouping = "goal";

/** The grouping read back from storage; the default for anything else. */
export function readWhereGrouping(raw: string | null | undefined): WhereGrouping {
  return WHERE_GROUPINGS.find((g) => g === raw) ?? WHERE_DEFAULT;
}

/** One row: a name, a bar, a spend, a unit count and a unit cost. `fill`
 * is the bar's share of the panel's longest, 0 to 1. `remainder` marks
 * the unattributed row, which wears the amber mark and is the longest bar
 * at the goal grouping. `spend`, `units` and `rate` are `DASH` when the
 * row has no source for them. */
export type WhereRow = {
  key: string;
  name: string;
  remainder: boolean;
  fill: number;
  spend: string;
  units: string;
  rate: string;
  title: string;
};

export type WhereToggle = { label: WhereGrouping; checked: boolean; name: string };

export type WherePanel = {
  grouping: WhereGrouping;
  rows: WhereRow[];
  note: string;
  toggles: WhereToggle[];
  /** The one line the panel folds to on a phone: `where the dollar goes ·
   * 91% unattributed`. */
  summary: string;
};

/** What the panel groups over. `goals` is every goal summary the page
 * holds, each with its project; `range` is the days the rollup answered. */
export type WhereInput = {
  report: UsageDaily | null | undefined;
  yield: YieldReport | null | undefined;
  projects: readonly ProjectSummary[];
  goals: readonly { project: ProjectRef; summary: KnowledgeSummary }[];
  range: { from: string; to: string };
};

/** A row before it is formatted: the numbers, or null for no source. */
type Raw = {
  key: string;
  name: string;
  spendUSD: number | null;
  /** The unit count, and the word for it; null for no source. */
  units: { n: number; label: string } | null;
  /** A rate computed by the caller, when it is not the spend per unit:
   * dollars an hour of a round, dollars an API hour of a role. */
  rate: { usd: number; unit: string } | null;
  title: string;
  remainder?: boolean;
  /** The folded dash row, which sorts after the named rows. */
  folded?: boolean;
};

/** The rounds of a goal that started inside the range. A record with no
 * start day cannot be placed and is left out, which is never a guess. */
export function roundsInRange(summary: KnowledgeSummary, range: { from: string; to: string }): RoundRecord[] {
  return (summary.rounds ?? []).filter((r) => typeof r.started === "string" && r.started >= range.from && r.started <= range.to);
}

const nameOf = (project: ProjectRef, summary: KnowledgeSummary): string => summary.slug ?? summary.goal ?? project.name;

function format(raw: Raw, max: number): WhereRow {
  const spend = raw.spendUSD;
  const units = raw.units;
  let rate = DASH;
  if (raw.rate && raw.rate.usd > 0) rate = `${unitCost(raw.rate.usd)} ${raw.rate.unit}`;
  else if (spend !== null && spend > 0 && units && units.n > 0) rate = `${unitCost(spend / units.n)} a ${units.label}`;
  return {
    key: raw.key,
    name: raw.name,
    remainder: raw.remainder === true,
    fill: spend !== null && max > 0 ? Math.max(0, Math.min(1, spend / max)) : 0,
    spend: spend === null ? DASH : dollars(spend),
    units: units === null ? DASH : units.label === "PR #" ? `PR #${units.n}` : plural(units.n, units.label, `${units.label}s`),
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
 *   rollup's bucket at its root, its units the merged pull requests of its
 *   history. The dollars the rollup keys on no listed project are the
 *   `no project` remainder.
 * - **goal**: one row per goal folder; its spend is the sum of the `Cost:`
 *   lines of its rounds that started in the range, its units the pull
 *   requests those records name. The dollars no round record claims are
 *   the `no round record` remainder: at this grouping the largest bar,
 *   which is the finding the panel exists to show.
 * - **task**: one row per round record started in the range; its own
 *   `Cost:` line, the pull request its `Result:` names, and its dollars an
 *   hour of the round's wall time.
 * - **role**: `root` and `crew`, from the rollup's split by the
 *   transcript's directory, with API hours and dollars an API hour.
 *
 * At the goal and task groupings the rows with neither a spend nor a pull
 * request fold into one dash row that says how many there are, so a
 * fleet with fifty rounds does not print fifty dashes.
 */
export function wherePanel(grouping: WhereGrouping, input: WhereInput): WherePanel | null {
  const { report } = input;
  if (!report || !report.ok) return null;
  const total = report.totals?.costUSD ?? 0;
  const empty = (report.totals?.sessions ?? 0) === 0;
  let raws: Raw[] = [];
  let note = "";

  if (grouping === "project") {
    let attributed = 0;
    for (const p of input.projects) {
      const bucket = projectUsage(report, p.root);
      const y = input.yield?.ok ? (input.yield.projects.find((e) => e.id === p.id)?.yield ?? null) : null;
      const prs = typeof y?.mergedPullRequests === "number" ? y.mergedPullRequests : null;
      if (bucket) attributed += bucket.costUSD;
      raws.push({
        key: `project:${p.id}`,
        name: p.name,
        spendUSD: bucket ? bucket.costUSD : null,
        units: prs === null ? null : { n: prs, label: "PR" },
        rate: null,
        title: !y ? `${p.name}: no yield read yet` : !y.checkout ? `${p.name}: ${p.root} is not a git checkout, so nothing is counted` : !y.remote ? `${p.name}: no remote, so no pull request to count` : `${p.name}: merged on ${y.branch ?? "HEAD"}, ${count(y.mergedLines ?? 0)} lines, ${count(y.releases ?? 0)} releases`,
      });
    }
    const rest = total - attributed;
    if (rest > 0.005) {
      raws.push({ key: "remainder", name: "no project", spendUSD: rest, units: null, rate: null, remainder: true, title: "Spend the rollup keys on a directory no listed project holds." });
    }
    note = empty ? "No usage recorded in the range." : "What each repository cost and shipped.";
  } else if (grouping === "goal" || grouping === "task") {
    let attributed = 0;
    const folded: string[] = [];
    for (const { project, summary } of input.goals) {
      const rounds = roundsInRange(summary, input.range);
      if (grouping === "goal") {
        const priced = rounds.filter((r) => typeof r.costUSD === "number");
        const spend = priced.length > 0 ? priced.reduce((sum, r) => sum + (r.costUSD ?? 0), 0) : null;
        const prs = new Set(rounds.flatMap((r) => (typeof r.pr === "number" ? [r.pr] : [])));
        const name = nameOf(project, summary);
        if (spend === null && prs.size === 0) {
          folded.push(name);
          continue;
        }
        attributed += spend ?? 0;
        raws.push({
          key: `goal:${project.id}:${name}`,
          name,
          spendUSD: spend,
          units: prs.size === 0 ? null : { n: prs.size, label: "PR" },
          rate: null,
          title: `${name} in ${project.name}: ${plural(rounds.length, "round", "rounds")} started in the range, ${priced.length} with a Cost line`,
        });
      } else {
        for (const r of rounds) {
          const name = r.task ?? `round ${r.number}`;
          const spend = typeof r.costUSD === "number" ? r.costUSD : null;
          if (spend === null && typeof r.pr !== "number") {
            folded.push(name);
            continue;
          }
          attributed += spend ?? 0;
          raws.push({
            key: `task:${project.id}:${summary.slug ?? ""}:${r.number}`,
            name,
            spendUSD: spend,
            units: typeof r.pr === "number" ? { n: r.pr, label: "PR #" } : null,
            rate: spend !== null && typeof r.durationMs === "number" && r.durationMs > 0 ? { usd: spend / (r.durationMs / 3_600_000), unit: "an hour" } : null,
            title: `round ${r.number} of ${nameOf(project, summary)} in ${project.name}, started ${r.started ?? "on no recorded day"}`,
          });
        }
      }
    }
    if (folded.length > 0) {
      const noun = grouping === "goal" ? "goal" : "round";
      raws.push({
        key: "folded",
        name: `${plural(folded.length, `more ${noun}`, `more ${noun}s`)}`,
        spendUSD: null,
        units: null,
        rate: null,
        folded: true,
        title: `${grouping === "goal" ? "Goals" : "Rounds"} with no Cost line and no pull request in the range: ${folded.join(", ")}`,
      });
    }
    const rest = total - attributed;
    if (rest > 0.005) {
      raws.push({ key: "remainder", name: "no round record", spendUSD: rest, units: null, rate: null, remainder: true, title: "Spend that no round record's Cost line claims: root sessions, and rounds recorded before the line existed." });
    }
    if (empty) note = "No usage recorded in the range.";
    else if (rest > 0.005 && total > 0) note = `${Math.round((rest / total) * 100)}% names no round, so it cannot be valued.`;
    else note = grouping === "goal" ? "A goal's spend sums the Cost line of its round records." : "One task is one round, and usually one pull request.";
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
        units: h > 0 ? { n: h, label: "API h" } : null,
        rate: h > 0 && role.measuredUSD > 0 ? { usd: role.measuredUSD / h, unit: "an API hour" } : null,
        title: `${plural(role.sessions, "session", "sessions")}, ${count(role.linesAdded)} lines added; the role is the transcript's directory, a crew being one under .claude/worktrees`,
      });
    }
    if (roles.length === 0) note = "This daemon sends no role split.";
    else if (empty) note = "No usage recorded in the range.";
    else if (rates.root && rates.crew) {
      const pct = Math.round((1 - rates.crew / rates.root) * 100);
      note = pct > 0 ? `A crew is ${pct}% cheaper an API hour.` : pct < 0 ? `A crew is ${-pct}% dearer an API hour.` : "A crew and a root session cost the same an API hour.";
    } else note = "A crew starts with a context sized to one item.";
  }

  raws = order(raws);
  const max = Math.max(0, ...raws.map((r) => r.spendUSD ?? 0));
  const remainder = raws.find((r) => r.remainder)?.spendUSD ?? 0;
  const summary = remainder > 0 && total > 0
    ? `where the dollar goes · ${Math.round((remainder / total) * 100)}% unattributed`
    : "where the dollar goes";
  return {
    grouping,
    summary,
    rows: raws.map((r) => {
      const row = format(r, max);
      // An API hour is not a count of things: print it as hours.
      if (r.units && r.units.label === "API h") row.units = `${hours(r.units.n * 3_600_000)} API h`;
      return row;
    }),
    note,
    toggles: WHERE_GROUPINGS.map((g) => ({ label: g, checked: g === grouping, name: `Group by ${g}` })),
  };
}

// --- MODELS ----------------------------------------------------------------

export type ModelRow = { key: string; name: string; fill: number; spend: string; sessions: string; title: string };

export type ModelsPanel = {
  rows: ModelRow[];
  note: string | null;
  /** The one line the panel folds to on a phone: `by model · Fable 5.1
   * $1,388.50`, the dearest. */
  summary: string;
};

/**
 * One row per model over the range, dearest first, from the split
 * `GET /api/usage/daily` answers (`models`): the name, a bar scaled to
 * the dearest, the spend and the session count. Null when the page has
 * no rollup, the daemon sends no split, or no model appears: a model
 * with no reading prints nothing rather than a guess. The note names the
 * dollars of records read before the rollup kept the map, which are in
 * the total and in no row, when there are any.
 */
export function modelsPanel(report: UsageDaily | null | undefined): ModelsPanel | null {
  if (!report || !report.ok || !report.models || report.models.length === 0) return null;
  const max = Math.max(0, ...report.models.map((m) => m.costUSD));
  const unsplit = report.totals?.unsplitUSD ?? 0;
  const dearest = report.models[0];
  return {
    summary: `by model · ${dearest.name} ${dollars(dearest.costUSD)}`,
    rows: report.models.map((m) => ({
      key: m.model,
      name: m.name,
      fill: max > 0 ? Math.max(0, Math.min(1, m.costUSD / max)) : 0,
      spend: dollars(m.costUSD),
      sessions: plural(m.sessions, "session", "sessions"),
      title: `${m.model}: ${dollars(m.costUSD)} over ${plural(m.sessions, "session", "sessions")}`,
    })),
    note: unsplit > 0.005 ? `${dollars(unsplit)} is from records read before the rollup kept the per-model map, in the total and in no row.` : null,
  };
}

// --- LEAKS -----------------------------------------------------------------

export type LeakKey = "unpriced" | "corrections" | "cache";

/** One marked line. The mark is amber when the line names something a
 * person can act on and grey when it reports a zero. */
export type LeakLine = { key: LeakKey; mark: "attention" | "idle"; text: string; title: string };

/**
 * The three leaks `corpus/valuemaxxing.md` names, one line each: the
 * rounds with no `Cost:` line, the corrections per round, and the sessions
 * under 95% cached. The first two count every round record the page
 * holds, over every range, because a record is priced or not for good.
 * The third is the rollup's own list over the range, sessions over $5,
 * the floor the research measured with. A line whose source the page does
 * not have is left out rather than printed as a zero.
 */
export function leakLines(
  report: UsageDaily | null | undefined,
  goals: readonly { summary: KnowledgeSummary }[],
): LeakLine[] {
  const lines: LeakLine[] = [];
  const rounds = goals.flatMap(({ summary }) => summary.rounds ?? []);
  if (rounds.length > 0) {
    const unpriced = rounds.filter((r) => typeof r.costUSD !== "number").length;
    lines.push({
      key: "unpriced",
      mark: unpriced > 0 ? "attention" : "idle",
      text: `${count(unpriced)} of ${plural(rounds.length, "round carries", "rounds carry")} no Cost line`,
      title: "A round with no Cost line prices at nothing: its spend sits in the no-round-record remainder. LOOP.md writes the line at collect.",
    });
    const corrections = rounds.filter((r) => r.correction).length;
    lines.push({
      key: "corrections",
      mark: "idle",
      text: `${plural(corrections, "correction", "corrections")} in ${plural(rounds.length, "round", "rounds")}`,
      title: "Records that carry a Correction section. The record template has no field for one, so this counts the records that wrote the heading.",
    });
  }
  if (report?.ok && report.lowCache) {
    const low = report.lowCache;
    const sum = low.reduce((s, l) => s + l.costUSD, 0);
    lines.push({
      key: "cache",
      mark: low.length > 0 ? "attention" : "idle",
      text: low.length > 0 ? `${plural(low.length, "session", "sessions")} over $5 under 95% cached, ${dollars(sum)}` : "no session over $5 under 95% cached",
      title: low.length > 0
        ? low.map((l) => `${l.project}: ${dollars(l.costUSD)} at ${Math.round(l.cacheShare * 100)}%`).join("; ")
        : "Every billed session over $5 in the range read 95% or more of its input from cache.",
    });
  }
  return lines;
}
