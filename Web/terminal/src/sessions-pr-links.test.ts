import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { goals, kitterm, mdp, rollup, yieldFor } from "./range-fixture";
import { pullRequestHref, type DayRange, type ProjectSummary } from "./sessions-model";
import { wherePanel } from "./sessions-value";

/**
 * `PR #124` is a link to the pull request (`agent-dashboard` round 15, the
 * human's word) wherever the page prints a pull request number: a task
 * line of the tree and a task row of `WHERE`. The link's base comes from
 * the project (`pullRequestBase`, which the daemon reads off the `origin`
 * remote); a project with none prints the number as plain text. The link
 * is in the accent as a `.mark.link.wide`, so the colour is a mark's
 * background like every owned colour, with an underline like the band's
 * `need you` link.
 */

const NOW = Date.now();
const BASE = "https://github.com/tienan92it/kitterm/pull/";
const fleet = goals(NOW);
const projects: ProjectSummary[] = [{ ...kitterm, knowledge: "docs/goals", pullRequestBase: BASE }, { ...mdp, knowledge: "docs/goals" }];
const rangeOf = (query: URLSearchParams): DayRange => ({ from: query.get("from") ?? "", to: query.get("to") ?? "" });
const quarter = { from: "2026-01-01", to: "2026-12-31" };

describe("pullRequestHref", () => {
  it("joins the base and the number, and is null with no base", () => {
    expect(pullRequestHref(BASE, 124)).toBe(`${BASE}124`);
    expect(pullRequestHref(undefined, 124)).toBeNull();
  });
});

describe("the WHERE task rows", () => {
  it("carry the link of their one PR under the project's base, and none for a project without one or a row of two PRs", () => {
    const report = rollup(quarter, NOW);
    const panel = wherePanel("task", { report, yield: yieldFor(quarter, NOW), projects, goals: fleet, range: quarter })!;
    const rows = panel.rows.map((r) => [r.name, r.units, r.unitsHref]);
    const named = rows.filter(([name]) => ["seed", "polish", "ship", "grow", "ingest"].includes(String(name))).sort((a, b) => String(a[0]).localeCompare(String(b[0])));
    expect(named).toEqual([
      ["grow", "PR #150", `${BASE}150`],
      ["ingest", "–", undefined],
      ["polish", "PR #202", `${BASE}202`],
      ["seed", "PR #120", `${BASE}120`],
      ["ship", "PR #201", `${BASE}201`],
    ]);
    // The pipeline has no base: the same row shape, no link.
    const bare = wherePanel("task", { report, yield: yieldFor(quarter, NOW), projects: projects.map((p) => ({ ...p, pullRequestBase: undefined })), goals: fleet, range: quarter })!;
    expect(bare.rows.find((r) => r.name === "ship")).toMatchObject({ units: "PR #201" });
    expect(bare.rows.find((r) => r.name === "ship")).not.toHaveProperty("unitsHref");
  });
});

// --- the page ----------------------------------------------------------------

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects },
  "/api/projects/kitterm/knowledge": {
    ok: true, project: "kitterm",
    goals: fleet.filter((g) => g.project.id === "kitterm").map((g) => ({ ...g.summary, tasks: [{ slug: "ship", state: "done", round: 4, pr: 201 }] })),
  },
  "/api/projects/mdp/knowledge": {
    ok: true, project: "mdp",
    goals: fleet.filter((g) => g.project.id === "mdp").map((g) => ({ ...g.summary, tasks: [{ slug: "ingest", state: "done", round: 1, pr: 7 }] })),
  },
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

/** The anchor inside a cell, as the page draws a pull request link. */
const linkIn = (cell: FakeElement | undefined) => {
  const a = cell?.querySelector("a") ?? null;
  if (a === null) return null;
  const el = a as unknown as { className: string; href: string; target: string; rel: string; textContent: string };
  return [el.className, el.href, el.target, el.rel, a.querySelector(".mark")?.className, el.textContent];
};

describe("the painted links", () => {
  it("make a task line's PR a link under its project's base, and plain text where the project has none", () => {
    const tasks = page.root.querySelectorAll(".line-task");
    const byName = (name: string) => tasks.find((t) => t.querySelector(".line-name")?.textContent === name)!;
    expect(byName("ship").querySelector(".pr")?.textContent).toBe("PR #201");
    expect(linkIn(byName("ship").querySelector(".pr") ?? undefined)).toEqual(["pr-link", `${BASE}201`, "_blank", "noopener", "mark link wide", "PR #201"]);
    expect(byName("ingest").querySelector(".pr")?.textContent).toBe("PR #7");
    expect(linkIn(byName("ingest").querySelector(".pr") ?? undefined)).toBeNull();
  });

  it("make a WHERE task row's PR the same link, and print two PRs or a dash as text", async () => {
    const where = page.root.querySelectorAll(".panel").find((p) => p.classList.contains("where"))!;
    where.querySelectorAll(".panel-toggle").find((b) => b.textContent === "task")!.click();
    await page.settle();
    const rows = page.root.querySelectorAll(".panel").find((p) => p.classList.contains("where"))!.querySelectorAll(".split-row");
    const cellOf = (name: string) => rows.find((r) => r.querySelector(".split-name")?.textContent === name)?.querySelector(".split-units") ?? undefined;
    expect(cellOf("ship")?.textContent).toBe("PR #201");
    expect(linkIn(cellOf("ship"))).toEqual(["pr-link", `${BASE}201`, "_blank", "noopener", "mark link wide", "PR #201"]);
    expect(cellOf("no round record")?.textContent).toBe("–");
    expect(linkIn(cellOf("no round record"))).toBeNull();
  });
});
