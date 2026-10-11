/**
 * The lifetime series behind the two VALUE charts (`value-lifetime`,
 * capability 3; the rule of `corpus/02-direction.md` and
 * `corpus/03-approved-design.md`): no DOM, no fetch, no clock. The chart
 * round draws from what this file computes.
 *
 * TOTALS: each of spend, merged pull requests, merged lines and releases,
 * cumulative from the first spend day, divided by its own cumulative value
 * on the start day — the base day (the first day of the first run of seven
 * consecutive days in which every day's spend is at least a quarter of the
 * median daily spend over the whole record, `corpus/03-approved-design.md`,
 * "The base day, decided"), or later, the range toggle's own first day,
 * never earlier (`corpus/05-legend-and-range.md`). UNIT COSTS: spend over
 * merged pull requests, over merged lines per 1,000, over releases, and
 * `measuredUSD` over model hours (the same division the VALUE tiles' hours
 * tile uses), each summed fresh from the start day — the first spend day,
 * or later, the range toggle's own first day (`corpus/05-legend-and-range.md`,
 * "cost within the range").
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
  const firstSpendIndex = sorted.findIndex((d) => d.costUSD > 0);
  if (firstSpendIndex === -1) return { firstSpendDay: null, baseDay: null };
  const firstSpendDay = sorted[firstSpendIndex].day;
  // The median and the run both read from the first spend day on: a day
  // before it is not the record, it is a day the fleet did not exist, and
  // `GET /api/usage/daily` zero-fills it the same as a quiet one inside the
  // record. A caller that asks a wide range to find the first spend day
  // without knowing it in advance (the lifetime charts ask 400 days) would
  // otherwise drag the median toward 0 with padding and let a run of true
  // zeros before the record qualify.
  const record = sorted.slice(firstSpendIndex);
  const floor = medianOf(record.map((d) => d.costUSD)) * BASE_RUN_FLOOR_SHARE;
  let baseDay: string | null = null;
  for (let i = 0; i + BASE_RUN_DAYS <= record.length && baseDay === null; i++) {
    let run = true;
    for (let j = 0; j < BASE_RUN_DAYS; j++) {
      const day = record[i + j];
      if (!(day.costUSD >= floor)) { run = false; break; }
      if (j > 0 && epochDay(day.day) !== epochDay(record[i + j - 1].day) + 1) { run = false; break; }
    }
    if (run) baseDay = record[i].day;
  }
  return { firstSpendDay, baseDay };
}

/** One day of TOTALS: the cumulative value of every measure since the
 * range's first day, and its multiple over the start day's cumulative
 * value — null where the start day's own cumulative value is 0. */
export type TotalsPoint = { day: string; cumulative: Record<Measure, number>; multiple: Record<Measure, number | null> };

export type Totals = { baseDay: string | null; startDay: string | null; points: readonly TotalsPoint[] };

/**
 * TOTALS: a point per day from the start day to the range's last day.
 * Empty, with null `baseDay`/`startDay`, when no seven-day run of spend
 * exists — the empty state of a fleet with too little recorded spend, or
 * none at all.
 *
 * `rangeFrom`, when given, is the range toggle's own first day
 * (`corpus/05-legend-and-range.md`, rule 2): each measure's lifetime
 * cumulative value on day d divides by its own lifetime cumulative value
 * on the start day, the later of `rangeFrom` and the base day — never
 * before the base day, so a range that reaches further back than the base
 * day (90d, `all`) still divides on the base day, unchanged from the
 * lifetime reading. Only the denominator and the first emitted point move;
 * every cumulative total keeps counting from the first spend day, as
 * before.
 */
export function totalsSeries(usageDays: readonly LifetimeUsageDay[], yieldDays: readonly LifetimeYieldDay[], rangeFrom?: string): Totals {
  const sorted = [...usageDays].sort((a, b) => cmpDay(a.day, b.day));
  const { firstSpendDay, baseDay } = baseDayOf(sorted);
  if (baseDay === null) return { baseDay: null, startDay: null, points: [] };
  const startDay = rangeFrom !== undefined && cmpDay(rangeFrom, baseDay) > 0 ? rangeFrom : baseDay;
  // Every cumulative count starts at the first spend day, PRs, lines and
  // releases included: a repository's history reaches back further than
  // the spend record (kitterm's own merges start 2026-07-16, over three
  // weeks before the first billed day), and a caller who asks a wide range
  // to find that first day without knowing it in advance (the lifetime
  // charts ask 400 days) would otherwise load the base day's own
  // cumulative count with merges no spend paid for, reading every later
  // multiple and unit cost too low (`corpus/02-direction.md`: "delivered
  // from the first spend day to d").
  const record = sorted.filter((d) => cmpDay(d.day, firstSpendDay!) >= 0);
  const yieldByDay = new Map(yieldDays.map((y) => [y.day, y]));
  const cumulative: Record<Measure, number> = { spend: 0, prs: 0, lines: 0, releases: 0 };
  let startCumulative: Record<Measure, number> | null = null;
  const points: TotalsPoint[] = [];
  for (const u of record) {
    cumulative.spend += u.costUSD;
    const y = yieldByDay.get(u.day);
    if (typeof y?.mergedPullRequests === "number") cumulative.prs += y.mergedPullRequests;
    if (typeof y?.mergedLines === "number") cumulative.lines += y.mergedLines;
    if (typeof y?.releases === "number") cumulative.releases += y.releases;
    if (u.day === startDay) startCumulative = { ...cumulative };
    if (cmpDay(u.day, startDay) >= 0 && startCumulative !== null) {
      const multiple = {} as Record<Measure, number | null>;
      for (const m of MEASURES) {
        const base = startCumulative[m];
        multiple[m] = base > 0 ? cumulative[m] / base : null;
      }
      points.push({ day: u.day, cumulative: { ...cumulative }, multiple });
    }
  }
  return { baseDay, startDay, points };
}

