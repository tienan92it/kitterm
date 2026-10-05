import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { type ModelRow, type ProjectSummary } from "./sessions-model";

/**
 * The SESSIONS section as the page paints it with pull request state
 * (`sessions-workflow`, capability 5; `goal.md` conditions 3, 4 and 7):
 * the legend, the `REVIEW` line, the status cell, the pull request's
 * state words, the joins, and the poll of
 * `GET /api/projects/<id>/pulls`. `sessions-stage-tree.test.ts` pins the
 * pure model.
 */

const NOW = Date.now();
const BASE = "https://github.com/tienan92it/kitterm/pull/";
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: "/Users/an/Workspace/kitterm", registered: true, knowledge: "docs/goals", pullRequestBase: BASE };
/** No GitHub remote: the page asks no pulls route for it. */
const local: ProjectSummary = { id: "fnb", name: "fnb-design", root: "/Users/an/Sites/fnb-design", registered: true, knowledge: "docs/goals" };
const ref = (p: ProjectSummary) => ({ id: p.id, name: p.name, root: p.root, registered: p.registered });

const crew = {
  id: "s-crew", name: "round 6", cwd: `${kitterm.root}/.claude/worktrees/x`, state: "running", mergedState: "working", marks: 0, project: ref(kitterm),
  labels: { goal: "sessions-workflow", task: "stage-tree", round: "6", pr: "185" }, lastOutputAt: NOW - 5_000,
} as ModelRow;

const pull = (number: number, head: string, extra: Record<string, unknown> = {}) => ({
  number, title: `t${number}`, state: "open", draft: false, headRefName: head, url: `${BASE}${number}`, additions: 1, deletions: 0, ...extra,
});

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [crew] },
  "/api/projects": { projects: [kitterm, local] },
  "/api/projects/kitterm/knowledge": {
    ok: true, project: "kitterm", source: "origin/main",
    goals: [
      {
        slug: "sessions-workflow", goal: "the SESSIONS tree shows each scope's work stage", status: "active", round: 1, budget: 3, source: "origin/goal/sessions-workflow", pullRequest: 185,
        tasks: [{ slug: "stage-tree", state: "pending", pr: 185 }],
      },
      { slug: "foreman-scope", goal: "each foreman keeps its own projects", status: "active", round: 2, budget: 3 },
      { slug: "green-ci-again", goal: "CI is green again", status: "active", round: 1, budget: 3 },
    ],
  },
  "/api/projects/kitterm/pulls": {
    ok: true, project: "kitterm", readAt: NOW - 20_000, ageSeconds: 20,
    pulls: [
      pull(185, "goal/sessions-workflow", { draft: true, ci: "pending" }),
      pull(180, "goal/foreman-scope", { ci: "passing" }),
      pull(177, "chore/readme"),
      pull(156, "goal/green-ci-again", { ci: "failing" }),
      pull(150, "goal/old", { state: "merged" }),
    ],
  },
  "/api/projects/fnb/knowledge": { ok: true, project: "fnb", goals: [{ slug: "menu-board", goal: "the menu board prints", status: "active", tasks: [{ slug: "print", state: "pending", pr: 12 }] }] },
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
const goalNamed = (name: string) => page.root.querySelectorAll(".goal-line").find((g) => g.querySelector(".line-name")?.textContent === name)!;

describe("the header", () => {
  it("prints the stages, a rule, and the session words, each mark at rest beside its word", () => {
    const keys = page.root.querySelector(".tree-keys")!;
    expect(kids(keys).map((k) => `${k.className}=${k.textContent}`)).toEqual([
      "tree-group=stage", "tree-key=•[plan]", "tree-key=◐[build]", "tree-key=?[review]", "tree-key=?![blocked]", "tree-key=✓[done]",
      "tree-rule=|",
      "tree-group=session", "tree-key=◐[working]", "tree-key=?[needs you]", "tree-key=–[idle]",
    ]);
    const blocked = kids(keys)[4];
    expect(blocked.querySelectorAll(".mark").map((m) => m.className)).toEqual(["mark attention rest", "mark failed rest"]);
  });

  it("puts REVIEW in the header's gutter, under SESSIONS", () => {
    const head = page.root.querySelector(".tree-head")!;
    expect(kids(head).map((c) => c.className)).toEqual(["tree-label", "tree-keys", "review-label", "review"]);
    expect(head.querySelector(".review-label")?.textContent).toBe("REVIEW");
    expect(head.querySelector(".review")?.hidden).toBe(false);
  });
});

