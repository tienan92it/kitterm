import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { VALUE_REGISTER_COMMAND, VALUE_REGISTER_NOTE, WHERE_REGISTER_COMMAND, WHERE_REGISTER_NOTE, valuePanel, wherePanel } from "./sessions-value";
import { band } from "./sessions-model";
import { USAGE_DEFAULT } from "./sessions-model";

/**
 * The first run (`agent-dashboard` round 20, the frame `Dashboard 1200 ·
 * first run`): the daemon knows no project, no session and no quota
 * reading, while transcripts exist, so the rollup has a total. The page
 * keeps its frame (principle 2) and each empty panel carries one line
 * that names the command that fills it: the band's zero counts wear the
 * fact colour and carry no link, VALUE and WHERE name `kitterm project
 * add` and `kitterm project init`, and the tree says where a shell is
 * opened. A second fixture with one project registered proves that
 * nothing else changed.
 */

const NOW = 1_758_000_000_000;
const tokens = { input: 1_000_000, output: 100_000, cacheCreation: 2_000_000, cacheRead: 60_000_000, requests: 100 };
const models = [
  { model: "claude-fable-5-1", name: "Fable 5.1", costUSD: 1283.48, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 97 },
  { model: "claude-opus-5[1m]", name: "Opus 5 · 1M", costUSD: 404.43, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 29 },
];
const totals = { costUSD: 2714.8, apportionedUSD: 1446, unsplitUSD: 0, tokens, sessions: 260, unbilledSessions: 0, apiMs: 50.3 * 3_600_000, measuredUSD: 2714.8 };
/** The rollup on a machine with transcripts and no project: every
 * session sits in a directory no project holds. */
const rollup = {
  ok: true, timeZone: "UTC", from: "2026-08-19", to: "2026-09-17", refreshedAt: NOW, recordedSessions: 260, days: [],
  totals, models, projects: [],
  roles: [{ role: "root" as const, costUSD: 2714.8, apportionedUSD: 0, sessions: 260, apiMs: 50.3 * 3_600_000, measuredUSD: 2714.8, linesAdded: 0 }],
  lowCache: [],
};
const emptyYield = { ok: true, from: "2026-08-19", to: "2026-09-17", projects: [], totals: { checkouts: 0, counted: 0, mergedPullRequests: 0, mergedLines: 0, releases: 0 } };

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/daily": rollup,
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
const cells = () => page.root.querySelectorAll(".band-cell").map((cell) => [
  cell.tagName, cell.querySelector(".band-value")?.textContent, cell.querySelector(".band-noun")?.textContent,
]);
const valueOf = (cell: FakeElement) => cell.querySelector(".band-value")!;
const noteOf = (panel: FakeElement) => panel.querySelector(".panel-note")!;

describe("the first run: no project, no session, no reading", () => {
  it("prints the band's zero counts in the fact colour, with no mark and no link", () => {
    expect(cells()).toEqual([
      ["SPAN", "0", "working"],
      ["SPAN", "0", "need you"],
      ["SPAN", "$2,714", "30d"],
      ["SPAN", "–", "quota"],
    ]);
    const values = page.root.querySelectorAll(".band-cell").map(valueOf);
    // Neither count is a mark: the accent and the amber say a state, and
    // zero is none. `muted` is the fact colour, `--ui-text-muted`.
    expect(values.map((v) => v.querySelector(".mark"))).toEqual([null, null, null, null]);
    expect(values.map((v) => v.classList.contains("muted"))).toEqual([true, true, false, false]);
    expect(page.root.querySelectorAll('[id="needs-you"]')).toEqual([]);
    expect(page.document.title).toBe("kitterm — sessions");
  });

  it("VALUE prints a dash on the three repository tiles, the hours as always, and the register command in the text colour", () => {
    const value = panelNamed("value");
    expect(value.querySelectorAll(".yield-tile").map((t) => [t.querySelector(".yield-count")?.textContent, t.querySelector(".yield-rate")?.textContent])).toEqual([
      ["–", "–"], ["–", "–"], ["–", "–"], ["50.3", "$53 an hour"],
    ]);
    const note = noteOf(value);
    expect(note.querySelector(".note-long")?.textContent).toBe(VALUE_REGISTER_NOTE);
    expect(note.querySelector(".note-short")?.textContent).toBe(VALUE_REGISTER_NOTE);
    expect(note.querySelector(".note-command")?.textContent).toBe("kitterm project add <path>");
    // Two spaces before the command, as the frame draws it; the note
    // wraps on a phone.
    expect(note.textContent).toBe(`${VALUE_REGISTER_NOTE}${VALUE_REGISTER_NOTE}  kitterm project add <path>`);
    expect(note.classList.contains("wraps")).toBe(true);
  });

  it("WHERE keeps the selector, prints the one remainder row with the whole spend, and the init command", () => {
    const where = panelNamed("where");
    expect(where.querySelectorAll(".panel-toggle").map((b) => [b.textContent, b.getAttribute("aria-checked")])).toEqual([
      ["project", "false"], ["goal", "true"], ["task", "false"], ["role", "false"],
    ]);
    expect(where.querySelectorAll(".split-row").map((row) => [
      row.querySelector(".split-name")?.textContent, row.querySelector(".split-spend")?.textContent, row.querySelector(".split-count")?.textContent, row.classList.contains("remainder"),
    ])).toEqual([["no round record", "$2,714.80", "100%", true]]);
    const note = noteOf(where);
    expect(note.querySelector(".note-long")?.textContent).toBe(WHERE_REGISTER_NOTE);
    expect(note.querySelector(".note-command")?.textContent).toBe("kitterm project init <path>");
    expect(note.classList.contains("wraps")).toBe(true);
  });

  it("SESSIONS keeps the vocabulary header and says where a shell is opened, with / a link in the accent", () => {
    expect(page.root.querySelector(".tree-label")?.textContent).toBe("SESSIONS");
    expect(page.root.querySelectorAll(".tree-key")).toHaveLength(6);
    const empty = page.root.querySelector(".tree")!.querySelector(".empty")!;
    expect(empty.textContent).toBe("No live sessions. Open a shell at / to start one.");
    const link = empty.querySelector("a")!;
    expect(link.href).toBe("/");
    expect(link.className).toBe("pr-link");
    expect(link.querySelector(".mark")?.className).toBe("mark link wide");
    expect(page.root.querySelectorAll(".row")).toEqual([]);
  });

  it("the folds line carries only the push switch: no Archived, no idle shells", () => {
    const folds = page.root.querySelector(".folds")!;
    expect(folds.querySelectorAll("details")).toEqual([]);
    const push = folds.querySelector(".push")!;
    expect(push.hidden).toBe(false);
    expect(push.textContent).toContain("Notify this device");
    expect(folds.textContent).not.toContain("Archived");
    expect(folds.textContent).not.toContain("idle shell");
  });

  it("USAGE, QUOTA and MODELS print as always: transcripts exist, so the rollup has a total", () => {
    expect(panelNamed("usage").querySelector(".usage-amount")?.textContent).toBe("$2,714.80");
    expect(panelNamed("quota").textContent).toContain("No quota reading yet");
    expect(panelNamed("models").querySelectorAll(".split-name").map((n) => n.textContent)).toEqual(["Fable 5.1", "Opus 5 · 1M"]);
  });
});

