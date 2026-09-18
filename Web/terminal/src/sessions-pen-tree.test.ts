import { beforeAll, describe, expect, it } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { type Approval, type KnowledgeSummary, type ModelRow, type ProjectSummary, type UsageDaily } from "./sessions-model";
import { goalFactColumns, headingFactColumns, sessionFactColumns, taskFactColumns, tree, type TreeLine } from "./sessions-tree";

/**
 * The tree as the frames `Dashboard 1200` and `Dashboard 390` draw it
 * (`agent-dashboard`, round 10): flat lines, the mark at the far left, an
 * indent per level, then the state word and three fact columns; a project's
 * most recent done goal open with its last two done tasks and the rest
 * behind `N done`; idle shells folded at the page's foot beside the
 * archives and the push switch. The first block pins the pure model over a
 * fleet shaped like the frame's fixture; the second renders the page
 * through `sessions.ts` and pins the columns, the folds and the absences.
 */

/** The page reads the clock, so the fixture's moments sit against it. */
const NOW = Date.now();
const W = "/w";
const NNT = `${W}/NgheNhanTrading`;
const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true, knowledge: "docs/goals" };
const mdp: ProjectSummary = { id: "mdp", name: "market-data-pipeline", root: `${NNT}/market-data-pipeline`, registered: true, knowledge: "docs/goals" };
const mt5: ProjectSummary = { id: "mt5", name: "nghenhan-mt5", root: `${NNT}/nghenhan-mt5`, registered: true, knowledge: "docs/goals" };
const ref = (p: ProjectSummary) => ({ id: p.id, name: p.name, root: p.root, registered: p.registered });

const rows = {
  /** A shell running a command in kitterm's root, no goal. */
  root: { id: "s-root", cwd: kitterm.root!, state: "running", mergedState: "working", marks: 0, project: ref(kitterm), lastOutputAt: NOW - 4 * 60_000 } as ModelRow,
  /** An agent stopped on a tool call. */
  blocked: { id: "s-blocked", name: "review", cwd: kitterm.root!, state: "running", mergedState: "needs-approval", marks: 0, project: ref(kitterm), lastOutputAt: NOW - 60_000 } as ModelRow,
  /** An idle shell: not a line of the tree. */
  idle: { id: "s-idle", cwd: kitterm.root!, state: "idle", mergedState: "idle", marks: 1, lastExit: 0, project: ref(kitterm), lastOutputAt: NOW - 3_600_000 } as ModelRow,
  /** The crew of a done goal, still on the tty. */
  crew: {
    id: "s-crew", name: "path-mapping-real-terminal", cwd: `${mdp.root}/.claude/worktrees/x`, state: "running", mergedState: "working", marks: 0,
    project: ref(mdp), labels: { crew: "symbol-onboarding", goal: "symbol-onboarding", round: "6" },
    agentModel: "claude-fable-5-1", agentModelName: "Fable 5.1", agent: { message: "Mapping the path" }, lastOutputAt: NOW - 4 * 60_000,
  } as ModelRow,
};
const approval: Approval = { id: "a-1", tool: "Bash", input: JSON.stringify({ command: "swift test" }), session: "s-blocked", waitingMs: 45_000 };

const kittermGoals: KnowledgeSummary[] = [
  {
    project: "kitterm", slug: "agent-dashboard", goal: "agent-dashboard", status: "waiting", round: 0, budget: 3,
    nextAction: "Round 10, `the-page-is-the-pen-design`.",
    tasks: [
      { slug: "no-input-on-the-page", state: "pending" },
      { slug: "the-foundation-in-the-stylesheet", state: "pending" },
      { slug: "a-task-is-the-fourth-level", state: "pending" },
      { slug: "others-not-a-count", state: "done", round: 9, pr: 133 },
      { slug: "models-top-three", state: "done", round: 8, pr: 132 },
      { slug: "every-line-is-one-line", state: "done", round: 7, pr: 131 },
    ],
  },
  {
    project: "kitterm", slug: "workspace-ledger", goal: "workspace-ledger", status: "done", round: 6, budget: 3, costUSD: 75.11, lastRound: 6, lastRecord: "workspace-ledger/rounds/006.md",
    tasks: [
      { slug: "the-strip-holds-only-what-needs-you", state: "done", round: 6, pr: 124 },
      { slug: "the-numbers-on-the-page", state: "done", round: 5, pr: 123 },
      { slug: "answer-from-the-page", state: "done", round: 4, pr: 122 },
    ],
    rounds: [{ number: 6, started: "2026-09-17", correction: false }],
  },
  { project: "kitterm", slug: "fleet-catch-up", goal: "fleet-catch-up", status: "done", round: 4, budget: 4, costUSD: 35.79, rounds: [{ number: 4, started: "2026-09-12", correction: false }] },
  { project: "kitterm", slug: "cost-per-round", goal: "cost-per-round", status: "done", round: 4, budget: 4, rounds: [{ number: 4, started: "2026-09-13", correction: false }] },
];
const mdpGoals: KnowledgeSummary[] = [
  {
    project: "mdp", slug: "symbol-onboarding", goal: "one command onboards a symbol", status: "done", round: 6, budget: 3, costUSD: 41.02,
    tasks: [{ slug: "path-mapping", state: "done", round: 6, pr: 40 }],
    rounds: [{ number: 6, started: "2026-09-16", correction: false }],
  },
];
const knowledge: Record<string, KnowledgeSummary[]> = { kitterm: kittermGoals, mdp: mdpGoals, mt5: [] };

