import { describe, expect, it } from "vitest";

import {
  baseDayOf,
  type LifetimeUsageDay,
  type LifetimeYieldDay,
  multipleLabel,
  shorthandCount,
  shorthandDollars,
  stackEndLabels,
  totalsSeries,
  unitCostLabel,
  unitCostsSeries,
} from "./value-lifetime";

/**
 * The arithmetic behind the two VALUE lifetime charts
 * (`corpus/02-direction.md`, `corpus/03-approved-design.md`), against the
 * real series the human saw on 2026-10-09: 61 days, every counted
 * repository, read from `GET /api/usage/daily` and `GET /api/yield/daily`
 * and reconstructed here as each day's own delta, the shape this module
 * takes. The first day's `costUSD` is `3.0528`, not the `3.05` the page
 * prints: a dollar rounds to the cent for display, and the first day's
 * own unit costs ($5.76 per 1k lines, $1.53 a release) only round-trip
 * from the fuller figure.
 *
 * `2026-08-23`'s `costUSD` is `0.09`, the real value from
 * `/api/usage/daily` and `/api/yield` on 2026-10-09 — round 3 pinned it
 * to `0` to match `corpus/03-approved-design.md`'s first rule ("every
 * earlier seven-day run holds a day with $0"); the human's later rule
 * (`corpus/03-approved-design.md`, "The base day, decided") no longer
 * needs that pin, so this fixture holds the real day.
 */

