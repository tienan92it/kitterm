import { describe, expect, it } from "vitest";

import {
  cacheShare,
  cachedLabel,
  costLabel,
  dayKey,
  dayLabel,
  dollars,
  goalCost,
  projectUsage,
  readUsageChoice,
  tokenCount,
  totalTokens,
  USAGE_DEFAULT,
  usageChartName,
  usageNote,
  usagePanel,
  usageRange,
  workspaceUsage,
  type UsageBucket,
  type UsageDaily,
  type UsageDay,
  type UsageProject,
  type UsageTokens,
} from "./sessions-model";

/**
 * The numbers on the page (`workspace-ledger`, capability 5): what the
 * panel and the headings print from `GET /api/usage/daily`, and what a
 * goal prints from its records' `Cost:` lines. The fixture is the corpus
 * request `01-where-did-it-go` as the route answered it on 2026-09-16:
 * thirty days, $1,084.03, of which $329.67 is apportioned across midnight,
 * 50 sessions unbilled, `kitterm` $850.51 with its worktrees folded in.
 */
const W = "/Users/antran/Workspace";
const NNT = `${W}/NgheNhanTrading`;
const NOW = new Date(2026, 8, 16, 15, 0, 0).getTime();
const MIN = 60_000;

const tokens = (input: number, output: number, cacheCreation: number, cacheRead: number): UsageTokens => ({
  input, output, cacheCreation, cacheRead, requests: Math.max(1, Math.round(output / 400)),
});
const zero: UsageTokens = { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 };

const project = (id: string, name: string, root: string, costUSD: number, t: UsageTokens, extra: Partial<UsageProject> = {}): UsageProject => ({
  id, name, root, registered: true, costUSD, apportionedUSD: 0, tokens: t, sessions: 3, unbilledSessions: 0, ...extra,
});

const kitterm = project("kitterm", "kitterm", `${W}/kitterm`, 850.51, tokens(1_200_000, 3_000_000, 40_000_000, 260_000_000), { sessions: 61, unbilledSessions: 30, apportionedUSD: 300.12 });
const home = project("antran", "antran", "/Users/antran", 89.47, tokens(100_000, 200_000, 4_000_000, 20_000_000), { registered: false });
const nnt = project("nghenhantrading", "NgheNhanTrading", NNT, 68.43, tokens(50_000, 100_000, 2_000_000, 12_000_000), { registered: false });
const mdp = project("mdp", "market-data-pipeline", `${NNT}/market-data-pipeline`, 13.35, tokens(10_000, 20_000, 500_000, 3_000_000));
const diagram = project("diagram-generation", "diagram-generation", `${W}/diagram-generation`, 34.84, tokens(20_000, 40_000, 1_000_000, 6_000_000), { registered: false });
const mt5 = project("mt5", "nghenhan-mt5", `${NNT}/nghenhan-mt5`, 0, tokens(0, 0, 0, 0), { sessions: 1, unbilledSessions: 1 });

/** Thirty days ending 16 Sep, with the shape round 2 read: a $99.95 peak on
 * 11 Sep and three silent days before the 15th. */
function days(): UsageDay[] {
  const out: UsageDay[] = [];
  for (let i = 29; i >= 0; i--) {
    const d = new Date(2026, 8, 16 - i);
    const day = dayKey(d.getTime());
    const silent = ["2026-09-12", "2026-09-13", "2026-09-14"].includes(day);
    const cost = silent ? 0 : day === "2026-09-11" ? 99.95 : day === "2026-09-10" ? 78.96 : 30;
    const t = silent ? zero : day === "2026-09-11" ? tokens(60_000, 150_000, 2_000_000, 14_000_000) : tokens(40_000, 100_000, 1_500_000, 10_000_000);
    out.push({ day, costUSD: cost, apportionedUSD: silent ? 0 : 10, tokens: t, sessions: silent ? 0 : 4, unbilledSessions: silent ? 0 : 2, projects: [] });
  }
  return out;
}

