import { beforeAll, describe, expect, it, vi } from "vitest";

import { FakeElement, installFakePage } from "./fake-page";
import {
  foldDoneTasks,
  goalFacts,
  goalLine,
  goalTag,
  HEADING_DROP_ORDER,
  keptFacts,
  markFamily,
  markGlyph,
  type MergedState,
  type ModelRow,
  ROW_DROP_ORDER,
  rowLine,
  stateTag,
  stateWord,
  taskFacts,
  type TaskLine,
  taskMark,
  taskTag,
  VOCABULARY,
  type KnowledgeSummary,
} from "./sessions-model";

/**
 * Every line is one line (`agent-dashboard`, capability 5;
 * `design-foundation.md`, principle 3 and "The line, in detail"). The
 * first blocks pin the pure model: the vocabulary every state reads as, a
 * bracketed word beside its mark; the facts of each level and the order
 * they drop in; how many survive a given shortfall; and the fold a phone
 * puts a goal's done tasks behind. The last block renders the page and
 * checks that every line names one cell to truncate and numbers its facts
 * in drop order, which is what `fitLines` reads.
 */

const NOW = 1_758_000_000_000;
const row = (id: string, extra: Partial<ModelRow> = {}): ModelRow => ({ id, cwd: "/w/kitterm", ...extra });

describe("the state vocabulary", () => {
  const states: MergedState[] = ["working", "needs-approval", "needs-input", "completed", "failed", "idle", "exited", "unknown"];

  it("reads every row state as a bracketed word beside its mark, never a bare one", () => {
    expect(states.map((state) => stateTag(row("r", { mergedState: state })))).toEqual([
      "[working]", "[needs you]", "[needs you]", "[done]", "[failed]", "[idle]", "[exited]", "[no integration]",
    ]);
    expect(states.map(markFamily)).toEqual(["running", "attention", "attention", "done", "failed", "idle", "unknown", "unknown"]);
    expect(states.map(stateWord).every((word) => !word.includes("["))).toBe(true);
  });

  it("keeps the exit code inside the word, once, and never prints exit 0", () => {
    expect(stateTag(row("r", { mergedState: "failed", lastExit: 1 }))).toBe("[failed (1)]");
    expect(stateTag(row("r", { mergedState: "exited", lastExit: 130 }))).toBe("[exited (130)]");
    expect(stateTag(row("r", { mergedState: "failed", lastExit: 0 }))).toBe("[failed]");
    expect(stateTag(row("r", { mergedState: "idle", lastExit: 1 }))).toBe("[idle]");
    expect(rowLine(row("r", { mergedState: "needs-input", lastOutputAt: NOW }), NOW).state).toBe("[needs you]");
  });

  it("prints one character per mark, and never a box: the working mark's rest is the spinner's", () => {
    expect((["attention", "failed", "done", "pending", "idle", "unknown", "running"] as const).map(markGlyph)).toEqual([
      "?", "!", "✓", "·", "–", "–", ">",
    ]);
  });

  it("reads every task state as its word and its mark", () => {
    expect((["working", "pending", "done", "failed"] as const).map((s) => [taskTag(s), taskMark(s)])).toEqual([
      ["[working]", "running"], ["[pending]", "pending"], ["[done]", "done"], ["[failed]", "failed"],
    ]);
  });

  it("reads a goal's state from its bucket, its status, and whether its proposals wait", () => {
    expect(goalTag("working", null, false)).toEqual({ family: "running", tag: "[working]" });
    expect(goalTag("pending", null, false)).toEqual({ family: "pending", tag: "[pending]" });
    expect(goalTag("pending", "waiting", false)).toEqual({ family: "attention", tag: "[waiting]" });
    expect(goalTag("pending", "stopped", false)).toEqual({ family: "idle", tag: "[stopped]" });
    expect(goalTag("working", null, true), "what needs a person wins").toEqual({ family: "attention", tag: "[needs you]" });
    expect(goalTag("pending", "waiting", true)).toEqual({ family: "attention", tag: "[needs you]" });
  });

  it("prints the whole vocabulary in the tree's header, in the foundation's order", () => {
    expect(VOCABULARY.map((v) => v.tag)).toEqual(["[working]", "[needs you]", "[pending]", "[done]", "[failed]", "[idle]"]);
    expect(VOCABULARY.map((v) => markGlyph(v.family))).toEqual([">", "?", "·", "✓", "!", "–"]);
  });
});