const tokens = { input: 1, output: 1, cacheCreation: 0, cacheRead: 0, requests: 1 };
const bucket = (p: { id: string; name: string; root?: string; registered: boolean }, costUSD: number) => ({
  id: p.id, name: p.name, root: p.root!, registered: p.registered, costUSD, apportionedUSD: 0, tokens, sessions: 1, unbilledSessions: 0,
});
const usage: UsageDaily = {
  ok: true, timeZone: "UTC", from: "2026-08-19", to: "2026-09-17", refreshedAt: NOW, recordedSessions: 4, days: [],
  totals: { costUSD: 2316.83, apportionedUSD: 0, tokens, sessions: 4, unbilledSessions: 0 },
  projects: [
    bucket(kitterm, 926.21),
    bucket(mdp, 30.91),
    bucket(mt5, 2.29),
    // Sessions in the workspace directory itself, which the workspace's line sums in.
    bucket({ id: "nnt", name: "NgheNhanTrading", root: NNT, registered: false }, 1216.03),
  ],
};

const projects = [kitterm, mdp, mt5];
const allRows = [rows.root, rows.blocked, rows.idle, rows.crew];

/** A line as one row of the frame: depth, name, the state word, and each
 * fact as `text@column`, with a `!` on the fact a phone keeps. */
const shape = (line: TreeLine<ModelRow>): [number, string, string | null, string[]] => [
  line.depth, line.kind === "fold" ? `▸ ${line.name}` : line.name, line.state?.tag ?? null,
  line.facts.map((f) => `${f.text}@${f.column}${f.narrow ? "!" : ""}`),
];

describe("the fact columns of each level", () => {
  it("put a goal's cost in column 2 and its counter in column 4, or the counter alone in column 2", () => {
    expect(goalFactColumns("$75.11", "r6/3").map((f) => [f.kind, f.text, f.column, f.narrow])).toEqual([["cost", "$75.11", 2, true], ["counter", "r6/3", 4, false]]);
    expect(goalFactColumns(null, "r0/3").map((f) => [f.kind, f.text, f.column, f.narrow])).toEqual([["counter", "r0/3", 2, true]]);
    expect(goalFactColumns("$1.00", null).map((f) => [f.kind, f.column, f.narrow])).toEqual([["cost", 2, true]]);
    expect(goalFactColumns(null, null)).toEqual([]);
  });

  it("put a task's round in column 2 and its PR in column 3, a session's model in column 2 and its time in column 4, a heading's cost in column 2 and its agents in column 4", () => {
    expect(taskFactColumns(6, 124).map((f) => [f.text, f.column, f.narrow])).toEqual([["round 6", 2, true], ["PR #124", 3, false]]);
    expect(taskFactColumns(undefined, undefined)).toEqual([]);
    expect(sessionFactColumns("Fable 5.1", "claude-fable-5-1", "4m").map((f) => [f.text, f.column, f.narrow, f.title])).toEqual([
      ["Fable 5.1", 2, false, "claude-fable-5-1"], ["4m", 4, true, undefined],
    ]);
    expect(sessionFactColumns(null, undefined, null)).toEqual([]);
    expect(headingFactColumns("$926.21", "1 agent", "kitterm").map((f) => [f.text, f.column, f.narrow])).toEqual([["$926.21", 2, true], ["1 agent", 4, false]]);
    expect(headingFactColumns(null, null, "x")).toEqual([]);
  });
});

