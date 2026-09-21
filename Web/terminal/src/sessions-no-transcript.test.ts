import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import {
  LEAKS_NO_TRANSCRIPT_LINE,
  MODELS_NO_TRANSCRIPT_LINE,
  USAGE_NO_TRANSCRIPT_NOTE,
  VALUE_REGISTER_NOTE,
  WHERE_REGISTER_NOTE,
  leakLines,
  modelsPanel,
  noSessionInRange,
  usageFootnote,
  usageHead,
  valuePanel,
  wherePanel,
} from "./sessions-value";
import { band, USAGE_DEFAULT, type UsageDaily } from "./sessions-model";

/**
 * The first run with no transcript (`agent-dashboard` round 21, the frame
 * `Dashboard 1200 · first run, no transcripts`): the daemon found no
 * Claude Code transcript at all, so the range's rollup holds no session,
 * and no project, no session and no reading either. Six lines change
 * from round 20's first run: the band prints `$0 30d`; `USAGE` prints
 * `$0.00` alone over an empty chart with one note in place of the
 * apportioned one; `MODELS` and `LEAKS` print one sentence each; the
 * hours tile is a dash like the other three; `WHERE` has no row. The
 * same page then reads a rollup with one session and no project and
 * shows round 20's first run unchanged, and a rollup with a project and
 * shows today's page unchanged.
 */

const NOW = 1_758_400_000_000;
const zero = { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 };
const days = Array.from({ length: 30 }, (_, i) => {
  const d = new Date(Date.UTC(2026, 7, 23 + i));
  return { day: d.toISOString().slice(0, 10), costUSD: 0, apportionedUSD: 0, tokens: zero, sessions: 0, unbilledSessions: 0, models: [], projects: [] };
});
/** The rollup on a machine with no transcript: every day zero, no
 * session, no model, no project. */
const emptyRollup: UsageDaily = {
  ok: true, timeZone: "UTC", from: "2026-08-23", to: "2026-09-21", refreshedAt: NOW - 60_000, recordedSessions: 0, days,
  totals: { costUSD: 0, apportionedUSD: 0, unsplitUSD: 0, tokens: zero, sessions: 0, unbilledSessions: 0, apiMs: 0, measuredUSD: 0 },
  models: [], projects: [],
  roles: [
    { role: "root", costUSD: 0, apportionedUSD: 0, sessions: 0, apiMs: 0, measuredUSD: 0, linesAdded: 0 },
    { role: "crew", costUSD: 0, apportionedUSD: 0, sessions: 0, apiMs: 0, measuredUSD: 0, linesAdded: 0 },
  ],
  lowCache: [],
};
const tokens = { input: 10_000, output: 3_000, cacheCreation: 50_000, cacheRead: 7_293_000, requests: 40 };
const fable = { model: "claude-fable-5-1", name: "Fable 5.1", costUSD: 6.41, apportionedUSD: 0, inputTokens: 10_000, outputTokens: 3_000, cacheReadInputTokens: 7_293_000, cacheCreationInputTokens: 50_000, sessions: 1 };
/** The rollup after one session, in a directory no project holds: round
 * 20's first run. */
const oneSession: UsageDaily = {
  ...emptyRollup,
  recordedSessions: 1,
  days: days.map((d, i) => (i === 29 ? { ...d, costUSD: 6.41, tokens, sessions: 1, models: [fable] } : d)),
  totals: { costUSD: 6.41, apportionedUSD: 0, unsplitUSD: 0, tokens, sessions: 1, unbilledSessions: 0, apiMs: 0.2 * 3_600_000, measuredUSD: 6.41 },
  models: [fable],
  roles: [{ role: "root", costUSD: 6.41, apportionedUSD: 0, sessions: 1, apiMs: 0.2 * 3_600_000, measuredUSD: 6.41, linesAdded: 12 }],
};
const kitterm = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, knowledge: "docs/goals" };
/** The rollup with a registered project: today's page. */
const withProject: UsageDaily = {
  ...oneSession,
  projects: [{ ...kitterm, costUSD: 6.41, apportionedUSD: 0, tokens, sessions: 1, unbilledSessions: 0 }],
};
const emptyYield = { ok: true, from: "2026-08-23", to: "2026-09-21", projects: [], totals: { checkouts: 0, counted: 0, mergedPullRequests: 0, mergedLines: 0, releases: 0 } };
const projectYield = {
  ok: true, from: "2026-08-23", to: "2026-09-21",
  projects: [{ ...kitterm, yield: { checkout: true, remote: true, branch: "origin/main", mergedPullRequests: 2, mergedLines: 400, releases: 1 } }],
  totals: { checkouts: 1, counted: 1, mergedPullRequests: 2, mergedLines: 400, releases: 1 },
};
const range = { from: "2026-08-23", to: "2026-09-21" };

