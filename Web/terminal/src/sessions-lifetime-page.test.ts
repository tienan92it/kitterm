import { readFileSync } from "node:fs";

import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { dayLabel } from "./sessions-model";
import { LIFETIME_EMPTY_LINE, LIFETIME_NOTE } from "./sessions-value";
import {
  logPosition,
  multipleLabel,
  totalsAxisTicks,
  totalsRealLine,
  totalsSeries,
  totalsTooltipRows,
  unitCostAxisTicks,
  unitCostLabel,
  unitCostsSeries,
  unitCostsTooltipRows,
} from "./value-lifetime";

/**
 * The two lifetime charts drawn under VALUE's tiles (`value-lifetime`,
 * capability 4): the SVG geometry against the series the same pure
 * functions compute, the end labels, the tooltip on keyboard focus, and
 * the empty state. `sessions-lifetime-fetch.test.ts` and
 * `sessions-lifetime-watch.test.ts` cover the poll cadence and the grade.
 */

const NOW = new Date(2026, 9, 10, 12, 0, 0).getTime();

const kitterm = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, knowledge: "docs/goals" };

/** Ten days, equal spend (so every seven-day run clears the median floor,
 * `baseDayOf`'s rule), with pull requests, lines and releases growing by a
 * fixed step a day — a small fixture whose multiples and unit costs this
 * file recomputes with the real pure functions rather than by hand. */
function days(): { usage: unknown[]; yield: unknown[] } {
  const usage: unknown[] = [];
  const yieldDays: unknown[] = [];
  for (let i = 1; i <= 10; i += 1) {
    const day = `2026-09-${String(i).padStart(2, "0")}`;
    usage.push({ day, costUSD: 10, apportionedUSD: 0, tokens: { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 }, sessions: 1, unbilledSessions: 0, apiMs: 3_600_000, measuredUSD: 10, projects: [] });
    yieldDays.push({ day, mergedPullRequests: i, mergedLines: i * 100, releases: 1, projects: [] });
  }
  return { usage, yield: yieldDays };
}
const fixture = days();

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [kitterm] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/daily": (query: URLSearchParams) => ({
    ok: true, timeZone: "UTC", from: query.get("from"), to: query.get("to"), refreshedAt: NOW, recordedSessions: 10,
    days: fixture.usage, totals: { costUSD: 100, apportionedUSD: 0, tokens: { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 }, sessions: 10, unbilledSessions: 0 },
    projects: [],
  }),
  "/api/yield": { ok: true, from: "2026-09-01", to: "2026-09-10", projects: [], totals: { checkouts: 0, counted: 0, mergedPullRequests: 0, mergedLines: 0, releases: 0 } },
  "/api/yield/daily": (query: URLSearchParams) => ({ ok: true, from: query.get("from"), to: query.get("to"), days: fixture.yield }),
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;

beforeAll(async () => {
  vi.spyOn(Date, "now").mockReturnValue(NOW);
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  await import("./sessions");
  await page.settle();
});

const valuePanel = () => page.root.querySelectorAll(".panel").find((p) => p.classList.contains("value"))!;
const blocks = () => valuePanel().querySelectorAll(".lifetime-chart-block");
const totalsBlock = () => blocks().find((b) => b.classList.contains("totals"))!;
const unitCostsBlock = () => blocks().find((b) => b.classList.contains("unit-costs"))!;

/** A tooltip's visible rows, as `{label, value}`, for comparison against
 * `totalsTooltipRows`/`unitCostsTooltipRows`'s own shape (minus `slot`,
 * which the swatch test below checks separately). */
const tooltipRows = (tooltip: FakeElement): Array<{ label: string; value: string }> =>
  tooltip.querySelectorAll(".lifetime-tooltip-line").map((line) => ({
    label: line.querySelector(".lifetime-tooltip-label")?.textContent ?? "",
    value: line.querySelector(".lifetime-tooltip-value")?.textContent ?? "",
  }));

const withoutSlot = (rows: ReadonlyArray<{ label: string; value: string }>): Array<{ label: string; value: string }> =>
  rows.map(({ label, value }) => ({ label, value }));

const CSS_SOURCE = readFileSync(new URL("./sessions.css", import.meta.url), "utf8");

