import { describe, expect, it } from "vitest";

import {
  attention,
  band,
  bandQuota,
  bandQuotaNoun,
  bandSpend,
  needsNoun,
  NEEDS_YOU_ID,
  proposedItems,
  USAGE_DEFAULT,
  withProposed,
  workingCount,
  type Approval,
  type KnowledgeSummary,
  type MergedState,
  type ModelRow,
  type UsageDaily,
  type UsageLimits,
} from "./sessions-model";

/**
 * The band (`agent-dashboard`, capability 4; `design-foundation.md`, The
 * frame): one row of four counts, in one order, whatever the fleet is
 * doing. The tests below drive it with an empty fleet, a fleet where
 * nothing needs a person, and 0, 4 and 20 items needing one, and pin
 * that the shape is the same every time: four cells, the same keys, the
 * same nouns, only the counts moving. The height itself is pinned in
 * `sessions-css.test.ts` and measured in the round's live check.
 */

const NOW = 1_758_000_000_000;
const kitterm = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true };

function state(id: string, mergedState: MergedState, extra: Partial<ModelRow> = {}): ModelRow {
  return { id, cwd: "/w/kitterm", project: kitterm, mergedState, ...extra };
}

function approval(id: string, session: string | undefined): Approval {
  return { id, tool: "Bash", input: "{}", session, waitingMs: 1000 };
}

const report: UsageDaily = {
  ok: true,
  timeZone: "UTC",
  from: "2026-08-20",
  to: "2026-09-18",
  refreshedAt: NOW,
  recordedSessions: 3,
  days: [],
  totals: { costUSD: 2316.45, apportionedUSD: 0, tokens: { input: 1, output: 1, cacheCreation: 0, cacheRead: 0, requests: 1 }, sessions: 3, unbilledSessions: 0 },
  projects: [],
};

const limits: UsageLimits = {
  ok: true,
  hasReading: true,
  receivedAt: NOW - 60_000,
  ageSeconds: 60,
  stale: false,
  rateLimits: {
    five_hour: { used_percentage: 19, resets_at: (NOW + 3_600_000) / 1000 },
    seven_day: { used_percentage: 42.4, resets_at: (NOW + 86_400_000) / 1000 },
  },
};

/** Everything that needs a person, the band's item list. */
function items(rows: ModelRow[], approvals: Approval[], goals: KnowledgeSummary[] = []) {
  return withProposed(attention(rows, approvals), proposedItems(goals.map((summary) => ({ project: kitterm, summary }))));
}

describe("band", () => {
  const fleet = [
    state("a", "working"),
    state("b", "working"),
    state("c", "needs-input"),
    state("d", "failed", { lastExit: 1 }),
    state("e", "needs-approval"),
    state("f", "idle"),
    state("g", "completed"),
  ];
  const proposing: KnowledgeSummary = { project: "kitterm", slug: "agent-dashboard", status: "active", proposals: 2, lastRound: 3 };

  it("prints the four counts: working, need you, spend over the range, quota used", () => {
    // Round 10 (the frame `Dashboard 1200`): the spend in whole dollars,
    // and the session window with its countdown, `19% quota · 1h`; the
    // working count wears the accent and the need-you count the amber.
    const out = band(fleet, items(fleet, [approval("ap", "e")], [proposing]), report, USAGE_DEFAULT, limits, NOW);
    expect(out.cells.map((cell) => [cell.key, cell.value, cell.noun])).toEqual([
      ["working", "2", "working"],
      // The approval, the waiting row, the failed row and the proposal.
      ["needs", "4", "need you"],
      ["spend", "$2,316", "30d"],
      // The session window, rounded like its bar, and when it resets.
      ["quota", "19%", "quota · 1h"],
    ]);
    expect(out.cells.map((cell) => cell.family ?? null)).toEqual(["running", "attention", null, null]);
    expect(out.needs).toBe(4);
    expect(out.target).toBe(NEEDS_YOU_ID);
  });

  it("counts a failed session as needing a person, so the first screen still shows what broke", () => {
    const rows = [state("d", "failed", { lastExit: 1 }), state("f", "idle")];
    const out = band(rows, items(rows, []), report, USAGE_DEFAULT, limits, NOW);
    expect(out.cells[1]).toMatchObject({ value: "1", noun: "needs you" });
    expect(out.target).toBe(NEEDS_YOU_ID);
  });

  it("still has four cells for an empty fleet, with a dash where the page has no source", () => {
    const out = band([], items([], []), null, USAGE_DEFAULT, null, NOW);
    expect(out.cells.map((cell) => [cell.key, cell.value, cell.noun])).toEqual([
      ["working", "0", "working"],
      ["needs", "0", "need you"],
      ["spend", "–", "spend"],
      ["quota", "–", "quota"],
    ]);
    // Round 20 (the first-run frame): a count of zero carries no state,
    // so it is no mark; it wears the fact colour.
    expect(out.cells.map((cell) => cell.family ?? null)).toEqual([null, null, null, null]);
    expect(out.cells.map((cell) => cell.muted ?? null)).toEqual([true, true, null, null]);
    expect(out.target).toBeNull();
  });

  it("links nothing when nothing needs a person, and the count still prints", () => {
    const rows = [state("a", "working"), state("f", "idle"), state("g", "completed")];
    const out = band(rows, items(rows, []), report, USAGE_DEFAULT, limits, NOW);
    expect(out.cells[0]).toMatchObject({ value: "1", noun: "working" });
    expect(out.cells[1]).toMatchObject({ value: "0", noun: "need you" });
    expect(out.needs).toBe(0);
    expect(out.target).toBeNull();
  });

  it("keeps the same shape with 0, 4 and 20 items needing a person: four cells, the same keys and nouns", () => {
    const shapes = [0, 4, 20].map((n) => {
      const approvals = Array.from({ length: n }, (_, i) => approval(`ap-${i}`, undefined));
      const out = band(fleet.filter((row) => row.mergedState === "working"), items([], approvals), report, USAGE_DEFAULT, limits, NOW);
      expect(out.cells[1].value).toBe(String(n));
      return out.cells.map((cell) => `${cell.key}:${cell.noun}`);
    });
    expect(shapes[0]).toEqual(["working:working", "needs:need you", "spend:30d", "quota:quota · 1h"]);
    expect(shapes[1]).toEqual(shapes[0]);
    expect(shapes[2]).toEqual(shapes[0]);
    // A cell is a count and its noun: no list grows with the fleet.
    expect(band([], items([], []), report, USAGE_DEFAULT, limits, NOW).cells).toHaveLength(4);
  });
});