describe("one project registered: nothing changed", () => {
  const W = "/w";
  const kitterm = { id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true, knowledge: "docs/goals" };
  const yieldReport = {
    ok: true, from: "2026-08-19", to: "2026-09-17",
    projects: [{ id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true, yield: { checkout: true, remote: true, branch: "origin/main", mergedPullRequests: 83, mergedLines: 58_853, releases: 24 } }],
    totals: { checkouts: 1, counted: 1, mergedPullRequests: 83, mergedLines: 58_853, releases: 24 },
  };
  const report = { ...rollup, projects: [{ ...kitterm, costUSD: 976.74, apportionedUSD: 0, tokens, sessions: 90, unbilledSessions: 0 }] };
  const range = { from: "2026-08-19", to: "2026-09-17" };

  it("VALUE names the scope and the caveat, with no command", () => {
    const panel = valuePanel(report, yieldReport, 30)!;
    expect(panel.note).toBe("kitterm, 30 days. Proxies for value, not value.");
    expect(panel.command).toBeUndefined();
    expect(panel.tiles.map((t) => t.count)).toEqual(["83", "58,853", "24", "50.3"]);
  });

  it("WHERE names the unattributed share, with no command", () => {
    const panel = wherePanel("goal", { report, yield: yieldReport, projects: [kitterm], goals: [], range })!;
    expect(panel.note).toBe("100% names no round, so it cannot be valued");
    expect(panel.command).toBeUndefined();
    expect(wherePanel("project", { report, yield: yieldReport, projects: [kitterm], goals: [], range })!.note).toBe("What each repository cost and shipped");
  });

  it("a yield not yet read decides nothing: the note has no command", () => {
    expect(valuePanel(report, null, 30)!.command).toBeUndefined();
    expect(wherePanel("goal", { report, yield: null, projects: [kitterm], goals: [], range })!.command).toBeUndefined();
  });

  it("the role grouping keeps its own note on the first run", () => {
    const panel = wherePanel("role", { report: rollup, yield: emptyYield, projects: [], goals: [], range })!;
    expect(panel.note).toBe("A crew starts with a context sized to one item");
    expect(panel.command).toBeUndefined();
  });

  it("a band with one working session wears the accent on that count and the fact colour on the zero", () => {
    const rows = [{ id: "a", cwd: "/w", state: "running" as const, mergedState: "working" as const }];
    const out = band(rows, [], rollup, USAGE_DEFAULT, null, NOW);
    expect(out.cells.map((cell) => [cell.family ?? null, cell.muted ?? null])).toEqual([["running", null], [null, true], [null, null], [null, null]]);
    expect(VALUE_REGISTER_COMMAND).toBe("kitterm project add <path>");
    expect(WHERE_REGISTER_COMMAND).toBe("kitterm project init <path>");
  });
});
