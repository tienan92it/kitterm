/**
 * The lifetime series behind the two VALUE charts (`value-lifetime`,
 * capability 3; the rule of `corpus/02-direction.md` and
 * `corpus/03-approved-design.md`): no DOM, no fetch, no clock. The chart
 * round draws from what this file computes.
 *
 * TOTALS: each of spend, merged pull requests, merged lines and releases,
 * cumulative from the first day of the range, divided by its own
 * cumulative value on the base day — the first day of the first run of
 * seven consecutive days in which every day's spend is at least a
 * quarter of the median daily spend over the whole record
 * (`corpus/03-approved-design.md`, "The base day, decided"). UNIT COSTS: cumulative spend
 * over cumulative pull requests, over cumulative lines per 1,000, over
 * cumulative releases, from the first day with recorded spend; and
 * cumulative `measuredUSD` over cumulative model hours, the same division
 * the VALUE tiles' hours tile uses.
 *
 * A gap in the yield's day (a date the array holds no entry for, or an
 * entry missing one field) has no source for that measure that day: it
 * adds nothing to that measure's running total, and it does not reset the
 * total that came before it.
 */

export type Measure = "spend" | "prs" | "lines" | "releases";
export const MEASURES: readonly Measure[] = ["spend", "prs", "lines", "releases"];

/** One day of `GET /api/usage/daily`'s `days`, the fields this module
 * reads. `measuredUSD` and `apiMs` default to 0 when a day carries
 * neither (every session billed with no measured duration). */
export type LifetimeUsageDay = { day: string; costUSD: number; measuredUSD?: number; apiMs?: number };

/** One day of `GET /api/yield/daily`'s `days`, summed over the counted
 * projects. A field is absent, never zero, when the day has no source
 * for it (round 1's absent-means-no-source rule); so is the whole day,
 * when the array holds no entry for that date. */
export type LifetimeYieldDay = { day: string; mergedPullRequests?: number; mergedLines?: number; releases?: number };

const cmpDay = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

function epochDay(day: string): number {
  const [y, m, d] = day.split("-").map(Number);
  return Math.round(Date.UTC(y, m - 1, d) / 86_400_000);
}

// The run length and its floor share: the human's rule of
// `corpus/03-approved-design.md`, "The base day, decided" — seven days,
// each at least a quarter of the median daily spend over the whole
// record.
const BASE_RUN_DAYS = 7;
const BASE_RUN_FLOOR_SHARE = 0.25;

export type BaseDayResult = { firstSpendDay: string | null; baseDay: string | null };

function medianOf(values: readonly number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
}

/**
 * The first day with recorded spend, and the base day: the first day of
 * the first run of `BASE_RUN_DAYS` consecutive calendar days in which
 * every day's `costUSD` is at least `BASE_RUN_FLOOR_SHARE` of the
 * median `costUSD` over the whole record (`corpus/03-approved-design.md`,
 * "The base day, decided"). Both are null with no spend at all; the base
 * day alone is null with spend but no such run.
 */
export function baseDayOf(usageDays: readonly LifetimeUsageDay[]): BaseDayResult {
  const sorted = [...usageDays].sort((a, b) => cmpDay(a.day, b.day));
  const firstSpendDay = sorted.find((d) => d.costUSD > 0)?.day ?? null;
  if (firstSpendDay === null) return { firstSpendDay: null, baseDay: null };
  const floor = medianOf(sorted.map((d) => d.costUSD)) * BASE_RUN_FLOOR_SHARE;
  let baseDay: string | null = null;
  for (let i = 0; i + BASE_RUN_DAYS <= sorted.length && baseDay === null; i++) {
    let run = true;
    for (let j = 0; j < BASE_RUN_DAYS; j++) {
      const day = sorted[i + j];
      if (!(day.costUSD >= floor)) { run = false; break; }
      if (j > 0 && epochDay(day.day) !== epochDay(sorted[i + j - 1].day) + 1) { run = false; break; }
    }
    if (run) baseDay = sorted[i].day;
  }
  return { firstSpendDay, baseDay };
}

/** One day of TOTALS: the cumulative value of every measure since the
 * range's first day, and its multiple over the base day's cumulative
 * value — null where the base day's own cumulative value is 0. */
export type TotalsPoint = { day: string; cumulative: Record<Measure, number>; multiple: Record<Measure, number | null> };

export type Totals = { baseDay: string | null; points: readonly TotalsPoint[] };

/**
 * TOTALS: a point per day from the base day to the range's last day.
 * Empty, with a null `baseDay`, when no seven-day run of spend exists —
 * the empty state of a fleet with too little recorded spend, or none at
 * all.
 */
export function totalsSeries(usageDays: readonly LifetimeUsageDay[], yieldDays: readonly LifetimeYieldDay[]): Totals {
  const sorted = [...usageDays].sort((a, b) => cmpDay(a.day, b.day));
  const { baseDay } = baseDayOf(sorted);
  if (baseDay === null) return { baseDay: null, points: [] };
  const yieldByDay = new Map(yieldDays.map((y) => [y.day, y]));
  const cumulative: Record<Measure, number> = { spend: 0, prs: 0, lines: 0, releases: 0 };
  let baseCumulative: Record<Measure, number> | null = null;
  const points: TotalsPoint[] = [];
  for (const u of sorted) {
    cumulative.spend += u.costUSD;
    const y = yieldByDay.get(u.day);
    if (typeof y?.mergedPullRequests === "number") cumulative.prs += y.mergedPullRequests;
    if (typeof y?.mergedLines === "number") cumulative.lines += y.mergedLines;
    if (typeof y?.releases === "number") cumulative.releases += y.releases;
    if (u.day === baseDay) baseCumulative = { ...cumulative };
    if (cmpDay(u.day, baseDay) >= 0 && baseCumulative !== null) {
      const multiple = {} as Record<Measure, number | null>;
      for (const m of MEASURES) {
        const base = baseCumulative[m];
        multiple[m] = base > 0 ? cumulative[m] / base : null;
      }
      points.push({ day: u.day, cumulative: { ...cumulative }, multiple });
    }
  }
  return { baseDay, points };
}

