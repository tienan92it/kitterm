import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { type ProjectSummary } from "./sessions-model";

/**
 * The REVIEW section as the page paints it (`sessions-workflow` round 7,
 * `corpus/02-review-rows.md`): the header with the counts, one row per
 * ready pull request on the line grid, the longest wait first, and the
 * drafts behind `▶ N drafts`, a disclosure button like the tree's that
 * keeps its state across repaints. `sessions-review-rows.test.ts` pins
 * the data; `sessions-review-css.test.ts` the sheet.
 */

const NOW = Date.now();
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const at = (ms: number): string => new Date(ms).toISOString();
const BASE = "https://github.com/tienan92it/kitterm/pull/";
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: "/Users/an/Workspace/kitterm", registered: true, knowledge: "docs/goals", pullRequestBase: BASE };
/** On GitHub too, so its pull requests are rows of the same section. */
const cafe: ProjectSummary = { id: "lume-cafe", name: "lume-cafe", root: "/Users/an/Sites/lume-cafe", registered: true, knowledge: "docs/goals", pullRequestBase: "https://github.com/tienan92it/lume-cafe/pull/" };

const pull = (number: number, head: string, extra: Record<string, unknown> = {}) => ({
  number, title: `t${number}`, state: "open", draft: false, headRefName: head, url: `${BASE}${number}`, additions: 1, deletions: 0, ...extra,
});

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [kitterm, cafe] },
  "/api/projects/kitterm/knowledge": {
    ok: true, project: "kitterm", source: "origin/main",
    goals: [
      { slug: "sessions-workflow", goal: "the SESSIONS tree shows each scope's work stage", status: "active", round: 7, budget: 7 },
      { slug: "foreman-scope", goal: "each foreman keeps its own projects", status: "active", round: 2, budget: 3 },
    ],
  },
  "/api/projects/kitterm/pulls": {
    ok: true, project: "kitterm", readAt: NOW - 20_000, ageSeconds: 20,
    pulls: [
      pull(186, "goal/sessions-workflow", { draft: true, ci: "pending", title: "sessions-workflow round 7: the REVIEW section is one row per pull request", additions: 400, deletions: 90, updatedAt: at(NOW - HOUR) }),
      pull(180, "goal/foreman-scope", { ci: "passing", title: "Each foreman keeps its own projects", additions: 120, deletions: 8, updatedAt: at(NOW - 2 * HOUR) }),
      pull(177, "chore/readme", { title: "Readme: the install line", additions: undefined, deletions: undefined }),
      pull(156, "fix/ci-cache", { ci: "failing", title: "Cache the swift build in CI", additions: 300, deletions: 12, updatedAt: at(NOW - 3 * HOUR) }),
      pull(190, "chore/palette", { draft: true, title: "A warmer amber", additions: 2, deletions: 2, updatedAt: at(NOW - 3 * DAY) }),
      pull(150, "goal/old", { state: "merged", updatedAt: at(NOW - 9 * DAY) }),
    ],
  },
  "/api/projects/lume-cafe/knowledge": { ok: true, project: "lume-cafe", goals: [{ slug: "product-definition", goal: "the product brief", status: "active" }] },
  "/api/projects/lume-cafe/pulls": {
    ok: true, project: "lume-cafe", readAt: NOW - 20_000, ageSeconds: 20,
    pulls: [pull(1, "goal/product-definition", { url: "https://github.com/tienan92it/lume-cafe/pull/1", ci: "pending", title: "Product brief for the cafe", additions: 40, deletions: 0, updatedAt: at(NOW - DAY) })],
  },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;

beforeAll(async () => {
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  await import("./sessions");
  await page.settle();
  await page.poll();
});

const kids = (el: FakeElement): FakeElement[] => el.children.filter((c): c is FakeElement => typeof c !== "string");
const head = () => page.root.querySelector(".review")!;
const block = () => page.root.querySelector(".review-rows")!;
const lines = () => block().querySelectorAll(".line-review");
const rows = () => lines().filter((row) => !row.classList.contains("line-fold"));
const fold = () => lines().find((row) => row.classList.contains("line-fold"))!;
const button = () => fold().querySelector("button")!;
/** The cells of a row's `.main`, as `class[@col]=text`. */
const cells = (row: FakeElement): string[] => kids(row.querySelector(".main")!).map((c) => `${c.className}${c.getAttribute("data-col") ? `@${c.getAttribute("data-col")}` : ""}=${c.textContent}`);