let rollup: UsageDaily = emptyRollup;
const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/daily": () => rollup,
  "/api/yield": emptyYield,
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;

beforeAll(async () => {
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  await import("./sessions");
  await page.settle();
});

const panelNamed = (name: string) => page.root.querySelectorAll(".panel").find((p) => p.classList.contains(name))!;
const bandCells = () => page.root.querySelectorAll(".band-cell").map((cell) => `${cell.querySelector(".band-value")?.textContent} ${cell.querySelector(".band-noun")?.textContent}`);
const usageFacts = () => panelNamed("usage").querySelectorAll(".usage-fact").map((f) => f.textContent);
const usageNote = () => panelNamed("usage").querySelector(".usage-note");
const tiles = () => panelNamed("value").querySelectorAll(".yield-tile").map((t) => [t.querySelector(".yield-count")?.textContent, t.querySelector(".yield-rate")?.textContent]);
const noteOf = (panel: FakeElement) => panel.querySelector(".panel-note")!;
const whereRows = () => panelNamed("where").querySelectorAll(".split-row").map((row) => row.querySelector(".split-name")?.textContent);
const modelRows = () => panelNamed("models").querySelectorAll(".split-name").map((n) => n.textContent);
/** A click on a range toggle asks the usage route again at once; the
 * safety poll alone waits 30 s between asks. */
const toggle = (label: string) => page.root.querySelectorAll(".usage-toggle").find((b) => b.textContent === label)!;
const leakTexts = () => panelNamed("leaks").querySelectorAll(".leak-text").map((l) => l.textContent);