// Expectations from the same pure module the page imports.
const usageDays = fixture.usage as Array<{ day: string; costUSD: number; measuredUSD?: number; apiMs?: number }>;
const yieldDays = fixture.yield as Array<{ day: string; mergedPullRequests?: number; mergedLines?: number; releases?: number }>;
const totals = totalsSeries(usageDays, yieldDays);
const unitCosts = unitCostsSeries(usageDays, yieldDays);
const lastTotals = totals.points[totals.points.length - 1];
const lastUnitCosts = unitCosts.points[unitCosts.points.length - 1];

describe("TOTALS", () => {
  it("prints the title with the base day and draws one tick per totalsAxisTicks value", () => {
    const title = totalsBlock().querySelector(".lifetime-title")!;
    expect(title.querySelector(".lifetime-title-word")?.textContent).toBe("TOTALS");
    expect(title.textContent).toContain(`growth since ${totals.baseDay === "2026-09-01" ? "1 Sep" : totals.baseDay}, log scale`);
    const maxMultiple = Math.max(1, ...totals.points.flatMap((p) => [p.multiple.spend, p.multiple.prs, p.multiple.lines, p.multiple.releases].map((v) => v ?? 1)));
    const ticks = totalsAxisTicks(maxMultiple);
    expect(totalsBlock().querySelectorAll(".lifetime-tick")).toHaveLength(ticks.length);
    expect(totalsBlock().querySelectorAll(".lifetime-tick").map((t) => t.textContent)).toEqual(ticks.map((t) => `×${t}`));
  });

  it("draws one path per measure, in the data palette's slot order, ending at the last point's own logPosition", () => {
    const svg = totalsBlock().querySelector("svg")!;
    const paths = svg.querySelectorAll("path");
    expect(paths.map((p) => p.getAttribute("class"))).toEqual(["lifetime-line data-1", "lifetime-line data-2", "lifetime-line data-3", "lifetime-line data-4"]);
    const maxMultiple = Math.max(1, ...totals.points.flatMap((p) => [p.multiple.spend, p.multiple.prs, p.multiple.lines, p.multiple.releases].map((v) => v ?? 1)));
    const axisMax = totalsAxisTicks(maxMultiple).at(-1)!;
    const measures: Array<"spend" | "prs" | "lines" | "releases"> = ["spend", "prs", "lines", "releases"];
    measures.forEach((m, i) => {
      const d = paths[i].getAttribute("d")!;
      const last = /(-?[\d.]+),(-?[\d.]+)\s*$/.exec(d)!;
      const expectedY = 100 - logPosition(lastTotals.multiple[m]!, axisMax) * 100;
      expect(Number(last[1])).toBeCloseTo(100, 5); // the last day sits at x = 100 (the right edge)
      expect(Number(last[2])).toBeCloseTo(expectedY, 2);
    });
  });

  it("labels each line with its multiple and its measure word, in the data palette's colour", () => {
    const labels = totalsBlock().querySelectorAll(".lifetime-label");
    expect(labels).toHaveLength(4);
    expect(labels.map((l) => l.className)).toEqual([
      "lifetime-label mark data-1", "lifetime-label mark data-2", "lifetime-label mark data-3", "lifetime-label mark data-4",
    ]);
    expect(labels.map((l) => l.textContent)).toEqual([
      `${multipleLabel(lastTotals.multiple.spend!)} spend`,
      `${multipleLabel(lastTotals.multiple.prs!)} PRs`,
      `${multipleLabel(lastTotals.multiple.lines!)} lines`,
      `${multipleLabel(lastTotals.multiple.releases!)} releases`,
    ]);
  });

  it("names the axis ends with the first and the last day", () => {
    const axis = totalsBlock().querySelector(".lifetime-axis")!;
    expect(axis.querySelector(".lifetime-axis-from")?.textContent).toBeTruthy();
    expect(axis.querySelector(".lifetime-axis-to")?.textContent).toBeTruthy();
  });

  it("carries one summary sentence for a screen reader, naming the chart, with no multiple", () => {
    const label = totalsBlock().querySelector("svg")?.getAttribute("aria-label") ?? "";
    expect(label).toContain("Totals chart");
    expect(label).toContain(totalsRealLine(lastTotals));
    // Chartered by corpus/04-chart-polish.md: the screen-reader text drops
    // the TOTALS multiples too.
    expect(label).not.toContain("×");
  });

  it("shows the last day's tooltip on focus — a header with the plain day, then one row per measure, real values only — and hides it on blur", () => {
    const hit = totalsBlock().querySelector(".lifetime-hit")! as FakeElement;
    const tooltip = totalsBlock().querySelector(".lifetime-tooltip")!;
    expect(hit.getAttribute("aria-label")).toBeTruthy();
    expect(tooltip.hidden).toBe(true);

    hit.listeners.get("focus")?.[0]({});
    expect(tooltip.hidden).toBe(false);
    expect(tooltip.querySelector(".lifetime-tooltip-day")?.textContent).toBe(dayLabel(lastTotals.day));
    expect(tooltipRows(tooltip)).toEqual(withoutSlot(totalsTooltipRows(lastTotals)));
    // Chartered by corpus/04-chart-polish.md: no multiple anywhere in the box.
    expect(tooltip.textContent).not.toContain("×");

    const prevented: boolean[] = [];
    hit.listeners.get("keydown")?.[0]({ key: "ArrowLeft", preventDefault: () => prevented.push(true) });
    expect(prevented).toEqual([true]);
    const prev = totals.points[totals.points.length - 2];
    expect(tooltip.querySelector(".lifetime-tooltip-day")?.textContent).toBe(dayLabel(prev.day));
    expect(tooltipRows(tooltip)).toEqual(withoutSlot(totalsTooltipRows(prev)));

    hit.listeners.get("blur")?.[0]({});
    expect(tooltip.hidden).toBe(true);
  });

  it("announces the day and the real totals in a polite live region, no multiple, on focus and on the arrow keys", () => {
    // A screen reader does not see the visible tooltip move, so `show`
    // also updates an `aria-live="polite"` sr-only paragraph beside it.
    const hit = totalsBlock().querySelector(".lifetime-hit")! as FakeElement;
    const announce = totalsBlock().querySelector('[aria-live="polite"]')!;
    expect(announce.classList.contains("sr-only")).toBe(true);
    const keydown = (key: string): void => hit.listeners.get("keydown")?.[0]({ key, preventDefault: () => undefined });

    // The previous test left the cursor mid-series; push it past the end
    // (`show` clamps) so this test starts from a known day, the last one.
    for (let i = 0; i < totals.points.length + 1; i += 1) keydown("ArrowRight");
    hit.listeners.get("focus")?.[0]({});
    expect(announce.textContent).toContain(dayLabel(lastTotals.day));
    expect(announce.textContent).toContain(totalsRealLine(lastTotals));
    // Chartered by corpus/04-chart-polish.md: the live region drops the
    // TOTALS multiples too.
    expect(announce.textContent).not.toContain("×");

    const prev = totals.points[totals.points.length - 2];
    keydown("ArrowLeft");
    expect(announce.textContent).toContain(totalsRealLine(prev));
    // The live region keeps announcing after blur hides the visible
    // tooltip: the last value read stays available, nothing is retracted.
    hit.listeners.get("blur")?.[0]({});
    expect(announce.textContent).toContain(totalsRealLine(prev));
  });
});