describe("the header", () => {
  it("prints the counts, the ready count a mark in the amber and the drafts count in grey", () => {
    expect(head().textContent).toBe("4 ready · 2 drafts");
    expect(kids(head()).map((c) => `${c.className}=${c.textContent}`)).toEqual(["mark attention wide=4", "review-drafts= · 2 drafts"]);
  });
});

describe("the rows", () => {
  it("draws one line per ready pull request, the longest wait first, and the drafts line last", () => {
    expect(rows().map((row) => row.querySelector(".pr")?.textContent)).toEqual(["PR #1", "PR #156", "PR #180", "PR #177"]);
    expect(lines().at(-1)).toBe(fold());
    expect(fold().textContent).toBe("▶2 drafts");
  });

  it("is a line on the grid: the mark as the line's own child, then the cells in the frame's order", () => {
    const row = rows()[1];
    expect(row.className).toBe("line line-review");
    expect(kids(row).map((c) => c.className)).toEqual(["mark attention", "main"]);
    expect(row.querySelector(".mark")?.textContent).toBe("?");
    expect(cells(row)).toEqual([
      "pr@3=PR #156",
      "line-name=kitterm / fix ci-cache",
      "line-detail=Cache the swift build in CI",
      "state=ready · CI ✗CI ✗",
      "size@2=+300 −12",
      "since@4=3h",
    ]);
    // The title and where it belongs each carry their whole text as a tooltip, because both truncate.
    expect(row.querySelector(".line-name")?.title).toBe("kitterm / fix ci-cache");
    expect(row.querySelector(".line-detail")?.title).toBe("Cache the swift build in CI");
  });

  it("links PR #N through the project's base, with a focus key", () => {
    const first = rows()[0];
    const link = first.querySelector("a")!;
    expect([link.className, link.href, link.getAttribute("data-focus"), link.textContent]).toEqual(["pr-link", "https://github.com/tienan92it/lume-cafe/pull/1", "review:lume-cafe:1", "PR #1"]);
    expect(first.querySelector(".line-name")?.textContent).toBe("lume-cafe / product-definition");
    expect(first.querySelector(".pr-prefix")?.textContent).toBe("PR ");
  });

  it("prints the state words at 768 px and up and one word for a phone, the CI glyph a mark", () => {
    const state = (n: number) => rows()[n].querySelector(".state")!;
    expect(rows().map((row) => [row.querySelector(".pr-words")?.textContent, row.querySelector(".pr-word")?.textContent])).toEqual([
      ["ready · CI …", "CI …"],
      ["ready · CI ✗", "CI ✗"],
      ["ready · CI ✓", "CI ✓"],
      ["ready", "ready"],
    ]);
    expect(state(1).querySelector(".pr-words")?.querySelector(".mark")?.className).toBe("mark failed wide");
    expect(state(2).querySelector(".pr-words")?.querySelector(".mark")?.className).toBe("mark done wide");
  });

  it("prints a dash for a size the route did not count and for a wait it did not date, and puts that row last", () => {
    const row = rows()[3];
    expect(row.querySelector(".pr")?.textContent).toBe("PR #177");
    expect(row.querySelector(".size")?.textContent).toBe("–");
    expect(row.querySelector(".since")?.textContent).toBe("–");
    expect(row.querySelector(".since")?.title).toBe("");
    expect(rows()[1].querySelector(".since")?.title).toMatch(/^last changed /);
  });

  it("keeps a merged pull request off the section", () => {
    expect(page.root.querySelector(".tree-head")!.textContent).not.toContain("#150");
  });
});