describe("the tree over a fleet shaped like the frame", () => {
  const built = tree({ rows: allRows, projects, goalsOf: (id) => knowledge[id], approvals: [approval], proposed: [], usage, now: NOW });

  it("is one section per lone project or workspace, with the idle shell apart", () => {
    expect(built.sections.map((s) => [s.key, s.label])).toEqual([["kitterm", "kitterm"], [`workspace:${NNT}`, "NgheNhanTrading"]]);
    expect(built.idle.map((r) => r.id)).toEqual(["s-idle"]);
  });

  it("draws kitterm as the frame does: the project, its sessions, the waiting goal with its tasks, the last done goal open with two tasks, the rest folded", () => {
    const [section] = built.sections;
    expect(section.lines.map(shape)).toEqual([
      [0, "kitterm", null, ["$926.21@2!", "1 agent@4"]],
      [1, "review", "[needs you]", ["1m@4!"]],
      [1, "kitterm", "[working]", ["4m@4!"]],
      [1, "agent-dashboard", "[waiting]", ["r0/3@2!"]],
      [2, "no-input-on-the-page", "[pending]", []],
      [2, "the-foundation-in-the-stylesheet", "[pending]", []],
      [2, "a-task-is-the-fourth-level", "[pending]", []],
      [2, "others-not-a-count", "[done]", ["round 9@2!", "PR #133@3"]],
      [2, "models-top-three", "[done]", ["round 8@2!", "PR #132@3"]],
      [1, "workspace-ledger", "[done]", ["$75.11@2!", "r6/3@4"]],
      [2, "the-strip-holds-only-what-needs-you", "[done]", ["round 6@2!", "PR #124@3"]],
      [2, "the-numbers-on-the-page", "[done]", ["round 5@2!", "PR #123@3"]],
      [1, "▸ 2 done", null, []],
    ]);
    const fold = section.lines[section.lines.length - 1];
    expect(fold.kind === "fold" && fold.lines.map(shape)).toEqual([
      [1, "fleet-catch-up", "[done]", ["$35.79@2!", "r4/4@4"]],
      [1, "cost-per-round", "[done]", ["r4/4@2!"]],
    ]);
    const project = section.lines[0];
    expect(project.kind === "project" && project.working).toBe(true);
    const blocked = section.lines[1];
    expect(blocked.kind === "session" && [blocked.needs, blocked.approvals.map((a) => a.id), blocked.mark]).toEqual([false, ["a-1"], "attention"]);
    const waiting = section.lines[3];
    expect(waiting.kind === "goal" && [waiting.mark, waiting.state?.family, waiting.href, waiting.title]).toEqual([
      "attention", "attention", "/api/projects/kitterm/knowledge/agent-dashboard/STATE.md", "Round 10, `the-page-is-the-pen-design`.",
    ]);
    const done = section.lines[9];
    expect(done.kind === "goal" && [done.mark, done.href]).toEqual(["pending", "/api/projects/kitterm/knowledge/workspace-ledger/rounds/006.md"]);
  });

  it("draws the workspace as the frame does: its cost and agents, the project's done goal open with the crew under it, and a project with no goal", () => {
    const [, section] = built.sections;
    expect(section.lines.map(shape)).toEqual([
      [0, "NgheNhanTrading", null, ["$1,249.23@2!", "1 agent@4"]],
      [1, "market-data-pipeline", null, ["$30.91@2!", "1 agent@4"]],
      [2, "one command onboards a symbol", "[done]", ["$41.02@2!", "r6/3@4"]],
      [3, "path-mapping", "[done]", ["round 6@2!", "PR #40@3"]],
      [3, "path-mapping-real-terminal", "[working]", ["Fable 5.1@2", "4m@4!"]],
      [1, "nghenhan-mt5", null, ["$2.29@2!"]],
    ]);
    const crew = section.lines[4];
    expect(crew.kind === "session" && crew.title).toBe(`Mapping the path\n${mdp.root}/.claude/worktrees/x`);
    const empty = section.lines[5];
    expect(empty.kind === "project" && [empty.working, empty.title]).toEqual([false, `${mt5.root}\nno goal folder`]);
  });

  it("gives an approval whose session is gone a line under No project, and draws nothing for no fleet", () => {
    const orphan = { ...approval, id: "a-2", session: "gone" };
    const out = tree({ rows: allRows, projects, goalsOf: (id) => knowledge[id], approvals: [orphan], proposed: [], usage, now: NOW });
    const none = out.sections[out.sections.length - 1];
    expect(none.label).toBe("No project");
    expect(none.lines.map((l) => [l.kind, l.depth, l.name])).toEqual([["project", 0, "No project"], ["approval", 1, "approve Bash"]]);
    expect(tree({ rows: [], projects: [], goalsOf: () => null, approvals: [], proposed: [], usage: null, now: NOW })).toEqual({ sections: [], idle: [] });
  });
});