/** One day of UNIT COSTS: null for a measure whose cumulative count is
 * still 0. */
export type UnitCostPoint = { day: string; perPR: number | null; perKLines: number | null; perRelease: number | null; perHour: number | null };

export type UnitCosts = { firstSpendDay: string | null; points: readonly UnitCostPoint[] };

/**
 * UNIT COSTS: a point per day from the first spend day to the range's
 * last day. Empty, with a null `firstSpendDay`, when no day has recorded
 * spend.
 */
export function unitCostsSeries(usageDays: readonly LifetimeUsageDay[], yieldDays: readonly LifetimeYieldDay[]): UnitCosts {
  const sorted = [...usageDays].sort((a, b) => cmpDay(a.day, b.day));
  const { firstSpendDay } = baseDayOf(sorted);
  if (firstSpendDay === null) return { firstSpendDay: null, points: [] };
  const yieldByDay = new Map(yieldDays.map((y) => [y.day, y]));
  let spend = 0;
  let measured = 0;
  let apiMs = 0;
  let prs = 0;
  let lines = 0;
  let releases = 0;
  const points: UnitCostPoint[] = [];
  for (const u of sorted) {
    spend += u.costUSD;
    measured += u.measuredUSD ?? 0;
    apiMs += u.apiMs ?? 0;
    const y = yieldByDay.get(u.day);
    if (typeof y?.mergedPullRequests === "number") prs += y.mergedPullRequests;
    if (typeof y?.mergedLines === "number") lines += y.mergedLines;
    if (typeof y?.releases === "number") releases += y.releases;
    if (cmpDay(u.day, firstSpendDay) >= 0) {
      const hours = apiMs / 3_600_000;
      points.push({
        day: u.day,
        perPR: prs > 0 ? spend / prs : null,
        perKLines: lines > 0 ? spend / (lines / 1000) : null,
        perRelease: releases > 0 ? spend / releases : null,
        perHour: hours > 0 ? measured / hours : null,
      });
    }
  }
  return { firstSpendDay, points };
}

// --- formatters --------------------------------------------------------

/** `244`, `6.4k`, `436k`, `1.2m`: whole under 1,000, else one decimal of
 * `k`/`m`/`b` under ten in that tier, else the tier's whole number. The
 * end labels and the tooltip of both charts, for a count. */
export function shorthandCount(n: number): string {
  const sign = n < 0 ? "-" : "";
  const abs = Math.abs(n);
  const tiers: readonly [number, string][] = [[1_000_000_000, "b"], [1_000_000, "m"], [1_000, "k"]];
  for (const [div, suffix] of tiers) {
    if (abs >= div) {
      const coeff = abs / div;
      return `${sign}${coeff < 10 ? coeff.toFixed(1) : String(Math.round(coeff))}${suffix}`;
    }
  }
  return `${sign}${String(Math.round(abs))}`;
}

/** `$6.4k`: the shorthand count with a dollar sign, for the spend line's
 * end label and tooltip. */
export function shorthandDollars(usd: number): string {
  return usd < 0 ? `-$${shorthandCount(-usd).slice(1)}` : `$${shorthandCount(usd)}`;
}

/** `$26.40` under $100, `$116` at $100 or more: the UNIT COSTS lines'
 * end labels and tooltip. */
export function unitCostLabel(usd: number): string {
  const sign = usd < 0 ? "-" : "";
  const abs = Math.abs(usd);
  return abs < 100 ? `${sign}$${abs.toFixed(2)}` : `${sign}$${String(Math.round(abs))}`;
}

/** `×26.2`, `×0.11` under 1: the TOTALS lines' end labels and tooltip,
 * one decimal down to a whole multiple, two once it reads under 1. */
export function multipleLabel(x: number): string {
  const sign = x < 0 ? "-" : "";
  const abs = Math.abs(x);
  return `${sign}×${abs.toFixed(abs < 1 ? 2 : 1)}`;
}

// --- end-label stacking --------------------------------------------------

/**
 * Given the four end-label positions on an axis (already placed by the
 * chart's own scale, log or not) and a line height, the positions moved
 * the least so that no two sit closer than one line height apart, their
 * relative order kept. The classic two-pass declutter: push later labels
 * down to clear the gap, then pull earlier ones back up where that
 * overshot. The result is in the same order as `positions`.
 */
export function stackEndLabels(positions: readonly number[], lineHeight: number): number[] {
  const order = positions.map((_, i) => i).sort((a, b) => positions[a] - positions[b]);
  const sorted = order.map((i) => positions[i]);
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i] - sorted[i - 1] < lineHeight) sorted[i] = sorted[i - 1] + lineHeight;
  }
  for (let i = sorted.length - 2; i >= 0; i--) {
    if (sorted[i + 1] - sorted[i] < lineHeight) sorted[i] = sorted[i + 1] - lineHeight;
  }
  const result = new Array<number>(positions.length);
  order.forEach((originalIndex, sortedIndex) => {
    result[originalIndex] = sorted[sortedIndex];
  });
  return result;
}