describe("the facts of each level, and the order they drop in", () => {
  const summary: KnowledgeSummary = {
    project: "kitterm", slug: "agent-dashboard", goal: "/sessions is a dashboard", status: "active", round: 7, budget: 3,
    nextAction: "Round 7, `every-line-is-one-line`.\nMore.",
  };

  it("a goal's facts stand cost, round, next action, and drop next, round, cost", () => {
    const line = goalLine(summary);
    const facts = goalFacts(line, "$65.72");
    expect(facts).toEqual(["$65.72", "round 7 of 3", "Round 7, `every-line-is-one-line`."]);
    // Each drop step takes the rightmost fact that is left.
    expect([3, 2, 1, 0].map((kept) => facts.slice(0, kept))).toEqual([
      ["$65.72", "round 7 of 3", "Round 7, `every-line-is-one-line`."],
      ["$65.72", "round 7 of 3"],
      ["$65.72"],
      [],
    ]);
    expect(goalFacts(goalLine({ ...summary, round: undefined, nextAction: undefined }), null)).toEqual([]);
    expect(goalFacts(line, null)).toEqual(["round 7 of 3", "Round 7, `every-line-is-one-line`."]);
  });

  it("a task's facts stand round, PR, and drop the PR first", () => {
    expect(taskFacts({ slug: "x", state: "done", round: 2, pr: 126 })).toEqual(["round 2", "PR #126"]);
  });

  it("a row drops what it is doing, then where it is, then its model, and never its state", () => {
    expect(ROW_DROP_ORDER).toEqual(["what", "place", "model"]);
    const line = rowLine(row("r", { name: "crew", cwd: "/w/kitterm/docs", mergedState: "working", agent: { message: "Running the floor" } }), NOW);
    expect([line.what, line.place, line.state]).toEqual(["Running the floor", "docs", "[working]"]);
  });

  it("a heading drops its count before its cost", () => {
    expect(HEADING_DROP_ORDER).toEqual(["tally", "cost"]);
  });
});

describe("keptFacts", () => {
  const widths = [30, 50, 40];

  it("keeps every fact when nothing is short", () => {
    expect(keptFacts(widths, 0, 8)).toBe(3);
    expect(keptFacts(widths, -5, 8)).toBe(3);
    expect(keptFacts([], 0, 8)).toBe(0);
  });

  it("drops facts from the front of the drop order until the room they free covers the need", () => {
    expect(keptFacts(widths, 1, 8), "the first fact and its gap free 38").toBe(2);
    expect(keptFacts(widths, 38, 8)).toBe(2);
    expect(keptFacts(widths, 39, 8), "two facts free 96").toBe(1);
    expect(keptFacts(widths, 96, 8)).toBe(1);
    expect(keptFacts(widths, 97, 8)).toBe(0);
  });

  it("drops them all, whole, when no number of facts covers the need: the name then truncates", () => {
    expect(keptFacts(widths, 1000, 8)).toBe(0);
    expect(keptFacts([], 1, 8)).toBe(0);
  });
});