describe("the REVIEW line (goal.md, condition 4)", () => {
  const review = () => page.root.querySelector(".review")!;

  it("counts the pull requests that are ready and links each one, a chore's too, then the drafts", () => {
    expect(review().querySelector(".mark")?.className).toBe("mark attention wide");
    expect(review().querySelector(".mark")?.textContent).toBe("3");
    const items = review().querySelectorAll(".review-pull");
    expect(items.map((i) => i.textContent)).toEqual([
      "PR #180 CI ✓ kitterm / foreman-scope",
      "PR #177 kitterm / chore readme",
      "PR #156 CI ✗ kitterm / green-ci-again",
      "PR #185 draft · CI … kitterm / sessions-workflow",
    ]);
    expect(items.map((i) => { const a = i.querySelector("a")!; return [a.className, a.href, a.getAttribute("data-focus")]; })).toEqual([
      ["pr-link", `${BASE}180`, "review:kitterm:180"],
      ["pr-link", `${BASE}177`, "review:kitterm:177"],
      ["pr-link", `${BASE}156`, "review:kitterm:156"],
      ["pr-link", `${BASE}185`, "review:kitterm:185"],
    ]);
    expect(review().querySelector(".review-drafts")?.textContent).toBe(" 1 draft");
    // A merged pull request is not on the line.
    expect(review().textContent).not.toContain("#150");
  });

  it("colours the CI glyph alone, as a mark", () => {
    const marks = review().querySelectorAll(".review-ci").flatMap((ci) => ci.querySelectorAll(".mark").map((m) => `${m.className}=${m.textContent}`));
    expect(marks).toEqual(["mark done wide=✓", "mark failed wide=✗"]);
  });

  it("carries the short form a phone prints: the count, each number, one state word", () => {
    // The sheet shows `.review-short` and hides `.review-long`, `.pr-prefix`
    // and a draft's CI word below 768 px (`sessions-stage-css.test.ts`).
    const phone = (el: FakeElement): string => kids(el).filter((c) => !c.classList.contains("review-long") && !c.classList.contains("pr-prefix")).map((c) => (c.children.some((k) => typeof k !== "string") ? phone(c) : c.textContent)).join("") + el.children.filter((c) => typeof c === "string").join("");
    const short = review().children.map((c) => (typeof c === "string" ? c : c.classList.contains("review-long") ? "" : c.classList.contains("review-pull") ? phone(c) : c.textContent)).join("");
    expect(short.replace(/\s+/g, " ")).toContain("3 ready");
    expect(short).toContain("#180");
    expect(short).not.toContain("kitterm /");
    expect(review().querySelectorAll(".review-short").map((s) => s.textContent)).toEqual([" ready", " ·"]);
  });

  it("says so when no pull request is ready", async () => {
    const was = routes["/api/projects/kitterm/pulls"] as { pulls: unknown[] };
    const later = vi.spyOn(Date, "now");
    try {
      routes["/api/projects/kitterm/pulls"] = { ...was, pulls: [pull(185, "goal/sessions-workflow", { draft: true, ci: "pending" })] };
      later.mockReturnValue(NOW + 60_000);
      await page.poll();
      expect(kids(review()).slice(0, 2).map((s) => `${s.className}=${s.textContent}`)).toEqual(["review-long=No pull request is ready for review.", "review-short=none ready"]);
      expect(review().querySelector(".mark.attention"), "no count to mark").toBeNull();
      expect(review().querySelectorAll(".review-pull").map((i) => i.textContent)).toEqual(["PR #185 draft · CI … kitterm / sessions-workflow"]);
      routes["/api/projects/kitterm/pulls"] = { ...was, pulls: [] };
      later.mockReturnValue(NOW + 120_000);
      await page.poll();
      expect(review().textContent).toBe("No pull request is ready for review.none ready");
    } finally {
      routes["/api/projects/kitterm/pulls"] = was;
      later.mockReturnValue(NOW + 180_000);
      await page.poll();
      later.mockRestore();
    }
    expect(review().querySelectorAll(".review-pull")).toHaveLength(4);
  });
});