/** One day of UNIT COSTS: null for a measure whose cumulative count is
 * still 0. */
export type UnitCostPoint = { day: string; perPR: number | null; perKLines: number | null; perRelease: number | null; perHour: number | null };

export type UnitCosts = { firstSpendDay: string | null; startDay: string | null; points: readonly UnitCostPoint[] };

/**
 * UNIT COSTS: a point per day from the start day to the range's last day.
 * Empty, with null `firstSpendDay`/`startDay`, when no day has recorded
 * spend.
 *
 * `rangeFrom`, when given, is the range toggle's own first day
 * (`corpus/05-legend-and-range.md`, rule 1): "cost within the range", not
 * the lifetime reading — the spend and the units both sum fresh from the
 * start day, the later of `rangeFrom` and the first spend day, rather than
 * from the first spend day always. A day's gap in the yield still carries
 * the running sum forward, as it does without a range.
 */
export function unitCostsSeries(usageDays: readonly LifetimeUsageDay[], yieldDays: readonly LifetimeYieldDay[], rangeFrom?: string): UnitCosts {
  const sorted = [...usageDays].sort((a, b) => cmpDay(a.day, b.day));
  const { firstSpendDay } = baseDayOf(sorted);
  if (firstSpendDay === null) return { firstSpendDay: null, startDay: null, points: [] };
  const startDay = rangeFrom !== undefined && cmpDay(rangeFrom, firstSpendDay) > 0 ? rangeFrom : firstSpendDay;
  // Every cumulative count starts at the start day (see `totalsSeries`):
  // a PR merged before it is not "delivered from the start day to d", and
  // counting it inflates the denominator under a numerator that is
  // genuinely 0 that early, reading every unit cost too low.
  const record = sorted.filter((d) => cmpDay(d.day, startDay) >= 0);
  const yieldByDay = new Map(yieldDays.map((y) => [y.day, y]));
  let spend = 0;
  let measured = 0;
  let apiMs = 0;
  let prs = 0;
  let lines = 0;
  let releases = 0;
  const points: UnitCostPoint[] = [];
  for (const u of record) {
    spend += u.costUSD;
    measured += u.measuredUSD ?? 0;
    apiMs += u.apiMs ?? 0;
    const y = yieldByDay.get(u.day);
    if (typeof y?.mergedPullRequests === "number") prs += y.mergedPullRequests;
    if (typeof y?.mergedLines === "number") lines += y.mergedLines;
    if (typeof y?.releases === "number") releases += y.releases;
    const hours = apiMs / 3_600_000;
    points.push({
      day: u.day,
      perPR: prs > 0 ? spend / prs : null,
      perKLines: lines > 0 ? spend / (lines / 1000) : null,
      perRelease: releases > 0 ? spend / releases : null,
      perHour: hours > 0 ? measured / hours : null,
    });
  }
  return { firstSpendDay, startDay, points };
}

// --- formatters --------------------------------------------------------

/** `244`, `6.4k`, `436k`, `1.2m`: whole under 1,000, else one decimal of
 * `k`/`m`/`b` under ten in that tier, else the tier's whole number. The
 * tooltip of both charts, for a count. */
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
 * tooltip. */
export function shorthandDollars(usd: number): string {
  return usd < 0 ? `-$${shorthandCount(-usd).slice(1)}` : `$${shorthandCount(usd)}`;
}

/** `$26.40` under $100, `$116` at $100 or more: the UNIT COSTS lines'
 * tooltip. */
export function unitCostLabel(usd: number): string {
  const sign = usd < 0 ? "-" : "";
  const abs = Math.abs(usd);
  return abs < 100 ? `${sign}$${abs.toFixed(2)}` : `${sign}$${String(Math.round(abs))}`;
}

// --- chart axes and geometry (capability 4: the charts) ----------------