describe("the drafts fold", () => {
  it("is a disclosure button like a goal's, closed by default, with the drafts under it when open", async () => {
    expect(kids(fold()).map((c) => [c.tagName, c.className])).toEqual([["BUTTON", "mark disclosure"], ["DIV", "main"]]);
    expect([button().getAttribute("aria-expanded"), button().getAttribute("aria-label"), button().getAttribute("data-focus"), button().textContent]).toEqual(["false", "Open the 2 drafts", "fold:review-drafts", "▶"]);
    expect(fold().querySelector(".line-name")?.textContent).toBe("2 drafts");
    expect(lines()).toHaveLength(5);

    button().click();
    expect([button().getAttribute("aria-expanded"), button().getAttribute("aria-label"), button().textContent]).toEqual(["true", "Fold the 2 drafts", "▼"]);
    const drafts = lines().slice(lines().indexOf(fold()) + 1);
    expect(drafts.map((row) => row.querySelector(".pr")?.textContent)).toEqual(["PR #190", "PR #186"]);
    expect(drafts.map((row) => row.querySelector(".mark")?.className)).toEqual(["mark pending", "mark pending"]);
    expect(cells(drafts[1])).toEqual([
      "pr@3=PR #186",
      "line-name=kitterm / sessions-workflow",
      "line-detail=sessions-workflow round 7: the REVIEW section is one row per pull request",
      "state=draft · CI …draft",
      "size@2=+400 −90",
      "since@4=1h",
    ]);
    expect(drafts[1].querySelector("a")?.href).toBe(`${BASE}186`);

    // The fold stays open across a repaint.
    const later = vi.spyOn(Date, "now").mockReturnValue(NOW + 120_000);
    await page.poll();
    later.mockRestore();
    expect(button().getAttribute("aria-expanded")).toBe("true");
    expect(lines()).toHaveLength(7);

    button().click();
    expect(button().getAttribute("aria-expanded")).toBe("false");
    expect(lines()).toHaveLength(5);
  });

  it("is the only control the section adds: links and one triangle", () => {
    const tree = page.root.querySelector(".tree-head")!;
    expect(tree.querySelectorAll("button").map((b) => b.className)).toEqual(["mark disclosure"]);
    expect(tree.querySelectorAll("input")).toEqual([]);
  });
});

describe("the section with no pull request to list", () => {
  it("says so in the header, and keeps the drafts line when drafts exist", async () => {
    const was = routes["/api/projects/kitterm/pulls"] as { pulls: unknown[] };
    const cafeWas = routes["/api/projects/lume-cafe/pulls"] as { pulls: unknown[] };
    const later = vi.spyOn(Date, "now");
    try {
      routes["/api/projects/lume-cafe/pulls"] = { ...cafeWas, pulls: [] };
      routes["/api/projects/kitterm/pulls"] = { ...was, pulls: [pull(186, "goal/sessions-workflow", { draft: true })] };
      later.mockReturnValue(NOW + 300_000);
      await page.poll();
      expect(head().textContent).toBe("No pull request is ready for review.none ready 1 draft");
      expect(rows().length).toBe(0);
      expect(fold().textContent).toBe("▶1 draft");
      routes["/api/projects/kitterm/pulls"] = { ...was, pulls: [] };
      later.mockReturnValue(NOW + 420_000);
      await page.poll();
      expect(head().textContent).toBe("No pull request is ready for review.none ready");
      expect(block().children.length).toBe(0);
      expect(block().hidden).toBe(false);
      // The no-gh notice hides the rows with the header's sentence in their place.
      routes["/api/projects/kitterm/pulls"] = { ok: true, project: "kitterm", pulls: [], reason: "gh is not on PATH" };
      later.mockReturnValue(NOW + 540_000);
      await page.poll();
      expect(head().textContent).toBe("Pull request states are not read: gh is not installed.");
      expect(block().hidden).toBe(true);
    } finally {
      routes["/api/projects/kitterm/pulls"] = was;
      routes["/api/projects/lume-cafe/pulls"] = cafeWas;
      later.mockReturnValue(NOW + 660_000);
      await page.poll();
      later.mockRestore();
    }
    expect(block().hidden).toBe(false);
    expect(rows()).toHaveLength(4);
  });
});