describe("foldDoneTasks", () => {
  const task = (slug: string, state: TaskLine<ModelRow>["state"]): TaskLine<ModelRow> => ({ slug, state, tag: taskTag(state), facts: [], rows: [] });

  it("keeps working, pending and failed tasks open, in their order, and folds the done ones", () => {
    const tasks = [task("a", "pending"), task("b", "done"), task("c", "working"), task("d", "failed"), task("e", "done")];
    const { open, done } = foldDoneTasks(tasks);
    expect(open.map((t) => t.slug)).toEqual(["a", "c", "d"]);
    expect(done.map((t) => t.slug)).toEqual(["b", "e"]);
  });

  it("folds nothing for a goal with no done task, and opens nothing for one with only done tasks", () => {
    expect(foldDoneTasks([task("a", "pending")])).toEqual({ open: [task("a", "pending")], done: [] });
    expect(foldDoneTasks([task("a", "done")]).open).toEqual([]);
    expect(foldDoneTasks([])).toEqual({ open: [], done: [] });
  });
});

// --- the page ------------------------------------------------------------------

const ROOT = "/Users/antran/Workspace/kitterm";
const project = { id: "kitterm", name: "kitterm", root: ROOT, registered: true, knowledge: "docs/goals" };

const crew = {
  id: "s-crew", name: "crew", cwd: `${ROOT}/.claude/worktrees/one-line`, state: "running", mergedState: "working", marks: 0,
  labels: { crew: "agent-dashboard", goal: "agent-dashboard", round: "7", task: "every-line-is-one-line" },
  foregroundProgram: "claude", agent: { status: "working", message: "Measuring the page", at: NOW - 5_000 },
  agentModel: "claude-fable-5-1", agentModelName: "Fable 5.1", lastOutputAt: NOW - 5_000, orchestrated: true, project,
};
const blocked = {
  id: "s-blocked", name: "review", cwd: ROOT, state: "running", mergedState: "needs-approval", marks: 0, pendingApproval: true,
  lastOutputAt: NOW - 60_000, project,
};
const approval = { id: "a-1", session: "s-blocked", tool: "Bash", input: JSON.stringify({ command: "swift test" }), waitingMs: 45_000 };

const dashboard = {
  project: "kitterm", slug: "agent-dashboard", goal: "/sessions is a dashboard for workspaces and agents", status: "active",
  round: 7, budget: 3, costUSD: 65.72, nextAction: "Round 7, `every-line-is-one-line`, from `plan.md` row 5.",
  tasks: [
    { slug: "every-line-is-one-line", state: "pending" },
    { slug: "the-page-says-what-the-spend-bought", state: "done", round: 6, pr: 130 },
    { slug: "no-input-on-the-page", state: "done", round: 1, pr: 125 },
  ],
};

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [crew, blocked] },
  "/api/projects": { projects: [project] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [dashboard] },
  "/api/approvals": { approvals: [approval] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
};

/** The page's width, as `matchMedia("(max-width: 767px)")` reports it. */
let phone = true;
let page: ReturnType<typeof installFakePage>;

beforeAll(async () => {
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ get matches() { return phone; }, addEventListener(): void {} }));
  await import("./sessions");
  await page.settle();
});

const lines = (): FakeElement[] => page.root.querySelectorAll(".line");
const textOf = (els: FakeElement[]): string[] => els.map((el) => el.textContent);

