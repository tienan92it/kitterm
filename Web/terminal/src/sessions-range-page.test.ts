import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { goals, kitterm, mdp, rollup, yieldFor } from "./range-fixture";
import { usageRange, type DayRange } from "./sessions-model";

/**
 * A toggle change moves every figure on the page at once (`agent-dashboard`
 * round 13): the page asks `/api/usage/daily` and `/api/yield` for the new
 * range and repaints the band, VALUE, WHERE, MODELS, LEAKS and the tree's
 * costs from the answers, with the round records filtered to the same
 * days. The daemon is the fixture's: it answers each range from the same
 * fleet (`range-fixture.ts`), so what differs between 7d and 90d is what
 * fell inside the days.
 */

const NOW = Date.now();
const fleet = goals(NOW);
const rangeOf = (query: URLSearchParams): DayRange => ({ from: query.get("from") ?? "", to: query.get("to") ?? "" });

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [kitterm, mdp].map((p) => ({ ...p, knowledge: "docs/goals" })) },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: fleet.filter((g) => g.project.id === "kitterm").map((g) => g.summary) },
  "/api/projects/mdp/knowledge": { ok: true, project: "mdp", goals: fleet.filter((g) => g.project.id === "mdp").map((g) => g.summary) },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/daily": (query: URLSearchParams) => rollup(rangeOf(query), NOW),
  "/api/yield": (query: URLSearchParams) => yieldFor(rangeOf(query), NOW),
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
const toggle = (label: string): FakeElement => page.root.querySelectorAll(".usage-toggle").find((b) => b.textContent === label)!;

/** Every figure the range moves, read off the page in one pass. */
function figures() {
  const rowsOf = (panel: FakeElement) => panel.querySelectorAll(".split-row").map((row) => [row.querySelector(".split-name")?.textContent, row.querySelector(".split-spend")?.textContent, row.querySelector(".split-count")?.textContent, row.querySelector(".split-units")?.textContent, row.querySelector(".split-rate")?.textContent]);
  return {
    band: page.root.querySelectorAll(".band-cell").filter((c) => c.classList.contains("spend")).map((c) => `${c.querySelector(".band-value")?.textContent} ${c.querySelector(".band-noun")?.textContent}`),
    value: panelNamed("value").querySelectorAll(".yield-tile").map((cell) => [cell.querySelector(".yield-count")?.textContent, cell.querySelector(".yield-rate")?.textContent]),
    valueNote: panelNamed("value").querySelector(".note-long")?.textContent,
    where: rowsOf(panelNamed("where")),
    whereSummary: panelNamed("where").querySelector(".panel-summary")?.textContent,
    models: panelNamed("models").querySelectorAll(".split-row").map((row) => [row.querySelector(".split-name")?.textContent, row.querySelector(".split-spend")?.textContent]),
    leaks: panelNamed("leaks").querySelectorAll(".leak-text").map((l) => l.textContent),
    tree: page.root.querySelectorAll(".line").filter((l) => l.querySelector(".cost") !== null).map((l) => [l.querySelector(".line-name")?.textContent, l.querySelector(".cost")?.textContent]),
  };
}

describe("one range for every figure", () => {
  it("asks the two routes for the toggles' range, and each panel and the tree repaint from the answer", async () => {
    // The page opens at 30d. A click on 7d asks both routes for the week
    // and repaints; a click on 90d asks for the quarter and repaints.
    expect(toggle("30d").getAttribute("aria-checked")).toBe("true");
    const asked = (span: 7 | 90) => {
      const { from, to } = usageRange(span, NOW);
      return page.requests.filter((u) => u.endsWith(`from=${from}&to=${to}`)).map((u) => u.replace(/\?.*$/, "")).sort();
    };

    toggle("7d").click();
    await page.settle();
    expect(asked(7)).toEqual(["/api/usage/daily", "/api/yield"]);
    const week = figures();
    expect(week).toEqual({
      band: ["$75 7d"],
      value: [["2", "$35.00 each"], ["500", "$0.140 each"], ["1", "$70.00 each"], ["3.5", "$21 an hour"]],
      valueNote: "2 repositories, 7 days. Proxies for value, not value.",
      where: [
        ["alpha", "$17.00", "2 tasks", "2 PRs", "$0.034/line"],
        ["beta", "–", "1 task", "–", "–"],
        ["gamma", "–", "–", "–", "–"],
        ["no round record", "$58.00", "77%", "–", "–"],
      ],
      whereSummary: "$70.00 in 2 repositories · 2 merged PRs · 500 lines · 1 release",
      models: [["Fable 5.1", "$45.00"], ["Opus 5 · 1M", "$30.00"]],
      leaks: ["1 of 3 rounds carry no Cost line", "0 corrections in 3 rounds · 1 session under 95% cached, $30.00"],
      // Round 15 (chartered): every task and goal line carries the cost
      // cell, the dash where its rounds in the range carry no Cost line.
      tree: [["Workspace", "$70.00"], ["kitterm", "$70.00"], ["alpha", "$17.00"], ["ship", "–"], ["beta", "–"], ["market-data-pipeline", "$0.00"], ["gamma", "–"]],
    });

    toggle("90d").click();
    await page.settle();
    expect(asked(90)).toEqual(["/api/usage/daily", "/api/yield"]);
    expect(toggle("90d").getAttribute("aria-checked")).toBe("true");
    const quarter = figures();
    expect(quarter).toEqual({
      band: ["$195 90d"],
      value: [["4", "$47.50 each"], ["2,000", "$0.095 each"], ["2", "$95.00 each"], ["8.5", "$22 an hour"]],
      valueNote: "2 repositories, 90 days. Proxies for value, not value.",
      where: [
        ["alpha", "$30.00", "4 tasks", "4 PRs", "$0.015/line"],
        ["gamma", "$20.00", "1 task", "–", "–"],
        ["beta", "$5.00", "2 tasks", "–", "–"],
        ["no round record", "$140.00", "72%", "–", "–"],
      ],
      whereSummary: "$190.00 in 2 repositories · 4 merged PRs · 2,000 lines · 2 releases",
      models: [["Fable 5.1", "$145.00"], ["Opus 5 · 1M", "$30.00"], ["Haiku 4.5", "$20.00"]],
      leaks: ["2 of 7 rounds carry no Cost line", "1 correction in 7 rounds · 2 sessions under 95% cached, $130.00"],
      tree: [["Workspace", "$190.00"], ["kitterm", "$170.00"], ["alpha", "$30.00"], ["ship", "–"], ["beta", "$5.00"], ["market-data-pipeline", "$20.00"], ["gamma", "$20.00"]],
    });
    // Nothing on the page kept the week's figure.
    for (const key of Object.keys(week) as Array<keyof typeof week>) expect(quarter[key], key).not.toEqual(week[key]);
  });
});