const report: UsageDaily = {
  ok: true,
  timeZone: "Asia/Ho_Chi_Minh",
  from: "2026-08-18",
  to: "2026-09-16",
  refreshedAt: NOW - 4 * MIN,
  recordedSessions: 118,
  days: days(),
  totals: { costUSD: 1084.03, apportionedUSD: 329.67, tokens: tokens(1_400_000, 3_400_000, 48_000_000, 301_000_000), sessions: 168, unbilledSessions: 50 },
  projects: [kitterm, home, nnt, diagram, mdp, mt5],
};

const emptyReport: UsageDaily = {
  ...report,
  from: "2026-05-01",
  to: "2026-05-07",
  days: ["01", "02", "03", "04", "05", "06", "07"].map((d) => ({
    day: `2026-05-${d}`, costUSD: 0, apportionedUSD: 0, tokens: zero, sessions: 0, unbilledSessions: 0, projects: [],
  })),
  totals: { costUSD: 0, apportionedUSD: 0, tokens: zero, sessions: 0, unbilledSessions: 0 },
  projects: [],
};

describe("the usage panel", () => {
  it("draws nothing when the route did not answer", () => {
    expect(usagePanel(null, USAGE_DEFAULT, NOW)).toBeNull();
    expect(usagePanel(undefined, USAGE_DEFAULT, NOW)).toBeNull();
    expect(usagePanel({ ...report, ok: false }, USAGE_DEFAULT, NOW)).toBeNull();
  });

  it("cost: the headline is the range's total, marked as the full API rate, and the series is one dollar figure a day", () => {
    const panel = usagePanel(report, { mode: "cost", span: 30 }, NOW)!;
    expect(panel.title).toBe("Usage · last 30 days");
    expect(panel.headline).toBe("$1,084.03");
    expect(panel.qualifier).toBe("if billed at full API rate");
    expect(panel.range).toBe("18 Aug to 16 Sep");
    expect(panel.series).toHaveLength(30);
    expect(panel.days[0]).toBe("2026-08-18");
    expect(panel.days[29]).toBe("2026-09-16");
    expect(panel.series[panel.days.indexOf("2026-09-11")]).toBe(99.95);
    expect(panel.series[panel.days.indexOf("2026-09-13")]).toBe(0);
    expect(panel.peak).toEqual({ day: "2026-09-11", value: 99.95 });
    expect(panel.empty).toBe(false);
    expect(panel.modes.map((t) => [t.label, t.checked])).toEqual([["cost", true], ["tokens", false]]);
    expect(panel.spans.map((t) => [t.label, t.checked])).toEqual([["7d", false], ["30d", true], ["90d", false]]);
  });

  it("says plainly what part is apportioned across midnight and how many sessions have no bill", () => {
    const panel = usagePanel(report, { mode: "cost", span: 30 }, NOW)!;
    expect(panel.note).toBe(
      "$329.67 of it is apportioned across midnight by token share, not measured; 50 sessions have no bill yet, so their tokens are in and their dollars are not.",
    );
    expect(panel.age).toBe("rollup refreshed 4m ago");
    expect(usageNote({ ...report.totals, apportionedUSD: 0 }, "cost")).toBe("50 sessions have no bill yet, so their tokens are in and their dollars are not.");
    expect(usageNote({ ...report.totals, unbilledSessions: 1, apportionedUSD: 0 }, "cost")).toBe("1 session has no bill yet, so their tokens are in and their dollars are not.");
    expect(usageNote({ ...report.totals, apportionedUSD: 0, unbilledSessions: 0 }, "cost")).toBe("Every dollar is a session's own bill on the day it ran.");
  });

  it("tokens: the headline is every token in the range and the series counts tokens, with no dollar in sight", () => {
    const panel = usagePanel(report, { mode: "tokens", span: 30 }, NOW)!;
    expect(panel.headline).toBe("353.80M");
    expect(panel.qualifier).toBe("tokens, every kind, input and output and cache");
    expect(panel.series[panel.days.indexOf("2026-09-10")]).toBe(totalTokens(tokens(40_000, 100_000, 1_500_000, 10_000_000)));
    expect(panel.series[panel.days.indexOf("2026-09-13")]).toBe(0);
    expect(panel.peak).toEqual({ day: "2026-09-11", value: 16_210_000 });
    expect(panel.note).toBe("50 sessions have no bill yet; their tokens are counted.");
    expect(panel.note).not.toContain("$");
    expect(usageNote({ ...report.totals, unbilledSessions: 0 }, "tokens")).toBe("Every session in the range has its bill.");
    expect(panel.modes.map((t) => t.checked)).toEqual([false, true]);
  });

  it("names each span in the title and the toggles, and asks the route for that many days ending today", () => {
    for (const span of [7, 30, 90] as const) {
      for (const mode of ["cost", "tokens"] as const) {
        const panel = usagePanel(report, { mode, span }, NOW)!;
        expect(panel.title).toBe(`Usage · last ${span} days`);
        expect(panel.spans.find((t) => t.checked)!.label).toBe(`${span}d`);
        expect(panel.spans.find((t) => t.checked)!.name).toBe(`Show the last ${span} days`);
      }
    }
    expect(usageRange(7, NOW)).toEqual({ from: "2026-09-10", to: "2026-09-16" });
    expect(usageRange(30, NOW)).toEqual({ from: "2026-08-18", to: "2026-09-16" });
    expect(usageRange(90, NOW)).toEqual({ from: "2026-06-19", to: "2026-09-16" });
  });

  it("an empty range draws the axis and says so, in either mode", () => {
    const cost = usagePanel(emptyReport, { mode: "cost", span: 7 }, NOW)!;
    expect(cost.empty).toBe(true);
    expect(cost.headline).toBe("$0.00");
    expect(cost.series).toEqual([0, 0, 0, 0, 0, 0, 0]);
    expect(cost.peak).toBeNull();
    expect(cost.note).toBe("No usage recorded from 1 May to 7 May.");
    expect(usageChartName(cost)).toBe("No cost per day, 1 May to 7 May.");
    const tok = usagePanel(emptyReport, { mode: "tokens", span: 7 }, NOW)!;
    expect(tok.headline).toBe("0");
    expect(tok.empty).toBe(true);
    expect(usageChartName(tok)).toBe("No tokens per day, 1 May to 7 May.");
    // A daemon whose rollup has never refreshed says so rather than "0 ago".
    expect(usagePanel({ ...emptyReport, refreshedAt: 0 }, USAGE_DEFAULT, NOW)!.age).toBe("the rollup has not refreshed yet");
  });

  it("gives the chart one sentence for a screen reader: the range, the peak day and its amount", () => {
    expect(usageChartName(usagePanel(report, { mode: "cost", span: 30 }, NOW)!)).toBe(
      "Cost per day, 18 Aug to 16 Sep; the most on 11 Sep, $99.95.",
    );
    expect(usageChartName(usagePanel(report, { mode: "tokens", span: 30 }, NOW)!)).toBe(
      "Tokens per day, 18 Aug to 16 Sep; the most on 11 Sep, 16.21M.",
    );
  });

  it("reads the choice back from storage and falls back to the default for anything else", () => {
    expect(readUsageChoice(null)).toEqual({ mode: "cost", span: 30 });
    expect(readUsageChoice('{"mode":"tokens","span":90}')).toEqual({ mode: "tokens", span: 90 });
    expect(readUsageChoice('{"mode":"euros","span":400}')).toEqual({ mode: "cost", span: 30 });
    expect(readUsageChoice("not json")).toEqual({ mode: "cost", span: 30 });
    expect(readUsageChoice('{"span":7}')).toEqual({ mode: "cost", span: 7 });
  });
});