const usageDays: LifetimeUsageDay[] = [
  { day: "2026-08-10", costUSD: 3.0528, measuredUSD: 3.0528, apiMs: 72000 },
  { day: "2026-08-11", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-12", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-13", costUSD: 14.74, measuredUSD: 14.74, apiMs: 504000 },
  { day: "2026-08-14", costUSD: 6.56, measuredUSD: 6.56, apiMs: 216000 },
  { day: "2026-08-15", costUSD: 10.29, measuredUSD: 10.29, apiMs: 360000 },
  { day: "2026-08-16", costUSD: 8.09, measuredUSD: 8.09, apiMs: 288000 },
  { day: "2026-08-17", costUSD: 3.9, measuredUSD: 3.9, apiMs: 144000 },
  { day: "2026-08-18", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-19", costUSD: 6.41, measuredUSD: 6.41, apiMs: 216000 },
  { day: "2026-08-20", costUSD: 6.63, measuredUSD: 6.63, apiMs: 216000 },
  { day: "2026-08-21", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-22", costUSD: 16.67, measuredUSD: 16.67, apiMs: 612000 },
  { day: "2026-08-23", costUSD: 0.09, measuredUSD: 0.09, apiMs: 0 },
  { day: "2026-08-24", costUSD: 4.08, measuredUSD: 4.08, apiMs: 180000 },
  { day: "2026-08-25", costUSD: 67.61, measuredUSD: 67.61, apiMs: 2268000 },
  { day: "2026-08-26", costUSD: 18.41, measuredUSD: 18.41, apiMs: 504000 },
  { day: "2026-08-27", costUSD: 127.97, measuredUSD: 127.97, apiMs: 4068000 },
  { day: "2026-08-28", costUSD: 0.46, measuredUSD: 0.46, apiMs: 36000 },
  { day: "2026-08-29", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-30", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-08-31", costUSD: 1.08, measuredUSD: 1.08, apiMs: 36000 },
  { day: "2026-09-01", costUSD: 7.16, measuredUSD: 7.16, apiMs: 504000 },
  { day: "2026-09-02", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-09-03", costUSD: 427.76, measuredUSD: 427.76, apiMs: 23220000 },
  { day: "2026-09-04", costUSD: 419.29, measuredUSD: 419.29, apiMs: 22356000 },
  { day: "2026-09-05", costUSD: 31.41, measuredUSD: 31.41, apiMs: 1944000 },
  { day: "2026-09-06", costUSD: 100.41, measuredUSD: 100.41, apiMs: 7740000 },
  { day: "2026-09-07", costUSD: 176.95, measuredUSD: 176.95, apiMs: 10548000 },
  { day: "2026-09-08", costUSD: 186.96, measuredUSD: 186.96, apiMs: 11592000 },
  { day: "2026-09-09", costUSD: 231.77, measuredUSD: 231.77, apiMs: 13428000 },
  { day: "2026-09-10", costUSD: 319.63, measuredUSD: 319.63, apiMs: 17784000 },
  { day: "2026-09-11", costUSD: 355.24, measuredUSD: 355.24, apiMs: 19440000 },
  { day: "2026-09-12", costUSD: 14.34, measuredUSD: 14.34, apiMs: 684000 },
  { day: "2026-09-13", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
  { day: "2026-09-14", costUSD: 30.28, measuredUSD: 30.28, apiMs: 1476000 },
  { day: "2026-09-15", costUSD: 227.04, measuredUSD: 227.04, apiMs: 12240000 },
  { day: "2026-09-16", costUSD: 309.55, measuredUSD: 309.55, apiMs: 21636000 },
  { day: "2026-09-17", costUSD: 291.61, measuredUSD: 291.61, apiMs: 16236000 },
  { day: "2026-09-18", costUSD: 533.27, measuredUSD: 533.27, apiMs: 28152000 },
  { day: "2026-09-19", costUSD: 70.39, measuredUSD: 70.39, apiMs: 3744000 },
  { day: "2026-09-20", costUSD: 164.44, measuredUSD: 164.44, apiMs: 11160000 },
  { day: "2026-09-21", costUSD: 207.56, measuredUSD: 207.56, apiMs: 15084000 },
  { day: "2026-09-22", costUSD: 18.17, measuredUSD: 18.17, apiMs: 1620000 },
  { day: "2026-09-23", costUSD: 113.58, measuredUSD: 113.58, apiMs: 8208000 },
  { day: "2026-09-24", costUSD: 59.89, measuredUSD: 59.89, apiMs: 4572000 },
  { day: "2026-09-25", costUSD: 98.95, measuredUSD: 98.95, apiMs: 8748000 },
  { day: "2026-09-26", costUSD: 37.05, measuredUSD: 37.05, apiMs: 3528000 },
  { day: "2026-09-27", costUSD: 2.53, measuredUSD: 2.53, apiMs: 180000 },
  { day: "2026-09-28", costUSD: 265.44, measuredUSD: 265.44, apiMs: 25956000 },
  { day: "2026-09-29", costUSD: 48.94, measuredUSD: 48.94, apiMs: 4824000 },
  { day: "2026-09-30", costUSD: 69.16, measuredUSD: 69.16, apiMs: 6696000 },
  { day: "2026-10-01", costUSD: 78.4, measuredUSD: 78.4, apiMs: 7524000 },
  { day: "2026-10-02", costUSD: 473.83, measuredUSD: 473.83, apiMs: 29052000 },
  { day: "2026-10-03", costUSD: 49.75, measuredUSD: 49.75, apiMs: 3204000 },
  { day: "2026-10-04", costUSD: 123.42, measuredUSD: 123.42, apiMs: 7956000 },
  { day: "2026-10-05", costUSD: 140.11, measuredUSD: 140.11, apiMs: 9252000 },
  { day: "2026-10-06", costUSD: 137.61, measuredUSD: 137.61, apiMs: 13500000 },
  { day: "2026-10-07", costUSD: 135.67, measuredUSD: 135.67, apiMs: 16524000 },
  { day: "2026-10-08", costUSD: 188.42, measuredUSD: 188.42, apiMs: 22248000 },
  { day: "2026-10-09", costUSD: 0.0, measuredUSD: 0.0, apiMs: 0 },
];

const yieldDays: LifetimeYieldDay[] = [
  { day: "2026-08-10", mergedPullRequests: 3, mergedLines: 530, releases: 2 },
  { day: "2026-08-11", mergedPullRequests: 3, mergedLines: 656, releases: 3 },
  { day: "2026-08-12", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-13", mergedPullRequests: 2, mergedLines: 1188, releases: 1 },
  { day: "2026-08-14", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-15", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-16", mergedPullRequests: 1, mergedLines: 1956, releases: 1 },
  { day: "2026-08-17", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-18", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-19", mergedPullRequests: 1, mergedLines: 317, releases: 1 },
  { day: "2026-08-20", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-21", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-22", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-23", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-24", mergedPullRequests: 1, mergedLines: 581, releases: 1 },
  { day: "2026-08-25", mergedPullRequests: 4, mergedLines: 551, releases: 2 },
  { day: "2026-08-26", mergedPullRequests: 3, mergedLines: 2524, releases: 1 },
  { day: "2026-08-27", mergedPullRequests: 1, mergedLines: 393, releases: 1 },
  { day: "2026-08-28", mergedPullRequests: 3, mergedLines: 38, releases: 1 },
  { day: "2026-08-29", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-30", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-08-31", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-09-01", mergedPullRequests: 1, mergedLines: 2815, releases: 0 },
  { day: "2026-09-02", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-09-03", mergedPullRequests: 4, mergedLines: 5094, releases: 3 },
  { day: "2026-09-04", mergedPullRequests: 7, mergedLines: 4475, releases: 2 },
  { day: "2026-09-05", mergedPullRequests: 3, mergedLines: 3040, releases: 1 },
  { day: "2026-09-06", mergedPullRequests: 5, mergedLines: 6572, releases: 2 },
  { day: "2026-09-07", mergedPullRequests: 6, mergedLines: 3272, releases: 5 },
  { day: "2026-09-08", mergedPullRequests: 6, mergedLines: 7243, releases: 1 },
  { day: "2026-09-09", mergedPullRequests: 5, mergedLines: 5461, releases: 1 },
  { day: "2026-09-10", mergedPullRequests: 9, mergedLines: 3105, releases: 3 },
  { day: "2026-09-11", mergedPullRequests: 15, mergedLines: 9074, releases: 1 },
  { day: "2026-09-12", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-09-13", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-09-14", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-09-15", mergedPullRequests: 8, mergedLines: 3998, releases: 0 },
  { day: "2026-09-16", mergedPullRequests: 16, mergedLines: 12236, releases: 2 },
  { day: "2026-09-17", mergedPullRequests: 6, mergedLines: 3210, releases: 0 },
  { day: "2026-09-18", mergedPullRequests: 10, mergedLines: 9468, releases: 0 },
  { day: "2026-09-19", mergedPullRequests: 1, mergedLines: 1394, releases: 0 },
  { day: "2026-09-20", mergedPullRequests: 5, mergedLines: 15407, releases: 1 },
  { day: "2026-09-21", mergedPullRequests: 8, mergedLines: 21004, releases: 3 },
  { day: "2026-09-22", mergedPullRequests: 4, mergedLines: 3117, releases: 0 },
  { day: "2026-09-23", mergedPullRequests: 11, mergedLines: 2725, releases: 2 },
  { day: "2026-09-24", mergedPullRequests: 7, mergedLines: 497, releases: 0 },
  { day: "2026-09-25", mergedPullRequests: 11, mergedLines: 17638, releases: 1 },
  { day: "2026-09-26", mergedPullRequests: 1, mergedLines: 2301, releases: 0 },
  { day: "2026-09-27", mergedPullRequests: 1, mergedLines: 4234, releases: 0 },
  { day: "2026-09-28", mergedPullRequests: 15, mergedLines: 17091, releases: 2 },
  { day: "2026-09-29", mergedPullRequests: 3, mergedLines: 1634, releases: 1 },
  { day: "2026-09-30", mergedPullRequests: 6, mergedLines: 4213, releases: 3 },
  { day: "2026-10-01", mergedPullRequests: 10, mergedLines: 4483, releases: 5 },
  { day: "2026-10-02", mergedPullRequests: 8, mergedLines: 90172, releases: 5 },
  { day: "2026-10-03", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-10-04", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
  { day: "2026-10-05", mergedPullRequests: 3, mergedLines: 29532, releases: 3 },
  { day: "2026-10-06", mergedPullRequests: 7, mergedLines: 19283, releases: 6 },
  { day: "2026-10-07", mergedPullRequests: 11, mergedLines: 63294, releases: 1 },
  { day: "2026-10-08", mergedPullRequests: 7, mergedLines: 28633, releases: 2 },
  { day: "2026-10-09", mergedPullRequests: 2, mergedLines: 21597, releases: 0 },
];

function totalsOn(day: string) {
  const point = totalsSeries(usageDays, yieldDays).points.find((p) => p.day === day);
  if (!point) throw new Error(`no TOTALS point for ${day}`);
  return point;
}

function unitCostsOn(day: string) {
  const point = unitCostsSeries(usageDays, yieldDays).points.find((p) => p.day === day);
  if (!point) throw new Error(`no UNIT COSTS point for ${day}`);
  return point;
}

describe("baseDayOf", () => {
  it("finds the base day as the first day of the first seven-day spend run", () => {
    expect(baseDayOf(usageDays)).toEqual({ firstSpendDay: "2026-08-10", baseDay: "2026-09-03" });
  });

  it("gives a null base day with spend but no seven-day run", () => {
    const short: LifetimeUsageDay[] = usageDays.slice(0, 6).map((d) => ({ ...d, costUSD: 1 }));
    expect(baseDayOf(short)).toEqual({ firstSpendDay: short[0].day, baseDay: null });
  });

  it("gives a null first spend day and base day with no spend at all", () => {
    const flat: LifetimeUsageDay[] = usageDays.map((d) => ({ ...d, costUSD: 0 }));
    expect(baseDayOf(flat)).toEqual({ firstSpendDay: null, baseDay: null });
  });

  it("skips the 22-28 Aug run: its nine-cent day sits below the floor", () => {
    // 2026-08-23 is 0.09, far under the real record's floor, so the
    // 22-28 Aug run no longer qualifies the way a bare "$0 or not" rule
    // once did; 2026-09-03 is still the first run where every day clears
    // a quarter of the median.
    const { baseDay } = baseDayOf(usageDays);
    expect(baseDay).not.toBe("2026-08-22");
    expect(baseDay).toBe("2026-09-03");
  });

  it("puts the real record's median at $48.94 and its quarter floor at $12.235", () => {
    const sorted = usageDays.map((d) => d.costUSD).sort((a, b) => a - b);
    const median = sorted[(sorted.length - 1) / 2]; // 61 days: the middle one
    expect(median).toBeCloseTo(48.94, 2);
    expect(median * 0.25).toBeCloseTo(12.235, 3);
  });

  it("counts a run whose days sit exactly at the floor", () => {
    // Seven days at 3, then thirteen at 12: the median of the twenty
    // days is 12 (the twelves outnumber the threes), so the floor is
    // 12 * 0.25 = 3 - exactly the run's own value. The rule is "at
    // least", so this run still counts.
    const usage: LifetimeUsageDay[] = [
      ...Array.from({ length: 7 }, (_, i) => ({ day: `2026-01-${String(i + 1).padStart(2, "0")}`, costUSD: 3 })),
      ...Array.from({ length: 13 }, (_, i) => ({ day: `2026-01-${String(i + 8).padStart(2, "0")}`, costUSD: 12 })),
    ];
    expect(baseDayOf(usage)).toEqual({ firstSpendDay: "2026-01-01", baseDay: "2026-01-01" });
  });

  it("makes the first day the base day when every day's spend is equal", () => {
    const usage: LifetimeUsageDay[] = Array.from({ length: 10 }, (_, i) => ({
      day: `2026-02-${String(i + 1).padStart(2, "0")}`,
      costUSD: 42,
    }));
    expect(baseDayOf(usage)).toEqual({ firstSpendDay: "2026-02-01", baseDay: "2026-02-01" });
  });
});

describe("totalsSeries", () => {
  it("rebases every measure on the base day's own cumulative value", () => {
    const totals = totalsSeries(usageDays, yieldDays);
    expect(totals.baseDay).toBe("2026-09-03");
    const base = totalsOn("2026-09-03");
    expect(base.multiple).toEqual({ spend: 1, prs: 1, lines: 1, releases: 1 });
    expect(base.cumulative).toEqual({ spend: 730.9628, prs: 27, lines: 16643, releases: 17 });
  });

  it("matches the human's table on 2026-09-20", () => {
    const point = totalsOn("2026-09-20");
    expect(multipleLabel(point.multiple.spend!)).toBe("×5.7");
    expect(multipleLabel(point.multiple.prs!)).toBe("×4.8");
    expect(multipleLabel(point.multiple.lines!)).toBe("×6.3");
    expect(multipleLabel(point.multiple.releases!)).toBe("×2.1");
  });

  it("matches the human's table on 2026-10-09, the last day", () => {
    const point = totalsOn("2026-10-09");
    expect(multipleLabel(point.multiple.spend!)).toBe("×8.8");
    expect(multipleLabel(point.multiple.prs!)).toBe("×9.0");
    expect(multipleLabel(point.multiple.lines!)).toBe("×26.2");
    expect(multipleLabel(point.multiple.releases!)).toBe("×4.1");
    expect(point.cumulative.spend).toBeCloseTo(6442.0228, 4);
    expect({ prs: point.cumulative.prs, lines: point.cumulative.lines, releases: point.cumulative.releases }).toEqual({
      prs: 244,
      lines: 436046,
      releases: 70,
    });
  });

  it("gives an empty series with no seven-day run", () => {
    const short: LifetimeUsageDay[] = usageDays.slice(0, 6).map((d) => ({ ...d, costUSD: 1 }));
    expect(totalsSeries(short, yieldDays)).toEqual({ baseDay: null, points: [] });
  });

  it("gives the empty state for a fleet with no spend", () => {
    const flat: LifetimeUsageDay[] = usageDays.map((d) => ({ ...d, costUSD: 0 }));
    expect(totalsSeries(flat, yieldDays)).toEqual({ baseDay: null, points: [] });
  });

  it("does not let a gap in the yield reset the running total", () => {
    // Day 2 of a five-day run carries no yield entry at all: a day the
    // route counted nothing for, not a day with zero merged PRs.
    const usage: LifetimeUsageDay[] = [
      { day: "2026-01-01", costUSD: 10 },
      { day: "2026-01-02", costUSD: 10 },
      { day: "2026-01-03", costUSD: 10 },
      { day: "2026-01-04", costUSD: 10 },
      { day: "2026-01-05", costUSD: 10 },
      { day: "2026-01-06", costUSD: 10 },
      { day: "2026-01-07", costUSD: 10 },
    ];
    const yld: LifetimeYieldDay[] = [
      { day: "2026-01-01", mergedPullRequests: 2, mergedLines: 100, releases: 1 },
      // 2026-01-02 is missing: no source that day, not a zero.
      { day: "2026-01-03", mergedPullRequests: 3, mergedLines: 150, releases: 0 },
      { day: "2026-01-04", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
      { day: "2026-01-05", mergedPullRequests: 1, mergedLines: 50, releases: 1 },
      { day: "2026-01-06", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
      { day: "2026-01-07", mergedPullRequests: 0, mergedLines: 0, releases: 0 },
    ];
    const totals = totalsSeries(usage, yld);
    expect(totals.baseDay).toBe("2026-01-01");
    const last = totals.points[totals.points.length - 1];
    // 2 + 3 + 0 + 1 + 0 + 0 = 6, carried straight through the gap day.
    expect(last.cumulative.prs).toBe(6);
    expect(last.cumulative.lines).toBe(300);
    expect(last.cumulative.releases).toBe(2);
  });
});

describe("unitCostsSeries", () => {
  it("matches the human's table on 2026-08-10, the first spend day", () => {
    const unitCosts = unitCostsSeries(usageDays, yieldDays);
    expect(unitCosts.firstSpendDay).toBe("2026-08-10");
    const point = unitCostsOn("2026-08-10");
    expect(unitCostLabel(point.perPR!)).toBe("$1.02");
    expect(unitCostLabel(point.perKLines!)).toBe("$5.76");
    expect(unitCostLabel(point.perRelease!)).toBe("$1.53");
  });

  it("matches the human's table on 2026-10-09", () => {
    const point = unitCostsOn("2026-10-09");
    expect(unitCostLabel(point.perPR!)).toBe("$26.40");
    expect(unitCostLabel(point.perKLines!)).toBe("$14.77");
    expect(unitCostLabel(point.perRelease!)).toBe("$92.03");
    expect(unitCostLabel(point.perHour!)).toBe("$54.92");
  });

  it("gives the empty state for a fleet with no spend", () => {
    const flat: LifetimeUsageDay[] = usageDays.map((d) => ({ ...d, costUSD: 0 }));
    expect(unitCostsSeries(flat, yieldDays)).toEqual({ firstSpendDay: null, points: [] });
  });

  it("gives null where a count is still zero", () => {
    const usage: LifetimeUsageDay[] = [{ day: "2026-01-01", costUSD: 5, measuredUSD: 5, apiMs: 0 }];
    const yld: LifetimeYieldDay[] = [{ day: "2026-01-01", mergedPullRequests: 0, mergedLines: 0, releases: 0 }];
    const point = unitCostsSeries(usage, yld).points[0];
    expect(point).toEqual({ day: "2026-01-01", perPR: null, perKLines: null, perRelease: null, perHour: null });
  });
});

describe("shorthandCount", () => {
  it.each([
    [244, "244"],
    [6400, "6.4k"],
    [436_000, "436k"],
    [1_200_000, "1.2m"],
  ])("formats %d as %s", (n, expected) => {
    expect(shorthandCount(n)).toBe(expected);
  });
});

describe("shorthandDollars", () => {
  it("prefixes the shorthand count with a dollar sign", () => {
    expect(shorthandDollars(6400)).toBe("$6.4k");
  });
});

describe("unitCostLabel", () => {
  it("prints two decimals under $100", () => {
    expect(unitCostLabel(26.4)).toBe("$26.40");
  });

  it("prints whole dollars at $100 or more", () => {
    expect(unitCostLabel(116.49)).toBe("$116");
  });
});

describe("multipleLabel", () => {
  it("prints one decimal at 1 or more", () => {
    expect(multipleLabel(26.197)).toBe("×26.2");
  });

  it("prints two decimals under 1", () => {
    expect(multipleLabel(0.1055)).toBe("×0.11");
  });
});

describe("stackEndLabels", () => {
  it("leaves labels alone when they already clear the line height", () => {
    expect(stackEndLabels([0, 50, 100, 150], 20)).toEqual([0, 50, 100, 150]);
  });

  it("spreads labels closer than one line height apart, keeping their order", () => {
    expect(stackEndLabels([100, 102, 140, 300], 20)).toEqual([100, 120, 140, 300]);
  });

  it("keeps the input order when the positions are not sorted", () => {
    // The releases line ends highest on the page (smallest y), lines
    // lowest: the same four positions, given out of order.
    const result = stackEndLabels([140, 300, 100, 102], 20);
    expect(result).toEqual([140, 300, 100, 120]);
  });
});