describe("UNIT COSTS", () => {
  it("prints the title with the first spend day and draws one tick per unitCostAxisTicks value", () => {
    const title = unitCostsBlock().querySelector(".lifetime-title")!;
    expect(title.querySelector(".lifetime-title-word")?.textContent).toBe("UNIT COSTS");
    const maxValue = Math.max(0, ...unitCosts.points.flatMap((p) => [p.perPR, p.perKLines, p.perRelease, p.perHour].map((v) => v ?? 0)));
    const ticks = unitCostAxisTicks(maxValue);
    expect(unitCostsBlock().querySelectorAll(".lifetime-tick").map((t) => t.textContent)).toEqual(ticks.map((t) => `${t}`));
  });

  it("draws one path per measure in $/hour, $/PR, $/1k lines, $/release order", () => {
    const svg = unitCostsBlock().querySelector("svg")!;
    expect(svg.querySelectorAll("path").map((p) => p.getAttribute("class"))).toEqual(["lifetime-line data-1", "lifetime-line data-2", "lifetime-line data-3", "lifetime-line data-4"]);
  });

  it("labels each line with its word and its dollar value", () => {
    const labels = unitCostsBlock().querySelectorAll(".lifetime-label");
    expect(labels.map((l) => l.textContent)).toEqual([
      `$/hour  ${unitCostLabel(lastUnitCosts.perHour!)}`,
      `$/PR  ${unitCostLabel(lastUnitCosts.perPR!)}`,
      `$/1k lines  ${unitCostLabel(lastUnitCosts.perKLines!)}`,
      `$/release  ${unitCostLabel(lastUnitCosts.perRelease!)}`,
    ]);
  });

  it("shows the last day's tooltip on focus — a header with the plain day, then one row per measure, in the corpus's $/PR, $/1k lines, $/release, $/hour order", () => {
    const hit = unitCostsBlock().querySelector(".lifetime-hit")! as FakeElement;
    const tooltip = unitCostsBlock().querySelector(".lifetime-tooltip")!;
    hit.listeners.get("focus")?.[0]({});
    expect(tooltip.hidden).toBe(false);
    expect(tooltip.querySelector(".lifetime-tooltip-day")?.textContent).toBe(dayLabel(lastUnitCosts.day));
    expect(tooltipRows(tooltip)).toEqual(withoutSlot(unitCostsTooltipRows(lastUnitCosts)));
  });
});