// --- the page --------------------------------------------------------------

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: allRows },
  "/api/projects": { projects },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: kittermGoals },
  "/api/projects/mdp/knowledge": { ok: true, project: "mdp", goals: mdpGoals },
  "/api/projects/mt5/knowledge": { ok: true, project: "mt5", goals: [] },
  "/api/approvals": { approvals: [approval] },
  "/api/archives": { archives: [{ id: "arch-1", name: "old", cwd: kitterm.root, archivedAt: NOW, project: ref(kitterm) }, { id: "arch-2", cwd: NNT }] },
  "/api/profiles": { profiles: [{ name: "box", command: "ssh box" }] },
  "/api/usage/daily": usage,
  "/api/usage/limits": { ok: true, hasReading: false },
};

let page: FakePage;

beforeAll(async () => {
  page = installFakePage(routes);
  await import("./sessions");
  await page.settle();
});

const cellsOf = (line: FakeElement) =>
  line.querySelector(".main")!.children.filter((c): c is FakeElement => typeof c !== "string").map((c) => `${c.className}=${c.textContent}${c.hasAttribute("data-col") ? `@${c.getAttribute("data-col")}` : ""}${c.hasAttribute("data-narrow") ? "!" : ""}`);

describe("the painted tree", () => {
  it("is flat lines in two sections, each line with its mark, its name and its fact cells in columns", () => {
    const sections = page.root.querySelector(".tree")!.querySelectorAll(".tree-section");
    expect(sections.map((s) => s.getAttribute("aria-label"))).toEqual(["kitterm", "NgheNhanTrading"]);
    const [kittermSection, workspace] = sections;
    const lines = kittermSection.querySelectorAll(".line").filter((l) => !l.classList.contains("line-approval"));
    expect(lines.map((l) => l.querySelector(".mark")?.className)).toEqual([
      "mark running", "mark attention", "mark running", "mark attention disclosure", "mark pending", "mark pending", "mark pending", "mark done", "mark done",
      "mark pending disclosure", "mark done", "mark done", "mark pending disclosure", "mark blank", "mark blank",
    ]);
    expect(cellsOf(lines[0])).toEqual(["line-name=kitterm", "cost=$926.21@2!", "agents=1 agent@4"]);
    expect(lines[0].querySelector(".line-name")?.tagName).toBe("H2");
    expect(cellsOf(lines[3])).toEqual(["line-name=agent-dashboard", "state attention=[waiting]", "counter=r0/3@2!"]);
    expect(cellsOf(lines[9])).toEqual(["line-name=workspace-ledger", "state idle=[done]", "cost=$75.11@2!", "counter=r6/3@4"]);
    expect(cellsOf(lines[10])).toEqual(["line-name=the-strip-holds-only-what-needs-you", "state done=[done]", "round=round 6@2!", "pr=PR #124@3"]);
    // The done fold: its summary is a line at the goal's indent, closed.
    const fold = kittermSection.querySelector(".fold")!;
    expect(fold.tagName).toBe("DETAILS");
    expect((fold as unknown as { open: boolean }).open).toBe(false);
    expect(fold.querySelector("summary")?.querySelector(".line-name")?.textContent).toBe("2 done");
    expect(fold.querySelector("summary")?.querySelector(".mark")?.textContent).toBe("▸");
    expect(fold.querySelectorAll(".goal-line").map((g) => g.querySelector(".line-name")?.textContent)).toEqual(["fleet-catch-up", "cost-per-round"]);
    // The workspace: an h2 over h3 projects, the crew under the done goal.
    const heads = workspace.querySelectorAll(".line-name").filter((n) => n.tagName === "H2" || n.tagName === "H3");
    expect(heads.map((h) => [h.tagName, h.textContent])).toEqual([["H2", "NgheNhanTrading"], ["H3", "market-data-pipeline"], ["H3", "nghenhan-mt5"]]);
    const crew = workspace.querySelectorAll(".row-line")[0];
    expect(cellsOf(crew)).toEqual(["folder line-name=path-mapping-real-terminal", "state running=[working]", "model=Fable 5.1@2", "since=4m@4!"]);
  });

  it("draws no card, no heading chrome, no profile select and no dropping fact in the tree", () => {
    for (const cls of [".card", ".workspace", ".head", ".tally", ".nested", ".goal-lines", ".tree-tasks", ".spawn-profile", ".goal-proposals", ".done-tasks"]) {
      expect(page.root.querySelectorAll(cls), cls).toEqual([]);
    }
    expect(page.root.querySelectorAll("select")).toEqual([]);
    expect(page.root.textContent).not.toContain("no live session");
    expect(page.root.textContent).not.toContain("no goal folder");
    expect(page.root.querySelector(".tree")!.querySelectorAll("[data-drop]").map((d) => d.textContent), "only an approval's arguments drop").toEqual(["swift test"]);
  });

  it("puts every action in the actions cell as quiet text: [new] on a project, ⋯ on a session, the answers on an approval", () => {
    const project = page.root.querySelectorAll(".line-project")[0];
    expect(project.querySelector(".actions")?.querySelectorAll("button").map((b) => [b.className, b.textContent])).toEqual([["quiet spawn-button", "new"]]);
    const row = page.root.querySelectorAll(".row-line")[0];
    expect(row.querySelector(".actions")?.querySelectorAll("button").map((b) => b.textContent)).toEqual(["⋯", "Rename", "Archive", "Kill"]);
    const approvalLine = page.root.querySelector(".line-approval")!;
    expect(approvalLine.querySelector(".actions")?.querySelectorAll("a").map((a) => a.textContent)).toEqual(["Open the pane"]);
    expect(approvalLine.querySelector(".actions")?.querySelectorAll("button").map((b) => b.textContent)).toEqual(["Deny", "Allow"]);
    expect(approvalLine.getAttribute("data-needs")).toBe("approval");
    // A goal name opens its record or its STATE.md in a new tab.
    const goal = page.root.querySelectorAll(".goal-line")[0];
    expect(goal.querySelector(".line-name")?.href).toBe("/api/projects/kitterm/knowledge/agent-dashboard/STATE.md");
  });

  it("folds the archives and the idle shells at the page's foot beside the push switch, and lists the idle shell as a row there", () => {
    const folds = page.root.querySelector(".folds")!;
    const children = folds.children.filter((c): c is FakeElement => typeof c !== "string");
    expect(children.map((c) => `${c.tagName.toLowerCase()}.${c.className}`)).toEqual(["details.fold", "details.fold", "p.push"]);
    expect(children.map((c) => c.querySelector(".line-name")?.textContent ?? c.querySelector(".push-switch")?.textContent)).toEqual(["Archived (2)", "1 idle shell", "Notify this deviceoff"]);
    expect(children[0].querySelectorAll(".archived-name").map((n) => n.textContent)).toEqual(["old", "NgheNhanTrading"]);
    const idle = children[1].querySelectorAll(".row-line");
    expect(idle).toHaveLength(1);
    expect(cellsOf(idle[0])).toEqual(["folder line-name=kitterm", "state idle=[idle]", "since=1h@4!"]);
    expect(idle[0].querySelector(".open")?.href).toBe("/?session=s-idle");
    // Every session is on the page once.
    const links = page.root.querySelectorAll(".row").flatMap((row) => row.querySelectorAll(".open").map((a) => a.href));
    expect([...links].sort()).toEqual(["s-blocked", "s-crew", "s-idle", "s-root"].map((id) => `/?session=${id}`));
  });

  it("prints the vocabulary under SESSIONS and puts the band's need-you link on the first marked line", () => {
    expect(page.root.querySelector(".tree-head")?.querySelector(".tree-label")?.textContent).toBe("SESSIONS");
    expect(page.root.querySelector('[id="needs-you"]')?.className).toBe("line line-approval");
    expect(page.root.querySelectorAll(".band-cell").find((c) => c.classList.contains("needs"))?.tagName).toBe("A");
  });
});