describe("the page's lines", () => {
  it("draws every level as one line with one name cell and its facts numbered in drop order", () => {
    const all = lines();
    expect(all.length).toBeGreaterThanOrEqual(5);
    for (const line of all) {
      expect(line.querySelectorAll("[data-name]").length, `${line.className}: one name`).toBe(1);
      const drops = line.querySelectorAll("[data-drop]").map((cell) => Number(cell.getAttribute("data-drop"))).sort((a, b) => a - b);
      expect(drops, `${line.className}: facts numbered from 0`).toEqual(drops.map((_, i) => i));
    }
  });

  it("prints a row's state as the bracketed word, its facts after it, its model before the time", () => {
    const main = page.root.querySelectorAll(".main").find((m) => m.textContent.startsWith("crew"))!;
    const cells = main.children.filter((c): c is FakeElement => typeof c !== "string");
    // The span reads the real clock, so only its shape is pinned.
    expect(cells.map((c) => [c.className, c.className === "since" ? c.textContent.replace(/^\d+[mhd]$/, "<span>") : c.textContent])).toEqual([
      ["folder", "crew"], ["state running", "[working]"], ["place", ".claude/worktrees/one-line"], ["what", "Measuring the page"],
      ["model", "Fable 5.1"], ["since", "<span>"],
    ]);
    expect(cells.map((c) => c.getAttribute("data-drop")), "what drops first, then place, then the model").toEqual([null, null, "1", "0", "2", null]);
  });

  it("prints a goal's line as mark, title, word, then cost, round, next action", () => {
    const goal = page.root.querySelector(".goal-line")!;
    expect(goal.querySelector(".mark")?.className).toBe("mark running");
    expect(goal.querySelector(".tag-state")?.textContent).toBe("[working]");
    expect(textOf(goal.querySelectorAll("[data-drop]"))).toEqual(["$65.72", "round 7 of 3", "Round 7, `every-line-is-one-line`, from `plan.md` row 5."]);
    expect(goal.querySelectorAll("[data-drop]").map((c) => c.getAttribute("data-drop"))).toEqual(["2", "1", "0"]);
    expect(page.root.querySelectorAll(".goal-next")[0].hasAttribute("hidden"), "hidden only by measurement, which this DOM cannot do").toBe(false);
  });

  it("prints the vocabulary in the tree's header, each mark beside its word, the working one at rest", () => {
    const head = page.root.querySelector(".tree-head")!;
    expect(head.querySelector(".tree-label")?.textContent).toBe("SESSIONS");
    expect(textOf(head.querySelectorAll(".tag-state"))).toEqual(["[working]", "[needs you]", "[pending]", "[done]", "[failed]", "[idle]"]);
    expect(head.querySelectorAll(".mark").map((m) => m.className)).toEqual([
      "mark running rest", "mark attention rest", "mark pending rest", "mark done rest", "mark failed rest", "mark idle rest",
    ]);
    expect(page.root.children.indexOf(head), "inside the tree, not above the panels").toBe(-1);
    expect(page.root.querySelector(".cards")?.children[0]).toBe(head);
  });

  it("folds a goal's done tasks on a phone behind `N done`, the way a project folds its done goals", () => {
    const fold = page.root.querySelector(".done-tasks")!;
    expect(fold.tagName).toBe("DETAILS");
    expect(fold.querySelector("summary")?.textContent).toBe("2 done");
    expect(textOf(fold.querySelectorAll(".line-name"))).toEqual(["the-page-says-what-the-spend-bought", "no-input-on-the-page"]);
    const open = page.root.querySelectorAll(".tree-tasks")[0];
    expect(textOf(open.querySelectorAll(".line-name")), "the working task stays open, the crew under it").toEqual(["every-line-is-one-line"]);
    expect(open.querySelectorAll(".row")).toHaveLength(1);
  });

  it("draws every task at 768 px and up, and no fold", async () => {
    phone = false;
    await page.poll();
    expect(page.root.querySelectorAll(".done-tasks")).toEqual([]);
    expect(textOf(page.root.querySelectorAll(".line-name"))).toEqual([
      "every-line-is-one-line", "the-page-says-what-the-spend-bought", "no-input-on-the-page",
    ]);
    phone = true;
  });

  it("marks an approval's line with its name and its one fact, the arguments", () => {
    const line = page.root.querySelector(".line-approval")!;
    expect(line.querySelector("[data-name]")?.textContent).toBe("approve Bash");
    expect(textOf(line.querySelectorAll("[data-drop]"))).toEqual(["swift test"]);
    expect(line.querySelector(".mark")?.textContent).toBe("?");
  });

  it("stands no label over a bucket: each goal line says its own state", () => {
    expect(page.root.querySelectorAll(".bucket")).toEqual([]);
    expect(page.root.textContent).not.toContain("1 working");
  });
});