describe("no transcript at all: the range's rollup holds no session", () => {
  it("1. the band prints $0 30d, with the zero counts in the fact colour and no quota", () => {
    expect(bandCells()).toEqual(["0 working", "0 need you", "$0 30d", "– quota"]);
    expect(page.root.querySelectorAll('[id="needs-you"]')).toEqual([]);
  });

  it("2. USAGE prints $0.00 alone, an empty chart on its baseline with the date axis and no peak caption, and the no-transcript note", () => {
    const usage = panelNamed("usage");
    expect(usage.querySelector(".usage-amount")?.textContent).toBe("$0.00");
    expect(usageFacts()).toEqual([]);
    // The chart is an SVG the fake page keeps by tag; its class is an
    // attribute.
    const chart = usage.querySelector("svg")!;
    expect(chart.getAttribute("class")).toBe("usage-chart");
    expect(chart.querySelectorAll("rect")).toEqual([]);
    expect(chart.getAttribute("aria-label")).toBe("No cost per day, 23 Aug to 21 Sep.");
    const axis = usage.querySelector(".usage-axis")!;
    expect(axis.querySelector(".usage-from")?.textContent).toBe("23 Aug");
    expect(axis.querySelector(".usage-to")?.textContent).toBe("21 Sep");
    expect(axis.querySelectorAll(".usage-peak")).toEqual([]);
    const note = usageNote()!;
    expect(note.textContent).toBe(USAGE_NO_TRANSCRIPT_NOTE);
    expect(note.textContent).toBe("No Claude Code transcript yet. Open a session in a shell here; its transcript fills this chart.");
    expect(note.textContent).not.toContain("apportioned");
    // The sentence wraps, and prints on a phone where the apportioned note
    // is dropped.
    expect(note.classList.contains("wraps")).toBe(true);
    // The toggles stay: the reader can still pick a range.
    expect(usage.querySelectorAll(".usage-toggle").map((b) => b.textContent)).toEqual(["cost", "tokens", "7d", "30d", "90d"]);
  });

  it("3. MODELS prints one sentence in its content cell and no row", () => {
    const models = panelNamed("models");
    expect(models.hidden).toBe(false);
    expect(models.querySelector(".panel-label")?.textContent).toBe("MODELS");
    expect(modelRows()).toEqual([]);
    expect(models.querySelector(".panel-sentence")?.textContent).toBe(MODELS_NO_TRANSCRIPT_LINE);
    expect(models.querySelector(".panel-sentence")?.textContent).toBe("Models appear once a session has run.");
  });

  it("4. VALUE prints a dash on every tile, the hours included, and the register command", () => {
    expect(tiles()).toEqual([["–", "–"], ["–", "–"], ["–", "–"], ["–", "–"]]);
    const note = noteOf(panelNamed("value"));
    expect(note.querySelector(".note-long")?.textContent).toBe(VALUE_REGISTER_NOTE);
    expect(note.querySelector(".note-command")?.textContent).toBe("kitterm project add <path>");
  });

  it("5. WHERE keeps the selector, has no row, and names the init command", () => {
    const where = panelNamed("where");
    expect(where.querySelectorAll(".panel-toggle").map((b) => [b.textContent, b.getAttribute("aria-checked")])).toEqual([
      ["project", "false"], ["goal", "true"], ["task", "false"], ["role", "false"],
    ]);
    expect(whereRows()).toEqual([]);
    const note = noteOf(where);
    expect(note.querySelector(".note-long")?.textContent).toBe(WHERE_REGISTER_NOTE);
    expect(note.querySelector(".note-command")?.textContent).toBe("kitterm project init <path>");
  });

  it("6. LEAKS prints one sentence and no marked line", () => {
    const leaks = panelNamed("leaks");
    expect(leaks.hidden).toBe(false);
    expect(leakTexts()).toEqual([]);
    expect(leaks.querySelectorAll(".mark")).toEqual([]);
    expect(leaks.querySelector(".panel-sentence")?.textContent).toBe(LEAKS_NO_TRANSCRIPT_LINE);
    expect(leaks.querySelector(".panel-sentence")?.textContent).toBe("No spend to attribute yet.");
  });

  it("the rest is round 20's first run: the quota sentence, the empty tree, the push switch", () => {
    expect(panelNamed("quota").textContent).toContain("No quota reading yet");
    expect(page.root.querySelector(".tree")!.querySelector(".empty")?.textContent).toBe("No live sessions. Open a shell at / to start one.");
    expect(page.root.querySelector(".folds")!.textContent).toContain("Notify this device");
  });
});

describe("one session and no project: round 20's first run, unchanged", () => {
  beforeAll(async () => {
    rollup = oneSession;
    toggle("7d").click();
    await page.settle();
  });

  it("the band, USAGE, MODELS, VALUE, WHERE and LEAKS print as round 20 does", () => {
    expect(bandCells()).toEqual(["0 working", "0 need you", "$6 7d", "– quota"]);
    expect(panelNamed("usage").querySelector(".usage-amount")?.textContent).toBe("$6.41");
    expect(usageFacts()).toEqual(["7.36M tokens", "0.2 h model time"]);
    // Nothing apportioned: no note, as before.
    expect(usageNote()).toBeNull();
    expect(panelNamed("usage").querySelectorAll("rect")).toHaveLength(1);
    expect(panelNamed("usage").querySelector(".usage-peak")?.textContent).toBe("most $6.41 on 21 Sep");
    expect(modelRows()).toEqual(["Fable 5.1"]);
    expect(panelNamed("models").querySelectorAll(".panel-sentence")).toEqual([]);
    expect(tiles()).toEqual([["–", "–"], ["–", "–"], ["–", "–"], ["0.2", "$32 an hour"]]);
    expect(noteOf(panelNamed("value")).querySelector(".note-command")?.textContent).toBe("kitterm project add <path>");
    expect(whereRows()).toEqual(["no round record"]);
    expect(noteOf(panelNamed("where")).querySelector(".note-command")?.textContent).toBe("kitterm project init <path>");
    expect(leakTexts()).toEqual(["no session under 95% cached"]);
    expect(panelNamed("leaks").querySelectorAll(".panel-sentence")).toEqual([]);
  });
});