/** The TOTALS log axis: ×1 ×2 ×5 ×10 ×20 ×50, extended by the same 1-2-5
 * sequence (×100 ×200 ×500 …) until a tick is at or above the highest
 * multiple any line reaches that day (`corpus/02-direction.md`, the frame
 * `Dashboard 1200`). `maxMultiple` under 1 still gets the ×1 tick: the
 * axis never reads below the base day's own line. */
export function totalsAxisTicks(maxMultiple: number): number[] {
  const ticks: number[] = [];
  let decade = 1;
  for (;;) {
    for (const step of [1, 2, 5]) {
      const tick = step * decade;
      ticks.push(tick);
      if (tick >= maxMultiple) return ticks;
    }
    decade *= 10;
  }
}

/** A point's position on the TOTALS log axis, 0 at the base day's own line
 * (×1) to 1 at `axisMax` (the top tick `totalsAxisTicks` returns): the
 * fraction of the axis's log span a multiple of `value` has climbed.
 * `value` is always 1 or more on a TOTALS line (`totalsSeries` divides a
 * cumulative total by itself or an earlier one), so this never takes a
 * value under 1. */
export function logPosition(value: number, axisMax: number): number {
  return Math.log(value) / Math.log(axisMax);
}

/** A UNIT COSTS axis tick list from 0 to a round dollar amount at or above
 * `max`: a 1-2-5-10 step picked so four to five gridlines cover the range,
 * the same family of round numbers `totalsAxisTicks` climbs. `max` of 0 or
 * less draws the single tick at 0. */
export function unitCostAxisTicks(max: number): number[] {
  if (max <= 0) return [0];
  const rough = max / 4;
  const magnitude = 10 ** Math.floor(Math.log10(rough));
  const residual = rough / magnitude;
  const step = (residual >= 5 ? 10 : residual >= 2 ? 5 : residual >= 1 ? 2 : 1) * magnitude;
  const ticks: number[] = [0];
  while (ticks[ticks.length - 1] < max - step * 1e-9) ticks.push(Math.round((ticks[ticks.length - 1] + step) * 100) / 100);
  return ticks;
}

// --- tooltip text --------------------------------------------------------

const TOOLTIP_DASH = "–";

/** The TOTALS tooltip's second line: the day's real totals in shorthand,
 * `$4.2k · 129 PRs · 105k lines · 36 releases`. */
export function totalsRealLine(point: Pick<TotalsPoint, "cumulative">): string {
  const c = point.cumulative;
  return `${shorthandDollars(c.spend)} · ${shorthandCount(c.prs)} PRs · ${shorthandCount(c.lines)} lines · ${shorthandCount(c.releases)} releases`;
}

/** The UNIT COSTS tooltip's one line: `$32.51/PR · $40.09/1k lines ·
 * $116/release · $64.63/hour`. A null count (nothing merged or billed yet
 * that day) prints the dash. */
export function unitCostsLine(point: UnitCostPoint): string {
  const p = (x: number | null): string => (x === null ? TOOLTIP_DASH : unitCostLabel(x));
  return `${p(point.perPR)}/PR · ${p(point.perKLines)}/1k lines · ${p(point.perRelease)}/release · ${p(point.perHour)}/hour`;
}

/** One row of the visual tooltip box (`corpus/04-chart-polish.md`): a
 * swatch in the measure's data-palette slot, its name, and its value. */
export type TooltipRow = { slot: 1 | 2 | 3 | 4; label: string; value: string };

/** The TOTALS tooltip's rows: the day's real values alone, no multiple
 * anywhere (`corpus/04-chart-polish.md`) — spend, PRs, lines, releases, the
 * chart's own measure and slot order. */
export function totalsTooltipRows(point: Pick<TotalsPoint, "cumulative">): TooltipRow[] {
  const c = point.cumulative;
  return [
    { slot: 1, label: "spend", value: shorthandDollars(c.spend) },
    { slot: 2, label: "PRs", value: shorthandCount(c.prs) },
    { slot: 3, label: "lines", value: shorthandCount(c.lines) },
    { slot: 4, label: "releases", value: shorthandCount(c.releases) },
  ];
}

/** The UNIT COSTS tooltip's rows, in the order `corpus/04-chart-polish.md`
 * gives: $/PR, $/1k lines, $/release, $/hour. A null count prints the
 * dash. */
export function unitCostsTooltipRows(point: UnitCostPoint): TooltipRow[] {
  const p = (x: number | null): string => (x === null ? TOOLTIP_DASH : unitCostLabel(x));
  return [
    { slot: 2, label: "$/PR", value: p(point.perPR) },
    { slot: 3, label: "$/1k lines", value: p(point.perKLines) },
    { slot: 4, label: "$/release", value: p(point.perRelease) },
    { slot: 1, label: "$/hour", value: p(point.perHour) },
  ];
}