describe("the tooltip box", () => {
  it("pins the box to the top of its own chart, never past it, so it cannot cover the other chart or its title", () => {
    expect((totalsBlock().querySelector(".lifetime-tooltip")! as FakeElement).style.top).toBe("0");
    expect((unitCostsBlock().querySelector(".lifetime-tooltip")! as FakeElement).style.top).toBe("0");
  });

  it("flips to the left of the cursor near the right edge, and sits to its right otherwise", () => {
    const hit = totalsBlock().querySelector(".lifetime-hit")! as FakeElement;
    const tooltip = totalsBlock().querySelector(".lifetime-tooltip")! as FakeElement;

    // The last day sits at x = 100 (the right edge), past the x > 60 flip.
    hit.listeners.get("focus")?.[0]({});
    expect(tooltip.style.left).toBe("auto");
    expect(tooltip.style.right).not.toBe("auto");

    // The first day sits at x = 0, well inside the flip's threshold.
    for (let i = 0; i < totals.points.length + 1; i += 1) hit.listeners.get("keydown")?.[0]({ key: "ArrowLeft", preventDefault: () => undefined });
    expect(tooltip.style.left).toBe("0%");
    expect(tooltip.style.right).toBe("auto");
  });

  it("swatches each row in the measure's own data-palette slot, through the mark rule", () => {
    const tooltip = totalsBlock().querySelector(".lifetime-tooltip")! as FakeElement;
    totalsBlock().querySelector(".lifetime-hit")!.listeners.get("focus")?.[0]({});
    const swatches = tooltip.querySelectorAll(".lifetime-tooltip-swatch");
    expect(swatches.map((s) => s.className)).toEqual([
      "mark bar lifetime-tooltip-swatch data-1",
      "mark bar lifetime-tooltip-swatch data-2",
      "mark bar lifetime-tooltip-swatch data-3",
      "mark bar lifetime-tooltip-swatch data-4",
    ]);
  });
});

describe("the space scale", () => {
  it("gives one more step between a chart's title and its plot (corpus/04-chart-polish.md)", () => {
    const rule = /\.lifetime-plot\s*\{[^}]*margin:\s*var\(--space-(\d)\)/.exec(CSS_SOURCE);
    expect(rule?.[1]).toBe("2");
  });
});

describe("the note", () => {
  it("prints the approved fixed sentence under both charts", () => {
    expect(valuePanel().querySelector(".lifetime-note")?.textContent).toBe(LIFETIME_NOTE);
  });
});

describe("the empty state", () => {
  it("replaces both charts with one sentence when the fleet has no spend at all", async () => {
    const empty = { usage: usageDays.map((d) => ({ ...d, costUSD: 0, measuredUSD: 0, apiMs: 0 })), yield: yieldDays };
    routes["/api/usage/daily"] = (query: URLSearchParams) => ({
      ok: true, timeZone: "UTC", from: query.get("from"), to: query.get("to"), refreshedAt: NOW, recordedSessions: 10,
      days: empty.usage, totals: { costUSD: 0, apportionedUSD: 0, tokens: { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 }, sessions: 10, unbilledSessions: 0 },
      projects: [],
    });
    // Past the lifetime routes' five-minute cadence, so the change above is
    // actually re-asked for.
    vi.spyOn(Date, "now").mockReturnValue(NOW + 6 * 60_000);
    await page.poll();
    expect(valuePanel().querySelectorAll(".lifetime-chart-block")).toEqual([]);
    expect(valuePanel().querySelector(".lifetime-empty")?.textContent).toBe(LIFETIME_EMPTY_LINE);
  });
});