describe("the band's cells", () => {
  it("counts the working rows, whatever else the fleet holds", () => {
    expect(workingCount([])).toBe(0);
    expect(workingCount([state("a", "working"), state("b", "idle"), { id: "c", cwd: "/w", state: "running" }])).toBe(2);
  });

  it("says needs you for one item and need you otherwise", () => {
    expect(needsNoun(0)).toBe("need you");
    expect(needsNoun(1)).toBe("needs you");
    expect(needsNoun(4)).toBe("need you");
  });

  it("prints the range's total in whole dollars with the span, or a dash without a rollup", () => {
    // Round 10: `$2,316 30d`; the cents are on the USAGE headline.
    expect(bandSpend(report, { mode: "tokens", span: 7 })).toMatchObject({ value: "$2,316", noun: "7d" });
    expect(bandSpend(report, USAGE_DEFAULT).title).toContain("$2,316.45");
    expect(bandSpend(null, USAGE_DEFAULT)).toMatchObject({ value: "–", noun: "spend" });
    expect(bandSpend({ ...report, ok: false }, USAGE_DEFAULT)).toMatchObject({ value: "–", noun: "spend" });
  });

  it("reads the session window while it stands, else the most-used window that has not reset, with its countdown", () => {
    // Round 10: the frame's band reads the session window, `19% quota ·
    // 3h 16m`, beside a weekly at 36%: the short window is the one that
    // decides whether work can start now.
    expect(bandQuota(limits, NOW)).toMatchObject({ value: "19%", noun: "quota · 1h" });
    const sessionGone: UsageLimits = { ...limits, rateLimits: { ...limits.rateLimits, five_hour: { used_percentage: 99, resets_at: (NOW - 1000) / 1000 } } };
    expect(bandQuota(sessionGone, NOW), "the session window has reset: the weekly stands").toMatchObject({ value: "42%", noun: "quota · 1d" });
    const noSession: UsageLimits = { ...limits, rateLimits: { seven_day: limits.rateLimits!.seven_day, spend_limit: { used_percentage: 60, resets_at: (NOW + 86_400_000 * 20) / 1000 } } };
    expect(bandQuota(noSession, NOW), "no session window: the most-used").toMatchObject({ value: "60%", noun: "quota · 20d" });
    expect(bandQuota({ ...limits, stale: true }, NOW).title).toContain("stale");
    expect(bandQuotaNoun("3h 16m")).toBe("quota · 3h 16m");
  });

  it("prints a dash with no reading, no window, or every window reset", () => {
    expect(bandQuota(null, NOW)).toMatchObject({ value: "–", noun: "quota" });
    expect(bandQuota({ ok: true, hasReading: false }, NOW)).toMatchObject({ value: "–", noun: "quota" });
    expect(bandQuota({ ok: true, hasReading: true, receivedAt: NOW, rateLimits: {} }, NOW)).toMatchObject({ value: "–", noun: "quota" });
    const gone: UsageLimits = { ok: true, hasReading: true, receivedAt: NOW, rateLimits: { five_hour: { used_percentage: 50, resets_at: (NOW - 1) / 1000 } } };
    expect(bandQuota(gone, NOW)).toMatchObject({ value: "–", noun: "quota" });
  });
});
