import { describe, expect, it } from "vitest";

import { type UsageDaily, type UsageModel, type UsageTokens } from "./sessions-model";
import { MODELS_NAMED, modelsPanel } from "./sessions-value";

/**
 * The `MODELS` panel names the top three models by cost and sums the rest
 * into one row (`agent-dashboard`, round 8). The fleet this was built on
 * runs seven models, and the tail is noise: Haiku 4.5 is $2.72 over 140
 * sessions beside Fable 5.1 at $1,388.50. The rules under test: the
 * summed row is a real row with a name that says how many it covers, its
 * spend is the split's total less the named rows, fewer than five models
 * print every name and no summed row, every bar is scaled to the longest
 * row with the summed row included, and a tail that sums past the leader
 * is the first row.
 */

const tokens: UsageTokens = { input: 1, output: 1, cacheCreation: 0, cacheRead: 1, requests: 1 };

const model = (id: string, name: string, costUSD: number, sessions: number): UsageModel => ({
  model: id,
  name,
  costUSD,
  apportionedUSD: 0,
  inputTokens: 1,
  outputTokens: 1,
  cacheReadInputTokens: 1,
  cacheCreationInputTokens: 0,
  sessions,
});

/** Thirty days on the machine this was built on: seven models, the
 * dearest first, the way the daemon sends them. */
const seven: UsageModel[] = [
  model("claude-fable-5-1", "Fable 5.1", 1388.5, 109),
  model("claude-opus-5[1m]", "Opus 5 · 1M", 404.43, 12),
  model("claude-fable-5-1[1m]", "Fable 5.1 · 1M", 343.25, 9),
  model("claude-opus-5", "Opus 5", 70.39, 6),
  model("claude-fable-5", "Fable 5", 30.1, 4),
  model("claude-opus-4-8", "Opus 4.8", 8, 2),
  model("claude-haiku-4-5-20251001", "Haiku 4.5", 2.72, 140),
];

function report(models: UsageModel[]): UsageDaily {
  const costUSD = models.reduce((sum, m) => sum + m.costUSD, 0);
  const sessions = models.reduce((sum, m) => sum + m.sessions, 0);
  return {
    ok: true,
    timeZone: "UTC",
    from: "2026-08-20",
    to: "2026-09-18",
    refreshedAt: 1,
    recordedSessions: sessions,
    days: [],
    totals: { costUSD, apportionedUSD: 0, unsplitUSD: 0, tokens, sessions, unbilledSessions: 0 },
    models,
    projects: [],
  };
}

const shape = (models: UsageModel[]) => modelsPanel(report(models))!.rows.map((r) => [r.name, r.spend, r.sessions, r.fill]);

describe("MODELS names the top three and sums the rest", () => {
  it("names three", () => {
    expect(MODELS_NAMED).toBe(3);
  });

  it("seven models are four rows: the top three by cost, then one row that says how many it sums", () => {
    const panel = modelsPanel(report(seven))!;
    expect(panel.rows.map((r) => r.name)).toEqual(["Fable 5.1", "Opus 5 · 1M", "Fable 5.1 · 1M", "4 more models"]);
    const more = panel.rows[3];
    // 70.39 + 30.10 + 8.00 + 2.72, which is the split's total less the three named rows.
    expect(more.spend).toBe("$111.21");
    expect(more.sessions, "the sum of its models' session counts").toBe("152 sessions");
    expect(more.key).toBe("more");
    expect(more.title).toBe("$111.21 over 152 sessions: Opus 5 $70.39, Fable 5 $30.10, Opus 4.8 $8.00, Haiku 4.5 $2.72");
    expect(more.fill, "measured against the same longest row as the three above it").toBeCloseTo(111.21 / 1388.5, 10);
    expect(panel.rows.map((r) => r.fill)).toEqual([1, 404.43 / 1388.5, 343.25 / 1388.5, more.fill]);
  });

  it("the summed row's spend is the split's total less the top three, to the cent", () => {
    const panel = modelsPanel(report(seven))!;
    const total = report(seven).totals.costUSD;
    const named = seven.slice(0, 3).reduce((sum, m) => sum + m.costUSD, 0);
    expect(panel.rows[3].spend).toBe(`$${(total - named).toFixed(2)}`);
  });

  it("picks the top three by cost when the daemon's order is not dearest first", () => {
    const shuffled = [seven[6], seven[3], seven[0], seven[5], seven[2], seven[1], seven[4]];
    expect(shape(shuffled)).toEqual(shape(seven));
  });

  it("exactly four models print four names and no summed row: a summary of one hides a name for the same height", () => {
    const four = seven.slice(0, 4);
    expect(shape(four)).toEqual([
      ["Fable 5.1", "$1,388.50", "109 sessions", 1],
      ["Opus 5 · 1M", "$404.43", "12 sessions", 404.43 / 1388.5],
      ["Fable 5.1 · 1M", "$343.25", "9 sessions", 343.25 / 1388.5],
      ["Opus 5", "$70.39", "6 sessions", 70.39 / 1388.5],
    ]);
    expect(modelsPanel(report(four))!.rows.some((r) => r.key === "more")).toBe(false);
  });

  it("five models are the first case that sums, and the summed row then covers two", () => {
    expect(modelsPanel(report(seven.slice(0, 5)))!.rows.map((r) => r.name)).toEqual(["Fable 5.1", "Opus 5 · 1M", "Fable 5.1 · 1M", "2 more models"]);
  });

  it("three, two and one model print that many rows, every one named, and no fourth row", () => {
    expect(shape(seven.slice(0, 3)).map((r) => r[0])).toEqual(["Fable 5.1", "Opus 5 · 1M", "Fable 5.1 · 1M"]);
    expect(shape(seven.slice(0, 2)).map((r) => r[0])).toEqual(["Fable 5.1", "Opus 5 · 1M"]);
    expect(shape(seven.slice(0, 1))).toEqual([["Fable 5.1", "$1,388.50", "109 sessions", 1]]);
    for (const n of [1, 2, 3]) {
      const rows = modelsPanel(report(seven.slice(0, n)))!.rows;
      expect(rows, `${n} models`).toHaveLength(n);
      expect(rows.some((r) => r.key === "more" || /more model/.test(r.name)), `${n} models: no summed row`).toBe(false);
    }
  });

  it("no model draws nothing", () => {
    expect(modelsPanel(report([]))).toBeNull();
  });

  it("a tail that sums past the leader is the first row and the longest bar; no bar is longer than the first", () => {
    const models = [
      model("a", "A", 100, 1),
      model("b", "B", 90, 1),
      model("c", "C", 80, 1),
      model("d", "D", 60, 2),
      model("e", "E", 60, 2),
      model("f", "F", 60, 2),
      model("g", "G", 60, 2),
    ];
    const panel = modelsPanel(report(models))!;
    expect(panel.rows.map((r) => [r.name, r.spend, r.sessions, r.fill])).toEqual([
      ["4 more models", "$240.00", "8 sessions", 1],
      ["A", "$100.00", "1 session", 100 / 240],
      ["B", "$90.00", "1 session", 90 / 240],
      ["C", "$80.00", "1 session", 80 / 240],
    ]);
    expect(panel.rows.every((r) => r.fill <= panel.rows[0].fill)).toBe(true);
    expect(panel.summary, "the phone's one line still names the dearest model, never the sum").toBe("by model · A $100.00");
  });

  it("the phone's one line is unchanged: the dearest model and its spend", () => {
    expect(modelsPanel(report(seven))!.summary).toBe("by model · Fable 5.1 $1,388.50");
  });
});