describe("the numbers on the headings", () => {
  it("prints a project's dollars and cache share from the bucket at its root", () => {
    // 260M read of 301.2M in: input, cache creation and cache read together.
    expect(costLabel(projectUsage(report, `${W}/kitterm`))).toBe("$850.51 · 86% cached");
    expect(costLabel(projectUsage(report, `${W}/kitterm/`))).toBe("$850.51 · 86% cached");
    expect(costLabel(projectUsage(report, `${NNT}/market-data-pipeline`))).toBe("$13.35 · 85% cached");
  });

  it("prints $0.00 for a project the report does not name and no share for one with no input", () => {
    expect(projectUsage(report, `${NNT}/trading-data-api`)).toBeNull();
    expect(costLabel(null)).toBe("$0.00");
    expect(costLabel(projectUsage(report, `${NNT}/nghenhan-mt5`))).toBe("$0.00");
    expect(projectUsage(null, `${W}/kitterm`)).toBeNull();
    expect(projectUsage(report, undefined)).toBeNull();
  });

  it("sums a workspace from the projects under its directory and the sessions in the directory itself", () => {
    const sum = workspaceUsage(report, NNT, [NNT])!;
    expect(sum.costUSD).toBeCloseTo(68.43 + 13.35, 2);
    expect(sum.sessions).toBe(nnt.sessions + mdp.sessions + mt5.sessions);
    expect(sum.unbilledSessions).toBe(1);
    // 15M read of 17.56M in over the three buckets.
    expect(costLabel(sum)).toBe("$81.78 · 85% cached");
    // A workspace that holds `Workspace/kitterm` and the discovered
    // `diagram-generation`, were it headed, would take both and not the
    // deeper workspace's projects.
    const ws = workspaceUsage(report, W, [W, NNT])!;
    expect(ws.costUSD).toBeCloseTo(850.51 + 34.84, 2);
    expect(workspaceUsage(report, "/elsewhere", ["/elsewhere"])).toBeNull();
    expect(workspaceUsage(null, NNT, [NNT])).toBeNull();
  });

  it("shares and formats", () => {
    expect(cacheShare(90, 100)).toBe(0.9);
    expect(cacheShare(0, 0)).toBeNull();
    expect(cachedLabel(0.914)).toBe("91% cached");
    expect(cachedLabel(null)).toBeNull();
    expect(dollars(1084.03)).toBe("$1,084.03");
    expect(dollars(0)).toBe("$0.00");
    expect(dollars(1234567.891)).toBe("$1,234,567.89");
    expect(dollars(2.6)).toBe("$2.60");
    expect(tokenCount(0)).toBe("0");
    expect(tokenCount(999)).toBe("999");
    expect(tokenCount(17_700)).toBe("17.7k");
    expect(tokenCount(1_100_000)).toBe("1.10M");
    expect(tokenCount(2_310_000_000)).toBe("2.31B");
    expect(dayLabel("2026-09-16")).toBe("16 Sep");
    expect(dayLabel("2026-01-01")).toBe("1 Jan");
    expect(dayLabel("today")).toBe("today");
    expect(dayKey(new Date(2026, 0, 5).getTime())).toBe("2026-01-05");
  });
});

describe("the number on a goal", () => {
  it("prints the records' summed Cost lines with the cache share, and nothing for a goal without one", () => {
    expect(goalCost({ costUSD: 12.34, inTokens: 4_432_000, cacheReadTokens: 3_900_000 })).toBe("$12.34 · 88% cached");
    expect(goalCost({ costUSD: 0.41, inTokens: 0, cacheReadTokens: 0 })).toBe("$0.41");
    expect(goalCost({ costUSD: 7.79 })).toBe("$7.79");
    expect(goalCost({})).toBeNull();
    expect(goalCost({ inTokens: 100 })).toBeNull();
  });
});

// The bucket type is what the two heading lookups return; a project bucket
// is one, so the sum's shape is the route's own.
const _shape: UsageBucket = kitterm;
void _shape;