describe("a goal line and a task line (goal.md, conditions 2 and 3)", () => {
  it("draws one status cell: the stage's mark as the line's own child, the word in .main", () => {
    const line = goalNamed("sessions-workflow");
    expect(kids(line).map((c) => c.className)).toEqual(["mark disclosure", "mark running", "joins", "main"]);
    expect(line.querySelector(".state")?.className).toBe("state running");
    expect(line.querySelector(".state")?.textContent).toBe("[build]");
    expect(goalNamed("green-ci-again").querySelectorAll(".mark").map((m) => m.className).slice(0, 2)).toEqual(["mark blank", "mark failed"]);
    expect(goalNamed("foreman-scope").querySelector(".state")?.textContent).toBe("[review]");
    const task = page.root.querySelectorAll(".line-task").find((t) => t.querySelector(".line-name")?.textContent === "stage-tree")!;
    // A task with a session under it: its mark, its triangle, its joins.
    expect(kids(task).map((c) => c.className)).toEqual(["mark running", "mark disclosure", "joins", "main"]);
    expect(task.querySelector(".state")?.textContent).toBe("[build]");
    expect(task.querySelector(".pr"), "PR #185 is its goal's").toBeNull();
  });

  it("orders the goals blocked, review, build, and prints the reason or the purpose after the name", () => {
    // The sections stand in name order: `fnb-design`, then `kitterm`.
    expect(page.root.querySelectorAll(".goal-line").map((g) => [g.querySelector(".line-name")?.textContent, g.querySelector(".line-detail")?.textContent])).toEqual([
      ["menu-board", "the menu board prints"],
      ["green-ci-again", "CI fails on PR #156"],
      ["foreman-scope", "each foreman keeps its own projects"],
      ["sessions-workflow", "the SESSIONS tree shows each scope's work stage"],
    ]);
  });

  it("prints PR #N as a link with the state words, and the one word a phone keeps", () => {
    const cell = (name: string) => goalNamed(name).querySelector(".pr")!;
    expect(["sessions-workflow", "foreman-scope", "green-ci-again"].map((name) => [cell(name).querySelector("a")?.href, cell(name).querySelector("a")?.textContent, cell(name).querySelector(".pr-words")?.textContent, cell(name).querySelector(".pr-word")?.textContent])).toEqual([
      [`${BASE}185`, "PR #185", " draft · CI …", " draft"],
      [`${BASE}180`, "PR #180", " ready · CI ✓", " CI ✓"],
      [`${BASE}156`, "PR #156", " ready · CI ✗", " CI ✗"],
    ]);
    // The `PR ` a phone drops is its own element inside the link.
    expect(cell("sessions-workflow").querySelector(".pr-prefix")?.textContent).toBe("PR ");
    expect(cell("green-ci-again").querySelector(".pr-words")?.querySelector(".mark")?.className).toBe("mark failed wide");
    expect(cell("sessions-workflow").getAttribute("data-col")).toBe("3");
  });

  it("ties each line under a scope to its parent with one join cell per level", () => {
    const joinsOf = (line: FakeElement) => line.querySelector(".joins")?.querySelectorAll(".join").map((j) => j.className.replace("join ", "")) ?? [];
    const section = page.root.querySelectorAll(".tree-section").find((s) => s.getAttribute("aria-label") === "kitterm")!;
    const lines = section.querySelectorAll(".line");
    expect(lines.map((l) => [l.querySelector(".line-name")?.textContent, joinsOf(l).join(" ")])).toEqual([
      ["kitterm", ""],
      ["green-ci-again", "tee"],
      ["foreman-scope", "tee"],
      ["sessions-workflow", "end"],
      ["stage-tree", "none end"],
      ["round 6", "none none end"],
    ]);
    // A line with no triangle draws its tick through to the name.
    expect(lines[5].querySelector(".joins")?.className).toBe("joins long");
    expect(lines[5].querySelector(".joins")?.getAttribute("aria-hidden")).toBe("true");
  });
});

describe("the poll of the pulls route", () => {
  it("asks for each project with a GitHub remote, and for no other", () => {
    const asked = page.requests.filter((u) => u.includes("/pulls"));
    expect(new Set(asked)).toEqual(new Set(["/api/projects/kitterm/pulls"]));
  });

  it("asks again no sooner than ten seconds after the last answer", async () => {
    const count = () => page.requests.filter((u) => u.includes("/pulls")).length;
    const before = count();
    await page.poll();
    await page.poll();
    expect(count()).toBe(before);
    const later = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 400_000);
    await page.poll();
    later.mockRestore();
    expect(count()).toBe(before + 1);
  });

  it("says on the line of a project with no GitHub remote why its numbers carry no state, and prints the number as plain text", () => {
    const project = page.root.querySelectorAll(".line-project").find((l) => l.querySelector(".line-name")?.textContent === "fnb-design")!;
    expect(project.querySelector(".line-detail")?.textContent).toBe("no GitHub remote: pull request states are not read");
    const cell = goalNamed("menu-board").querySelector(".pr")!;
    expect([cell.textContent, cell.querySelector("a"), cell.querySelector(".pr-words")]).toEqual(["PR #12", null, null]);
  });
});

describe("the page still holds no action", () => {
  it("adds links and triangles, and no other control", () => {
    const head = page.root.querySelector(".tree-head")!;
    expect(head.querySelectorAll("button")).toEqual([]);
    expect(head.querySelectorAll("input")).toEqual([]);
    expect(page.root.querySelector(".tree")!.querySelectorAll("button").map((b) => b.className).every((c) => c === "mark disclosure")).toBe(true);
  });
});