describe("a registered project: today's page, unchanged", () => {
  beforeAll(async () => {
    rollup = withProject;
    routes["/api/projects"] = { projects: [kitterm] };
    routes["/api/yield"] = projectYield;
    await page.poll();
    toggle("30d").click();
    await page.settle();
  });

  it("VALUE names the scope, WHERE and LEAKS print their rows, and no first-run line is on the page", () => {
    expect(bandCells()).toEqual(["0 working", "0 need you", "$6 30d", "– quota"]);
    expect(tiles()).toEqual([["2", "$3.21 each"], ["400", "$0.016 each"], ["1", "$6.41 each"], ["0.2", "$32 an hour"]]);
    expect(noteOf(panelNamed("value")).querySelector(".note-long")?.textContent).toBe("kitterm, 30 days. Proxies for value, not value.");
    expect(noteOf(panelNamed("value")).querySelectorAll(".note-command")).toEqual([]);
    expect(whereRows()).toEqual(["no round record"]);
    expect(noteOf(panelNamed("where")).querySelector(".note-long")?.textContent).toBe("100% names no round, so it cannot be valued");
    expect(modelRows()).toEqual(["Fable 5.1"]);
    expect(leakTexts()).toEqual(["no session under 95% cached"]);
    expect(page.root.querySelectorAll(".panel-sentence")).toEqual([]);
    expect(page.root.textContent).not.toContain("transcript yet");
  });
});

describe("the decision, in the model", () => {
  it("is one predicate: the rollup answered and counts no session in the range", () => {
    expect(noSessionInRange(emptyRollup)).toBe(true);
    expect(noSessionInRange(oneSession)).toBe(false);
    expect(noSessionInRange(withProject)).toBe(false);
    // A rollup not yet read, or a route that failed, decides nothing.
    expect(noSessionInRange(null)).toBe(false);
    expect(noSessionInRange(undefined)).toBe(false);
    expect(noSessionInRange({ ...emptyRollup, ok: false })).toBe(false);
  });

  it("USAGE: the head keeps the amount and drops its facts in either mode; the footnote is the sentence in either mode", () => {
    expect(usageHead(emptyRollup, { mode: "cost", span: 30 })).toMatchObject({ amount: "$0.00", facts: [], span: "30 days" });
    expect(usageHead(emptyRollup, { mode: "tokens", span: 7 })).toMatchObject({ amount: "0", facts: [], span: "7 days" });
    expect(usageFootnote(emptyRollup, "cost")).toBe(USAGE_NO_TRANSCRIPT_NOTE);
    expect(usageFootnote(emptyRollup, "tokens")).toBe(USAGE_NO_TRANSCRIPT_NOTE);
    // With a session the footnote is the apportioned note, or nothing.
    expect(usageFootnote(oneSession, "cost")).toBeNull();
    expect(usageFootnote({ ...oneSession, totals: { ...oneSession.totals, apportionedUSD: 1.5 } }, "cost")).toBe("$1.50 apportioned across midnight");
    expect(usageFootnote(null, "cost")).toBeNull();
    expect(usageHead(oneSession, USAGE_DEFAULT)!.facts).toEqual(["7.36M tokens", "0.2 h model time"]);
  });

  it("VALUE: the hours tile is a dash with no session, even when the rollup carries a duration beside its zero", () => {
    const odd = { ...emptyRollup, totals: { ...emptyRollup.totals, apiMs: 3_600_000, measuredUSD: 5 } };
    expect(valuePanel(odd, emptyYield, 30)!.tiles.map((t) => [t.count, t.rate])).toEqual([["–", "–"], ["–", "–"], ["–", "–"], ["–", "–"]]);
    expect(valuePanel(oneSession, emptyYield, 30)!.tiles[3]).toMatchObject({ count: "0.2", rate: "$32 an hour" });
  });

  it("the pure panels keep their own answers for an empty rollup: the page makes the choice", () => {
    expect(modelsPanel(emptyRollup)).toBeNull();
    expect(leakLines(emptyRollup, [], range).map((l) => l.text)).toEqual(["no session under 95% cached"]);
    expect(wherePanel("goal", { report: emptyRollup, yield: emptyYield, projects: [], goals: [], range })!.rows).toEqual([]);
    expect(band([], [], emptyRollup, USAGE_DEFAULT, null, NOW).cells[2]).toMatchObject({ value: "$0", noun: "30d" });
  });
});
